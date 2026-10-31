import CoreML
import Foundation
import os

/// Loads Spotify's Basic Pitch Core ML model (Apache-2.0, ICASSP 2022).
///
/// The model ships as an uncompiled `.mlpackage` because compiling (coremlc) requires Xcode, which
/// the xtool build does not use. On first use we compile on device with `MLModel.compileModel(at:)`
/// and cache the `.mlmodelc` in Application Support, keyed by the model's content hash.
///
/// Facts from the reference implementation (basic-pitch 0.4.0):
/// - input  `input_2`: mono float32 audio at 22 050 Hz, window of 43 844 samples (2 s − 1 hop)
/// - output `Identity`   = contour (264 bins, 3 per semitone)
/// - output `Identity_1` = note activations (88 pitches, A0…C8)
/// - output `Identity_2` = onset activations (88 pitches)
/// - frame rate 22 050 / 256 ≈ 86.13 fps; windows overlap by 30 frames.
public actor BasicPitchModel {
    public enum Constants {
        public static let sampleRate: Double = 22_050
        public static let fftHop = 256
        public static let windowSamples = 22_050 * 2 - 256 // 43 844
        public static let overlappingFrames = 30
        public static let lowestMIDI = 21 // A0
        public static let noteBins = 88
        public static let contourBins = 264
        public static let inputName = "input_2"
        public static let contourOutput = "Identity"
        public static let noteOutput = "Identity_1"
        public static let onsetOutput = "Identity_2"
        /// SHA-256 of `nmp.mlpackage/Data/com.apple.CoreML/model.mlmodel` as bundled.
        public static let modelVersion = "icassp2022-af7bf7d4"
    }

    public enum ModelError: Error, LocalizedError {
        case missingResource
        case missingOutput(String)
        case notCompiled

        public var errorDescription: String? {
            switch self {
            case .missingResource: "O modelo Basic Pitch não foi encontrado no pacote do app."
            case .missingOutput(let name): "O modelo não produziu a saída esperada: \(name)."
            case .notCompiled: "O modelo ainda não foi preparado neste aparelho."
            }
        }
    }

    private static let log = Logger(subsystem: RXLog.subsystem, category: "basic-pitch")
    private var model: MLModel?
    private var loadedUnits: MLComputeUnits?

    public init() {}

    /// URL of the bundled, uncompiled model package.
    public static func bundledPackageURL() -> URL? {
        Bundle.module.url(forResource: "nmp", withExtension: "mlpackage", subdirectory: "BasicPitch")
    }

    /// Where the compiled model is cached.
    static func compiledModelURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("BasicPitch-\(Constants.modelVersion).mlmodelc", isDirectory: true)
    }

    public struct LoadReport: Sendable {
        public let compiledThisLaunch: Bool
        public let compileSeconds: Double?
        public let loadSeconds: Double
        public let inputShape: [Int]
    }

    /// Compiles (if needed) and loads the model. Safe to call repeatedly.
    @discardableResult
    public func load(computeUnits: MLComputeUnits = .all) async throws -> LoadReport {
        let clock = ContinuousClock()
        let destination = try Self.compiledModelURL()
        var compiled = false
        var compileSeconds: Double?

        if !FileManager.default.fileExists(atPath: destination.path) {
            guard let source = Self.bundledPackageURL() else { throw ModelError.missingResource }
            Self.log.info("Compiling Basic Pitch model on device")
            let start = clock.now
            let temporary = try await MLModel.compileModel(at: source)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            compileSeconds = (clock.now - start).seconds
            compiled = true
        }

        if model != nil, loadedUnits == computeUnits, !compiled {
            return LoadReport(compiledThisLaunch: false, compileSeconds: nil, loadSeconds: 0,
                              inputShape: [1, Constants.windowSamples, 1])
        }
        let start = clock.now
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        // Synchronous load inside the actor: MLModel is not Sendable, so it never leaves this actor.
        let loaded = try MLModel(contentsOf: destination, configuration: configuration)
        model = loaded
        loadedUnits = computeUnits
        let shape = loaded.modelDescription.inputDescriptionsByName[Constants.inputName]?
            .multiArrayConstraint?.shape.map(\.intValue) ?? []
        let report = LoadReport(compiledThisLaunch: compiled, compileSeconds: compileSeconds,
                                loadSeconds: (clock.now - start).seconds, inputShape: shape)
        Self.log.info("Basic Pitch loaded; input shape \(shape, privacy: .public)")
        return report
    }

    public struct WindowOutput: Sendable {
        /// Shapes as reported by Core ML, e.g. [1, 172, 88].
        public let noteShape: [Int]
        public let onsetShape: [Int]
        public let contourShape: [Int]
        public let maxNoteActivation: Float
        /// MIDI pitch of the strongest note activation in the window (A0 = 21).
        public let strongestMIDI: Int
        public let seconds: Double
    }

    /// Runs one window of audio (exactly `Constants.windowSamples` samples, zero-padded by the caller).
    public func predictWindow(_ samples: [Float]) async throws -> WindowOutput {
        precondition(samples.count == Constants.windowSamples, "Window must be \(Constants.windowSamples) samples")
        if model == nil { try await load() }
        guard let model else { throw ModelError.missingResource }

        let input = try MLMultiArray(shape: [1, NSNumber(value: Constants.windowSamples), 1], dataType: .float32)
        samples.withUnsafeBufferPointer { source in
            let destination = input.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
            destination.update(from: source.baseAddress!, count: samples.count)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let provider = try MLDictionaryFeatureProvider(dictionary: [Constants.inputName: MLFeatureValue(multiArray: input)])
        let output = try Self.predictSynchronously(model, provider)
        let elapsed = (clock.now - start).seconds

        func array(_ name: String) throws -> MLMultiArray {
            guard let value = output.featureValue(for: name)?.multiArrayValue else { throw ModelError.missingOutput(name) }
            return value
        }
        let notes = try array(Constants.noteOutput)
        let onsets = try array(Constants.onsetOutput)
        let contours = try array(Constants.contourOutput)

        // Index with the shape (not a linear offset) so non-contiguous strides are handled correctly.
        let shape = notes.shape.map(\.intValue)
        var maxActivation: Float = 0
        var strongestBin = 0
        if shape.count == 3 {
            for frame in 0..<shape[1] {
                for bin in 0..<shape[2] {
                    let value = notes[[0, frame, bin] as [NSNumber]].floatValue
                    if value > maxActivation {
                        maxActivation = value
                        strongestBin = bin
                    }
                }
            }
        }

        return WindowOutput(noteShape: shape, onsetShape: onsets.shape.map(\.intValue),
                            contourShape: contours.shape.map(\.intValue), maxNoteActivation: maxActivation,
                            strongestMIDI: Constants.lowestMIDI + strongestBin, seconds: elapsed)
    }
}

