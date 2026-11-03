import Foundation
import MusicCore
import Observation
import Persistence
import PlaybackEngine
import UIKit

/// State of the practice screen for one prepared song: what you hear (focus), how fast, and
/// which riff is caught in the ring. Everything shown is something the app really knows:
/// laps played, the speed you chose, time practised.
@MainActor
@Observable
final class ArenaModel {
    /// +1 only the guitar, 0 everything, −1 the band without the guitar.
    private(set) var focus: Double = 0
    private(set) var speed: Double = 1
    private(set) var loop: LoopRegion?
    private(set) var laps = 0
    private(set) var ramping = false
    private(set) var lapsAtThisSpeed = 0
    private(set) var practicedSeconds: Double = 0

    nonisolated static let speedRange: ClosedRange<Double> = 0.4...1
    nonisolated static let rampStep = 0.05
    nonisolated static let lapsPerStep = 2

    let song: SongRecord
    let map: RiffMap
    let player: AudioPlayer
    /// Frame-rate visual state (particles, banners); not observed.
    @ObservationIgnored let fx = ArenaFX()

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastTime: Seconds = 0
    @ObservationIgnored private let lapHaptic = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let stepHaptic = UISelectionFeedbackGenerator()
    @ObservationIgnored private let bigHaptic = UIImpactFeedbackGenerator(style: .medium)

    init(song: SongRecord, map: RiffMap, app: AppModel) {
        self.song = song
        self.map = map
        self.app = app
        self.player = app.player
    }

    // MARK: Lifecycle

