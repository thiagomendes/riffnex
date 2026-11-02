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

    struct KeyValue: Decodable, Sendable {
        let tonic: String
        let mode: String
    }

    struct KeyRange: Decodable, Sendable {
        let range: Range
        let value: KeyValue
    }

    struct Key: Decodable, Sendable {
        let ranges: [KeyRange]?
    }

    let rhythm: Rhythm?
    let structure: Structure?
    let key: Key?

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

    /// The key that covers most of the song.
    public var mainKey: SongKey? {
        var durations: [SongKey: Double] = [:]
        for range in key?.ranges ?? [] {
            guard let length = range.range.duration.seconds, length > 0,
                  let tonic = Self.pitchClass(named: range.value.tonic) else { continue }
            let mode = range.value.mode.lowercased()
            guard mode == "major" || mode == "minor" else { continue }
            durations[SongKey(tonic: tonic, minor: mode == "minor", source: .musicUnderstanding), default: 0] += length
        }
        return durations.max { $0.value < $1.value }?.key
    }

    /// "e", "c#", "f♯", "bb", "B♭"… → pitch class.
    static func pitchClass(named raw: String) -> PitchClass? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "sharp", with: "#").replacingOccurrences(of: "flat", with: "b")
        guard let letter = name.first else { return nil }
        let base: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]
        guard let semitone = base[letter] else { return nil }
        var offset = 0
        for accidental in name.dropFirst() {
            switch accidental {
            case "#": offset += 1
            case "b": offset -= 1
            default: return nil
            }
        }
        return PitchClass.c.transposed(by: semitone + offset)
    }
}
