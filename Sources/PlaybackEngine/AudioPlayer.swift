import AVFoundation
import Foundation
import MediaPlayer
import MusicCore
import Observation
import os

/// Plays one song with precise seeking, pitch-preserving speed change and gapless looping.
///
/// Graph: `AVAudioPlayerNode ─┐
///         metronome source ──┴→ mixer → AVAudioUnitTimePitch → mainMixer`.
/// The metronome renders in song frames next to the player, so its clicks follow seeks, loops
/// and speed changes exactly. The player node always renders
/// source frames, so its sample time maps directly to a file position through `PlaybackPosition`,
/// whatever the speed. Loops are gapless because the next two iterations are always queued ahead.
///
/// UI reads `currentTime` every frame (e.g. from a `TimelineView`); it is computed from the audio
/// clock, not stored, so observation is not triggered at frame rate.
@MainActor
@Observable
public final class AudioPlayer {
    public private(set) var isLoaded = false
    public private(set) var isPlaying = false
    public private(set) var duration: Seconds = 0
    public private(set) var rate: Double = 1
    public private(set) var loop: LoopRegion?
    public private(set) var loopEnabled = false
    public private(set) var lastError: String?
    public private(set) var metronomeEnabled = false
    public private(set) var countInEnabled = false
    /// Whether a beat grid is available (metronome and count-in need one).
    public private(set) var hasBeatGrid = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let songMixer = AVAudioMixerNode()
    @ObservationIgnored private var clickNode: AVAudioSourceNode?
    @ObservationIgnored private let metronome = MetronomeBox()
    @ObservationIgnored private var beatTimes: [Seconds] = []
    @ObservationIgnored private var barTimes: [Seconds] = []
    /// Silent frames before the first scheduled segment (the count-in).
    @ObservationIgnored private var leadFrames: Int64 = 0
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var sampleRate: Double = 44_100
    @ObservationIgnored private var fileLength: Int64 = 0
    @ObservationIgnored private var startFrame: Int64 = 0
    @ObservationIgnored private var pausedFrame: Int64 = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var practiceAccumulator: Double = 0
    @ObservationIgnored private var nowPlayingTitle = ""
    @ObservationIgnored private var nowPlayingArtist: String?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.thiagomendes.riffnex", category: "playback")

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(songMixer)
        observeSystemEvents()
        configureRemoteCommands()
    }

    // MARK: Loading

    public func load(url: URL, title: String, artist: String?) throws {
        stopInternal()
        if engine.isRunning { engine.stop() }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(songMixer)
        engine.disconnectNodeOutput(timePitch)
        if let old = clickNode {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
        }
        metronome.reset(sampleRate: format.sampleRate)
        let click = metronome.makeNode(format: format)
        engine.attach(click)
        clickNode = click
        // iOS 27 replaced the non-throwing connect/play with throwing variants that report failures.
        // Mixer inputs: each connection takes the next free input bus.
        try engine.connectNode(player, to: songMixer, format: format)
        try engine.connectNode(click, to: songMixer, format: format)
        try engine.connectNode(songMixer, to: timePitch, format: format)
        try engine.connectNode(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()

        self.file = file
        sampleRate = format.sampleRate
        fileLength = file.length
        duration = Double(fileLength) / sampleRate
        pausedFrame = 0
        startFrame = 0
        loop = nil
        loopEnabled = false
        practiceAccumulator = 0
        leadFrames = 0
        beatTimes = []
        barTimes = []
        hasBeatGrid = false
        nowPlayingTitle = title
        nowPlayingArtist = artist
        isLoaded = true
        lastError = nil
        updateNowPlaying()
        log.info("Loaded \(url.lastPathComponent, privacy: .public): \(self.duration, privacy: .public)s")
    }

    public func unload() {
        stopInternal()
        if engine.isRunning { engine.stop() }
        file = nil
        isLoaded = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Transport

    /// Current position in seconds, compensated for output latency so it matches what is heard.
    public var currentTime: Seconds {
        guard isLoaded, sampleRate > 0 else { return 0 }
        return Double(currentFrame(compensated: true)) / sampleRate
    }

    public func play() {
        guard isLoaded, !isPlaying else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
        } catch {
            lastError = "Não foi possível iniciar o áudio: \(error.localizedDescription)"
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if pausedFrame >= fileLength { pausedFrame = 0 }
        if loopEnabled, let loop, !loop.contains(Double(pausedFrame) / sampleRate),
           Double(pausedFrame) / sampleRate >= loop.end {
            pausedFrame = frame(for: loop.start)
        }
        schedule(from: pausedFrame, countIn: countInEnabled)
        guard startNode() else { return }
        isPlaying = true
        playStartedAt = ContinuousClock.now
        updateNowPlaying()
    }

    public func pause() {
        guard isPlaying else { return }
        pausedFrame = currentFrame(compensated: true)
        haltPlayer()
        isPlaying = false
        accumulatePractice()
        updateNowPlaying()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func seek(to seconds: Seconds) {
        guard isLoaded else { return }
        let target = frame(for: seconds)
        if isPlaying {
            schedule(from: target)
            if !startNode() { isPlaying = false }
        } else {
            pausedFrame = target
        }
        updateNowPlaying()
    }

    public func skip(by seconds: Seconds) {
        seek(to: currentTime + seconds)
    }

    public func setRate(_ newRate: Double) {
        let clamped = min(max(newRate, 0.25), 1.25)
        rate = clamped
        timePitch.rate = Float(clamped)
        updateNowPlaying()
    }

    /// Sets (or clears) the loop region. While playing inside the region, playback continues seamlessly.
    public func setLoop(_ region: LoopRegion?) {
        loop = region
        if region == nil { loopEnabled = false }
        rescheduleIfPlaying()
    }

    public func setLoopEnabled(_ enabled: Bool) {
        guard loop != nil || !enabled else { return }
        loopEnabled = enabled
        if enabled, let loop, !loop.contains(currentTime) {
            seek(to: loop.start)
        } else {
            rescheduleIfPlaying()
        }
    }

    // MARK: Metronome

    /// Beat and bar times (seconds) from the analysis; without them the metronome stays off.
    public func setBeatGrid(beats: [Seconds], bars: [Seconds]) {
        beatTimes = beats
        barTimes = bars
        hasBeatGrid = beats.count >= 2
        metronome.setGrid(MetronomeRenderer.Grid(beatTimes: beats, barTimes: bars, sampleRate: sampleRate))
        if !hasBeatGrid {
            setMetronomeEnabled(false)
            countInEnabled = false
        }
    }

    public func setMetronomeEnabled(_ enabled: Bool) {
        metronomeEnabled = enabled && hasBeatGrid
        metronome.setEnabled(metronomeEnabled)
    }

    public func setCountInEnabled(_ enabled: Bool) {
        countInEnabled = enabled && hasBeatGrid
    }

    /// While a count-in is sounding: beats left before the song starts (e.g. 4, 3, 2, 1).
    public var countInBeatsRemaining: Int? {
        guard isPlaying, leadFrames > 0, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        let remaining = leadFrames - playerTime.sampleTime
        guard remaining > 0, let interval = beatIntervalFrames, interval > 0 else { return nil }
        return Int((remaining + interval - 1) / interval)
    }

    private var beatIntervalFrames: Int64? {
        let intervals = zip(beatTimes.dropFirst(), beatTimes).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !intervals.isEmpty else { return nil }
        return Int64((intervals[intervals.count / 2] * sampleRate).rounded())
    }

    /// Beats in a bar, from the bar grid (defaults to 4).
    private var beatsPerBar: Int {
        guard barTimes.count >= 2 else { return 4 }
        let first = barTimes[0]
        let second = barTimes[1]
        let count = beatTimes.filter { $0 >= first - 0.03 && $0 < second - 0.03 }.count
        return (2...7).contains(count) ? count : 4
    }

    /// Wall-clock seconds spent playing since the last call. Includes the current run if playing.
    public func takePracticedSeconds() -> Double {
        if isPlaying { accumulatePractice(); playStartedAt = ContinuousClock.now }
        defer { practiceAccumulator = 0 }
        return practiceAccumulator
    }

    // MARK: Scheduling

    private var activeFrameLoop: PlaybackPosition.FrameLoop? {
        guard loopEnabled, let loop else { return nil }
        let start = frame(for: loop.start)
        let end = frame(for: loop.end)
        return end > start ? PlaybackPosition.FrameLoop(start: start, end: end) : nil
    }

    private func frame(for seconds: Seconds) -> Int64 {
        PlaybackPosition.frame(for: seconds, sampleRate: sampleRate, fileLength: fileLength)
    }

    private func currentFrame(compensated: Bool) -> Int64 {
        guard isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return pausedFrame }
        var rendered = playerTime.sampleTime - leadFrames
        if compensated {
            // Audio rendered now is heard after the output latency; at speed r, the source advances r× faster.
            let session = AVAudioSession.sharedInstance()
            let latency = session.outputLatency + session.ioBufferDuration
            rendered -= Int64(latency * sampleRate * rate)
        }
        rendered = max(0, rendered) // during the count-in, stay at the start position
        return PlaybackPosition.fileFrame(renderedFrames: rendered, startFrame: startFrame,
                                          loop: activeFrameLoop, fileLength: fileLength)
    }

    private func haltPlayer() {
        generation += 1 // completion handlers from the old schedule become no-ops
        player.stop()
        metronome.stop()
    }

    private func rescheduleIfPlaying() {
        guard isPlaying else { return }
        let position = currentFrame(compensated: false)
        schedule(from: position)
        if !startNode() { isPlaying = false }
    }

    /// Starts the player node; on failure records the error and leaves playback stopped.
    private func startNode() -> Bool {
        do {
            try player.playAudio()
            return true
        } catch {
            haltPlayer()
            lastError = "Não foi possível tocar: \(error.localizedDescription)"
            log.error("playAudio failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func schedule(from frame: Int64, countIn: Bool = false) {
        guard let file else { return }
        haltPlayer()
        let current = generation
        startFrame = min(max(0, frame), fileLength)

        // Count-in: the metronome clicks one bar first; the song's first segment waits for it.
        var countInBeats = 0
        var interval: Int64 = 0
        if countIn, let beat = beatIntervalFrames, beat > 0 {
            countInBeats = beatsPerBar
            interval = beat
        }
        leadFrames = Int64(countInBeats) * interval
        metronome.start(at: startFrame, loop: activeFrameLoop.map { ($0.start, $0.end) },
                        countInBeats: countInBeats, interval: interval)
        let firstAt = leadFrames > 0 ? AVAudioTime(sampleTime: leadFrames, atRate: sampleRate) : nil

        if let loop = activeFrameLoop, startFrame < loop.end {
            scheduleSegment(file, from: startFrame, to: loop.end, at: firstAt, generation: current, onEnd: nil)
            enqueueLoopIteration(file, loop, generation: current)
            enqueueLoopIteration(file, loop, generation: current)
        } else {
            scheduleSegment(file, from: startFrame, to: fileLength, at: firstAt, generation: current) { [weak self] in
                self?.reachedEnd(generation: current)
            }
        }
    }

    private func enqueueLoopIteration(_ file: AVAudioFile, _ loop: PlaybackPosition.FrameLoop, generation current: Int) {
        scheduleSegment(file, from: loop.start, to: loop.end, generation: current) { [weak self] in
            // Keep two iterations queued so the loop never runs dry.
            guard let self, self.generation == current, let file = self.file else { return }
            self.enqueueLoopIteration(file, loop, generation: current)
        }
    }

    private func scheduleSegment(_ file: AVAudioFile, from start: Int64, to end: Int64, at when: AVAudioTime? = nil,
                                 generation current: Int, onEnd: (@MainActor () -> Void)?) {
        let count = end - start
        guard count > 0 else {
            onEnd?()
            return
        }
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(count), at: when,
                               completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                onEnd?()
            }
        }
    }

    private func reachedEnd(generation current: Int) {
        guard generation == current, isPlaying else { return }
        isPlaying = false
        pausedFrame = fileLength
        accumulatePractice()
        updateNowPlaying()
    }

    private func stopInternal() {
        if isPlaying {
            haltPlayer()
            isPlaying = false
            accumulatePractice()
        }
    }

    private func accumulatePractice() {
        guard let started = playStartedAt else { return }
        let elapsed = ContinuousClock.now - started
        practiceAccumulator += Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        playStartedAt = nil
    }

    // MARK: System events

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                // Another app or a call took the audio: pause and keep the position. We never auto-resume,
                // because a musician may not be ready to play when the interruption ends.
                if typeValue == AVAudioSession.InterruptionType.began.rawValue { self?.pause() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                // Headphones unplugged: pause instead of suddenly playing through the speaker.
                if reasonValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverFromEngineReset() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverFromEngineReset() }
        })
    }

    /// The engine stops itself when the hardware configuration changes. Resume from where we were.
    private func recoverFromEngineReset() {
        guard isLoaded else { return }
        let wasPlaying = isPlaying
        if wasPlaying {
            pausedFrame = currentFrame(compensated: true)
            haltPlayer()
            isPlaying = false
            accumulatePractice()
        }
        log.notice("Audio engine configuration changed; resuming=\(wasPlaying, privacy: .public)")
        if wasPlaying { play() }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard isLoaded else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
        ]
        if let nowPlayingArtist { info[MPMediaItemPropertyArtist] = nowPlayingArtist }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// Thread-safe holder of the metronome renderer, shared between the main actor (transport) and
