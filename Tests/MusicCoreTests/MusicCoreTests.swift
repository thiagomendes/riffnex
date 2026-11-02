import Foundation
import Testing
@testable import MusicCore

@Suite("Pitch")
struct PitchTests {
    @Test func rangeValidation() {
        #expect(MIDINote(-1) == nil)
        #expect(MIDINote(128) == nil)
        #expect(MIDINote(0) != nil)
        #expect(MIDINote(127) != nil)
    }

    @Test func pitchClassAndOctave() {
        let c4 = MIDINote(unchecked: 60)
        #expect(c4.pitchClass == .c)
        #expect(c4.octave == 4)
        let lowE = MIDINote(unchecked: 40)
        #expect(lowE.pitchClass == .e)
        #expect(lowE.octave == 2)
    }

    @Test func frequencyRoundTrip() throws {
        #expect(abs(MIDINote(unchecked: 69).frequency() - 440) < 1e-9)
        #expect(abs(MIDINote(unchecked: 40).frequency() - 82.4069) < 1e-3)
        for value in 21...108 {
            let note = MIDINote(unchecked: value)
            let result = try #require(MIDINote.nearest(toFrequency: note.frequency()))
            #expect(result.note == note)
            #expect(abs(result.cents) < 1e-6)
        }
    }

    @Test func centsDeviation() throws {
        // 20 cents sharp of A4.
        let hz = 440 * pow(2, 20.0 / 1200)
        let result = try #require(MIDINote.nearest(toFrequency: hz))
        #expect(result.note.value == 69)
        #expect(abs(result.cents - 20) < 1e-6)
        #expect(MIDINote.nearest(toFrequency: 0) == nil)
        #expect(MIDINote.nearest(toFrequency: .nan) == nil)
    }

    @Test func pitchClassIntervals() {
        #expect(PitchClass.e.transposed(by: 7) == .b)
        #expect(PitchClass.c.transposed(by: -1) == .b)
        #expect(PitchClass.a.interval(to: .e) == 7)
        #expect(PitchClass.e.interval(to: .c) == 8)
    }

    @Test func naming() {
        let e2 = MIDINote(unchecked: 40)
        #expect(NoteNaming.letters.name(of: e2) == "E2")
        #expect(NoteNaming.solfege.name(of: e2) == "Mi 2")
        #expect(NoteNaming.letters.name(of: PitchClass.aSharp, preferFlats: true) == "B♭")
        #expect(NoteNaming.solfege.name(of: PitchClass.fSharp) == "Fá♯")
    }

    @Test func codableRejectsOutOfRange() throws {
        let data = Data("200".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MIDINote.self, from: data) }
        let ok = try JSONDecoder().decode(MIDINote.self, from: Data("64".utf8))
        #expect(ok.value == 64)
    }
}

@Suite("Tuning")
struct TuningTests {
    @Test func standardOpenStrings() {
        let names = Tuning.standard.openStrings.map { NoteNaming.letters.name(of: $0) }
        #expect(names == ["E2", "A2", "D3", "G3", "B3", "E4"])
    }

    @Test func pitchAtPosition() {
        let t = Tuning.standard
        #expect(t.pitch(at: FretPosition(string: 0, fret: 0))?.value == 40)
        #expect(t.pitch(at: FretPosition(string: 0, fret: 5))?.value == 45) // = open A
        #expect(t.pitch(at: FretPosition(string: 5, fret: 12))?.value == 76)
        #expect(t.pitch(at: FretPosition(string: 6, fret: 0)) == nil)
        #expect(t.pitch(at: FretPosition(string: 0, fret: 23)) == nil)
        #expect(t.pitch(at: FretPosition(string: 0, fret: -1)) == nil)
    }

