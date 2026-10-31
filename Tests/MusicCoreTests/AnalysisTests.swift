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

@Suite("Music Understanding result parsing")
struct MusicUnderstandingResultTests {
    @Test func parsesDemoResult() throws {
        let mu = try AnalysisFixtures.musicUnderstanding()
        let rhythm = try #require(mu.rhythmGrid(version: "test"))
        #expect(rhythm.beatsPerMinute == 96)
        #expect(rhythm.beats.count == 35)
        #expect(rhythm.bars.count == 9)
        #expect(abs((rhythm.medianBeatInterval ?? 0) - 0.625) < 0.001)
        #expect((rhythm.beatIntervalVariation ?? 1) < 0.01)

        let keys = mu.keySpans(version: "test")
        #expect(keys.count == 1)
        #expect(keys.first?.tonic == .e && keys.first?.mode == .minor)
        #expect(keys.first?.name() == "Em")

        #expect(mu.sectionRanges.count == 3)
        #expect(abs(mu.sectionRanges[1].lowerBound - 10) < 0.01)
        #expect(mu.phraseRanges.count == 5)

        let activity = try #require(mu.activity(duration: 21.5))
        #expect(activity.other.count == 86)
        #expect(activity.meanVocal == 0)
        #expect(activity.meanOther > 0.3)
    }

    @Test func pitchClassNames() {
        #expect(MusicUnderstandingResult.pitchClass(named: "e") == .e)
        #expect(MusicUnderstandingResult.pitchClass(named: "C#") == .cSharp)
        #expect(MusicUnderstandingResult.pitchClass(named: "b♭") == .aSharp)
        #expect(MusicUnderstandingResult.pitchClass(named: "cb") == .b)
        #expect(MusicUnderstandingResult.pitchClass(named: "h") == nil)
    }

    @Test func rejectsInvalidTimes() throws {
        let json = #"{"rhythm":{"beats":[{"epoch":0,"flags":0,"timescale":44100,"value":10},{"epoch":0,"flags":1,"timescale":44100,"value":44100}],"bars":[],"beatsPerMinute":0}}"#
        let mu = try MusicUnderstandingResult.decode(Data(json.utf8))
        let rhythm = try #require(mu.rhythmGrid(version: "t"))
        #expect(rhythm.beats == [1.0])
        #expect(rhythm.beatsPerMinute == nil)
        #expect(mu.keySpans(version: "t").isEmpty)
        #expect(mu.activity(duration: 10) == nil)
    }
}

@Suite("Chord estimation on the demo")
struct ChordEstimatorTests {
    func demoNotes() throws -> [NoteEvent] {
        let activations = try AnalysisFixtures.activations()
        let raw = NoteDecoder.decode(notes: activations.notes, onsets: activations.onsets)
        let source = AnalysisSource(component: .basicPitch, version: "test")
        return NotePostProcessor().process(raw, onsets: activations.onsets).notes.compactMap { $0.noteEvent(source: source) }
    }

    @Test func findsPowerChordsAndLeavesRiffAlone() throws {
        let truth = try AnalysisFixtures.truth()
        let notes = try demoNotes()
        let chords = ChordEstimator().estimate(notes: notes, beats: truth.beats, duration: truth.duration)
        print("[chords] " + chords.map { "\($0.chord?.symbol() ?? "N")@\(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end)) \($0.confidence.level)" }.joined(separator: ", "))

        // Per-beat accuracy against the truth chord spans.
        var correct = 0
        var total = 0
        var riffClean = 0
        var riffTotal = 0
        for beat in truth.beats {
            let mid = beat + 0.3
            let estimated = chords.first { $0.start <= mid && mid < $0.end }?.chord?.symbol()
            if let expected = truth.chords.first(where: { $0.start <= mid && mid < $0.end }) {
                total += 1
                if estimated == expected.symbol { correct += 1 }
            } else if mid < 10 {
                riffTotal += 1
                if estimated == nil { riffClean += 1 }
            }
        }
        print("[chords] beat accuracy \(correct)/\(total); riff beats without chord \(riffClean)/\(riffTotal)")
        #expect(Double(correct) / Double(max(total, 1)) >= 0.9)
        #expect(Double(riffClean) / Double(max(riffTotal, 1)) >= 0.8)
        #expect(chords.allSatisfy { $0.provenance == .inferred && !$0.confidence.isCalibrated })
        #expect(zip(chords, chords.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })
    }

