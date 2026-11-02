import Foundation
import Testing
@testable import MusicCore

private let source = AnalysisSource(component: .basicPitch, version: "test")

private func note(_ pitch: Int, _ onset: Double, _ length: Double = 0.25, amplitude: Double = 0.7) -> NoteEvent {
    NoteEvent(onset: onset, offset: onset + length, pitch: MIDINote(unchecked: pitch), amplitude: amplitude,
              confidence: Confidence(raw: amplitude, thresholds: (0.45, 0.6)), source: source)
}

@Suite("Fingering optimizer")
struct FingeringOptimizerTests {
    let optimizer = FingeringOptimizer()

    @Test func invariantsHold() {
        let notes = [note(40, 0), note(47, 0), note(52, 0), note(55, 0.5), note(57, 1.0), note(64, 1.5), note(76, 2)]
        let arrangement = optimizer.arrange(notes: notes)
        #expect(arrangement.notes.count == notes.count)
        #expect(arrangement.unplayable.isEmpty)
        for arranged in arrangement.notes {
            // Every recommended position sounds the detected pitch.
            #expect(Tuning.standard.pitch(at: arranged.position) == arranged.pitch)
            #expect(arranged.provenance == .recommended)
            #expect((arranged.position.fret == 0) == (arranged.finger == .open))
        }
        // Simultaneous notes are on distinct strings within a playable span.
        let chord = arrangement.notes.filter { $0.onset == 0 }
        #expect(Set(chord.map(\.position.string)).count == 3)
        let frets = chord.map(\.position.fret).filter { $0 > 0 }
        #expect((frets.max() ?? 0) - (frets.min() ?? 0) <= 4)
        // Deterministic.
        #expect(optimizer.arrange(notes: notes).notes.map(\.position) == arrangement.notes.map(\.position))
    }

    @Test func reportsUnplayableNotes() {
        let low = note(30, 0) // below low E
        let arrangement = optimizer.arrange(notes: [low, note(45, 1)])
        #expect(arrangement.unplayable == [low.id])
        #expect(arrangement.notes.count == 1)
    }

    @Test func powerChordRiffUsesLowStringShapes() {
        // G5 – A5 – C5 (root, fifth, octave).
        let chords = [[43, 50, 55], [45, 52, 57], [48, 55, 60]]
        let notes = chords.enumerated().flatMap { index, pitches in pitches.map { note($0, Double(index)) } }
        let arrangement = optimizer.arrange(notes: notes)
        for (index, pitches) in chords.enumerated() {
            let group = arrangement.notes.filter { $0.onset == Double(index) }.sorted { $0.pitch < $1.pitch }
            #expect(group.count == 3)
            let root = group[0].position
            #expect(root.string <= 1, "root of \(pitches) on string \(root.string)")
            // Classic shape: root, then the next two strings two frets up (or open on an open root).
            #expect(group.map(\.position.string) == [root.string, root.string + 1, root.string + 2])
        }
        let g5 = arrangement.notes.first { $0.pitch.value == 43 }!.position
        #expect(g5 == FretPosition(string: 0, fret: 3))
        let c5 = arrangement.notes.first { $0.pitch.value == 48 }!.position
        #expect(c5 == FretPosition(string: 1, fret: 3))
    }

    @Test func pentatonicBoxDoesNotZigZag() {
        // E minor pentatonic, two octaves up and down, at a steady eighth-note pace (12th-position box).
        let up = [52, 55, 57, 59, 62, 64, 67, 69, 71, 74, 76]
        let line = up + up.reversed().dropFirst()
        let notes = line.enumerated().map { note($0.element, Double($0.offset) * 0.25, 0.24) }
        let arrangement = optimizer.arrange(notes: notes)
        let hands = arrangement.notes.compactMap(\.handPosition)
        let shifts = zip(hands, hands.dropFirst()).filter { $0 != $1 }.count
        print("[fingering] pentatonic hands \(hands); positions \(arrangement.notes.map(\.position.description))")
        #expect(shifts <= 2, "hand moved \(shifts) times: \(hands)")
        let frets = arrangement.notes.map(\.position.fret)
        // Either the open box or the 12th-fret box, not a mix of both ends of the neck.
        #expect((frets.max() ?? 0) - (frets.filter { $0 > 0 }.min() ?? 0) <= 5)
        // No open strings mixed into a box played up the neck.
        if let lowestHand = hands.min(), lowestHand > 4 { #expect(!frets.contains(0)) }
    }

    @Test func demoRiffMatchesHowItWasWritten() throws {
        let truth = try AnalysisFixtures.truth()
        struct Written: Decodable { let notes: [N]; struct N: Decodable { let onset: Double; let offset: Double; let midi: Int; let string: Int; let fret: Int } }
        let written = try JSONDecoder().decode(Written.self, from: Data(contentsOf: AnalysisFixtures.truthURL))
        #expect(written.notes.count == truth.notes.count)
        let notes = written.notes.map { note($0.midi, $0.onset, $0.offset - $0.onset) }
        let arrangement = optimizer.arrange(notes: notes, phraseBoundaries: [5, 10, 15])
        var same = 0
        for (input, writtenNote) in zip(notes, written.notes) {
            let arranged = arrangement.notes.first { $0.noteID == input.id }
            if arranged?.position == FretPosition(string: writtenNote.string, fret: writtenNote.fret) { same += 1 }
        }
        print("[fingering] demo: \(same)/\(written.notes.count) positions as written")
        #expect(Double(same) / Double(written.notes.count) >= 0.8)
    }

    @Test func barreAndFingers() {
        // F major barre chord: F2 C3 F3 A3 C4 F4 (1-3-3-2-1-1 at the 1st fret).
        let pitches = [41, 48, 53, 57, 60, 65]
        let arrangement = optimizer.arrange(notes: pitches.map { note($0, 0) })
        let byString = arrangement.notes.sorted { $0.position.string < $1.position.string }
        print("[fingering] F: \(byString.map { "\($0.position) \($0.finger)" })")
        #expect(byString.map(\.position.fret) == [1, 3, 3, 2, 1, 1])
        #expect(byString.filter(\.isBarre).count >= 2)
        #expect(byString.map(\.finger) == [.index, .ring, .ring, .middle, .index, .index])
    }

    @Test func emptyInput() {
        #expect(optimizer.arrange(notes: []).notes.isEmpty)
    }
}
