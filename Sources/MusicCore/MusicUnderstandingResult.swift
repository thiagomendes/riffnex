import Foundation

/// Decodes the JSON encoding of Music Understanding's `SessionResult` (iOS 27), as observed on
/// device (see `docs/m0-findings.md`). Parsing the Codable JSON — instead of reading the Swift
/// properties — keeps this pure and testable on Linux, and isolates us from API renames.
/// Only what the practice screen uses is read: beats, bars, tempo and section boundaries.
public struct MusicUnderstandingResult: Decodable, Sendable {
    struct Time: Decodable, Sendable {
        let value: Int64
        let timescale: Int32
        let flags: UInt32

        var seconds: Double? {
            // kCMTimeFlags_Valid = 1; reject indefinite/infinite (flags 1<<2…1<<4).
            guard flags & 1 == 1, flags & 0b11100 == 0, timescale > 0 else { return nil }
            return Double(value) / Double(timescale)
        }
    }

    struct Range: Decodable, Sendable {
        let start: Time
        let duration: Time
    }

    struct Rhythm: Decodable, Sendable {
        let beats: [Time]?
        let bars: [Time]?
        let beatsPerMinute: Double?
    }

    struct Structure: Decodable, Sendable {
        let sections: [Range]?
    }

    let rhythm: Rhythm?
    let structure: Structure?

    public static func decode(_ data: Data) throws -> MusicUnderstandingResult {
        try JSONDecoder().decode(MusicUnderstandingResult.self, from: data)
    }

    public var beats: [Seconds] { (rhythm?.beats ?? []).compactMap(\.seconds).sorted() }
    public var bars: [Seconds] { (rhythm?.bars ?? []).compactMap(\.seconds).sorted() }

    public var beatsPerMinute: Double? {
        rhythm?.beatsPerMinute.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
    }

    /// Section boundaries, in order.
    public var sections: [RiffMap.Span] {
        (structure?.sections ?? []).compactMap { range in
            guard let start = range.start.seconds, let length = range.duration.seconds, length > 0 else { return nil }
            return RiffMap.Span(start: start, end: start + length)
        }.sorted { $0.start < $1.start }
    }
}
