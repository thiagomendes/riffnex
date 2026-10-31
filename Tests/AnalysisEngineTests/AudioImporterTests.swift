import AVFoundation
import Foundation
import Testing
@testable import AnalysisEngine

/// Writes a mono 16-bit WAV of a sine tone named `name`.
private func makeWav(named name: String, seconds: Double, frequency: Double = 330) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    let sampleRate = 22_050.0
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(frames) {
        // Louder in the second half, so the waveform has a measurable shape.
        let gain: Float = Double(i) < Double(frames) / 2 ? 0.2 : 0.8
        data[i] = gain * Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
    return url
}

@Suite("AudioImporter")
struct AudioImporterTests {
    @Test func importsValidFile() async throws {
        let source = try makeWav(named: "My_Test_Riff.wav", seconds: 6)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: folder)
        }

        let imported = try await AudioImporter.importAudio(from: source, into: folder)
        #expect(imported.audioFileName == "audio.wav")
        #expect(imported.inspection.title == "My Test Riff")
        #expect(imported.inspection.artist == nil)
        #expect(abs(imported.inspection.duration - 6) < 0.05)
        #expect(imported.waveform.peaks.count == AudioImporter.waveformBuckets)
        #expect(imported.waveform.peaks.max() == 1)
        // Second half is 4× louder than the first.
        let firstHalf = imported.waveform.peaks.prefix(250).max() ?? 0
        #expect(firstHalf > 0.2 && firstHalf < 0.3, "first-half peak \(firstHalf)")

        let copy = folder.appendingPathComponent("audio.wav")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try copy.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try AudioImporter.contentHash(of: copy) == AudioImporter.contentHash(of: source))
    }

    @Test func rejectsTooShortAndCleansUp() async throws {
        let source = try makeWav(named: "short.wav", seconds: 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        await #expect(throws: AudioImporter.ImportError.self) {
            _ = try await AudioImporter.importAudio(from: source, into: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func rejectsNonAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.mp3")
        try Data("this is not audio".utf8).write(to: url)
        await #expect(throws: AudioImporter.ImportError.self) {
            _ = try await AudioImporter.inspect(url)
        }
    }

    @Test func hashDistinguishesFiles() throws {
        let a = try makeWav(named: "a.wav", seconds: 6, frequency: 330)
        let b = try makeWav(named: "b.wav", seconds: 6, frequency: 440)
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        let hashA = try AudioImporter.contentHash(of: a)
        #expect(hashA.count == 64)
        #expect(hashA != (try AudioImporter.contentHash(of: b)))
    }

    @Test func fallbackTitles() {
        #expect(AudioImporter.fallbackTitle(for: URL(fileURLWithPath: "/x/Minha_Musica.mp3")) == "Minha Musica")
        #expect(AudioImporter.fallbackTitle(for: URL(fileURLWithPath: "/x/_.mp3")) == "Sem título")
    }
}