    @Test func positionsForMiddleE() {
        // E4 (64) in standard tuning: open high e, B string 5th fret, G 9th, D 14th, A 19th.
        let positions = Tuning.standard.positions(for: MIDINote(unchecked: 64))
        #expect(positions == [
            FretPosition(string: 1, fret: 19),
            FretPosition(string: 2, fret: 14),
            FretPosition(string: 3, fret: 9),
            FretPosition(string: 4, fret: 5),
            FretPosition(string: 5, fret: 0),
        ])
    }

    @Test func outOfRangeHasNoPositions() {
        #expect(Tuning.standard.positions(for: MIDINote(unchecked: 39)).isEmpty) // below low E
        #expect(Tuning.standard.positions(for: MIDINote(unchecked: 87)).isEmpty) // above 22nd fret high e
        #expect(Tuning.dropD.positions(for: MIDINote(unchecked: 38)) == [FretPosition(string: 0, fret: 0)])
    }

    /// Invariant: every reported position sounds exactly the requested pitch, for every tuning,
    /// capo and pitch in the instrument's range.
    @Test(arguments: [Tuning.standard, .dropD, .halfStepDown,
                      Tuning(name: "Std capo 3", openStrings: Tuning.standard.openStrings, capo: 3)])
    func positionsRoundTrip(tuning: Tuning) {
        for value in 0...127 {
            let note = MIDINote(unchecked: value)
            let positions = tuning.positions(for: note)
            for p in positions {
                #expect(tuning.pitch(at: p) == note, "\(tuning.name) \(p) should sound \(note)")
            }
            #expect(Set(positions.map(\.string)).count == positions.count, "one position per string")
            if positions.isEmpty == false { #expect(tuning.range.contains(note)) }
        }
    }

    @Test func capoBlocksLowerFrets() {
        let capo2 = Tuning(name: "capo 2", openStrings: Tuning.standard.openStrings, capo: 2)
        #expect(capo2.pitch(at: FretPosition(string: 0, fret: 0))?.value == 42)
        #expect(capo2.pitch(at: FretPosition(string: 0, fret: 1)) == nil)
        #expect(capo2.positions(for: MIDINote(unchecked: 40)).isEmpty)
        #expect(capo2.range.lowerBound.value == 42)
    }

    @Test func tabLineNumbering() {
        #expect(FretPosition(string: 0, fret: 3).tabLineNumber(stringCount: 6) == 6)
        #expect(FretPosition(string: 5, fret: 3).tabLineNumber(stringCount: 6) == 1)
    }
}

@Suite("Chords & events")
struct ChordTests {
    @Test func symbols() {
        #expect(Chord(root: .e, quality: .minor).symbol() == "Em")
        #expect(Chord(root: .g, quality: .power).symbol() == "G5")
        #expect(Chord(root: .d, quality: .major, bass: .fSharp).symbol() == "D/F♯")
        #expect(Chord(root: .c, quality: .major7).symbol(naming: .solfege) == "Dó7M")
        #expect(Chord(root: .a, quality: .major, bass: .a).bass == nil)
    }

    @Test func pitchClasses() {
        #expect(Chord(root: .a, quality: .minor).pitchClasses == [.a, .c, .e])
        #expect(Chord(root: .e, quality: .power).pitchClasses == [.e, .b])
    }

    @Test func confidenceLevels() {
        let thresholds = (medium: 0.4, high: 0.7)
        #expect(Confidence(raw: 0.9, thresholds: thresholds).level == .high)
        #expect(Confidence(raw: 0.5, thresholds: thresholds).level == .medium)
        #expect(Confidence(raw: 0.1, thresholds: thresholds).level == .low)
        #expect(Confidence(raw: 1.7, thresholds: thresholds).raw == 1)
        #expect(Confidence(raw: 0.5, thresholds: thresholds).isCalibrated == false)
    }

    @Test func noteEventCodableRoundTrip() throws {
        let source = AnalysisSource(component: .basicPitch, version: "icassp2022")
        let note = NoteEvent(onset: 1.0, offset: 1.5, pitch: MIDINote(unchecked: 52), amplitude: 0.8,
                             pitchContourCents: [0, 10, 20],
                             techniques: [TechniqueAnnotation(kind: .bend(cents: 200),
                                                              confidence: Confidence(raw: 0.3, isCalibrated: false, level: .low),
                                                              source: source)],
                             confidence: Confidence(raw: 0.8, thresholds: (0.4, 0.7)), source: source)
        let decoded = try JSONDecoder().decode(NoteEvent.self, from: JSONEncoder().encode(note))
        #expect(decoded == note)
        #expect(decoded.isSounding(at: 1.2))
        #expect(!decoded.isSounding(at: 1.5))
        #expect(abs(decoded.duration - 0.5) < 1e-12)
    }
}
