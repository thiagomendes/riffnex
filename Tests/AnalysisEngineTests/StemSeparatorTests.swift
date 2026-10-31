import AVFoundation
import Foundation
import Testing
@testable import AnalysisEngine

private enum SeparationFixtures {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let stft = repo.appendingPathComponent("Tests/Fixtures/demucs-stft.json")
    static let envelopes = repo.appendingPathComponent("Tests/Fixtures/demucs-demo-envelopes.json")
    static let demo = repo.appendingPathComponent("Sources/RiffnexApp/Resources/Demo/riffnex-demo.m4a")

    struct STFT: Decodable {
        let signal: [Float]
        let frames: Int
        let bins: [Int]
        let real: [[Float]]
        let imag: [[Float]]
        let roundTrip: [Float]
        let roundTripStride: Int
    }

    struct Envelopes: Decodable {
        let hopSeconds: Double
        let sources: [String: [Float]]
    }
}

@Suite("Demucs spectrogram")
struct DemucsSpectrogramTests {
    @Test func matchesTorchSTFT() throws {
        let fixture = try JSONDecoder().decode(SeparationFixtures.STFT.self, from: Data(contentsOf: SeparationFixtures.stft))
        let spectrogram = DemucsSpectrogram(nfft: 4096)
        let frames = spectrogram.frameCount(forSamples: fixture.signal.count)
        #expect(frames == fixture.frames)
        var real = [Float](repeating: 0, count: 2048 * frames)
        var imag = [Float](repeating: 0, count: 2048 * frames)
        fixture.signal.withUnsafeBufferPointer { signal in
            spectrogram.forward(signal, frames: frames, real: &real, imag: &imag)
        }
        var worst: Float = 0
        var peak: Float = 0
        for (row, bin) in fixture.bins.enumerated() {
            for t in 0..<frames {
                let dr = abs(real[bin * frames + t] - fixture.real[row][t])
                let di = abs(imag[bin * frames + t] - fixture.imag[row][t])
                worst = max(worst, dr, di)
                peak = max(peak, abs(fixture.real[row][t]), abs(fixture.imag[row][t]))
            }
        }
        print("[demucs stft] worst abs error \(worst), peak \(peak)")
        #expect(worst <= max(1e-3, peak * 1e-3))
    }

    @Test func inverseRoundTripsAndMatchesTorch() throws {
        let fixture = try JSONDecoder().decode(SeparationFixtures.STFT.self, from: Data(contentsOf: SeparationFixtures.stft))
        let spectrogram = DemucsSpectrogram(nfft: 4096)
        let n = fixture.signal.count
        let frames = spectrogram.frameCount(forSamples: n)
        var real = [Float](repeating: 0, count: 2048 * frames)
        var imag = [Float](repeating: 0, count: 2048 * frames)
        fixture.signal.withUnsafeBufferPointer { spectrogram.forward($0, frames: frames, real: &real, imag: &imag) }
        var back = [Float](repeating: 0, count: n)
        spectrogram.inverse(real: real, imag: imag, frames: frames, length: n, into: &back)
        let worstSelf = zip(back, fixture.signal).map { abs($0 - $1) }.max() ?? 0
        let worstTorch = fixture.roundTrip.enumerated().map { abs(back[$0.offset * fixture.roundTripStride] - $0.element) }.max() ?? 0
        print("[demucs istft] round trip error \(worstSelf), vs torch \(worstTorch)")
        #expect(worstSelf < 1e-3)
        #expect(worstTorch < 1e-3)
    }

    @Test func reflectPadding() {
        // torch reflect: [a b c d] → … c b | a b c d | c b …
        #expect(DemucsSpectrogram.reflect(-1, 4) == 1)
        #expect(DemucsSpectrogram.reflect(-2, 4) == 2)
        #expect(DemucsSpectrogram.reflect(4, 4) == 2)
        #expect(DemucsSpectrogram.reflect(5, 4) == 1)
        #expect(DemucsSpectrogram.reflect(2, 4) == 2)
    }
}

