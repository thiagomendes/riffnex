import AVFoundation
import Foundation

/// Decodes an audio file into mono float32 samples at a target sample rate, in chunks, with
/// cooperative cancellation and real progress (frames decoded / total frames).
public enum AudioDecoder {
    public enum DecodeError: Error, LocalizedError {
        case unsupportedFormat
        case converterFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Formato de áudio não suportado."
            case .converterFailed(let detail): "Falha ao converter o áudio: \(detail)"
            }
        }
    }

    public struct Result: Sendable {
        public let samples: [Float]
        public let sampleRate: Double
        public let sourceSampleRate: Double
        public let sourceChannels: Int
        public var duration: Double { Double(samples.count) / sampleRate }
    }

    /// - Parameter progress: called with a fraction in 0...1 computed from frames actually read.
    public static func decodeMono(
        url: URL,
        sampleRate targetRate: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat // deinterleaved float32
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw DecodeError.unsupportedFormat
        }
        // Mono downmix: average channels rather than taking the left channel only.
        if sourceFormat.channelCount > 1 {
            converter.downmix = true
        }

        let totalFrames = max(file.length, 1)
        let chunkFrames: AVAudioFrameCount = 32_768
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
            throw DecodeError.unsupportedFormat
        }
        let ratio = targetRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw DecodeError.unsupportedFormat
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1024)
        var reachedEnd = false
        var readError: (any Error)?

        while true {
            try Task.checkCancellation()
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                // Reading at or past the end throws kAudioFileEndOfFileError (-39) on device,
                // so stop based on the position instead of waiting for an empty read.
                if reachedEnd || file.framePosition >= file.length {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inputBuffer, frameCount: chunkFrames)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let readError { throw readError }
            if status == .error {
                throw DecodeError.converterFailed(conversionError?.localizedDescription ?? "desconhecido")
            }
            if let channel = outputBuffer.floatChannelData?[0], outputBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
            }
            progress?(min(1, Double(file.framePosition) / Double(totalFrames)))
            if status == .endOfStream { break }
        }

        return Result(samples: samples, sampleRate: targetRate, sourceSampleRate: sourceFormat.sampleRate,
                      sourceChannels: Int(sourceFormat.channelCount))
    }
}
