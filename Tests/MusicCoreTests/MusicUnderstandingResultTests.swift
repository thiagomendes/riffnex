import Foundation
import Testing
@testable import MusicCore

@Suite("Music Understanding result parsing")
struct MusicUnderstandingResultTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo-music-understanding.json")

    @Test func parsesDemoResult() throws {
        let mu = try MusicUnderstandingResult.decode(Data(contentsOf: Self.fixture))
        #expect(mu.beatsPerMinute == 96)
        #expect(mu.beats.count == 35)
        #expect(mu.bars.count == 9)
        #expect(abs((BeatGrid.medianInterval(mu.beats) ?? 0) - 0.625) < 0.001)
        #expect(mu.sections.count == 3)
        #expect(mu.mainKey?.name == "Em")
        #expect(abs(mu.sections[1].start - 10) < 0.01)
    }

    @Test func rejectsInvalidTimes() throws {
        let json = #"{"rhythm":{"beats":[{"epoch":0,"flags":0,"timescale":44100,"value":10},{"epoch":0,"flags":1,"timescale":44100,"value":44100}],"bars":[],"beatsPerMinute":0}}"#
        let mu = try MusicUnderstandingResult.decode(Data(json.utf8))
        #expect(mu.beats == [1.0])
        #expect(mu.beatsPerMinute == nil)
        #expect(mu.sections.isEmpty)
    }
}