/// the audio render thread. The lock is held only for the few microseconds a buffer takes.
final class MetronomeBox: @unchecked Sendable {
    private struct State {
        var renderer: MetronomeRenderer
        var scratch = [Float](repeating: 0, count: 4096)
    }

    private let lock = OSAllocatedUnfairLock(initialState: State(renderer: MetronomeRenderer(sampleRate: 44_100)))

    func reset(sampleRate: Double) {
        lock.withLock { $0 = State(renderer: MetronomeRenderer(sampleRate: sampleRate)) }
    }

    func setGrid(_ grid: MetronomeRenderer.Grid) { lock.withLock { $0.renderer.grid = grid } }
    func setEnabled(_ enabled: Bool) { lock.withLock { $0.renderer.enabled = enabled } }
    func stop() { lock.withLock { $0.renderer.stop() } }

    func start(at frame: Int64, loop: (Int64, Int64)?, countInBeats: Int, interval: Int64) {
        lock.withLock { state in
            state.renderer.start(at: frame, loop: loop.map { (start: $0.0, end: $0.1) },
                                 countInBeats: countInBeats, interval: interval)
        }
    }

    func makeNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] isSilence, _, frameCount, bufferList -> OSStatus in
            let count = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            // Unchecked: the closure touches the render buffers (non-Sendable pointers), synchronously.
            lock.withLockUnchecked { state in
                state.renderer.render(count, into: &state.scratch)
                var silent = true
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let channels = max(Int(buffer.mNumberChannels), 1)
                    for i in 0..<count {
                        let value = state.scratch[i]
                        if value != 0 { silent = false }
                        for c in 0..<channels { data[i * channels + c] = value }
                    }
                }
                isSilence.pointee = ObjCBool(silent)
            }
            return noErr
        }
    }
}
