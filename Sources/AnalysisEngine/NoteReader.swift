import CoreML
import Foundation
import MusicCore
import os

/// Guesses the guitar's notes from its separated audio: Basic Pitch on the guitar stem(s), the
/// Swift port of Basic Pitch's note decoding, guitar clean-up, then string/fret/finger from the
/// fingering optimizer. Reading the isolated guitar (not the full mix) is what makes this usable.
public enum NoteReader {
    private static let log = Logger(subsystem: RXLog.subsystem, category: "notes")

    /// - Parameter progress: 0…1, windows done / total.
    public static func read(stems: [URL], duration: Seconds, model: BasicPitchModel,
                            computeUnits: MLComputeUnits = .all,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> NoteMap {
        let clock = ContinuousClock()
        let start = clock.now
        try await model.load(computeUnits: computeUnits)
        let samples = try mix(stems)
        try Task.checkCancellation()

        let windows = BasicPitchTiming.windowCount(forSamples: samples.count)
        let totalFrames = BasicPitchTiming.frameCount(forSamples: samples.count)
        let bins = BasicPitchModel.Constants.noteBins
        let half = BasicPitchModel.Constants.overlappingFrames / 2
        var notes: [Float] = []
        var onsets: [Float] = []
        notes.reserveCapacity((totalFrames + BasicPitchTiming.framesPerWindow) * bins)
        onsets.reserveCapacity(notes.capacity)
        var window = [Float](repeating: 0, count: BasicPitchModel.Constants.windowSamples)
        for index in 0..<windows {
            try Task.checkCancellation()
            fill(&window, from: samples, start: BasicPitchTiming.windowStartSample(index))
            let output = try await model.activations(for: window, computeUnits: computeUnits)
            let kept = max(0, output.frames - 2 * half)
            notes.append(contentsOf: output.notes[(half * bins)..<((half + kept) * bins)])
            onsets.append(contentsOf: output.onsets[(half * bins)..<((half + kept) * bins)])
            progress(Double(index + 1) / Double(max(windows, 1)))
        }
        let frames = min(totalFrames, notes.count / bins)
        let detected = NoteMapBuilder.detect(
            notes: ActivationMatrix(frames: frames, bins: bins, values: Array(notes.prefix(frames * bins))),
            onsets: ActivationMatrix(frames: frames, bins: bins, values: Array(onsets.prefix(frames * bins))),
            duration: duration)
        let seconds = (clock.now - start).seconds
        log.info("Read \(detected.count) notes in \(seconds, privacy: .public)s")
        return NoteMap(model: "\(BasicPitchModel.Constants.modelVersion)+\(NoteMapBuilder.version)",
                       sources: stems.map { $0.deletingPathExtension().lastPathComponent }, detected: detected, seconds: seconds)
    }

    /// Sum of the stems, mono at Basic Pitch's sample rate.
    static func mix(_ stems: [URL]) throws -> [Float] {
        var sum: [Float] = []
        for url in stems {
            let mono = try autoreleasepool {
                try AudioDecoder.decodeMono(url: url, sampleRate: BasicPitchModel.Constants.sampleRate).samples
            }
            if sum.isEmpty {
                sum = mono
            } else {
                for i in 0..<min(sum.count, mono.count) { sum[i] += mono[i] }
            }
        }
        return sum
    }

    /// Copies `samples[start ..< start + window.count]` into `window`, zero-filling outside the signal.
    static func fill(_ window: inout [Float], from samples: [Float], start: Int) {
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