@Suite("Stem separation on the demo", .serialized)
struct StemSeparatorTests {
    @Test(.timeLimit(.minutes(10)))
    func separatesLikeTheReference() async throws {
        guard StemSeparator.isAvailable else {
            Issue.record("separation model not bundled")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stems-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let separator = StemSeparator()
        let result = try await separator.separate(fileURL: SeparationFixtures.demo, into: directory, computeUnits: .cpuOnly) { _ in }
        print("[separation] \(String(format: "%.1f", result.duration)) s of audio in \(String(format: "%.1f", result.seconds)) s; per segment \(result.segmentSeconds.map { String(format: "%.2f", $0) })")
        #expect(result.stems.count == 6)

        let reference = try JSONDecoder().decode(SeparationFixtures.Envelopes.self, from: Data(contentsOf: SeparationFixtures.envelopes))
        for (name, url) in result.stems.sorted(by: { $0.key < $1.key }) {
            let file = try AVAudioFile(forReading: url)
            #expect(abs(Double(file.length) / file.processingFormat.sampleRate - result.duration) < 0.1, "\(name) length")
            let envelope = try Self.envelope(file, hopSeconds: reference.hopSeconds)
            guard let expected = reference.sources[name] else { continue }
            let count = min(envelope.count, expected.count)
            let energy = expected.prefix(count).reduce(0, +) / Float(max(count, 1))
            let correlation = Self.correlation(Array(envelope.prefix(count)), Array(expected.prefix(count)))
            let level = (envelope.prefix(count).reduce(0, +) / Float(max(count, 1))) / max(energy, 1e-6)
            print("[separation] \(name): mean RMS ref \(String(format: "%.4f", energy)), level ratio \(String(format: "%.2f", level)), envelope correlation \(String(format: "%.3f", correlation))")
            // Sources that are actually present on the demo must follow the reference closely.
            if energy > 0.01 {
                #expect(correlation > 0.9, "\(name) correlation \(correlation)")
                #expect(level > 0.7 && level < 1.4, "\(name) level \(level)")
            }
        }
    }

    static func envelope(_ file: AVAudioFile, hopSeconds: Double) throws -> [Float] {
        let hop = AVAudioFrameCount(hopSeconds * file.processingFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: hop) else { return [] }
        var values: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: hop)
            guard buffer.frameLength == hop else { break }
            let channels = Int(buffer.format.channelCount)
            var sum: Float = 0
            for i in 0..<Int(hop) {
                var mono: Float = 0
                for c in 0..<channels { mono += buffer.floatChannelData![c][i] }
                mono /= Float(channels)
                sum += mono * mono
            }
            values.append((sum / Float(hop)).squareRoot())
        }
        return values
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 2 else { return 0 }
        let ma = a.reduce(0, +) / Float(a.count)
        let mb = b.reduce(0, +) / Float(b.count)
        var num: Float = 0, da: Float = 0, db: Float = 0
        for (x, y) in zip(a, b) {
            num += (x - ma) * (y - mb)
            da += (x - ma) * (x - ma)
            db += (y - mb) * (y - mb)
        }
        return num / max((da * db).squareRoot(), 1e-12)
    }
}

@Suite("Analysis with separation", .serialized)
struct SeparatedAnalysisTests {
    @Test(.timeLimit(.minutes(10)))
    func notesComeFromPitchedStems() async throws {
        guard StemSeparator.isAvailable else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stems-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AnalysisCoordinator()
        let analysis = try await coordinator.analyze(
            fileURL: SeparationFixtures.demo,
            options: .init(computeUnits: .cpuOnly, runMusicUnderstanding: false, stemsDirectory: directory)) { _ in }
        let stems = try #require(analysis.stems)
        print("[separated analysis] sources \(stems.noteSources), share \(stems.energyShare.mapValues { (($0 * 100).rounded()) / 100 }), notes \(analysis.notes.count), chords \(analysis.chords.compactMap { $0.chord?.symbol() }), timings \(analysis.timings.map { "\($0.stage)=\(String(format: "%.1f", $0.seconds))" })")
        #expect(stems.names.count == 6)
        #expect(!stems.noteSources.contains("vocals") && !stems.noteSources.contains("drums"))
        #expect(analysis.notes.count > 30)
        #expect(analysis.components.contains { $0.component == .stemSeparator })
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("guitar.m4a").path))
    }
}
