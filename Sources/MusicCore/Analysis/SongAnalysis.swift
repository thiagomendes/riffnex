import Foundation

/// Everything RIFFNEX learned about one song, persisted as versioned JSON next to the audio.
/// Each fact carries its source; nothing here is invented when an analyzer did not produce it
/// (optional fields stay `nil` and the quality report says why).
public struct SongAnalysis: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var createdAt: Date
    public var duration: Seconds
    public var rhythm: RhythmGrid?
    public var keys: [KeySpan]
    public var sections: [SongSection]
    public var notes: [NoteEvent]
    public var chords: [ChordEvent]
    public var activity: InstrumentActivity?
    public var quality: QualityReport
    public var noteReport: NotePostProcessor.Report
    public var timings: [StageTiming]
    public var components: [AnalysisSource]
    /// Non-fatal failures of individual stages (stage name → message), shown in the Overview.
    public var stageErrors: [String: String]

    public init(schemaVersion: Int = SongAnalysis.currentSchemaVersion, createdAt: Date = Date(), duration: Seconds,
                rhythm: RhythmGrid?, keys: [KeySpan], sections: [SongSection], notes: [NoteEvent],
                chords: [ChordEvent], activity: InstrumentActivity?, quality: QualityReport,
                noteReport: NotePostProcessor.Report, timings: [StageTiming], components: [AnalysisSource], stageErrors: [String: String] = [:]) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.duration = duration
        self.rhythm = rhythm
        self.keys = keys
        self.sections = sections
        self.notes = notes
        self.chords = chords
        self.activity = activity
        self.quality = quality
        self.noteReport = noteReport
        self.timings = timings
        self.components = components
        self.stageErrors = stageErrors
    }

    /// The key that covers most of the song, if any.
    public var mainKey: KeySpan? {
        keys.max { $0.end - $0.start < $1.end - $1.start }
    }
}

/// Beats and bar lines from Music Understanding. Tempo is the framework's estimate; it reports no
/// confidence, so neither do we.
public struct RhythmGrid: Codable, Sendable, Equatable {
    public var beatsPerMinute: Double?
    public var beats: [Seconds]
    public var bars: [Seconds]
    public var source: AnalysisSource

    public init(beatsPerMinute: Double?, beats: [Seconds], bars: [Seconds], source: AnalysisSource) {
        self.beatsPerMinute = beatsPerMinute
        self.beats = beats
        self.bars = bars
        self.source = source
    }

    /// Median inter-beat interval in seconds.
    public var medianBeatInterval: Seconds? {
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !intervals.isEmpty else { return nil }
        return intervals[intervals.count / 2]
    }

    /// Coefficient of variation of the inter-beat intervals (0 = perfectly steady).
    public var beatIntervalVariation: Double? {
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.filter { $0 > 0 }
        guard intervals.count >= 2 else { return nil }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
        return mean > 0 ? variance.squareRoot() / mean : nil
    }
}

public enum KeyMode: String, Codable, Sendable {
    case major, minor
}

public struct KeySpan: Codable, Sendable, Equatable {
    public var start: Seconds
    public var end: Seconds
    public var tonic: PitchClass
    public var mode: KeyMode
    public var source: AnalysisSource

    public init(start: Seconds, end: Seconds, tonic: PitchClass, mode: KeyMode, source: AnalysisSource) {
        self.start = start
        self.end = end
        self.tonic = tonic
        self.mode = mode
        self.source = source
    }

    public func name(naming: NoteNaming = .letters) -> String {
        let tonicName = naming.name(of: tonic, preferFlats: Self.prefersFlats(tonic: tonic, mode: mode))
        switch naming {
        case .letters: return tonicName + (mode == .minor ? "m" : "")
        case .solfege: return tonicName + (mode == .minor ? " menor" : " maior")
        }
    }

    /// Keys conventionally spelled with flats (F, B♭, E♭, A♭, D♭ major and their relative minors).
    public static func prefersFlats(tonic: PitchClass, mode: KeyMode) -> Bool {
        let major = mode == .major ? tonic : tonic.transposed(by: 3)
        return [.f, .aSharp, .dSharp, .gSharp, .cSharp].contains(major)
    }
}

public struct SongSection: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A section with a letter label (A, B, A′…).
        case lettered
        /// Short tail at the end of the song.
        case ending
        /// No pitched content was detected.
        case silent
    }

    public var id: Int { Int((start * 1000).rounded()) }
    public var start: Seconds
    public var end: Seconds
    /// "A", "B", "A′"… for lettered sections; empty otherwise.
    public var letter: String
    public var kind: Kind
    /// Whether the section is mostly chords (true) or a single line / riff (false).
    public var isChordal: Bool
    public var provenance: Provenance

    public init(start: Seconds, end: Seconds, letter: String, kind: Kind, isChordal: Bool,
                provenance: Provenance = .inferred) {
        self.start = start
        self.end = end
        self.letter = letter
        self.kind = kind
        self.isChordal = isChordal
        self.provenance = provenance
    }
}

/// Music Understanding's per-class activity (0…1), downsampled for storage and display.
public struct InstrumentActivity: Codable, Sendable, Equatable {
    public var resolution: Seconds
    public var other: [Float]
    public var vocal: [Float]
    public var bass: [Float]
    public var drum: [Float]

    public init(resolution: Seconds, other: [Float], vocal: [Float], bass: [Float], drum: [Float]) {
        self.resolution = resolution
        self.other = other
        self.vocal = vocal
        self.bass = bass
        self.drum = drum
    }

    static func mean(_ values: [Float]) -> Double {
        values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
    }

    public var meanOther: Double { Self.mean(other) }
    public var meanVocal: Double { Self.mean(vocal) }
    public var meanBass: Double { Self.mean(bass) }
    public var meanDrum: Double { Self.mean(drum) }
}

public struct StageTiming: Codable, Sendable, Equatable {
    public var stage: String
    public var seconds: Double

    public init(stage: String, seconds: Double) {
        self.stage = stage
        self.seconds = seconds
    }
}
