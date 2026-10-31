import Foundation

/// An honest summary of how much the user can trust this analysis, built only from measured
/// signals. Shown on the Song Overview; each reason maps to a pt-BR explanation in the app.
public struct QualityReport: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable, Comparable {
        case limited, fair, good

        private var order: Int { switch self { case .limited: 0; case .fair: 1; case .good: 2 } }
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.order < rhs.order }
    }

    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// Music Understanding found no beat grid; chords use fixed half-second slices.
        case noBeatGrid
        /// Beat intervals vary a lot (rubato, tempo changes, or unreliable tracking).
        case unsteadyTempo
        /// No key estimate.
        case noKey
        /// Vocals dominate; the note model hears the voice too.
        case vocalsDominant
        /// Very few notes were detected.
        case fewNotes
        /// Many detected notes are low confidence.
        case manyLowConfidenceNotes
        /// Very dense texture (full band); expect missing and extra notes.
        case denseTexture
        /// The "other" class (where guitar falls) is barely active.
        case littleGuitarLikeContent
    }

    public struct Metrics: Codable, Sendable, Equatable {
        public var noteCount: Int
        public var notesPerSecond: Double
        public var lowConfidenceFraction: Double
        public var chordCoverage: Double
        public var beatIntervalVariation: Double?
        public var meanOtherActivity: Double?
        public var meanVocalActivity: Double?
    }

    public var level: Level
    public var reasons: [Reason]
    public var metrics: Metrics

    public init(level: Level, reasons: [Reason], metrics: Metrics) {
        self.level = level
        self.reasons = reasons
        self.metrics = metrics
    }

    /// `separated`: notes were detected on separated instrument stems (vocals, drums and bass
    /// removed), so the vocals no longer contaminate them.
    public static func assess(duration: Seconds, notes: [NoteEvent], chords: [ChordEvent], rhythm: RhythmGrid?,
                              keys: [KeySpan], activity: InstrumentActivity?, separated: Bool = false) -> QualityReport {
        let seconds = max(duration, 0.001)
        let lowFraction = notes.isEmpty ? 0 : Double(notes.filter { $0.confidence.level == .low }.count) / Double(notes.count)
        let chordSeconds = chords.filter { $0.chord != nil }.map { $0.end - $0.start }.reduce(0, +)
        let metrics = Metrics(noteCount: notes.count, notesPerSecond: Double(notes.count) / seconds,
                              lowConfidenceFraction: lowFraction, chordCoverage: min(1, chordSeconds / seconds),
                              beatIntervalVariation: rhythm?.beatIntervalVariation,
                              meanOtherActivity: activity?.meanOther, meanVocalActivity: activity?.meanVocal)

        var reasons: [Reason] = []
        if rhythm == nil || (rhythm?.beats.count ?? 0) < 2 { reasons.append(.noBeatGrid) }
        if let variation = metrics.beatIntervalVariation, variation > 0.1 { reasons.append(.unsteadyTempo) }
        if keys.isEmpty { reasons.append(.noKey) }
        if !separated, let vocal = metrics.meanVocalActivity, let other = metrics.meanOtherActivity, vocal > 0.3, vocal > other {
            reasons.append(.vocalsDominant)
        }
        if metrics.notesPerSecond < 0.3 { reasons.append(.fewNotes) }
        if notes.count >= 10, lowFraction > 0.4 { reasons.append(.manyLowConfidenceNotes) }
        if metrics.notesPerSecond > 14 { reasons.append(.denseTexture) }
        if let other = metrics.meanOtherActivity, other < 0.15 { reasons.append(.littleGuitarLikeContent) }

        let level: Level
        if reasons.contains(.fewNotes) || reasons.contains(.littleGuitarLikeContent) {
            level = .limited
        } else if reasons.contains(where: { [.vocalsDominant, .manyLowConfidenceNotes, .denseTexture].contains($0) }) {
            level = .fair
        } else {
            level = reasons.isEmpty ? .good : .fair
        }
        return QualityReport(level: level, reasons: reasons, metrics: metrics)
    }
}
