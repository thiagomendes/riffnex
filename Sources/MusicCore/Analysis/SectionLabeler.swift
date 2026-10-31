import Foundation

/// Gives Music Understanding's unlabeled section ranges musical letters (A, B, A′…) by comparing
/// what is played in them: each section becomes a sequence of pitch-class profiles over 16 equal
/// slices, and sections are compared slice by slice with cosine similarity.
public struct SectionLabeler: Sendable {
    public struct Parameters: Sendable, Equatable {
        public var slices = 16
        public var sameThreshold = 0.85
        public var variationThreshold = 0.7
        public var endingMaxLength: Seconds = 4
        public var chordalCoverage = 0.5

        public init() {}
    }

    public var parameters: Parameters

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    public func label(ranges: [ClosedRange<Seconds>], notes: [NoteEvent], chords: [ChordEvent],
                      duration: Seconds) -> [SongSection] {
        var spans = ranges.map { (max(0, $0.lowerBound), min(duration, $0.upperBound)) }.filter { $0.1 > $0.0 }
        if spans.isEmpty, duration > 0 { spans = [(0, duration)] }

        let features = spans.map { profileSequence(notes: notes, start: $0.0, end: $0.1) }
        var sections: [SongSection] = []
        var representatives: [(letter: String, feature: [[Double]])] = []
        let lengths = spans.map { $0.1 - $0.0 }.sorted()
        let medianLength = lengths.isEmpty ? 0 : lengths[lengths.count / 2]

        for (index, span) in spans.enumerated() {
            let feature = features[index]
            let chordal = chordCoverage(chords, start: span.0, end: span.1) >= parameters.chordalCoverage
            let hasContent = feature.contains { slice in slice.contains { $0 > 0 } }
            let length = span.1 - span.0
            if index == spans.count - 1, spans.count > 1, length <= parameters.endingMaxLength,
               length < 0.5 * medianLength {
                sections.append(SongSection(start: span.0, end: span.1, letter: "", kind: .ending, isChordal: chordal))
                continue
            }
            if !hasContent {
                sections.append(SongSection(start: span.0, end: span.1, letter: "", kind: .silent, isChordal: false))
                continue
            }
            var bestLetter: String?
            var bestSimilarity = -1.0
            for representative in representatives {
                let similarity = Self.similarity(feature, representative.feature)
                if similarity > bestSimilarity {
                    bestSimilarity = similarity
                    bestLetter = representative.letter
                }
            }
            let letter: String
            if let bestLetter, bestSimilarity >= parameters.sameThreshold {
                letter = bestLetter
            } else if let bestLetter, bestSimilarity >= parameters.variationThreshold {
                letter = bestLetter + "′"
            } else {
                letter = Self.letter(at: representatives.count)
                representatives.append((letter, feature))
            }
            sections.append(SongSection(start: span.0, end: span.1, letter: letter, kind: .lettered, isChordal: chordal))
        }
        return sections
    }

    func profileSequence(notes: [NoteEvent], start: Seconds, end: Seconds) -> [[Double]] {
        let count = parameters.slices
        let width = (end - start) / Double(count)
        var result = [[Double]](repeating: [Double](repeating: 0, count: 12), count: count)
        guard width > 0 else { return result }
        for note in notes where note.offset > start && note.onset < end {
            for slice in 0..<count {
                let a = start + Double(slice) * width
                let b = a + width
                let overlap = min(note.offset, b) - max(note.onset, a)
                if overlap > 0 { result[slice][note.pitch.pitchClass.rawValue] += note.amplitude * overlap }
            }
        }
        return result
    }

    static func similarity(_ a: [[Double]], _ b: [[Double]]) -> Double {
        var total = 0.0
        var counted = 0
        for (x, y) in zip(a, b) {
            let nx = x.map { $0 * $0 }.reduce(0, +).squareRoot()
            let ny = y.map { $0 * $0 }.reduce(0, +).squareRoot()
            if nx == 0 && ny == 0 { continue }
            counted += 1
            if nx > 0 && ny > 0 { total += zip(x, y).map { $0 * $1 }.reduce(0, +) / (nx * ny) }
        }
        return counted > 0 ? total / Double(counted) : 0
    }

    func chordCoverage(_ chords: [ChordEvent], start: Seconds, end: Seconds) -> Double {
        guard end > start else { return 0 }
        let covered = chords.filter { $0.chord != nil }
            .map { max(0, min($0.end, end) - max($0.start, start)) }.reduce(0, +)
        return covered / (end - start)
    }

    static func letter(at index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < letters.count ? String(letters[index]) : "S\(index + 1)"
    }
}