    @Test func recognizesTriadsFromSyntheticNotes() throws {
        let source = AnalysisSource(component: .basicPitch, version: "t")
        func note(_ pitch: Int, _ start: Double, _ end: Double) -> NoteEvent {
            NoteEvent(onset: start, offset: end, pitch: MIDINote(unchecked: pitch), amplitude: 0.7,
                      confidence: Confidence(raw: 0.7, thresholds: (0.45, 0.6)), source: source)
        }
        // C major (C3 E3 G3) for 2 s, then A minor (A2 C3 E3) for 2 s.
        let notes = [note(48, 0, 2), note(52, 0, 2), note(55, 0, 2), note(45, 2, 4), note(48, 2, 4), note(52, 2, 4)]
        let beats = stride(from: 0.0, to: 4.0, by: 0.5).map { $0 }
        let chords = ChordEstimator().estimate(notes: notes, beats: beats, duration: 4)
        #expect(chords.map { $0.chord?.symbol() ?? "N" } == ["C", "Am"])
        #expect(chords.first?.confidence.level == .high)
    }

    @Test func fallbackGridWithoutBeats() {
        let estimator = ChordEstimator()
        let segments = estimator.segments(beats: [], duration: 1.2)
        #expect(segments.count == 3)
        #expect(segments.last?.end == 1.2)
    }
}

@Suite("Full analysis assembly on the demo")
struct AnalysisAssemblerTests {
    @Test func assemblesDemo() throws {
        let activations = try AnalysisFixtures.activations()
        let truth = try AnalysisFixtures.truth()
        let input = AnalysisAssembler.Input(duration: truth.duration, notes: activations.notes, onsets: activations.onsets,
                                            musicUnderstanding: try AnalysisFixtures.musicUnderstanding(),
                                            musicUnderstandingVersion: "ios27", basicPitchVersion: "icassp2022")
        let analysis = AnalysisAssembler.assemble(input)

        #expect(analysis.rhythm?.beatsPerMinute == 96)
        #expect(analysis.mainKey?.name() == "Em")
        print("[assembly] sections " + analysis.sections.map { "\($0.letter.isEmpty ? $0.kind.rawValue : $0.letter)(\($0.isChordal ? "chords" : "line"))" }.joined(separator: " "))
        print("[assembly] quality \(analysis.quality.level) \(analysis.quality.reasons) \(analysis.quality.metrics)")
        #expect(analysis.sections.map(\.letter) == ["A", "B", ""])
        #expect(analysis.sections.map(\.kind) == [.lettered, .lettered, .ending])
        #expect(analysis.sections.prefix(2).map(\.isChordal) == [false, true])
        #expect(analysis.quality.level == .good)
        #expect(analysis.notes.count > 40)
        #expect(analysis.chords.count >= 7)
        #expect(analysis.components.contains { $0.component == .musicUnderstanding })

        // Round-trips through JSON unchanged.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var rounded = analysis
        rounded.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try encoder.encode(rounded)
        #expect(try decoder.decode(SongAnalysis.self, from: data) == rounded)
    }

    @Test func worksWithoutMusicUnderstanding() throws {
        let activations = try AnalysisFixtures.activations()
        let input = AnalysisAssembler.Input(duration: 21.5, notes: activations.notes, onsets: activations.onsets,
                                            musicUnderstanding: nil, musicUnderstandingVersion: "none",
                                            basicPitchVersion: "icassp2022")
        let analysis = AnalysisAssembler.assemble(input)
        #expect(analysis.rhythm == nil)
        #expect(analysis.keys.isEmpty)
        #expect(analysis.sections.count == 1)
        #expect(analysis.quality.reasons.contains(.noBeatGrid))
        #expect(analysis.quality.reasons.contains(.noKey))
        #expect(analysis.quality.level == .fair)
        #expect(!analysis.chords.isEmpty)
    }
}
