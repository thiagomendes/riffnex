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
        let neck = NeckNotes(tuning: .standard, notes: notes, unplayable: 0)
        #expect(neck.notes(from: 2, to: 4).map(\.midi) == [40]) // started earlier, still sounding
        #expect(neck.notes(from: 0.5, to: 1.1).map(\.midi) == [40, 43])
        #expect(neck.notes(from: 6, to: 7).isEmpty)
    }

    @Test func demoNotesArePlayableAndMostlyRight() throws {
        let activations = try AnalysisFixtures.activations()
        let truth = try AnalysisFixtures.truth()
        let detected = NoteMapBuilder.detect(notes: activations.notes, onsets: activations.onsets, duration: truth.duration)
        let neck = NoteMapBuilder.arrange(detected, tuning: .standard)
        for note in neck.notes {
            #expect((0..<6).contains(note.string))
            #expect(note.fret >= 0 && note.fret <= 24)
            #expect(Tuning.standard.pitch(at: FretPosition(string: note.string, fret: note.fret))?.value == note.midi)
        }
        let score = TranscriptionMetrics.score(
            reference: truth.notes.map { .init(onset: $0.onset, pitch: $0.midi) },
            estimated: neck.notes.map { .init(onset: $0.start, pitch: $0.midi) },
            onsetTolerance: 0.05)
        print("[guessed notes] \(score); sure \(neck.notes.filter(\.sure).count)/\(neck.notes.count), unplayable \(neck.unplayable)")
        #expect(score.f1 >= 0.7)
        // The demo is in standard tuning.
        #expect(TuningDetector.suggest(detected) == nil)
    }

    @Test func retuningMovesFretsNotPitches() {
        let detected = [DetectedNote(start: 0, end: 0.5, midi: 39, amplitude: 0.8),
                        DetectedNote(start: 0.5, end: 1, midi: 44, amplitude: 0.8)]
        #expect(NoteMapBuilder.arrange(detected, tuning: .standard).unplayable == 1) // D#2 is below the low E
        let eb = NoteMapBuilder.arrange(detected, tuning: TuningPreset.halfDown.tuning)
        #expect(eb.unplayable == 0)
        #expect(eb.notes.map(\.midi) == [39, 44])
        #expect(eb.notes.first?.fret == 0)
    }
}

@Suite("Tuning detection")
struct TuningDetectorTests {
    func notes(_ pitches: [Int: Int], sure: Bool = true) -> [DetectedNote] {
        var out: [DetectedNote] = []
        var t = 0.0
        for (midi, count) in pitches {
            for _ in 0..<count {
                out.append(DetectedNote(start: t, end: t + 0.2, midi: midi, amplitude: sure ? 0.8 : 0.2))
                t += 0.25
            }
        }
        return out
    }

    @Test func standardWhenItReachesTheLowE() {
        #expect(TuningDetector.suggest(notes([40: 30, 45: 20, 47: 20])) == nil)
    }

    @Test func halfDownWhenItSitsOnDSharp() {
        #expect(TuningDetector.suggest(notes([39: 30, 44: 20, 46: 20]))?.preset == .halfDown)
        // Occasional D# with plenty of low E is just a note, not a tuning.
        #expect(TuningDetector.suggest(notes([39: 5, 40: 40, 45: 20])) == nil)
    }

    @Test func dropTuningsFromNotesBelowE() {
        #expect(TuningDetector.suggest(notes([38: 20, 45: 20, 50: 20]))?.preset == .dropD)
        #expect(TuningDetector.suggest(notes([37: 20, 44: 20]))?.preset == .dropCSharp)
        #expect(TuningDetector.suggest(notes([36: 20, 43: 20]))?.preset == .dropC)
    }

    @Test func needsEnoughSureNotes() {
        #expect(TuningDetector.suggest(notes([36: 10])) == nil)
        #expect(TuningDetector.suggest(notes([36: 50], sure: false)) == nil)
    }

    @Test func presetNames() {
        #expect(TuningPreset.standard.stringNames == "E A D G B E")
        #expect(TuningPreset.dropD.stringNames == "D A D G B E")
        #expect(TuningPreset.halfDown.stringNames == "E♭ A♭ D♭ G♭ B♭ E♭")
    }
}

@Suite("Harmony")
struct HarmonyTests {
    func n(_ midi: Int, _ start: Double, _ end: Double) -> DetectedNote {
        DetectedNote(start: start, end: end, midi: midi, amplitude: 0.8)
    }

    @Test func powerChordsBecomeRootSpans() {
        // E5 for two beats, then G5 for two beats (root + fifth + octave).
        let notes = [n(40, 0, 1), n(47, 0, 1), n(52, 0, 1), n(43, 1, 2), n(50, 1, 2), n(55, 1, 2)]
        let spans = RootTrack.build(notes, beats: [0, 0.5, 1, 1.5], duration: 2)
        #expect(spans.map(\.name) == ["E5", "G5"])
        #expect(spans.first?.end == 1)
        let (current, next) = RootTrack.at(0.7, in: spans)
        #expect(current?.name == "E5" && next?.name == "G5")
    }

    @Test func aPassingNoteDoesNotFlicker() {
        // A riff on E with one passing low D beat in the middle.
        let notes = [n(40, 0, 0.5), n(38, 0.5, 1.0), n(40, 1.0, 1.5), n(40, 1.5, 2)]
        let spans = RootTrack.build(notes, beats: [0, 0.5, 1, 1.5], duration: 2)
        #expect(spans.map(\.name) == ["E"])
    }

    @Test func thirdsGiveMajorAndMinor() {
        let a = RootTrack.build([n(45, 0, 1), n(49, 0, 1), n(52, 0, 1)], beats: [0, 0.5], duration: 1)
        #expect(a.map(\.name) == ["A"])
        let am = RootTrack.build([n(45, 0, 1), n(48, 0, 1), n(52, 0, 1)], beats: [0, 0.5], duration: 1)
        #expect(am.map(\.name) == ["Am"])
    }

    @Test func keyFromNotes() {
        // E minor pentatonic riff, heavy on E.
        var notes: [DetectedNote] = []
        var t = 0.0
        for midi in [40, 43, 45, 47, 50, 40, 40, 43, 45, 40, 52, 47] {
            notes.append(n(midi, t, t + 0.4))
            t += 0.5
        }
        let key = KeyFinder.estimate(notes)
        #expect(key?.name == "Em")
        #expect(key?.source == .notes)
    }

    @Test func keyNames() {
        #expect(SongKey(tonic: .fSharp, minor: true, source: .notes).name == "F♯m")
        #expect(SongKey(tonic: .aSharp, minor: false, source: .notes).name == "B♭")
        #expect(SongKey(tonic: .e, minor: false, source: .notes).name == "E")
    }

    @Test func musicUnderstandingKey() throws {
        let json = #"{"key":{"ranges":[{"range":{"start":{"value":0,"timescale":1,"flags":1,"epoch":0},"duration":{"value":30,"timescale":1,"flags":1,"epoch":0}},"value":{"tonic":"f#","mode":"minor"}},{"range":{"start":{"value":30,"timescale":1,"flags":1,"epoch":0},"duration":{"value":5,"timescale":1,"flags":1,"epoch":0}},"value":{"tonic":"a","mode":"major"}}]}}"#
        let mu = try MusicUnderstandingResult.decode(Data(json.utf8))
        #expect(mu.mainKey?.name == "F♯m")
        #expect(mu.mainKey?.source == .musicUnderstanding)
    }
}
