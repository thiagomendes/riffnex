import AVFoundation
import Foundation
import MediaPlayer
import MusicCore
import Observation
import os

/// Plays one song with precise seeking, pitch-preserving speed change and gapless looping.
///
/// Graph: `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer`. The player node always renders
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

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
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
        engine.disconnectNodeOutput(timePitch)
        // iOS 27 replaced the non-throwing connect/play with throwing variants that report failures.
        try engine.connectNode(player, to: timePitch, format: format)
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
        schedule(from: pausedFrame)
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
        var rendered = playerTime.sampleTime
        if compensated {
            // Audio rendered now is heard after the output latency; at speed r, the source advances r× faster.
            let session = AVAudioSession.sharedInstance()
            let latency = session.outputLatency + session.ioBufferDuration
            rendered -= Int64(latency * sampleRate * rate)
        }
        return PlaybackPosition.fileFrame(renderedFrames: rendered, startFrame: startFrame,
                                          loop: activeFrameLoop, fileLength: fileLength)
    }

    private func haltPlayer() {
        generation += 1 // completion handlers from the old schedule become no-ops
        player.stop()
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

    private func schedule(from frame: Int64) {
        guard let file else { return }
        haltPlayer()
        let current = generation
        startFrame = min(max(0, frame), fileLength)

        if let loop = activeFrameLoop, startFrame < loop.end {
            scheduleSegment(file, from: startFrame, to: loop.end, generation: current, onEnd: nil)
            enqueueLoopIteration(file, loop, generation: current)
            enqueueLoopIteration(file, loop, generation: current)
        } else {
            scheduleSegment(file, from: startFrame, to: fileLength, generation: current) { [weak self] in
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

    private func scheduleSegment(_ file: AVAudioFile, from start: Int64, to end: Int64, generation current: Int,
                                 onEnd: (@MainActor () -> Void)?) {
        let count = end - start
        guard count > 0 else {
            onEnd?()
            return
        }
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(count), at: nil,
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
