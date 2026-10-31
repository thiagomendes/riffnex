import Foundation

/// Beat-synchronous chord estimation from detected notes.
///
/// For every beat we build a pitch-class profile (note amplitude × time overlap) and a bass
/// histogram (the lowest sounding note), and match it against binary chord templates with cosine
/// similarity plus a small bonus when the bass is the chord root. Beats where fewer than two
/// distinct pitch classes sound together for most of the beat are "no chord": a single-line riff
/// is not a chord, and we do not pretend it is. Runs of chord beats are smoothed with Viterbi
/// decoding (a constant penalty for changing chord).
///
/// Confidence is derived from the template score and the margin to the runner-up. It is a
/// heuristic, **uncalibrated** — the UI shows only its level.
public struct ChordEstimator: Sendable {
    public static let version = "chords-1"

    public struct Parameters: Sendable, Equatable {
        public var qualities: [ChordQuality]
        public var bassBonus: Double
        public var minPolyphony: Double
        public var changePenalty: Double
        public var samplesPerBeat: Int
        /// Used when there is no beat grid.
        public var fallbackSegment: Seconds

        public init(qualities: [ChordQuality] = [.major, .minor, .power, .dominant7, .major7, .minor7],
                    bassBonus: Double = 0.15, minPolyphony: Double = 0.5, changePenalty: Double = 0.08,
                    samplesPerBeat: Int = 24, fallbackSegment: Seconds = 0.5) {
            self.qualities = qualities
            self.bassBonus = bassBonus
            self.minPolyphony = minPolyphony
            self.changePenalty = changePenalty
            self.samplesPerBeat = samplesPerBeat
            self.fallbackSegment = fallbackSegment
        }
    }

    /// Per-beat evidence, exposed for tests and the quality report.
    public struct BeatEvidence: Sendable, Equatable {
        public var start: Seconds
        public var end: Seconds
        public var polyphony: Double
        public var profile: [Double]
        /// How often each pitch class was the lowest sounding note.
        public var bass: [Double]
        /// Best chord by raw score, before smoothing; `nil` for no-chord beats.
        public var best: Chord?
        public var score: Double
        public var margin: Double
    }

    struct Template {
        let chord: Chord
        let vector: [Double]
    }

