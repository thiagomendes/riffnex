import AVFoundation
import Foundation
import Testing
@testable import AnalysisEngine

/// Writes a stereo 16-bit WAV containing a harmonic tone, so tests never depend on bundled media.
/// The frame count is deliberately not a multiple of the decoder's chunk size, so the last read is partial.
private func makeToneFile(frequency: Double, seconds: Double, sampleRate: Double = 44_100) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tone-\(UUID().uuidString).wav")
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for channel in 0..<2 {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            // Fundamental plus two weaker harmonics, with a gentle decay: a rough plucked-string stand-in.
            let value = sin(2 * .pi * frequency * t)
                + 0.4 * sin(2 * .pi * 2 * frequency * t)
                + 0.2 * sin(2 * .pi * 3 * frequency * t)
            data[i] = Float(0.4 * value * exp(-t * 0.6))
        }
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    } // file closes when it goes out of scope
    return url
}

/// The decoder reports progress synchronously on the calling thread; a box keeps the closure @Sendable.
private final class ProgressBox: @unchecked Sendable {
    var value = 0.0
}

@Suite("AudioDecoder")
struct AudioDecoderTests {
    @Test func decodesWholeFileToMono22k() throws {
        let seconds = 3.37 // 148 617 frames at 44.1 kHz: ends with a partial chunk
        let url = try makeToneFile(frequency: 220, seconds: seconds)
        defer { try? FileManager.default.removeItem(at: url) }

        let lastProgress = ProgressBox()
        let result = try AudioDecoder.decodeMono(url: url, sampleRate: 22_050) { lastProgress.value = $0 }

        #expect(result.sourceChannels == 2)
        #expect(result.sourceSampleRate == 44_100)
        #expect(result.sampleRate == 22_050)
        // Resampling may trim or pad a few frames; anything beyond 1% means data was lost.
        #expect(abs(result.duration - seconds) < seconds * 0.01, "decoded \(result.duration)s of \(seconds)s")
        #expect(lastProgress.value > 0.99)
        #expect(result.samples.contains { $0 != 0 })
    }

    @Test func dominantFrequencySurvivesResampling() throws {
        let url = try makeToneFile(frequency: 220, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try AudioDecoder.decodeMono(url: url, sampleRate: 22_050)

        // Count rising zero crossings in a steady middle section. Harmonics add crossings within a period
        // only if they dominate; here the fundamental does, so crossings/second ≈ 220.
        let slice = result.samples[2_205..<(2_205 + 11_025)] // 0.5 s
        var crossings = 0
        var previous = slice.first!
        for sample in slice.dropFirst() {
            if previous < 0 && sample >= 0 { crossings += 1 }
            previous = sample
        }
        let hz = Double(crossings) / 0.5
        #expect(abs(hz - 220) < 6, "measured \(hz) Hz")
    }
}

@Suite("BasicPitchModel", .serialized)
struct BasicPitchModelTests {
    @Test func bundledModelIsPresent() {
        #expect(BasicPitchModel.bundledPackageURL() != nil)
    }

    @Test func compilesLoadsAndHearsTheRightPitch() async throws {
        let model = BasicPitchModel()
        let report = try await model.load(computeUnits: .cpuOnly)
        #expect(report.inputShape == [1, BasicPitchModel.Constants.windowSamples, 1])

        // A3 = 220 Hz = MIDI 57.
        let url = try makeToneFile(frequency: 220, seconds: 2.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try AudioDecoder.decodeMono(url: url, sampleRate: BasicPitchModel.Constants.sampleRate)
        var window = Array(decoded.samples.prefix(BasicPitchModel.Constants.windowSamples))
        window += [Float](repeating: 0, count: BasicPitchModel.Constants.windowSamples - window.count)

        let output = try await model.predictWindow(window)
        #expect(output.noteShape.last == BasicPitchModel.Constants.noteBins)
        #expect(output.onsetShape.last == BasicPitchModel.Constants.noteBins)
        #expect(output.contourShape.last == BasicPitchModel.Constants.contourBins)
        #expect(output.noteShape.count == 3 && output.noteShape[1] > 150, "frames per window: \(output.noteShape)")
        #expect(output.maxNoteActivation > 0.3, "max activation \(output.maxNoteActivation)")
        #expect(output.strongestMIDI == 57, "strongest MIDI \(output.strongestMIDI)")
    }
}
