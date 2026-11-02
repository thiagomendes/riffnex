import Foundation
import Testing
@testable import MusicCore

@Suite("RiffMap")
struct RiffMapTests {
    private func map(beats: [Seconds] = [], attacks: [Seconds] = []) -> RiffMap {
        RiffMap(duration: 10, beatsPerMinute: 120, beats: beats, bars: [], sections: [], envelopeRate: 10,
                guitar: [0, 1, 0.5], band: [0, 0, 0], guitarAttacks: attacks, stemsDirectory: "Stems",
                stemNames: ["guitar"], guitarStems: ["guitar"], separationSeconds: 1)
    }

    @Test func interpolatesEnvelopes() {
        let m = map()
        #expect(m.guitarLevel(at: 0) == 0)
        #expect(abs(m.guitarLevel(at: 0.05) - 0.5) < 1e-6)
        #expect(m.guitarLevel(at: 0.1) == 1)
        #expect(m.guitarLevel(at: -1) == 0)
        #expect(m.guitarLevel(at: 99) == 0)
    }

    @Test func snapsToBeats() {
        let m = map(beats: [0, 0.5, 1.0, 1.5])
        #expect(m.snapToBeat(0.7) == 0.5)
        #expect(m.snapToBeat(0.8) == 1.0)
        #expect(m.beat(atOrBefore: 0.99) == 0.5)
        #expect(m.beatLength == 0.5)
        #expect(abs((m.beatPhase(at: 0.75) ?? -1) - 0.5) < 1e-9)
        // Without a grid, times pass through.
        #expect(map().snapToBeat(0.7) == 0.7)
        #expect(map().beatPhase(at: 1) == nil)
    }

    @Test func attacksInRange() {
        let m = map(attacks: [0.1, 0.4, 0.4001, 2])
        #expect(Array(m.attacks(after: 0.1, upTo: 0.4)) == [0.4])
        #expect(Array(m.attacks(after: 0, upTo: 3)) == [0.1, 0.4, 0.4001, 2])
        #expect(m.attacks(after: 3, upTo: 1).isEmpty)
    }

    @Test func roundTripsAsJSON() throws {
        let m = map(beats: [0, 0.5], attacks: [0.2])
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(RiffMap.self, from: data) == m)
    }
}

@Suite("RiffMapBuilder")
struct RiffMapBuilderTests {
    @Test func rmsOfASteadySineIsItsRMS() {
        let sr = 1000.0
        let samples = (0..<2000).map { Float(sin(2 * Double.pi * 50 * Double($0) / sr)) }
        let env = RiffMapBuilder.rms(samples, sampleRate: sr, rate: 10)
        #expect(env.count == 20)
        for value in env { #expect(abs(value - Float(0.5.squareRoot())) < 0.01) }
    }

    @Test func combinesEnergies() {
        let out = RiffMapBuilder.combine([[3, 0], [4, 1, 2]])
        #expect(out == [5, 1, 2])
    }

    @Test func normalizesOnASharedScale() {
        let (g, b) = RiffMapBuilder.normalize(guitar: [0, 0.1, 0.4], band: [0.4, 0.4, 0.4])
        #expect(g[0] == 0)
        #expect(b.allSatisfy { abs($0 - 1) < 1e-6 })
        #expect(abs(g[1] - 0.5) < 1e-6) // sqrt(0.1 / 0.4)
        #expect(g.allSatisfy { $0 <= 1 })
    }

    @Test func findsPluckedAttacks() {
        // Plucks every 0.5 s with exponential decay, at 100 envelope values per second.
        let rate = 100.0
        let plucks: [Seconds] = [0.5, 1.0, 1.5, 2.0, 2.5]
        let env: [Float] = (0..<300).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for p in plucks where t >= p { v += exp(-(t - p) / 0.12) }
            return Float(0.01 + v)
        }
        let found = RiffMapBuilder.attacks(envelope: env, rate: rate)
        #expect(found.count == plucks.count)
        for (f, p) in zip(found, plucks) { #expect(abs(f - p) <= 0.02) }
    }

    @Test func silenceHasNoAttacks() {
        #expect(RiffMapBuilder.attacks(envelope: [Float](repeating: 0, count: 100), rate: 100).isEmpty)
        #expect(RiffMapBuilder.attacks(envelope: [Float](repeating: 0.3, count: 100), rate: 100).isEmpty)
    }

    @Test func barsEveryFourBeats() {
        #expect(RiffMapBuilder.bars(fromBeats: [0, 1, 2, 3, 4, 5, 6, 7, 8]) == [0, 4, 8])
    }
}

@Suite("Guitar stems")
struct GuitarStemsTests {
    @Test func guitarAloneWhenItIsLoudest() {
        #expect(RiffMapBuilder.guitarStems(energy: ["guitar": 0.5, "piano": 0.1, "other": 0.2]) == ["guitar"])
    }

    @Test func louderPitchedStemsJoin() {
        #expect(RiffMapBuilder.guitarStems(energy: ["guitar": 0.1, "piano": 0.3, "other": 0.05]) == ["guitar", "piano"])
        #expect(RiffMapBuilder.guitarStems(energy: [:]) == ["guitar"])
    }
}
