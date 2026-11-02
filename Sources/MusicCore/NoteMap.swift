import Foundation

/// Notes guessed from the separated guitar. Stored independent of tuning (pitch and time only), so
/// changing the tuning only re-runs the fingering. A guess, not a transcription.
public struct NoteMap: Codable, Sendable, Equatable {
    /// 2: detected pitches are stored without string/fret (tuning chosen per song). 3: the song's key.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var createdAt: Date
    /// Note model and post-processing versions.
    public var model: String
    /// Separated instruments the notes were read from.
    public var sources: [String]
    /// Sorted by start time.
    public var detected: [DetectedNote]
    public var seconds: Double
    /// The song's key (Music Understanding, or estimated from these notes when it is unavailable).
    public var key: SongKey?

    public init(schemaVersion: Int = NoteMap.currentSchemaVersion, createdAt: Date = Date(), model: String,
                sources: [String], detected: [DetectedNote], seconds: Double, key: SongKey? = nil) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.model = model
        self.sources = sources
        self.detected = detected.sorted { ($0.start, $0.midi) < ($1.start, $1.midi) }
        self.seconds = seconds
    }
}

/// One detected guitar note: when, which pitch, how strongly the model heard it.
public struct DetectedNote: Codable, Sendable, Equatable, Hashable {
    public var start: Seconds
    public var end: Seconds
    public var midi: Int
    /// Mean model activation (0…1). Not a calibrated probability.
    public var amplitude: Double

    public init(start: Seconds, end: Seconds, midi: Int, amplitude: Double) {
        self.start = start
        self.end = end
        self.midi = midi
        self.amplitude = amplitude
    }

    /// The note model was fairly sure (medium or high level).
    public var sure: Bool { amplitude >= FrameNote.confidenceThresholds.medium }
}

/// The detected notes placed on the neck for one tuning.
public struct NeckNotes: Sendable, Equatable {
    public let tuning: Tuning
    /// Sorted by start time.
    public let notes: [GuessedNote]
    /// Detected notes this tuning cannot play (too low, too high, or too many at once).
    public let unplayable: Int
    private let longest: Seconds

    public init(tuning: Tuning, notes: [GuessedNote], unplayable: Int) {
        self.tuning = tuning
        self.notes = notes.sorted { ($0.start, $0.string) < ($1.start, $1.string) }
        self.unplayable = unplayable
        self.longest = notes.map { $0.end - $0.start }.max() ?? 0
    }

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

/// A detected note with a recommended string, fret and finger.
public struct GuessedNote: Codable, Sendable, Equatable, Hashable {
    public var start: Seconds
    public var end: Seconds
    public var midi: Int
    /// String index: 0 = lowest (6th) string … 5 = highest (1st).
    public var string: Int
    public var fret: Int
    /// 0 = open, 1 = index … 4 = pinky.
    public var finger: Int
    /// The note model was fairly sure; unsure notes are drawn hollow.
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
    public static let version = "rx-notes-3"

    /// Pitch range kept before a tuning is chosen: down to C2 so drop tunings can be detected.
    static let detectionRange = Tuning(name: "detection", openStrings: [36, 45, 50, 55, 59, 64].map(MIDINote.init(unchecked:)),
                                       fretCount: 24)

    /// Decoded activations → cleaned-up guitar notes (tuning-independent).
    public static func detect(notes: ActivationMatrix, onsets: ActivationMatrix, duration: Seconds) -> [DetectedNote] {
        let decoded = NoteDecoder.decode(notes: notes, onsets: onsets)
        let (frameNotes, _) = NotePostProcessor(parameters: .guitar(tuning: detectionRange)).process(decoded, onsets: onsets)
        return frameNotes.compactMap { note -> DetectedNote? in
            let start = BasicPitchTiming.time(ofFrame: note.startFrame)
            let end = min(BasicPitchTiming.time(ofFrame: note.endFrame), duration)
            guard end > start, start < duration else { return nil }
            return DetectedNote(start: start, end: end, midi: note.pitch, amplitude: note.amplitude)
        }
    }

