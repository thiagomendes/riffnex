import Foundation
import Testing
@testable import MusicCore

@Suite("Basic Pitch note decoding (golden vectors)")
struct NoteDecoderGoldenTests {
    @Test(arguments: ["default", "guitar", "sensitive-no-melodia"])
    func matchesReference(configName: String) throws {
        let golden = try AnalysisFixtures.golden()
        let activations = try AnalysisFixtures.activations()
        let config = try #require(golden.configs.first { $0.name == configName })
        #expect(activations.notes.frames == golden.frames)

        let decoded = NoteDecoder.decode(notes: activations.notes, onsets: activations.onsets, parameters: config.parameters)
        let expected = config.notes.map { FrameNote(startFrame: Int($0[0]), endFrame: Int($0[1]), pitch: Int($0[2]), amplitude: $0[3]) }

        func key(_ n: FrameNote) -> [Int] { [n.startFrame, n.endFrame, n.pitch] }
        let expectedKeys = expected.map(key).sorted { $0.lexicographicallyPrecedes($1) }
        let decodedKeys = decoded.map(key).sorted { $0.lexicographicallyPrecedes($1) }
        let missing = expectedKeys.filter { !decodedKeys.contains($0) }
        let extra = decodedKeys.filter { !expectedKeys.contains($0) }
        print("[golden \(configName)] reference \(expected.count) notes, port \(decoded.count); missing \(missing.prefix(5)) extra \(extra.prefix(5))")
        #expect(decodedKeys == expectedKeys, "missing \(missing.prefix(8)), extra \(extra.prefix(8))")

        // Same order as the reference, and amplitudes agree (float32 vs float64 means).
        if decoded.count == expected.count {
            for (d, e) in zip(decoded, expected) {
                #expect(key(d) == key(e))
                #expect(abs(d.amplitude - e.amplitude) < 1e-4)
            }
        }
    }

    @Test func emptyAndTinyInputs() {
        let empty = ActivationMatrix(frames: 0, bins: 88)
        #expect(NoteDecoder.decode(notes: empty, onsets: empty).isEmpty)
        let silent = ActivationMatrix(frames: 100, bins: 88)
        #expect(NoteDecoder.decode(notes: silent, onsets: silent).isEmpty)
    }

    @Test func syntheticSingleNote() {
        var notes = ActivationMatrix(frames: 60, bins: 88)
        var onsets = ActivationMatrix(frames: 60, bins: 88)
        for t in 10..<40 { notes[t, 19] = 0.8 } // MIDI 40
        onsets[10, 19] = 0.9
        let decoded = NoteDecoder.decode(notes: notes, onsets: onsets)
        #expect(decoded.count == 1)
        #expect(decoded.first?.pitch == 40)
        #expect(decoded.first?.startFrame == 10)
        #expect(decoded.first?.endFrame == 40)
    }
}

@Suite("Basic Pitch timing")
struct BasicPitchTimingTests {
    @Test func frameTimes() {
        #expect(BasicPitchTiming.time(ofFrame: 0) == 0)
        #expect(abs(BasicPitchTiming.time(ofFrame: 86) - 86 * 256 / 22_050) < 1e-12)
        // First frame of the second window is pulled back by 188 samples.
        #expect(abs(BasicPitchTiming.time(ofFrame: 142) - (142.0 * 256 - 188) / 22_050) < 1e-12)
        // Monotonic across window boundaries.
        for f in 1..<2000 { #expect(BasicPitchTiming.time(ofFrame: f) > BasicPitchTiming.time(ofFrame: f - 1)) }
    }

    @Test func windowAndFrameCountsMatchReference() throws {
        let golden = try AnalysisFixtures.golden()
        #expect(BasicPitchTiming.windowCount(forSamples: golden.samples) == golden.windows)
        #expect(BasicPitchTiming.frameCount(forSamples: golden.samples) == golden.frames)
        #expect(BasicPitchTiming.windowStartSample(0) == -3840)
        #expect(BasicPitchTiming.windowStartSample(1) == 36_164 - 3840)
    }

    @Test func timeTracksAudioAcrossWindows() {
        // Frame f of window w starts at sample w·36164 − 3840 + (f − 142w + 15)·256.
        for f in [0, 141, 142, 300, 1848] {
            let w = f / 142
            let sample = w * 36_164 - 3840 + (f - 142 * w + 15) * 256
            #expect(abs(BasicPitchTiming.time(ofFrame: f) - Double(sample) / 22_050) < 1e-12)
        }
    }
}

@Suite("Note post-processing on the demo")
struct NotePostProcessorTests {
    func score(_ notes: [NoteEvent], tolerance: Double = 0.05) throws -> TranscriptionMetrics.Score {
        let truth = try AnalysisFixtures.truth()
        return TranscriptionMetrics.score(
            reference: truth.notes.map { .init(onset: $0.onset, pitch: $0.midi) },
            estimated: notes.map { .init(onset: $0.onset, pitch: $0.pitch.value) },
            onsetTolerance: tolerance)
    }

