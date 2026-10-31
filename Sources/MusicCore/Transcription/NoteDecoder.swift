import Foundation

/// A dense (frames × bins) activation matrix in row-major order, as produced by Basic Pitch
/// after the windows have been unwrapped.
public struct ActivationMatrix: Sendable, Equatable {
    public let frames: Int
    public let bins: Int
    public var values: [Float]

    public init(frames: Int, bins: Int, values: [Float]) {
        precondition(values.count == frames * bins, "Matrix size mismatch")
        self.frames = frames
        self.bins = bins
        self.values = values
    }

    public init(frames: Int, bins: Int, repeating value: Float = 0) {
        self.init(frames: frames, bins: bins, values: Array(repeating: value, count: frames * bins))
    }

    @inlinable public subscript(frame: Int, bin: Int) -> Float {
        get { values[frame * bins + bin] }
        set { values[frame * bins + bin] = newValue }
    }
}

/// A note in model frames, before conversion to seconds.
public struct FrameNote: Sendable, Equatable, Hashable {
    public var startFrame: Int
    /// Exclusive.
    public var endFrame: Int
    public var pitch: Int
    /// Mean note activation over the note's frames.
    public var amplitude: Double

    public init(startFrame: Int, endFrame: Int, pitch: Int, amplitude: Double) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.pitch = pitch
        self.amplitude = amplitude
    }
}

/// Swift port of `basic_pitch.note_creation.output_to_notes_polyphonic` (basic-pitch 0.4.0,
/// Apache-2.0). Validated against golden vectors produced by the reference implementation
/// (`tools/fixtures/make_golden.py`), so behavior — including tie-breaking and iteration order —
/// must stay identical to the reference.
public enum NoteDecoder {
    public static let midiOffset = 21
    static let maxFrequencyIndex = 87

    public struct Parameters: Sendable, Equatable, Codable {
        public var onsetThreshold: Float
        public var frameThreshold: Float
        /// Notes must be strictly longer than this many frames.
        public var minNoteFrames: Int
        public var inferOnsets: Bool
        public var melodiaTrick: Bool
        /// Inclusive MIDI range kept; `nil` keeps everything.
        public var minMIDI: Int?
        public var maxMIDI: Int?
        public var energyTolerance: Int

        public init(onsetThreshold: Float = 0.5, frameThreshold: Float = 0.3, minNoteFrames: Int = 11,
                    inferOnsets: Bool = true, melodiaTrick: Bool = true, minMIDI: Int? = nil,
                    maxMIDI: Int? = nil, energyTolerance: Int = 11) {
            self.onsetThreshold = onsetThreshold
            self.frameThreshold = frameThreshold
            self.minNoteFrames = minNoteFrames
            self.inferOnsets = inferOnsets
            self.melodiaTrick = melodiaTrick
            self.minMIDI = minMIDI
            self.maxMIDI = maxMIDI
            self.energyTolerance = energyTolerance
        }

        /// The reference CLI defaults (onset 0.5, frame 0.3, 127.7 ms minimum ≈ 11 frames).
        public static let reference = Parameters()
    }

    public static func decode(notes frames: ActivationMatrix, onsets: ActivationMatrix,
                              parameters p: Parameters = .reference) -> [FrameNote] {
        precondition(frames.frames == onsets.frames && frames.bins == onsets.bins)
        let nFrames = frames.frames
        let nBins = frames.bins
        guard nFrames > 2, nBins > 0 else { return [] }

        var frames = frames
        var onsets = onsets
        constrainFrequency(&frames, &onsets, minMIDI: p.minMIDI, maxMIDI: p.maxMIDI)
        if p.inferOnsets { onsets = inferredOnsets(onsets: onsets, frames: frames) }

        // Onset peaks: strict local maxima along time (scipy.signal.argrelmax, axis 0, mode "clip",
        // so the first and last frame are never peaks), at or above the onset threshold.
        // Visited backwards in time; within a frame, from the highest bin down (np.where order reversed).
        var remaining = frames
        var notes: [FrameNote] = []
        for t in stride(from: nFrames - 2, through: 1, by: -1) {
            for f in stride(from: nBins - 1, through: 0, by: -1) {
                let v = onsets[t, f]
                guard v > onsets[t - 1, f], v > onsets[t + 1, f], v >= p.onsetThreshold else { continue }
                // "if we're too close to the end of the audio, continue" — t ≤ nFrames - 2 already.
                var i = t + 1
                var k = 0
                while i < nFrames - 1 && k < p.energyTolerance {
                    if remaining[i, f] < p.frameThreshold { k += 1 } else { k = 0 }
                    i += 1
                }
                i -= k
                if i - t <= p.minNoteFrames { continue }
                for j in t..<i {
                    remaining[j, f] = 0
                    if f < maxFrequencyIndex, f + 1 < nBins { remaining[j, f + 1] = 0 }
                    if f > 0 { remaining[j, f - 1] = 0 }
                }
                notes.append(FrameNote(startFrame: t, endFrame: i, pitch: f + midiOffset,
                                       amplitude: mean(frames, from: t, to: i, bin: f)))
            }
        }

        if p.melodiaTrick { melodia(&remaining, frames: frames, parameters: p, into: &notes) }
        return notes
    }

    // MARK: Steps

    static func constrainFrequency(_ frames: inout ActivationMatrix, _ onsets: inout ActivationMatrix,
                                   minMIDI: Int?, maxMIDI: Int?) {
        let bins = frames.bins
        // Reference: max index = round(hz_to_midi(max_freq) - 21), exclusive. We take MIDI directly.
        let upper = maxMIDI.map { min(max($0 + 1 - midiOffset, 0), bins) } ?? bins
        let lower = minMIDI.map { min(max($0 - midiOffset, 0), bins) } ?? 0
        guard upper < bins || lower > 0 else { return }
        for t in 0..<frames.frames {
            for f in 0..<bins where f >= upper || f < lower {
                frames[t, f] = 0
                onsets[t, f] = 0
            }
        }
    }