extension BasicPitchModel {
    /// The note and onset activations of one window, frames × 88, row-major.
    public struct WindowActivations: Sendable {
        public let frames: Int
        public let notes: [Float]
        public let onsets: [Float]
        public let seconds: Double
    }

    /// Runs one window and returns its full note/onset activations.
    public func activations(for samples: [Float], computeUnits: MLComputeUnits = .all) throws -> WindowActivations {
        precondition(samples.count == Constants.windowSamples, "Window must be \(Constants.windowSamples) samples")
        if model == nil || loadedUnits != computeUnits { try loadSynchronously(computeUnits: computeUnits) }
        guard let model else { throw ModelError.missingResource }
        let input = try MLMultiArray(shape: [1, NSNumber(value: Constants.windowSamples), 1], dataType: .float32)
        samples.withUnsafeBufferPointer { source in
            input.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
                .update(from: source.baseAddress!, count: samples.count)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let provider = try MLDictionaryFeatureProvider(dictionary: [Constants.inputName: MLFeatureValue(multiArray: input)])
        let output = try Self.predictSynchronously(model, provider)
        let elapsed = (clock.now - start).seconds
        guard let notes = output.featureValue(for: Constants.noteOutput)?.multiArrayValue else {
            throw ModelError.missingOutput(Constants.noteOutput)
        }
        guard let onsets = output.featureValue(for: Constants.onsetOutput)?.multiArrayValue else {
            throw ModelError.missingOutput(Constants.onsetOutput)
        }
        let (frames, noteValues) = try Self.matrix(notes)
        let (_, onsetValues) = try Self.matrix(onsets)
        return WindowActivations(frames: frames, notes: noteValues, onsets: onsetValues, seconds: elapsed)
    }

    /// Copies a [1, frames, bins] (or [frames, bins]) multi-array into a dense row-major Float array,
    /// honoring strides. Fast paths for float32/float16 storage; generic subscript otherwise.
    static func matrix(_ array: MLMultiArray) throws -> (frames: Int, values: [Float]) {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2 else { throw ModelError.missingOutput("shape \(shape)") }
        let frames = shape[shape.count - 2]
        let bins = shape[shape.count - 1]
        let frameStride = strides[strides.count - 2]
        let binStride = strides[strides.count - 1]
        var values = [Float](repeating: 0, count: frames * bins)
        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for t in 0..<frames {
                    for f in 0..<bins { values[t * bins + f] = buffer[t * frameStride + f * binStride] }
                }
            }
        #if arch(arm64)
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                for t in 0..<frames {
                    for f in 0..<bins { values[t * bins + f] = Float(buffer[t * frameStride + f * binStride]) }
                }
            }
        #endif
        default:
            let leading = Array(repeating: NSNumber(value: 0), count: shape.count - 2)
            for t in 0..<frames {
                for f in 0..<bins {
                    values[t * bins + f] = array[leading + [NSNumber(value: t), NSNumber(value: f)]].floatValue
                }
            }
        }
        return (frames, values)
    }

    private func loadSynchronously(computeUnits: MLComputeUnits) throws {
        let destination = try Self.compiledModelURL()
        guard FileManager.default.fileExists(atPath: destination.path) else { throw ModelError.notCompiled }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: destination, configuration: configuration)
        loadedUnits = computeUnits
    }
}

extension BasicPitchModel {
    /// In an async context the compiler picks MLModel's async `prediction` overload, which would send
    /// the non-Sendable model off the actor. A synchronous helper keeps inference on the actor's thread.
    private nonisolated static func predictSynchronously(
        _ model: MLModel, _ provider: any MLFeatureProvider
    ) throws -> any MLFeatureProvider {
        try model.prediction(from: provider)
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
