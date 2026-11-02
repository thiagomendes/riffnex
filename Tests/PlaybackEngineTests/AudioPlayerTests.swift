import AVFoundation
import Foundation
import MusicCore
import Testing
@testable import PlaybackEngine

private func makeTone(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("player-\(UUID().uuidString).caf")
    let sampleRate = 44_100.0
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for channel in 0..<2 {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) { data[i] = 0.2 * Float(sin(2 * .pi * 220 * Double(i) / sampleRate)) }
    }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    return url
}

@Suite("AudioPlayer", .serialized)
@MainActor
struct AudioPlayerTests {
    @Test func loadReportsDuration() throws {
        let url = try makeTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        try player.load(url: url, title: "Tom", artist: nil)
        #expect(player.isLoaded)
        #expect(abs(player.duration - 3) < 0.001)
        #expect(player.currentTime == 0)
        #expect(!player.isPlaying)
    }

    @Test func seekWhilePausedIsExactAndClamped() throws {
        let url = try makeTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        try player.load(url: url, title: "Tom", artist: nil)
        player.seek(to: 1.25)
        #expect(abs(player.currentTime - 1.25) < 0.0001)
        player.seek(to: 99)
        #expect(abs(player.currentTime - 3) < 0.0001)
        player.seek(to: -5)
        #expect(player.currentTime == 0)
    }

    @Test func rateIsClamped() throws {
        let url = try makeTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        try player.load(url: url, title: "Tom", artist: nil)
        player.setRate(0.1)
        #expect(player.rate == 0.25)
        player.setRate(2)
        #expect(player.rate == 1.25)
        player.setRate(0.7)
        #expect(player.rate == 0.7)
    }

    @Test func enablingLoopOutsideRegionJumpsToLoopStart() throws {
        let url = try makeTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        try player.load(url: url, title: "Tom", artist: nil)
        player.setLoopEnabled(true) // no loop yet: ignored
        #expect(!player.loopEnabled)

        let loop = try #require(LoopRegion(start: 1, end: 2, duration: player.duration))
        player.setLoop(loop)
        player.seek(to: 2.5)
        player.setLoopEnabled(true)
        #expect(player.loopEnabled)
        #expect(abs(player.currentTime - 1) < 0.0001)

        player.setLoop(nil)
        #expect(!player.loopEnabled)
    }

    @Test func reloadResetsState() throws {
        let a = try makeTone(seconds: 3)
        let b = try makeTone(seconds: 6)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let player = AudioPlayer()
        try player.load(url: a, title: "A", artist: nil)
        player.seek(to: 2)
        player.setLoop(LoopRegion(start: 0, end: 1, duration: 3))
        try player.load(url: b, title: "B", artist: "Artista")
        #expect(abs(player.duration - 6) < 0.001)
        #expect(player.currentTime == 0)
        #expect(player.loop == nil)
    }
}
