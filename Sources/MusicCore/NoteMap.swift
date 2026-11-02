import Foundation

/// Notes guessed from the separated guitar, each placed on a string and fret by the fingering
/// optimizer. A guess, not a transcription: shown as a hint on the neck, with uncertain notes dimmed.
public struct NoteMap: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var createdAt: Date
    /// Note model and post-processing versions.
    public var model: String
    /// Separated instruments the notes were read from.
    public var sources: [String]
    /// Sorted by start time.
    public var notes: [GuessedNote]
    public var seconds: Double

    public init(schemaVersion: Int = NoteMap.currentSchemaVersion, createdAt: Date = Date(), model: String,
                sources: [String], notes: [GuessedNote], seconds: Double) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.model = model
        self.sources = sources
        self.notes = notes.sorted { ($0.start, $0.string) < ($1.start, $1.string) }
        self.seconds = seconds
    }

    /// Longest note, so a window query can include notes that started before it and still sound.
    public var longest: Seconds { notes.map { $0.end - $0.start }.max() ?? 0 }

    /// Notes that overlap `from ... to`.
    public func notes(from: Seconds, to: Seconds) -> [GuessedNote] {
        guard to >= from, !notes.isEmpty else { return [] }
        let earliest = from - longest
        var lo = 0, hi = notes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if notes[mid].start < earliest { lo = mid + 1 } else { hi = mid }
        }
        var out: [GuessedNote] = []
        var i = lo
        while i < notes.count, notes[i].start <= to {
            if notes[i].end >= from { out.append(notes[i]) }
            i += 1
        }
        return out
    }
}

public struct GuessedNote: Codable, Sendable, Equatable, Hashable {
    public var start: Seconds
    public var end: Seconds
    public var midi: Int
    /// String index: 0 = low E … 5 = high e (standard tuning).
    public var string: Int
    public var fret: Int
    /// 0 = open, 1 = index … 4 = pinky.
    public var finger: Int
    /// The note model was fairly sure (medium or high level); unsure notes are drawn dimmed.
    public var sure: Bool

    public init(start: Seconds, end: Seconds, midi: Int, string: Int, fret: Int, finger: Int, sure: Bool) {
        self.start = start
        self.end = end
        self.midi = midi
        self.string = string
        self.fret = fret
        self.finger = finger
        self.sure = sure
    }
}

public enum NoteMapBuilder {
    /// RIFFNEX's note post-processing version; bump when decoding parameters or clean-up change.
    public static let version = "rx-notes-2"

    /// Decoded activations → cleaned-up guitar notes → string, fret and finger.
    public static func guess(notes: ActivationMatrix, onsets: ActivationMatrix, duration: Seconds,
                             tuning: Tuning = .standard) -> [GuessedNote] {
        let decoded = NoteDecoder.decode(notes: notes, onsets: onsets)
        let (frameNotes, _) = NotePostProcessor(parameters: .guitar(tuning: tuning)).process(decoded, onsets: onsets)
        let source = AnalysisSource(component: .basicPitch, version: version)
        let events = frameNotes.compactMap { $0.noteEvent(source: source) }.filter { $0.onset < duration }
        let arrangement = FingeringOptimizer(tuning: tuning).arrange(notes: events)
        return arrangement.notes.map {
            GuessedNote(start: $0.onset, end: min($0.offset, duration), midi: $0.pitch.value,
                        string: $0.position.string, fret: $0.position.fret, finger: $0.finger.rawValue,
                        sure: $0.confidence >= .medium)
        }
    }
}