    /// String, fret and finger for every playable note on `tuning`.
    public static func arrange(_ detected: [DetectedNote], tuning: Tuning) -> NeckNotes {
        let source = AnalysisSource(component: .basicPitch, version: version)
        let events = detected.compactMap { note -> NoteEvent? in
            guard note.end > note.start, let pitch = MIDINote(note.midi) else { return nil }
            return NoteEvent(onset: note.start, offset: note.end, pitch: pitch, amplitude: note.amplitude,
                             confidence: Confidence(raw: note.amplitude, thresholds: FrameNote.confidenceThresholds),
                             source: source)
        }
        let arrangement = FingeringOptimizer(tuning: tuning).arrange(notes: events)
        let notes = arrangement.notes.map {
            GuessedNote(start: $0.onset, end: $0.offset, midi: $0.pitch.value, string: $0.position.string,
                        fret: $0.position.fret, finger: $0.finger.rawValue, sure: $0.confidence >= .medium)
        }
        return NeckNotes(tuning: tuning, notes: notes, unplayable: arrangement.unplayable.count)
    }
}

// MARK: - Tunings

/// The tunings offered in the app, lowest string first.
public enum TuningPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard, halfDown, wholeDown, dropD, dropCSharp, dropC

    public var id: String { rawValue }

    public var openStrings: [Int] {
        switch self {
        case .standard: [40, 45, 50, 55, 59, 64]
        case .halfDown: [39, 44, 49, 54, 58, 63]
        case .wholeDown: [38, 43, 48, 53, 57, 62]
        case .dropD: [38, 45, 50, 55, 59, 64]
        case .dropCSharp: [37, 44, 49, 54, 58, 63]
        case .dropC: [36, 43, 48, 53, 57, 62]
        }
    }

    public var tuning: Tuning {
        Tuning(name: rawValue, openStrings: openStrings.map(MIDINote.init(unchecked:)), fretCount: 22)
    }

    /// Name shown in the app (Portuguese).
    public var title: String {
        switch self {
        case .standard: "Padrão"
        case .halfDown: "Meio tom abaixo"
        case .wholeDown: "Um tom abaixo"
        case .dropD: "Drop D"
        case .dropCSharp: "Drop C#"
        case .dropC: "Drop C"
        }
    }

    /// The open strings from the lowest, e.g. "E A D G B E".
    public var stringNames: String {
        // Half a step down is known as "E♭ standard", so it reads in flats.
        openStrings.map { NoteNaming.letters.name(of: MIDINote(unchecked: $0).pitchClass, preferFlats: self == .halfDown) }
            .joined(separator: " ")
    }
}

/// Why a tuning is suggested, for the user to judge.
public struct TuningSuggestion: Sendable, Equatable {
    public var preset: TuningPreset
    public var reason: String
}

public enum TuningDetector {
    /// Suggests a non-standard tuning when the guitar clearly plays below what standard tuning can
    /// reach (or never reaches the low E and sits a half step under it). `nil` means "looks standard".
    ///
    /// From pitch alone, a song in another key can look like a retuned guitar, so this is a suggestion
    /// with its reason, never applied on its own.
    public static func suggest(_ detected: [DetectedNote]) -> TuningSuggestion? {
        let sure = detected.filter(\.sure)
        guard sure.count >= 20 else { return nil }
        func count(_ midi: Int) -> Int { sure.filter { $0.midi == midi }.count }
        let threshold = max(4, sure.count / 100)
        let low = (36...39).map { (midi: $0, count: count($0)) }
        if low[0].count >= threshold {
            return TuningSuggestion(preset: .dropC, reason: "A guitarra desce até o Dó grave (C), abaixo do que a afinação padrão alcança.")
        }
        if low[1].count >= threshold {
            return TuningSuggestion(preset: .dropCSharp, reason: "A guitarra desce até o Dó# grave (C#), abaixo do que a afinação padrão alcança.")
        }
        if low[2].count >= threshold {
            return TuningSuggestion(preset: .dropD, reason: "A guitarra desce até o Ré grave (D), abaixo do Mi grave. Pode ser Drop D ou um tom abaixo.")
        }
        let e = count(40), dSharp = low[3].count
        if dSharp >= threshold, Double(e) < 0.3 * Double(dSharp) {
            return TuningSuggestion(preset: .halfDown, reason: "O Ré# grave (D#) aparece muito e o Mi grave quase nunca: as cordas parecem estar meio tom abaixo.")
        }
        return nil
    }
}
