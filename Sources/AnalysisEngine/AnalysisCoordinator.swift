import AVFoundation
import CoreML
import Foundation
import MusicCore
import MusicUnderstanding
import os

/// Runs the full on-device analysis of one song:
///
/// 1. **Decode** to mono 22 050 Hz (determinate progress: frames read).
/// 2. In parallel:
///    - **Music Understanding** — tempo, beats, bars, key, sections, instrument activity
///      (indeterminate: the framework reports no progress).
///    - **Basic Pitch** — windowed note inference (determinate: windows done / total).
/// 3. **Assemble** — note decoding, guitar clean-up, chords, sections, quality report (pure,
///    `AnalysisAssembler`).
///
/// Cancellation is cooperative and leaves no partial state: nothing is written here; the caller
/// persists the returned `SongAnalysis` atomically.
public actor AnalysisCoordinator {
    public enum Stage: String, Sendable, CaseIterable {
        case decoding, musicUnderstanding, notes, assembling
    }

    public struct Update: Sendable, Equatable {
        public var stage: Stage
        /// 0…1, or `nil` when the stage cannot report real progress.
        public var fraction: Double?
        public var detail: String?
    }

    public struct Options: Sendable {
        public var computeUnits: MLComputeUnits
        public var tuning: Tuning
        public var runMusicUnderstanding: Bool

        public init(computeUnits: MLComputeUnits = .all, tuning: Tuning = .standard, runMusicUnderstanding: Bool = true) {
            self.computeUnits = computeUnits
            self.tuning = tuning
            self.runMusicUnderstanding = runMusicUnderstanding
        }
    }

    public enum AnalysisError: Error, LocalizedError {
        case tooShort

        public var errorDescription: String? {
            switch self {
            case .tooShort: "O áudio é curto demais para analisar."
            }
        }
    }

    private static let log = Logger(subsystem: RXLog.subsystem, category: "analysis")
    private let model: BasicPitchModel

    public init(model: BasicPitchModel = BasicPitchModel()) {
        self.model = model
    }

    public static var musicUnderstandingVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "ios\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public func analyze(fileURL: URL, options: Options = Options(),
                        onUpdate: @escaping @Sendable (Update) -> Void) async throws -> SongAnalysis {
        let clock = ContinuousClock()
        var timings: [StageTiming] = []

        // 1. Decode.
        onUpdate(Update(stage: .decoding, fraction: 0))
        var start = clock.now
        let decoded = try AudioDecoder.decodeMono(url: fileURL, sampleRate: BasicPitchModel.Constants.sampleRate) { fraction in
            onUpdate(Update(stage: .decoding, fraction: fraction))
        }
        timings.append(StageTiming(stage: Stage.decoding.rawValue, seconds: (clock.now - start).seconds))
        guard decoded.samples.count > BasicPitchModel.Constants.windowSamples / 4 else { throw AnalysisError.tooShort }
        try Task.checkCancellation()
        let duration = decoded.duration

        // 2. Model preparation (first run compiles the model on device).
        start = clock.now
        try await model.load(computeUnits: options.computeUnits)
        timings.append(StageTiming(stage: "modelLoad", seconds: (clock.now - start).seconds))

        // 3. Music Understanding and Basic Pitch in parallel.
        let samples = decoded.samples
        let units = options.computeUnits
        let model = self.model
        async let understanding = Self.runMusicUnderstanding(fileURL: fileURL, enabled: options.runMusicUnderstanding,
                                                             onUpdate: onUpdate)
        let notesStart = clock.now
        let activations = try await Self.runBasicPitch(samples: samples, model: model, computeUnits: units,
                                                       onUpdate: onUpdate)
        timings.append(StageTiming(stage: Stage.notes.rawValue, seconds: (clock.now - notesStart).seconds))
        let mu = await understanding
        if let seconds = mu.seconds {
            timings.append(StageTiming(stage: Stage.musicUnderstanding.rawValue, seconds: seconds))
        }
        try Task.checkCancellation()

        // 4. Assemble.
        onUpdate(Update(stage: .assembling, fraction: nil))
        let input = AnalysisAssembler.Input(duration: duration, notes: activations.notes, onsets: activations.onsets,
                                            musicUnderstanding: mu.result,
                                            musicUnderstandingVersion: Self.musicUnderstandingVersion,
                                            basicPitchVersion: BasicPitchModel.Constants.modelVersion,
                                            tuning: options.tuning, timings: timings)
        var analysis = AnalysisAssembler.assemble(input)
        if let failure = mu.failure { analysis.stageErrors[Stage.musicUnderstanding.rawValue] = failure }
        Self.log.info("Analysis done: \(analysis.notes.count) notes, \(analysis.chords.count) chords, quality \(analysis.quality.level.rawValue, privacy: .public)")
        return analysis
    }

    // MARK: Stages

    struct UnderstandingOutcome: Sendable {
        var result: MusicUnderstandingResult?
        var seconds: Double?
        var failure: String?
    }

    static func runMusicUnderstanding(fileURL: URL, enabled: Bool,
                                      onUpdate: @escaping @Sendable (Update) -> Void) async -> UnderstandingOutcome {
        guard enabled else { return UnderstandingOutcome(result: nil, seconds: nil, failure: nil) }
        onUpdate(Update(stage: .musicUnderstanding, fraction: nil))
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let asset = AVURLAsset(url: fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let session = try await MusicUnderstandingSession(asset: asset)
            let result = try await session.analyze(for: [.rhythm, .key, .structure, .instrumentActivity])
            let data = try JSONEncoder().encode(result)
            let parsed = try MusicUnderstandingResult.decode(data)
            let seconds = (clock.now - start).seconds
            log.info("Music Understanding finished in \(seconds, privacy: .public)s")
            return UnderstandingOutcome(result: parsed, seconds: seconds, failure: nil)
        } catch is CancellationError {
            return UnderstandingOutcome(result: nil, seconds: nil, failure: nil)
        } catch {
            log.error("Music Understanding failed: \(error.localizedDescription, privacy: .public)")
            return UnderstandingOutcome(result: nil, seconds: (clock.now - start).seconds,
                                        failure: error.localizedDescription)
        }
    }

    struct Activations: Sendable {
        let notes: ActivationMatrix
        let onsets: ActivationMatrix
    }

    /// Windows the audio exactly like the reference `run_inference` and unwraps the outputs.
    static func runBasicPitch(samples: [Float], model: BasicPitchModel, computeUnits: MLComputeUnits,
                              onUpdate: @escaping @Sendable (Update) -> Void) async throws -> Activations {
        let windows = BasicPitchTiming.windowCount(forSamples: samples.count)
        let totalFrames = BasicPitchTiming.frameCount(forSamples: samples.count)
        let bins = BasicPitchModel.Constants.noteBins
        let half = BasicPitchTiming.overlapFrames / 2
        var notes: [Float] = []
        var onsets: [Float] = []
        notes.reserveCapacity(totalFrames * bins + BasicPitchTiming.framesPerWindow * bins)
        onsets.reserveCapacity(notes.capacity)

        onUpdate(Update(stage: .notes, fraction: 0, detail: "0/\(windows)"))
        var window = [Float](repeating: 0, count: BasicPitchModel.Constants.windowSamples)
        for index in 0..<windows {
            try Task.checkCancellation()
            fillWindow(&window, from: samples, start: BasicPitchTiming.windowStartSample(index))
            let output = try await model.activations(for: window, computeUnits: computeUnits)
            let kept = max(0, output.frames - 2 * half)
            notes.append(contentsOf: output.notes[(half * bins)..<((half + kept) * bins)])
            onsets.append(contentsOf: output.onsets[(half * bins)..<((half + kept) * bins)])
            onUpdate(Update(stage: .notes, fraction: Double(index + 1) / Double(windows), detail: "\(index + 1)/\(windows)"))
        }
        let frames = min(totalFrames, notes.count / bins)
        return Activations(notes: ActivationMatrix(frames: frames, bins: bins, values: Array(notes.prefix(frames * bins))),
                           onsets: ActivationMatrix(frames: frames, bins: bins, values: Array(onsets.prefix(frames * bins))))
    }

    /// Copies `samples[start ..< start + window.count]` into `window`, zero-filling outside the signal.
    static func fillWindow(_ window: inout [Float], from samples: [Float], start: Int) {
        let count = window.count
        window.withUnsafeMutableBufferPointer { destination in
            destination.update(repeating: 0)
            let from = max(start, 0)
            let to = min(start + count, samples.count)
            guard to > from else { return }
            samples.withUnsafeBufferPointer { source in
                for i in from..<to { destination[i - start] = source[i] }
            }
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
