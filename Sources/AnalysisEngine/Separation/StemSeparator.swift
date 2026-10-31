import AVFoundation
import CoreML
import Foundation
import os

/// On-device source separation with Demucs v4 `htdemucs_6s` (Meta AI, MIT): drums, bass, other,
/// vocals, guitar, piano.
///
/// Reproduces `demucs.apply.apply_model(split=True, overlap=0.25, shifts=0)`:
/// - the song is normalized like `demucs.separate` (mean/std of the mono mix);
/// - it is cut into segments of the model's training length with 25% overlap, each centered and
///   zero-padded at the file end, weighted by a triangle and overlap-added;
/// - per segment, the app computes the STFT, the Core ML model runs the network, and the app adds
///   the time branch to the inverse STFT of the frequency branch.
///
/// Output is streamed to one AAC file per source as soon as a region is final, so memory stays
/// at a few segments regardless of song length.
public actor StemSeparator {
    public struct Config: Decodable, Sendable {
        public let model: String
        public let sources: [String]
        public let sampleRate: Double
        public let channels: Int
        public let segmentSamples: Int
        public let nfft: Int
        public let hop: Int
        public let frames: Int
        public let overlap: Double
    }

    public struct Progress: Sendable {
        public let fraction: Double
        public let segment: Int
        public let segments: Int
    }

    public struct Result: Sendable {
        public let stems: [String: URL]
        public let seconds: Double
        public let segmentSeconds: [Double]
        public let duration: Double
    }

    public enum SeparationError: Error, LocalizedError {
        case missingModel
        case unexpectedOutput(String)

        public var errorDescription: String? {
            switch self {
            case .missingModel: "O modelo de separação de instrumentos não está no app."
            case .unexpectedOutput(let detail): "O modelo de separação respondeu num formato inesperado (\(detail))."
            }
        }
    }

    public static let modelVersion = "htdemucs_6s-coreml-1"
    private static let log = Logger(subsystem: RXLog.subsystem, category: "separation")
    private var model: MLModel?
    private var loadedUnits: MLComputeUnits?
    public private(set) var config: Config?

    public init() {}

    public static func bundledConfig() throws -> Config {
        guard let url = Bundle.module.url(forResource: "htdemucs6s", withExtension: "json", subdirectory: "Separation") else {
            throw SeparationError.missingModel
        }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public static var isAvailable: Bool {
        Bundle.module.url(forResource: "htdemucs6s", withExtension: "mlpackage", subdirectory: "Separation") != nil
    }

    // MARK: Model

    @discardableResult
    public func load(computeUnits: MLComputeUnits = .all) async throws -> Double {
        if model != nil, loadedUnits == computeUnits { return 0 }
        let clock = ContinuousClock()
        let start = clock.now
        config = try Self.bundledConfig()
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = base.appendingPathComponent("Models/\(Self.modelVersion).mlmodelc", isDirectory: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard let source = Bundle.module.url(forResource: "htdemucs6s", withExtension: "mlpackage", subdirectory: "Separation") else {
                throw SeparationError.missingModel
            }
            Self.log.info("Compiling separation model on device")
            let compiled = try await MLModel.compileModel(at: source)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: compiled, to: destination)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: destination, configuration: configuration)
        loadedUnits = computeUnits
        return (clock.now - start).seconds
    }

    // MARK: Separation

    /// Separates `fileURL` into one `.m4a` per source in `directory`.
    public func separate(fileURL: URL, into directory: URL, computeUnits: MLComputeUnits = .all,
                         progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        try await load(computeUnits: computeUnits)
        guard let model, let config else { throw SeparationError.missingModel }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. Decode to 44.1 kHz stereo float in a temporary file we can read at random positions.
        let temporary = directory.appendingPathComponent("mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let total = try Self.decodeStereo(fileURL, to: temporary, sampleRate: config.sampleRate)
        try Task.checkCancellation()
        let source = try AVAudioFile(forReading: temporary, commonFormat: .pcmFormatFloat32, interleaved: false)
        let (mean, std) = try Self.monoStatistics(source, frames: total)

        // 2. Writers, one per source.
        let segment = config.segmentSamples
        let stride = Int((1 - config.overlap) * Double(segment))
        var writers: [AVAudioFile] = []
        var urls: [String: URL] = [:]
        for name in config.sources {
            let url = directory.appendingPathComponent("\(name).m4a")
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: config.sampleRate,
                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000]
            writers.append(try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false))
            urls[name] = url
        }

        // Triangle weight, as in apply_model (transition_power = 1).
        let halfSegment = segment / 2
        var weight = [Float](repeating: 0, count: segment)
        for i in 0..<halfSegment { weight[i] = Float(i + 1) }
        for i in halfSegment..<segment { weight[i] = Float(segment - i) }
        let maxWeight = weight.max() ?? 1
        for i in weight.indices { weight[i] /= maxWeight }

        // Rolling accumulators covering [bufferStart, bufferStart + capacity).
        let sourceCount = config.sources.count
        let capacity = segment + stride
        var accum = [[Float]](repeating: [Float](repeating: 0, count: capacity), count: sourceCount * 2)
        var weightSum = [Float](repeating: 0, count: capacity)
        var bufferStart = 0

        func flush(upTo end: Int) throws {
            let count = min(end, total) - bufferStart
            guard count > 0 else { return }
            for s in 0..<sourceCount {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: writers[s].processingFormat, frameCapacity: AVAudioFrameCount(count)) else { continue }
                buffer.frameLength = AVAudioFrameCount(count)
                for c in 0..<2 {
                    let out = buffer.floatChannelData![c]
                    let values = accum[s * 2 + c]
                    for i in 0..<count {
                        let w = weightSum[i]
                        out[i] = (w > 0 ? values[i] / w : 0) * std + mean
                    }
                }
                try writers[s].write(from: buffer)
            }
            // Shift the remainder to the front.
            let remaining = capacity - count
            for k in accum.indices {
                accum[k].withUnsafeMutableBufferPointer { p in
                    if remaining > 0 { p.baseAddress!.update(from: p.baseAddress! + count, count: remaining) }
                    (p.baseAddress! + remaining).update(repeating: 0, count: count)
                }
            }
            weightSum.withUnsafeMutableBufferPointer { p in
                if remaining > 0 { p.baseAddress!.update(from: p.baseAddress! + count, count: remaining) }
                (p.baseAddress! + remaining).update(repeating: 0, count: count)
            }
            bufferStart += count
        }

        let spectrogram = DemucsSpectrogram(nfft: config.nfft)
        let frames = config.frames
        let bins = config.nfft / 2
        let offsets = Array(Swift.stride(from: 0, to: total, by: stride))
        var segmentTimes: [Double] = []
        var window = [[Float]](repeating: [Float](repeating: 0, count: segment), count: 2)
        var reconstruction = [Float](repeating: 0, count: segment)

        for (index, offset) in offsets.enumerated() {
            try Task.checkCancellation()
            let segmentStart = clock.now
            try flush(upTo: offset)

            // Centered, zero-padded window (TensorChunk.padded).
            let chunkLength = min(segment, total - offset)
            let delta = segment - chunkLength
            let windowStart = offset - delta / 2
            try Self.read(source, from: windowStart, count: segment, total: total, into: &window)
            for c in 0..<2 { for i in 0..<segment { window[c][i] = (window[c][i] - mean) / std } }

            let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: segment)], dataType: .float32)
            let mag = try MLMultiArray(shape: [1, 4, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)
            let mixPointer = mix.dataPointer.bindMemory(to: Float.self, capacity: 2 * segment)
            let magPointer = mag.dataPointer.bindMemory(to: Float.self, capacity: 4 * bins * frames)
            for c in 0..<2 {
                window[c].withUnsafeBufferPointer { samples in
                    (mixPointer + c * segment).update(from: samples.baseAddress!, count: segment)
                    spectrogram.forward(samples, frames: frames,
                                        real: magPointer + (2 * c) * bins * frames,
                                        imag: magPointer + (2 * c + 1) * bins * frames)
                }
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: ["mix": MLFeatureValue(multiArray: mix),
                                                                        "mag": MLFeatureValue(multiArray: mag)])
            let output = try Self.predict(model, provider)
            guard let timeOut = output.featureValue(for: "time")?.multiArrayValue,
                  let specOut = output.featureValue(for: "spec")?.multiArrayValue else {
                throw SeparationError.unexpectedOutput("faltam as saídas time/spec")
            }
            let timeValues = try Self.floats(timeOut, expected: sourceCount * 2 * segment)
            let specValues = try Self.floats(specOut, expected: sourceCount * 4 * bins * frames)

            let trim = delta / 2
            let base = offset - bufferStart
            for s in 0..<sourceCount {
                for c in 0..<2 {
                    specValues.withUnsafeBufferPointer { spec in
                        let planeReal = spec.baseAddress! + ((s * 4 + 2 * c) * bins * frames)
                        let planeImag = spec.baseAddress! + ((s * 4 + 2 * c + 1) * bins * frames)
                        reconstruction.withUnsafeMutableBufferPointer { out in
                            spectrogram.inverse(real: planeReal, imag: planeImag, frames: frames, length: segment, into: out.baseAddress!)
                        }
                    }
                    let timeBase = (s * 2 + c) * segment
                    let slot = s * 2 + c
                    accum[slot].withUnsafeMutableBufferPointer { acc in
                        for i in 0..<chunkLength {
                            let value = reconstruction[trim + i] + timeValues[timeBase + trim + i]
                            acc[base + i] += weight[i] * value
                        }
                    }
                }
            }
            for i in 0..<chunkLength { weightSum[base + i] += weight[i] }

            segmentTimes.append((clock.now - segmentStart).seconds)
            progress(Progress(fraction: Double(index + 1) / Double(offsets.count), segment: index + 1, segments: offsets.count))
        }
        try flush(upTo: total)

        let seconds = (clock.now - start).seconds
        Self.log.info("Separated \(Double(total) / config.sampleRate, privacy: .public)s in \(seconds, privacy: .public)s")
        return Result(stems: urls, seconds: seconds, segmentSeconds: segmentTimes, duration: Double(total) / config.sampleRate)
    }

    // MARK: Helpers

    private nonisolated static func predict(_ model: MLModel, _ provider: any MLFeatureProvider) throws -> any MLFeatureProvider {
        try model.prediction(from: provider)
    }

    /// Dense Float copy of a contiguous multi-array (float32 or float16 storage).
    static func floats(_ array: MLMultiArray, expected: Int) throws -> [Float] {
        guard array.count == expected else {
            throw SeparationError.unexpectedOutput("\(array.count) valores em vez de \(expected), forma \(array.shape)")
        }
        // Require row-major contiguity (the converted model's outputs are).
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        var expectedStride = 1
        for axis in stride(from: shape.count - 1, through: 0, by: -1) {
            guard strides[axis] == expectedStride || shape[axis] == 1 else {
                throw SeparationError.unexpectedOutput("saída não contígua \(strides)")
            }
            expectedStride *= shape[axis]
        }
        var values = [Float](repeating: 0, count: expected)
        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                values.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: buffer.baseAddress!, count: expected) }
            }
        #if arch(arm64)
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                for i in 0..<expected { values[i] = Float(buffer[i]) }
            }
        #endif
        default:
            for i in 0..<expected { values[i] = array[i].floatValue }
        }
        return values
    }

    /// Decodes any audio file to stereo float at `sampleRate`, written to `destination`. Returns frames.
    static func decodeStereo(_ url: URL, to destination: URL, sampleRate: Double) throws -> Int {
        let input = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
            throw AudioDecoder.DecodeError.unsupportedFormat
        }
        if input.processingFormat.channelCount == 1 {
            converter.channelMap = [0, 0] // mono: same signal on both channels
        }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 32_768
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(chunk) * sampleRate / input.processingFormat.sampleRate) + 1024) else {
            throw AudioDecoder.DecodeError.unsupportedFormat
        }
        var written = 0
        var finished = false
        var readError: (any Error)?
        while true {
            try Task.checkCancellation()
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if finished || input.framePosition >= input.length {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do { try input.read(into: inBuffer, frameCount: chunk) } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let readError { throw readError }
            if let error { throw error }
            if outBuffer.frameLength > 0 {
                try output.write(from: outBuffer)
                written += Int(outBuffer.frameLength)
            }
            if status == .endOfStream || status == .error || (finished && outBuffer.frameLength == 0) { break }
        }
        return written
    }

    /// Mean and standard deviation of the mono (channel-averaged) signal, like `demucs.separate`.
    static func monoStatistics(_ file: AVAudioFile, frames: Int) throws -> (Float, Float) {
        file.framePosition = 0
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return (0, 1) }
        var sum = 0.0
        var squares = 0.0
        var count = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0 else { break }
            let left = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![buffer.format.channelCount > 1 ? 1 : 0]
            for i in 0..<n {
                let v = Double(left[i] + right[i]) / 2
                sum += v
                squares += v * v
            }
            count += n
        }
        guard count > 1 else { return (0, 1) }
        let mean = sum / Double(count)
        let variance = max(0, (squares - Double(count) * mean * mean) / Double(count - 1))
        return (Float(mean), Float(max(variance.squareRoot(), 1e-8)))
    }

    /// Reads `count` frames starting at `start` (may be negative or run past the end: zeros there).
    static func read(_ file: AVAudioFile, from start: Int, count: Int, total: Int, into window: inout [[Float]]) throws {
        for c in 0..<2 { window[c].withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        let first = max(start, 0)
        let last = min(start + count, total)
        guard last > first else { return }
        file.framePosition = AVAudioFramePosition(first)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(last - first)) else { return }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(last - first))
        let n = Int(buffer.frameLength)
        for c in 0..<2 {
            let data = buffer.floatChannelData![min(c, Int(buffer.format.channelCount) - 1)]
            for i in 0..<n { window[c][first - start + i] = data[i] }
        }
    }
}
