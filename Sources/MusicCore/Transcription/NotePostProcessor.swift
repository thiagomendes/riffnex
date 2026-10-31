import Foundation

/// RIFFNEX's own clean-up of decoded Basic Pitch notes for guitar. Every step is measured against
/// the demo ground truth in `NotePostProcessorTests`; none of it is part of the reference model.
///
/// 1. **Range gating** to what a guitar in the chosen tuning can play (lowest open string − 2
///    semitones, to tolerate drop tunings, up to the 24th fret of the high string).
/// 2. **Harmonic suppression**: a note an octave, an octave + fifth or two octaves above a louder
///    note that starts together with it and lies mostly inside it is treated as an overtone.
///    The amplitude ratio is conservative so real octave doublings (power chords) survive.
/// 3. **Onset refinement**: the decoder often starts repeated notes late (it grows them from the
///    frame energy after the previous note ends). We move each note's start back to the strongest
///    onset-activation peak at its pitch within ~105 ms, and shorten the previous note at that
///    pitch if it now overlaps.
/// 4. **De-duplication** of same-pitch notes that ended up overlapping.
public struct NotePostProcessor: Sendable {
    public struct Parameters: Sendable, Equatable, Codable {
        public var minMIDI: Int
        public var maxMIDI: Int
        public var harmonicIntervals: [Int]
        public var harmonicAmplitudeRatio: Double
        public var harmonicOnsetToleranceFrames: Int
        public var harmonicOverlapFraction: Double
        public var refineBackFrames: Int
        public var refineForwardFrames: Int
        public var refineOnsetThreshold: Float

        public init(minMIDI: Int = 38, maxMIDI: Int = 88, harmonicIntervals: [Int] = [12, 19, 24],
                    harmonicAmplitudeRatio: Double = 0.6, harmonicOnsetToleranceFrames: Int = 4,
                    harmonicOverlapFraction: Double = 0.7, refineBackFrames: Int = 9,
                    refineForwardFrames: Int = 2, refineOnsetThreshold: Float = 0.25) {
            self.minMIDI = minMIDI
            self.maxMIDI = maxMIDI
            self.harmonicIntervals = harmonicIntervals
            self.harmonicAmplitudeRatio = harmonicAmplitudeRatio
            self.harmonicOnsetToleranceFrames = harmonicOnsetToleranceFrames
            self.harmonicOverlapFraction = harmonicOverlapFraction
            self.refineBackFrames = refineBackFrames
            self.refineForwardFrames = refineForwardFrames
            self.refineOnsetThreshold = refineOnsetThreshold
        }

        public static func guitar(tuning: Tuning = .standard, frets: Int = 24) -> Parameters {
            let pitches = tuning.openStrings.map(\.value)
            return Parameters(minMIDI: (pitches.min() ?? 40) + tuning.capo - 2,
                              maxMIDI: (pitches.max() ?? 64) + tuning.capo + frets)
        }
    }

    public struct Report: Sendable, Equatable, Codable {
        public var decoded = 0
        public var outOfRange = 0
        public var harmonics = 0
        public var refinedOnsets = 0
        public var merged = 0
        public var kept = 0
    }

    public var parameters: Parameters

    public init(parameters: Parameters = .guitar()) {
        self.parameters = parameters
    }

    public func process(_ input: [FrameNote], onsets: ActivationMatrix) -> (notes: [FrameNote], report: Report) {
        let p = parameters
        var report = Report()
        report.decoded = input.count

        // 1. Range.
        var notes = input.filter { $0.pitch >= p.minMIDI && $0.pitch <= p.maxMIDI }
        report.outOfRange = input.count - notes.count

        // 2. Harmonics.
        let intervals = Set(p.harmonicIntervals)
        let beforeHarmonics = notes.count
        notes = notes.filter { note in
            !notes.contains { lower in
                guard intervals.contains(note.pitch - lower.pitch),
                      abs(note.startFrame - lower.startFrame) <= p.harmonicOnsetToleranceFrames,
                      note.amplitude < p.harmonicAmplitudeRatio * lower.amplitude else { return false }
                let overlap = min(note.endFrame, lower.endFrame) - max(note.startFrame, lower.startFrame)
                return Double(overlap) >= p.harmonicOverlapFraction * Double(note.endFrame - note.startFrame)
            }
        }
        report.harmonics = beforeHarmonics - notes.count

        // 3. Onset refinement, in time order.
        notes.sort { ($0.startFrame, $0.pitch, $0.endFrame) < ($1.startFrame, $1.pitch, $1.endFrame) }
        var refined: [FrameNote] = []
        var lastIndexForPitch: [Int: Int] = [:]
        for var note in notes {
            let bin = note.pitch - NoteDecoder.midiOffset
            guard bin >= 0, bin < onsets.bins, onsets.frames > 2 else { refined.append(note); continue }
            var low = max(1, note.startFrame - p.refineBackFrames)
            let high = min(onsets.frames - 2, note.startFrame + p.refineForwardFrames)
            let previous = lastIndexForPitch[note.pitch]
            if let previous, refined[previous].endFrame >= low - 1 {
                low = max(low, refined[previous].startFrame + 3)
            }
            var best: (value: Float, frame: Int)?
            if low <= high {
                for j in low...high {
                    let v = onsets[j, bin]
                    guard v >= p.refineOnsetThreshold, v > onsets[j - 1, bin], v >= onsets[j + 1, bin] else { continue }
                    // Tie → later frame, matching Python's max() over (value, frame) tuples.
                    if best == nil || v > best!.value || (v == best!.value && j > best!.frame) { best = (v, j) }
                }
            }
            if let best, best.frame < note.endFrame - 1 {
                if best.frame != note.startFrame { report.refinedOnsets += 1 }
                if let previous, refined[previous].endFrame > best.frame,
                   refined[previous].startFrame < best.frame {
                    refined[previous].endFrame = best.frame
                }
                note.startFrame = best.frame
            }
            lastIndexForPitch[note.pitch] = refined.count
            refined.append(note)
        }

        // 4. Merge same-pitch overlaps (keep the earlier start, the later end, the louder amplitude).
        refined.sort { ($0.pitch, $0.startFrame) < ($1.pitch, $1.startFrame) }
        var merged: [FrameNote] = []
        for note in refined {
            if let last = merged.last, last.pitch == note.pitch, note.startFrame < last.endFrame {
                merged[merged.count - 1].endFrame = max(last.endFrame, note.endFrame)
                merged[merged.count - 1].amplitude = max(last.amplitude, note.amplitude)
                report.merged += 1
            } else {
                merged.append(note)
            }
        }
        merged.removeAll { $0.endFrame <= $0.startFrame }
        merged.sort { ($0.startFrame, $0.pitch) < ($1.startFrame, $1.pitch) }
        report.kept = merged.count
        return (merged, report)
    }
}

extension FrameNote {
    /// Basic Pitch amplitude thresholds for the confidence *level*. The raw value is the mean note
    /// activation and is **not** a calibrated probability; the UI only ever shows the level.
    public static let confidenceThresholds = (medium: 0.45, high: 0.6)

    public func noteEvent(source: AnalysisSource) -> NoteEvent? {
        let onset = BasicPitchTiming.time(ofFrame: startFrame)
        let offset = BasicPitchTiming.time(ofFrame: endFrame)
        guard offset > onset, let midi = MIDINote(pitch) else { return nil }
        return NoteEvent(onset: onset, offset: offset, pitch: midi, amplitude: amplitude,
                         provenance: .detected,
                         confidence: Confidence(raw: amplitude, thresholds: Self.confidenceThresholds),
                         source: source)
    }
}