    @Test func improvesOnRawDecoding() throws {
        let activations = try AnalysisFixtures.activations()
        let source = AnalysisSource(component: .basicPitch, version: "test")
        let raw = NoteDecoder.decode(notes: activations.notes, onsets: activations.onsets)
        let (processed, report) = NotePostProcessor().process(raw, onsets: activations.onsets)

        let rawScore = try score(raw.compactMap { $0.noteEvent(source: source) })
        let processedScore = try score(processed.compactMap { $0.noteEvent(source: source) })
        print("[notes] raw \(rawScore) → processed \(processedScore); report \(report)")
        #expect(processedScore.f1 > rawScore.f1 + 0.1)
        #expect(processedScore.recall >= 0.85)
        #expect(processedScore.f1 >= 0.7)
        #expect(report.harmonics > 0)
        #expect(report.refinedOnsets > 0)
        #expect(report.kept == processed.count)
    }

    @Test func gatesToGuitarRange() {
        let notes = [
            FrameNote(startFrame: 10, endFrame: 30, pitch: 30, amplitude: 0.8),
            FrameNote(startFrame: 10, endFrame: 30, pitch: 45, amplitude: 0.8),
            FrameNote(startFrame: 10, endFrame: 30, pitch: 100, amplitude: 0.8),
        ]
        let (kept, report) = NotePostProcessor().process(notes, onsets: ActivationMatrix(frames: 40, bins: 88))
        #expect(kept.map(\.pitch) == [45])
        #expect(report.outOfRange == 2)
    }

    @Test func suppressesQuietOctaveButKeepsDoubling() {
        let onsets = ActivationMatrix(frames: 60, bins: 88)
        let quietOctave = [
            FrameNote(startFrame: 10, endFrame: 40, pitch: 40, amplitude: 0.8),
            FrameNote(startFrame: 11, endFrame: 35, pitch: 52, amplitude: 0.3),
        ]
        #expect(NotePostProcessor().process(quietOctave, onsets: onsets).notes.map(\.pitch) == [40])
        let doubling = [
            FrameNote(startFrame: 10, endFrame: 40, pitch: 40, amplitude: 0.8),
            FrameNote(startFrame: 10, endFrame: 40, pitch: 52, amplitude: 0.7),
        ]
        #expect(NotePostProcessor().process(doubling, onsets: onsets).notes.map(\.pitch) == [40, 52])
    }

    @Test func confidenceIsUncalibratedLevel() throws {
        let note = try #require(FrameNote(startFrame: 0, endFrame: 20, pitch: 40, amplitude: 0.5)
            .noteEvent(source: AnalysisSource(component: .basicPitch, version: "t")))
        #expect(note.confidence.isCalibrated == false)
        #expect(note.confidence.level == .medium)
        #expect(note.provenance == .detected)
    }
}

@Suite("Transcription metrics")
struct TranscriptionMetricsTests {
    @Test func maximumMatching() {
        // Greedy would match ref 0 to est 1 and leave ref 1 unmatched; the maximum matching gets both.
        let reference: [TranscriptionMetrics.Note] = [.init(onset: 1.00, pitch: 60), .init(onset: 1.06, pitch: 60)]
        let estimated: [TranscriptionMetrics.Note] = [.init(onset: 0.97, pitch: 60), .init(onset: 1.03, pitch: 60)]
        let score = TranscriptionMetrics.score(reference: reference, estimated: estimated)
        #expect(score.matched == 2)
        #expect(score.f1 == 1)
        let wrongPitch = TranscriptionMetrics.score(reference: reference, estimated: [.init(onset: 1, pitch: 61)])
        #expect(wrongPitch.matched == 0 && wrongPitch.f1 == 0)
    }
}


@Suite("Guessed notes")
struct NoteMapTests {
    @Test func windowQueryIncludesSoundingNotes() {
        let notes = [
            GuessedNote(start: 0, end: 3, midi: 40, string: 0, fret: 0, finger: 0, sure: true),
            GuessedNote(start: 1, end: 1.2, midi: 43, string: 0, fret: 3, finger: 3, sure: true),
            GuessedNote(start: 5, end: 5.5, midi: 45, string: 1, fret: 0, finger: 0, sure: false),
        ]
        let map = NoteMap(model: "t", sources: ["guitar"], notes: notes, seconds: 0)
        #expect(map.notes(from: 2, to: 4).map(\.midi) == [40]) // started earlier, still sounding
        #expect(map.notes(from: 0.5, to: 1.1).map(\.midi) == [40, 43])
        #expect(map.notes(from: 6, to: 7).isEmpty)
    }

    @Test func demoNotesArePlayableAndMostlyRight() throws {
        let activations = try AnalysisFixtures.activations()
        let truth = try AnalysisFixtures.truth()
        let guessed = NoteMapBuilder.guess(notes: activations.notes, onsets: activations.onsets, duration: truth.duration)
        let tuning = Tuning.standard
        for note in guessed {
            #expect((0..<6).contains(note.string))
            #expect(note.fret >= 0 && note.fret <= 24)
            #expect(tuning.pitch(at: FretPosition(string: note.string, fret: note.fret))?.value == note.midi)
        }
        let score = TranscriptionMetrics.score(
            reference: truth.notes.map { .init(onset: $0.onset, pitch: $0.midi) },
            estimated: guessed.map { .init(onset: $0.start, pitch: $0.midi) },
            onsetTolerance: 0.05)
        print("[guessed notes] \(score); sure \(guessed.filter(\.sure).count)/\(guessed.count)")
        #expect(score.f1 >= 0.7)
    }
}
