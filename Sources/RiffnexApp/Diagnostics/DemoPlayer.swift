import AVFoundation
import Foundation
import os

/// Minimal AVAudioEngine player used by the M0 diagnostics to prove the playback path works on
/// device and to measure the audio route's real latency. The full PlaybackEngine arrives in M1.
@MainActor
final class DemoPlayer {
    struct RouteReport: Sendable {
        let sampleRate: Double
        let ioBufferMs: Double
        let outputLatencyMs: Double
        let outputPort: String
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let log = Logger(subsystem: "com.thiagomendes.riffnex", category: "playback")
    private(set) var isPlaying = false

    init() {
        engine.attach(player)
    }

    func play(url: URL) throws -> RouteReport {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        let file = try AVAudioFile(forReading: url)
        try engine.connectNode(player, to: engine.mainMixerNode, format: file.processingFormat)
        player.stop()
        player.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor in self?.isPlaying = false }
        }
        if !engine.isRunning { try engine.start() }
        try player.playAudio()
        isPlaying = true

        let port = session.currentRoute.outputs.first?.portName ?? "—"
        log.info("Playback started on \(port, privacy: .public)")
        return RouteReport(sampleRate: session.sampleRate,
                           ioBufferMs: session.ioBufferDuration * 1000,
                           outputLatencyMs: session.outputLatency * 1000,
                           outputPort: port)
    }

    func stop() {
        player.stop()
        engine.stop()
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