    public var parameters: Parameters
    let templates: [Template]

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
        var templates: [Template] = []
        for root in PitchClass.allCases {
            for quality in parameters.qualities {
                var v = [Double](repeating: 0, count: 12)
                for interval in quality.intervals { v[root.transposed(by: interval).rawValue] = 1 }
                let norm = v.reduce(0, +).squareRoot()
                templates.append(Template(chord: Chord(root: root, quality: quality), vector: v.map { $0 / norm }))
            }
        }
        self.templates = templates
    }

    var source: AnalysisSource { AnalysisSource(component: .chordEstimator, version: Self.version) }

    /// Segment boundaries: beats if available (extended by one beat at the end), otherwise a fixed grid.
    public func segments(beats: [Seconds], duration: Seconds) -> [(start: Seconds, end: Seconds)] {
        let sorted = beats.filter { $0 >= 0 && $0 < duration }.sorted()
        if sorted.count >= 2 {
            var result: [(Seconds, Seconds)] = zip(sorted, sorted.dropFirst()).map { ($0, $1) }
            let intervals = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.sorted()
            let median = intervals[intervals.count / 2]
            if let last = sorted.last, last < duration { result.append((last, min(duration, last + median))) }
            return result.filter { $0.1 > $0.0 }
        }
        var result: [(Seconds, Seconds)] = []
        var t = 0.0
        while t < duration {
            result.append((t, min(duration, t + parameters.fallbackSegment)))
            t += parameters.fallbackSegment
        }
        return result
    }

    public func evidence(notes: [NoteEvent], beats: [Seconds], duration: Seconds) -> [BeatEvidence] {
        let sortedNotes = notes.sorted { $0.onset < $1.onset }
        let longest = sortedNotes.map(\.duration).max() ?? 0
        let onsets = sortedNotes.map(\.onset)

        return segments(beats: beats, duration: duration).map { segment in
            // Notes overlapping the segment: onset in (start − longest, end).
            let lower = Self.firstIndex(in: onsets, notBelow: segment.start - longest)
            let upper = Self.firstIndex(in: onsets, notBelow: segment.end)
            let overlapping = sortedNotes[lower..<upper].filter { $0.offset > segment.start }

            var profile = [Double](repeating: 0, count: 12)
            for note in overlapping {
                let overlap = min(note.offset, segment.end) - max(note.onset, segment.start)
                if overlap > 0 { profile[note.pitch.pitchClass.rawValue] += note.amplitude * overlap }
            }
            var bass = [Double](repeating: 0, count: 12)
            var polyphonic = 0
            let samples = max(1, parameters.samplesPerBeat)
            for s in 0..<samples {
                let t = segment.start + (segment.end - segment.start) * Double(s) / Double(samples)
                let sounding = overlapping.filter { $0.isSounding(at: t) }
                if Set(sounding.map(\.pitch.pitchClass)).count >= 2 { polyphonic += 1 }
                if let lowest = sounding.min(by: { $0.pitch < $1.pitch }) { bass[lowest.pitch.pitchClass.rawValue] += 1 }
            }
            let polyphony = Double(polyphonic) / Double(samples)

            var evidence = BeatEvidence(start: segment.start, end: segment.end, polyphony: polyphony,
                                        profile: profile, bass: bass, best: nil, score: 0, margin: 0)
            let norm = profile.map { $0 * $0 }.reduce(0, +).squareRoot()
            guard polyphony >= parameters.minPolyphony, norm > 0 else { return evidence }
            let scores = self.scores(profile: profile.map { $0 / norm }, bass: bass)
            var order = Array(scores.indices)
            order.sort { scores[$0] > scores[$1] }
            evidence.best = templates[order[0]].chord
            evidence.score = scores[order[0]]
            evidence.margin = order.count > 1 ? scores[order[0]] - scores[order[1]] : scores[order[0]]
            return evidence
        }
    }

    func scores(profile: [Double], bass: [Double]) -> [Double] {
        let bassTotal = bass.reduce(0, +)
        return templates.map { template in
            var dot = 0.0
            for i in 0..<12 { dot += profile[i] * template.vector[i] }
            let bassShare = bassTotal > 0 ? bass[template.chord.root.rawValue] / bassTotal : 0
            return dot + parameters.bassBonus * bassShare
        }
    }

    public func estimate(notes: [NoteEvent], beats: [Seconds], duration: Seconds) -> [ChordEvent] {
        let beatEvidence = evidence(notes: notes, beats: beats, duration: duration)
        var labels = [Int?](repeating: nil, count: beatEvidence.count)
        var beatScores = [Double](repeating: 0, count: beatEvidence.count)
        var beatMargins = [Double](repeating: 0, count: beatEvidence.count)

        // Viterbi over each run of consecutive chord beats.
        var runStart: Int?
        func smooth(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let tables: [[Double]] = range.map { scoreTable(beatEvidence[$0]) }
            let n = templates.count
            var dp = tables[0]
            var back: [[Int]] = []
            for step in tables.indices.dropFirst() {
                let bestPrevious = dp.indices.max { dp[$0] < dp[$1] }!
                let change = dp[bestPrevious] - parameters.changePenalty
                var next = [Double](repeating: 0, count: n)
                var pointers = [Int](repeating: 0, count: n)
                for s in 0..<n {
                    if dp[s] >= change {
                        next[s] = dp[s] + tables[step][s]
                        pointers[s] = s
                    } else {
                        next[s] = change + tables[step][s]
                        pointers[s] = bestPrevious
                    }
                }
                back.append(pointers)
                dp = next
            }
            var state = dp.indices.max { dp[$0] < dp[$1] }!
            var path = [Int](repeating: 0, count: tables.count)
            for step in stride(from: tables.count - 1, through: 0, by: -1) {
                path[step] = state
                if step > 0 { state = back[step - 1][state] }
            }
            for (offset, index) in range.enumerated() {
                let table = tables[offset]
                let chosen = path[offset]
                labels[index] = chosen
                beatScores[index] = table[chosen]
                let runnerUp = table.indices.filter { $0 != chosen }.map { table[$0] }.max() ?? 0
                beatMargins[index] = table[chosen] - runnerUp
            }
        }
        for index in beatEvidence.indices {
            if beatEvidence[index].best != nil {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                smooth(start..<index)
                runStart = nil
            }
        }
        if let start = runStart { smooth(start..<beatEvidence.count) }

        // Merge equal consecutive labels into events (no-chord spans are omitted).
        var events: [ChordEvent] = []
        var index = 0
        while index < beatEvidence.count {
            guard let label = labels[index] else { index += 1; continue }
            var end = index
            while end + 1 < beatEvidence.count, labels[end + 1] == label,
                  abs(beatEvidence[end + 1].start - beatEvidence[end].end) < 1e-6 { end += 1 }
            let span = index...end
            let score = span.map { beatScores[$0] }.reduce(0, +) / Double(span.count)
            let margin = span.map { beatMargins[$0] }.reduce(0, +) / Double(span.count)
            let start = beatEvidence[index].start
            let stop = beatEvidence[end].end
            if stop > start {
                events.append(ChordEvent(start: start, end: stop, chord: templates[label].chord, provenance: .inferred,
                                         confidence: Self.confidence(score: score, margin: margin), source: source))
            }
            index = end + 1
        }
        return events
    }

    func scoreTable(_ e: BeatEvidence) -> [Double] {
        let norm = e.profile.map { $0 * $0 }.reduce(0, +).squareRoot()
        guard norm > 0 else { return [Double](repeating: 0, count: templates.count) }
        return scores(profile: e.profile.map { $0 / norm }, bass: e.bass)
    }

    static func confidence(score: Double, margin: Double) -> Confidence {
        let level: Confidence.Level
        if score >= 0.9 && margin >= 0.1 { level = .high } else if score >= 0.75 && margin >= 0.04 { level = .medium } else { level = .low }
        return Confidence(raw: min(max(score, 0), 1), isCalibrated: false, level: level)
    }

    static func firstIndex(in sorted: [Double], notBelow value: Double) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
