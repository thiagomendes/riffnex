import Foundation

/// Decodes the JSON encoding of Music Understanding's `SessionResult` (iOS 27), as observed on
/// device (see `docs/m0-findings.md`). Parsing the Codable JSON — instead of reading the Swift
/// properties — keeps this pure and testable on Linux, and isolates us from API renames.
/// The undocumented `structurePredictions` member is deliberately ignored.
public struct MusicUnderstandingResult: Decodable, Sendable {
    public static let component = AnalysisSource.Component.musicUnderstanding

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

    struct Structure: Decodable, Sendable {
        let sections: [Range]?
        let segments: [Range]?
        let phrases: [Range]?
    }

    struct ActivityPoint: Decodable, Sendable {
        let time: Time
        let value: Float
    }

    struct Activity: Decodable, Sendable {
        let activity: [String: [ActivityPoint]]?
    }

    let rhythm: Rhythm?
    let key: Key?
    let structure: Structure?
    let instrumentActivity: Activity?

    public static func decode(_ data: Data) throws -> MusicUnderstandingResult {
        try JSONDecoder().decode(MusicUnderstandingResult.self, from: data)
    }

    // MARK: Conversion

    public func rhythmGrid(version: String) -> RhythmGrid? {
        guard let rhythm else { return nil }
        let beats = (rhythm.beats ?? []).compactMap(\.seconds).sorted()
        let bars = (rhythm.bars ?? []).compactMap(\.seconds).sorted()
        guard !beats.isEmpty || rhythm.beatsPerMinute != nil else { return nil }
        let bpm = rhythm.beatsPerMinute.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        return RhythmGrid(beatsPerMinute: bpm, beats: beats, bars: bars,
                          source: AnalysisSource(component: Self.component, version: version))
    }

    public func keySpans(version: String) -> [KeySpan] {
        (key?.ranges ?? []).compactMap { range in
            guard let start = range.range.start.seconds, let length = range.range.duration.seconds, length > 0,
                  let tonic = Self.pitchClass(named: range.value.tonic),
                  let mode = KeyMode(rawValue: range.value.mode.lowercased()) else { return nil }
            return KeySpan(start: start, end: start + length, tonic: tonic, mode: mode,
                           source: AnalysisSource(component: Self.component, version: version))
        }
    }

    /// Unlabeled section ranges, in order.
    public var sectionRanges: [ClosedRange<Seconds>] {
        Self.ranges(structure?.sections)
    }

    public var phraseRanges: [ClosedRange<Seconds>] {
        Self.ranges(structure?.phrases)
    }

    /// Activity per class resampled to `resolution` seconds (mean of the points in each bucket).
    public func activity(duration: Seconds, resolution: Seconds = 0.25) -> InstrumentActivity? {
        guard let classes = instrumentActivity?.activity, !classes.isEmpty, duration > 0, resolution > 0 else { return nil }
        let count = max(1, Int((duration / resolution).rounded(.up)))
        func series(_ name: String) -> [Float] {
            guard let points = classes[name] else { return Array(repeating: 0, count: count) }
            var sums = [Float](repeating: 0, count: count)
            var counts = [Int](repeating: 0, count: count)
            for point in points {
                guard let t = point.time.seconds, t >= 0 else { continue }
                let index = min(count - 1, Int(t / resolution))
                sums[index] += point.value
                counts[index] += 1
            }
            return zip(sums, counts).map { $1 > 0 ? $0 / Float($1) : 0 }
        }
        return InstrumentActivity(resolution: resolution, other: series("other"), vocal: series("vocal"),
                                  bass: series("bass"), drum: series("drum"))
    }

    static func ranges(_ ranges: [Range]?) -> [ClosedRange<Seconds>] {
        (ranges ?? []).compactMap { range in
            guard let start = range.start.seconds, let length = range.duration.seconds, length > 0 else { return nil }
            return start...(start + length)
        }.sorted { $0.lowerBound < $1.lowerBound }
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
