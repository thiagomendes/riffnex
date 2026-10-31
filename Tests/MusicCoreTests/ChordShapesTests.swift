import Testing
@testable import MusicCore

@Suite("Chord shapes")
struct ChordShapesTests {
    @Test func openShapesWhenTheyExist() throws {
        let c = try #require(ChordShapes.shape(for: Chord(root: .c, quality: .major)))
        #expect(c.frets == [nil, 3, 2, 0, 1, 0])
        #expect(c.barreFret == nil)
        let em = try #require(ChordShapes.shape(for: Chord(root: .e, quality: .minor)))
        #expect(em.frets == [0, 2, 2, 0, 0, 0])
    }

    @Test func barreShapesForEverythingElse() throws {
        let f = try #require(ChordShapes.shape(for: Chord(root: .f, quality: .major)))
        #expect(f.frets == [1, 3, 3, 2, 1, 1])
        #expect(f.barreFret == 1)
        let bm = try #require(ChordShapes.shape(for: Chord(root: .b, quality: .minor)))
        #expect(bm.frets == [nil, 2, 4, 4, 3, 2]) // A-form at the 2nd fret is lower than E-form at the 7th
        let g5 = try #require(ChordShapes.shape(for: Chord(root: .g, quality: .power)))
        #expect(g5.frets == [3, 5, 5, nil, nil, nil])
    }

    @Test(arguments: PitchClass.allCases)
    func everyShapeSoundsItsChord(root: PitchClass) {
        for quality in ChordQuality.allCases {
            let chord = Chord(root: root, quality: quality)
            guard let shape = ChordShapes.shape(for: chord) else { continue }
            #expect(shape.pitchClasses(in: .standard) == chord.pitchClasses, "\(chord.symbol())")
            #expect(shape.maxFret - shape.baseFret <= 4, "\(chord.symbol()) too wide")
            #expect(shape.frets.count == 6 && shape.fingers.count == 6)
        }
        // Majors, minors and power chords always have a diagram.
        for quality in [ChordQuality.major, .minor, .power] {
            #expect(ChordShapes.shape(for: Chord(root: root, quality: quality)) != nil)
        }
    }

    @Test func noDiagramForOtherTunings() {
        #expect(ChordShapes.shape(for: Chord(root: .d, quality: .major), tuning: .dropD) == nil)
    }
}