    /// `get_infered_onsets` with n_diff = 2.
    static func inferredOnsets(onsets: ActivationMatrix, frames: ActivationMatrix) -> ActivationMatrix {
        let nFrames = frames.frames
        let nBins = frames.bins
        var diff = ActivationMatrix(frames: nFrames, bins: nBins)
        var maxDiff: Float = 0
        for t in 2..<nFrames {
            for f in 0..<nBins {
                let d1 = frames[t, f] - frames[t - 1, f]
                let d2 = frames[t, f] - frames[t - 2, f]
                let d = max(min(d1, d2), 0)
                diff[t, f] = d
                maxDiff = max(maxDiff, d)
            }
        }
        let maxOnset = onsets.values.max() ?? 0
        guard maxDiff > 0 else { return onsets }
        var result = onsets
        let scale = Double(maxOnset) / Double(maxDiff)
        for index in result.values.indices {
            let scaled = Float(Double(diff.values[index]) * scale)
            if scaled > result.values[index] { result.values[index] = scaled }
        }
        return result
    }

    /// The "melodia trick": repeatedly take the global maximum of the remaining energy and grow a
    /// note forwards and backwards from it. Values only ever drop to zero, so instead of rescanning
    /// the matrix for the maximum each round (as the reference does), candidates are visited in
    /// (value desc, row-major index asc) order — the same order `np.argmax` would pick them in.
    static func melodia(_ remaining: inout ActivationMatrix, frames: ActivationMatrix,
                        parameters p: Parameters, into notes: inout [FrameNote]) {
        let nFrames = frames.frames
        let nBins = frames.bins
        var candidates: [Int] = []
        for index in remaining.values.indices where remaining.values[index] > p.frameThreshold {
            candidates.append(index)
        }
        let original = remaining.values
        candidates.sort { a, b in
            original[a] != original[b] ? original[a] > original[b] : a < b
        }

        func clear(_ i: Int, _ f: Int) {
            remaining[i, f] = 0
            if f < maxFrequencyIndex, f + 1 < nBins { remaining[i, f + 1] = 0 }
            if f > 0 { remaining[i, f - 1] = 0 }
        }

        for index in candidates {
            // Skip anything already cleared; uncleared cells still hold their original value.
            guard remaining.values[index] == original[index], original[index] > p.frameThreshold else { continue }
            let iMid = index / nBins
            let f = index % nBins
            remaining[iMid, f] = 0

            var i = iMid + 1
            var k = 0
            while i < nFrames - 1 && k < p.energyTolerance {
                if remaining[i, f] < p.frameThreshold { k += 1 } else { k = 0 }
                clear(i, f)
                i += 1
            }
            let iEnd = i - 1 - k

            i = iMid - 1
            k = 0
            while i > 0 && k < p.energyTolerance {
                if remaining[i, f] < p.frameThreshold { k += 1 } else { k = 0 }
                clear(i, f)
                i -= 1
            }
            let iStart = i + 1 + k

            if iEnd - iStart <= p.minNoteFrames { continue }
            notes.append(FrameNote(startFrame: iStart, endFrame: iEnd, pitch: f + midiOffset,
                                   amplitude: mean(frames, from: iStart, to: iEnd, bin: f)))
        }
    }

    static func mean(_ m: ActivationMatrix, from start: Int, to end: Int, bin: Int) -> Double {
        guard end > start else { return 0 }
        var sum = 0.0
        for t in start..<end { sum += Double(m[t, bin]) }
        return sum / Double(end - start)
    }
}

/// Frame ↔ time mapping for Basic Pitch's windowed inference.
///
/// The reference pads 15 frames' worth of zeros (3 840 samples) in front, cuts windows of 43 844
/// samples every 36 164 samples, and keeps 142 of each window's 172 frames. Frame `f` therefore
/// falls in window `w = f / 142` and starts at `(256·f − 188·w) / 22 050` s. The reference's
/// `model_frames_to_time` approximates this with a fitted constant; we use the exact expression,
/// which keeps the error from drifting across windows.
public enum BasicPitchTiming {
    public static let sampleRate = 22_050.0
    public static let hop = 256
    public static let windowSamples = 43_844
    public static let framesPerWindow = 172
    public static let overlapFrames = 30
    public static var keptFramesPerWindow: Int { framesPerWindow - overlapFrames }
    public static var windowHopSamples: Int { windowSamples - overlapFrames * hop }
    public static var leadingPadSamples: Int { overlapFrames / 2 * hop }

    public static func time(ofFrame frame: Int) -> Double {
        let window = frame / keptFramesPerWindow
        let drift = keptFramesPerWindow * hop - windowHopSamples // 188 samples
        return Double(hop * frame - drift * window) / sampleRate
    }

    /// Number of output frames for `samples` of 22 050 Hz audio (`floor(n · 86 / 22 050)` in the reference).
    public static func frameCount(forSamples samples: Int) -> Int {
        Int((Double(samples) * 86.0 / sampleRate).rounded(.down))
    }

    /// Number of model windows needed for `samples` of audio.
    public static func windowCount(forSamples samples: Int) -> Int {
        let padded = samples + leadingPadSamples
        return max(1, (padded + windowHopSamples - 1) / windowHopSamples)
    }

    /// Start of window `index` in the original (unpadded) signal; may be negative for the first window.
    public static func windowStartSample(_ index: Int) -> Int {
        index * windowHopSamples - leadingPadSamples
    }
}