    func start() async {
        let stems = app.stemSources(for: song, map: map)
        do {
            try player.load(url: app.audioURL(for: song), title: song.title, artist: song.artist, stems: stems)
        } catch {
            return
        }
        let state = await app.studioState(for: song)
        practicedSeconds = state.practicedSeconds
        tuning = state.tuning.flatMap(TuningPreset.init(rawValue:)) ?? .standard
        tuningAnswered = state.tuningAnswered ?? false
        playShifted = (state.playShifted ?? false) && tuning.playableShift != nil
        player.setTranspose(semitones: shift)
        riffs = state.riffs ?? []
        setSpeed(Self.speedRange.contains(state.rate) ? state.rate : 1, haptic: false)
        if let saved = state.loop, state.loopEnabled {
            catchRiff(saved, animated: false)
        } else {
            player.seek(to: state.position)
        }
        applyFocus()
        lastTime = player.currentTime
        await refreshNeck()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() async {
        ticker?.cancel()
        ticker = nil
        player.pause()
        practicedSeconds += player.takePracticedSeconds()
        let state = StudioState(position: player.currentTime, rate: speed, loop: loop, loopEnabled: loop != nil,
                                practicedSeconds: practicedSeconds, tuning: tuning.rawValue, tuningAnswered: tuningAnswered,
                                playShifted: playShifted, riffs: riffs)
        await app.save(state, for: song)
        player.unload()
    }

    // MARK: Transport

    /// Notes guessed from the separated guitar, once read.
    var notes: NoteMap? { app.prep.notes[song.id] }
    var noteProgress: Double? { app.prep.noteProgress[song.id] }

    // MARK: Tuning

    /// The tuning the song was recorded in (as chosen for this song).
    private(set) var tuning: TuningPreset = .standard
    /// Play the song raised so it fits the guitar in `tuning.playableShift.target`.
    private(set) var playShifted = false
    /// The guessed notes placed on the neck for the tuning you play in.
    private(set) var neck: NeckNotes?
    /// What the guitar is built on, beat by beat (E5, G, Am…), as you hear it.
    private(set) var roots: [RootSpan] = []
    /// A suggested tuning, shown until the user answers it.
    private(set) var suggestion: TuningSuggestion?
    private(set) var tuningAnswered = false

    /// Semitones the song is raised by (0 unless playing shifted).
    var shift: Int { playShifted ? (tuning.playableShift?.semitones ?? 0) : 0 }
    /// The tuning your guitar should be in to follow the neck.
    var playingTuning: TuningPreset { playShifted ? (tuning.playableShift?.target ?? tuning) : tuning }

    /// The song's key as you hear it now.
    var key: SongKey? {
        guard var key = notes?.key else { return nil }
        key.tonic = key.tonic.transposed(by: shift)
        return key
    }

    /// Places the notes on the neck for the tuning you play in (off the main actor) and looks for a
    /// tuning suggestion. Called when the notes arrive or the tuning changes.
    func refreshNeck() async {
        guard let notes else { neck = nil; return }
        let semitones = shift
        let detected = notes.detected.map { note -> DetectedNote in
            var note = note
            note.midi += semitones
            return note
        }
        let preset = playingTuning
        let beats = map.beats, duration = map.duration
        let (placed, track) = await Task.detached(priority: .userInitiated) {
            (NoteMapBuilder.arrange(detected, tuning: preset.tuning), RootTrack.build(detected, beats: beats, duration: duration))
        }.value
        guard preset == playingTuning, semitones == shift else { return }
        neck = placed
        roots = track
        if !tuningAnswered, let found = TuningDetector.suggest(notes.detected), found.preset != tuning {
            suggestion = found
        } else {
            suggestion = nil
        }
    }

    /// Sets the song's tuning and whether to raise it to the standard equivalent.
    func choose(_ preset: TuningPreset, shifted: Bool = false) {
        tuningAnswered = true
        suggestion = nil
        let shifted = shifted && preset.playableShift != nil
        guard preset != tuning || shifted != playShifted else { return }
        tuning = preset
        playShifted = shifted
        player.setTranspose(semitones: shift)
        neck = nil
        stepHaptic.selectionChanged()
        Task { await refreshNeck() }
    }

    /// The detector's opinion even after it was answered (to mark it in the tuning list).
    var detectedSuggestion: TuningSuggestion? {
        notes.flatMap { TuningDetector.suggest($0.detected) }
    }

    func dismissSuggestion() {
        tuningAnswered = true
        suggestion = nil
    }

    // MARK: Saved riffs

    private(set) var riffs: [SavedRiff] = []

    /// Saves the riff in the ring under the next free name ("Riff 1", "Riff 2"…).
    @discardableResult
    func saveRiff() -> SavedRiff? {
        guard let loop, !riffs.contains(where: { $0.region == loop }) else { return nil }
        var number = riffs.count + 1
        while riffs.contains(where: { $0.name == "Riff \(number)" }) { number += 1 }
        let riff = SavedRiff(name: "Riff \(number)", region: loop)
        riffs.append(riff)
        riffs.sort { $0.region.start < $1.region.start }
        bigHaptic.impactOccurred()
        return riff
    }

    var currentRiffIsSaved: Bool { loop.map { l in riffs.contains { $0.region == l } } ?? false }

    func play(_ riff: SavedRiff) {
        catchRiff(riff.region)
    }

    func rename(_ riff: SavedRiff, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = riffs.firstIndex(of: riff) else { return }
        riffs[index].name = String(trimmed.prefix(24))
    }

    func delete(_ riff: SavedRiff) {
        riffs.removeAll { $0.id == riff.id }
    }

    var isPlaying: Bool { player.isPlaying }
    var currentTime: Seconds { player.currentTime }
    var duration: Seconds { player.duration }

    func togglePlay() {
        player.togglePlayPause()
        lastTime = player.currentTime
    }

    func pause() { player.pause() }

    func seek(to time: Seconds) {
        player.seek(to: min(max(0, time), duration))
        lastTime = player.currentTime
    }

    /// Back to the start of the caught riff, or of the song.
    func restart() {
        seek(to: loop?.start ?? 0)
        stepHaptic.selectionChanged()
    }

    // MARK: Focus

    /// Any mix between the three stops; a light tick when passing one of them.
    func setFocus(_ value: Double) {
        let new = min(max(value, -1), 1)
        if [1.0, 0, -1].contains(where: { ($0 - focus) * ($0 - new) < 0 || ($0 == new && $0 != focus) }) {
            stepHaptic.selectionChanged()
        }
        focus = new
        applyFocus()
    }

    /// Lands exactly on a stop only when released right next to it; otherwise the mix stays as set.
    @discardableResult
    func settleFocus() -> Double? {
        guard let stop = [1.0, 0, -1].first(where: { abs($0 - focus) < 0.06 }) else { return nil }
        setFocus(stop)
        return stop
    }

    nonisolated static func guitarLevel(_ focus: Double) -> Double { focus >= 0 ? 1 : 1 + focus }
    nonisolated static func bandLevel(_ focus: Double) -> Double { focus <= 0 ? 1 : 1 - focus }

    private func applyFocus() {
        // Squared levels: loudness falls off evenly along the rail instead of all at the end.
        let guitar = Float(pow(Self.guitarLevel(focus), 2))
        let band = Float(pow(Self.bandLevel(focus), 2))
        for name in player.stemNames {
            player.setVolume(map.guitarStems.contains(name) ? guitar : band, forStem: name)
        }
    }

    // MARK: Speed

    func setSpeed(_ value: Double, haptic: Bool = true) {
        let clamped = (min(max(value, Self.speedRange.lowerBound), Self.speedRange.upperBound) * 100).rounded() / 100
        if haptic, (clamped * 20).rounded() != (speed * 20).rounded() { stepHaptic.selectionChanged() }
        speed = clamped
        player.setRate(clamped)
    }

    /// The speed button: 100 → 85 → 70 → 55 → 100.
    func cycleSpeed() {
        stopRamp()
        let steps = [1.0, 0.85, 0.7, 0.55]
        let index = steps.firstIndex { abs($0 - speed) < 0.01 } ?? -1
        setSpeed(steps[(index + 1) % steps.count])
    }

    func setRamping(_ on: Bool) {
        ramping = on
        lapsAtThisSpeed = 0
        if on {
            if speed >= 1 { setSpeed(0.6, haptic: false) }
            if !player.isPlaying { togglePlay() }
            fx.banner("\(Int((speed * 100).rounded()))%")
        }
    }

    func stopRamp() {
        if ramping { setRamping(false) }
    }

    // MARK: The ring

    /// Catches `region` in the ring: it repeats until released.
    func catchRiff(_ region: LoopRegion, animated: Bool = true) {
        loop = region
        laps = 0
        lapsAtThisSpeed = 0
        player.setLoop(region)
        player.setLoopEnabled(true)
        player.seek(to: region.start)
        lastTime = region.start
        fx.setRing(true, animated: animated)
        if animated { fx.shockwave = 1 }
        if animated {
            if speed > 0.7 { setSpeed(0.7, haptic: false) }
            if !player.isPlaying { togglePlay() }
            bigHaptic.impactOccurred()
        }
    }

    func releaseRiff() {
        stopRamp()
        player.setLoop(nil)
        loop = nil
        fx.setRing(false, animated: true)
    }

    /// A loop from a drag on the tape, snapped to beats (at least one beat long).
    func region(from a: Seconds, to b: Seconds) -> LoopRegion? {
        let lo = min(a, b), hi = max(a, b)
        let start = map.beats.isEmpty ? lo : map.beat(atOrBefore: lo + 0.01)
        var end = map.beats.isEmpty ? hi : map.snapToBeat(hi)
        let minimum = map.beatLength ?? 0.5
        if end - start < minimum { end = start + minimum }
        return LoopRegion(start: start, end: end, duration: duration)
    }

    // MARK: Frame tick

    private func tick() {
        let now = player.currentTime
        defer { lastTime = now }
        guard player.isPlaying else { return }
        var hits: [Seconds] = []
        if let loop, now < lastTime - loop.length / 2 {
            completedLap()
            hits = Array(map.attacks(after: lastTime, upTo: loop.end)) + Array(map.attacks(after: loop.start - 0.001, upTo: now))
        } else if now > lastTime, now - lastTime < 0.25 {
            hits = Array(map.attacks(after: lastTime, upTo: now))
        }
        guard !hits.isEmpty, Self.guitarLevel(focus) > 0.2 else { return }
        for t in hits.prefix(6) { fx.spark(strength: Double(map.guitarLevel(at: t))) }
    }

    private func completedLap() {
        laps += 1
        fx.lapPulse = 1
        lapHaptic.impactOccurred(intensity: 0.6)
        guard ramping else { return }
        lapsAtThisSpeed += 1
        guard lapsAtThisSpeed >= Self.lapsPerStep else { return }
        lapsAtThisSpeed = 0
        setSpeed(speed + Self.rampStep, haptic: false)
        bigHaptic.impactOccurred()
        if speed >= 1 {
            ramping = false
            fx.banner("VELOCIDADE REAL", burst: true)
        } else {
            fx.banner("\(Int((speed * 100).rounded()))%")
        }
    }
}

/// Frame-rate visual state shared between the model's tick and the canvas.
final class ArenaFX {
    struct Particle {
        var x, y, vx, vy, life, radius: Double
        var hot: Bool
    }

    /// Sparks waiting to be emitted at the playhead (the canvas knows where that is).
    var pendingSparks: [Double] = []
    var pendingBurst = false
    var particles: [Particle] = []
    var bannerText = ""
    var bannerLife = 0.0
    var shake = 0.0
    /// 0 = tape, 1 = ring; eases toward `ringTarget`.
    var ring = 0.0
    var ringTarget = 0.0
    /// The loop still being drawn while the ring unrolls after a release.
    var lastLoop: LoopRegion?
    /// 0 → 1 over the first second on screen: the tape lights up from the playhead outward.
    var entrance = 0.0
    /// 1 when a riff is caught, fading: a shockwave from the ring.
    var shockwave = 0.0
    /// 1 on every completed lap, fading: the speed meter flashes.
    var lapPulse = 0.0

    func setRing(_ on: Bool, animated: Bool) {
        ringTarget = on ? 1 : 0
        if !animated { ring = ringTarget }
    }

    func spark(strength: Double) { pendingSparks.append(strength) }

    func banner(_ text: String, burst: Bool = false) {
        bannerText = text
        bannerLife = 1
        shake = 0.6
        if burst { pendingBurst = true }
    }
}
