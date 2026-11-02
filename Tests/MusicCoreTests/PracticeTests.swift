import Foundation
import Testing
@testable import MusicCore

private let source = AnalysisSource(component: .basicPitch, version: "t")
private func note(_ pitch: Int, _ onset: Double, _ length: Double, _ amplitude: Double = 0.7) -> NoteEvent {
    NoteEvent(onset: onset, offset: onset + length, pitch: MIDINote(unchecked: pitch), amplitude: amplitude,
              confidence: Confidence(raw: amplitude, thresholds: (0.45, 0.6)), source: source)
}

@Suite("Practice: main line, phrases, key")
struct PracticeTests {
    @Test func mainLineKeepsOneNoteAtATime() {
        let notes = [
            note(40, 0, 1.0, 0.8), note(47, 0.01, 1.0, 0.5), note(52, 0.02, 1.0, 0.4), // chord: loudest wins
            note(43, 0.5, 0.5, 0.7),                                                  // cuts the previous note
            note(64, 1.2, 0.3, 0.2),                                                  // too quiet: dropped
            note(45, 1.5, 0.4, 0.6),
        ]
        let line = MainLine.extract(from: notes)
        #expect(line.map(\.pitch.value) == [40, 43, 45])
        #expect(abs(line[0].offset - 0.5) < 1e-9)
        for (a, b) in zip(line, line.dropFirst()) { #expect(a.offset <= b.onset + 1e-9) }
    }

    @Test func demoRiffLineIsTheRiff() throws {
        let truth = try AnalysisFixtures.truth()
        let notes = truth.notes.map { note($0.midi, $0.onset, $0.offset - $0.onset) }
        let line = MainLine.extract(from: notes)
        // The riff part (first 10 s) is single notes already: all of it survives.
        #expect(line.filter { $0.onset < 10 }.count == truth.notes.filter { $0.onset < 10 }.count)
        // Power chords become one note each (7 chords).
        #expect(line.filter { $0.onset >= 10 }.count == 7)
    }

    @Test func phrasesFollowBars() {
        let notes = (0..<16).map { note(40 + $0 % 5, Double($0) * 0.5, 0.4) }
        let bars = stride(from: 0.0, to: 8.0, by: 2.0).map { $0 }
        let phrases = PhraseSplitter.split(line: notes, bars: bars, duration: 8)
        #expect(phrases.count == 2) // 2 bars per phrase, 4 bars
        #expect(phrases[0].noteIDs.count == 8)
        #expect(phrases[0].start == 0)
        #expect(phrases[1].start >= 3.8 && phrases[1].start <= 4)
    }

    @Test func phrasesFollowSilencesWithoutBars() {
        let notes = [note(40, 0, 0.4), note(41, 0.5, 0.4), note(42, 3, 0.4), note(43, 3.5, 0.4)]
        let phrases = PhraseSplitter.split(line: notes, bars: [], duration: 5)
        #expect(phrases.count == 2)
        #expect(phrases.map(\.noteIDs.count) == [2, 2])
    }

    @Test func keySummary() {
        let key = KeySpan(start: 0, end: 10, tonic: .e, mode: .minor, source: source)
        let chords = [
            ChordEvent(start: 0, end: 4, chord: Chord(root: .e, quality: .minor), provenance: .inferred,
                       confidence: Confidence(raw: 1, isCalibrated: false, level: .high), source: source),
            ChordEvent(start: 4, end: 5, chord: Chord(root: .g, quality: .major), provenance: .inferred,
                       confidence: Confidence(raw: 1, isCalibrated: false, level: .high), source: source),
        ]
        let summary = KeySummary(key: key, chords: chords)
        #expect(summary.names(summary.scale) == ["E", "F♯", "G", "A", "B", "C", "D"])
        #expect(summary.names(summary.pentatonic) == ["E", "G", "A", "B", "D"])
        #expect(summary.chords.map { $0.symbol() } == ["Em", "G"])
        let flat = KeySummary(key: KeySpan(start: 0, end: 1, tonic: .f, mode: .major, source: source), chords: [])
        #expect(flat.names(flat.scale) == ["F", "G", "A", "B♭", "C", "D", "E"])
    }

    @Test func beatPosition() throws {
        let beats = stride(from: 0.0, to: 8.0, by: 0.5).map { $0 }
        let bars = stride(from: 0.0, to: 8.0, by: 2.0).map { $0 }
        let first = try #require(BeatPosition.at(0.1, beats: beats, bars: bars))
        #expect(first.beat == 1 && first.beatsPerBar == 4)
        let third = try #require(BeatPosition.at(3.1, beats: beats, bars: bars))
        #expect(third.beat == 3)
        #expect(BeatPosition.beats(from: 2.1, until: 4.0, beats: beats) == 4)
        #expect(BeatPosition.at(1, beats: [], bars: []) == nil)
    }
}
