import AVFoundation
import CoreML
import Foundation
import MusicCore
import MusicUnderstanding
import os

/// Prepares one song for practice, entirely on the device:
///
/// 1. **Separation** (Demucs `htdemucs_6s`) into six instruments, written as AAC files
///    (determinate progress: segments done / total). Music Understanding runs alongside it.
/// 2. **Measurement**: loudness envelopes of the guitar and of the rest of the band, and the
///    guitar attacks, measured directly on the separated audio.
///
/// Cancellation is cooperative and leaves nothing behind: stems go to the folder the caller
/// passes, and the caller keeps or discards it.
public actor RiffPreparer {
    public enum Stage: String, Sendable {
        case separating, measuring
    }

    public struct Update: Sendable, Equatable {
        public var stage: Stage
        /// 0…1, or `nil` when the stage cannot report real progress.
        public var fraction: Double?
    }

    public enum PreparationError: Error, LocalizedError {
        case tooShort
        case modelMissing

        public var errorDescription: String? {
            switch self {
            case .tooShort: "O áudio é curto demais."
            case .modelMissing: "O modelo de separação não está no app."
            }
        }
    }

    /// Envelope values per second stored in the map (drawing), and used to find attacks.
    public static let envelopeRate = 50.0
    static let attackRate = 100.0
    static let measureSampleRate = 11_025.0

    private static let log = Logger(subsystem: RXLog.subsystem, category: "prepare")
    private let separator: StemSeparator

    public init(separator: StemSeparator = StemSeparator()) {
        self.separator = separator
    }

    public func prepare(fileURL: URL, stemsDirectory: URL, directoryName: String, computeUnits: MLComputeUnits = .all,
                        onUpdate: @escaping @Sendable (Update) -> Void) async throws -> RiffMap {
        guard StemSeparator.isAvailable else { throw PreparationError.modelMissing }
        onUpdate(Update(stage: .separating, fraction: 0))
        async let understanding = Self.runMusicUnderstanding(fileURL: fileURL)

        let separation = try await separator.separate(fileURL: fileURL, into: stemsDirectory, computeUnits: computeUnits) { progress in
            onUpdate(Update(stage: .separating, fraction: progress.fraction))
        }
        try Task.checkCancellation()
        guard separation.duration > 1 else { throw PreparationError.tooShort }

        onUpdate(Update(stage: .measuring, fraction: 0))
        var drawn: [String: [Float]] = [:]
        var fine: [String: [Float]] = [:]
        var energy: [String: Double] = [:]
        let names = separation.stems.keys.sorted()
        for (index, name) in names.enumerated() {
            try Task.checkCancellation()
            guard let url = separation.stems[name] else { continue }
            try autoreleasepool {
                let mono = try AudioDecoder.decodeMono(url: url, sampleRate: Self.measureSampleRate).samples
                drawn[name] = RiffMapBuilder.rms(mono, sampleRate: Self.measureSampleRate, rate: Self.envelopeRate)
                if ["guitar", "piano", "other"].contains(name) {
                    fine[name] = RiffMapBuilder.rms(mono, sampleRate: Self.measureSampleRate, rate: Self.attackRate)
                }
                let sumOfSquares = mono.reduce(Float(0)) { $0 + $1 * $1 }
                energy[name] = mono.isEmpty ? 0 : Double(sumOfSquares) / Double(mono.count)
            }
            onUpdate(Update(stage: .measuring, fraction: Double(index + 1) / Double(names.count)))
        }

        let guitarStems = RiffMapBuilder.guitarStems(energy: energy)
        let guitarDrawn = RiffMapBuilder.combine(guitarStems.compactMap { drawn[$0] })
        let bandDrawn = RiffMapBuilder.combine(names.filter { !guitarStems.contains($0) }.compactMap { drawn[$0] })
        let (guitar, band) = RiffMapBuilder.normalize(guitar: guitarDrawn, band: bandDrawn)
        let attacks = RiffMapBuilder.attacks(envelope: RiffMapBuilder.combine(guitarStems.compactMap { fine[$0] }),
                                             rate: Self.attackRate)

        let mu = await understanding
        var notes: [String] = []
        if let failure = mu.failure { notes.append("Tempo e compassos indisponíveis: \(failure)") }
        let beats = mu.result?.beats ?? []
        var bars = mu.result?.bars ?? []
        if bars.isEmpty, beats.count >= 8 { bars = RiffMapBuilder.bars(fromBeats: beats) }
        if guitarStems != ["guitar"] { notes.append("Guitarra somada com: \(guitarStems.filter { $0 != "guitar" }.joined(separator: ", "))") }

        let map = RiffMap(duration: separation.duration, beatsPerMinute: mu.result?.beatsPerMinute, beats: beats,
                          bars: bars, sections: mu.result?.sections ?? [], envelopeRate: Self.envelopeRate,
                          guitar: guitar, band: band, guitarAttacks: attacks, stemsDirectory: directoryName,
                          stemNames: names, guitarStems: guitarStems, separationSeconds: separation.seconds, notes: notes)
        Self.log.info("Prepared: \(separation.duration, privacy: .public)s, \(attacks.count) attacks, \(beats.count) beats, guitar = \(guitarStems, privacy: .public)")
        return map
    }

    struct UnderstandingOutcome: Sendable {
        var result: MusicUnderstandingResult?
        var failure: String?
    }

    static func runMusicUnderstanding(fileURL: URL) async -> UnderstandingOutcome {
        do {
            let asset = AVURLAsset(url: fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let session = try await MusicUnderstandingSession(asset: asset)
            let result = try await session.analyze(for: [.rhythm, .structure])
            let data = try JSONEncoder().encode(result)
            return UnderstandingOutcome(result: try MusicUnderstandingResult.decode(data), failure: nil)
        } catch is CancellationError {
            return UnderstandingOutcome(result: nil, failure: nil)
        } catch {
            log.error("Music Understanding failed: \(error.localizedDescription, privacy: .public)")
            return UnderstandingOutcome(result: nil, failure: error.localizedDescription)
        }
    }
}

extension MLComputeUnits {
    /// Stable identifiers for persistence and display.
    public var identifier: String {
        switch self {
        case .cpuOnly: "cpuOnly"
        case .cpuAndGPU: "cpuAndGPU"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        case .all: "all"
        @unknown default: "unknown"
        }
    }

    public init?(identifier: String) {
        switch identifier {
        case "cpuOnly": self = .cpuOnly
        case "cpuAndGPU": self = .cpuAndGPU
        case "cpuAndNeuralEngine": self = .cpuAndNeuralEngine
        case "all": self = .all
        default: return nil
        }
    }
}
