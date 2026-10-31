import Foundation

/// Seconds relative to the start of the original audio file.
public typealias Seconds = Double

/// A single detected note.
public struct NoteEvent: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var onset: Seconds
    public var offset: Seconds
    public var pitch: MIDINote
    /// Model activation amplitude (0...1), not a velocity in the MIDI sense.
    public var amplitude: Double
    /// Optional pitch contour in cents relative to `pitch`, sampled at the producer's frame rate.
    public var pitchContourCents: [Double]?
    public var techniques: [TechniqueAnnotation]
    public var provenance: Provenance
    public var confidence: Confidence
    public var source: AnalysisSource

    public init(
        id: UUID = UUID(), onset: Seconds, offset: Seconds, pitch: MIDINote, amplitude: Double,
        pitchContourCents: [Double]? = nil, techniques: [TechniqueAnnotation] = [],
        provenance: Provenance = .detected, confidence: Confidence, source: AnalysisSource
    ) {
        precondition(offset > onset, "A note must have positive duration")
        self.id = id
        self.onset = onset
        self.offset = offset
        self.pitch = pitch
        self.amplitude = amplitude
        self.pitchContourCents = pitchContourCents
        self.techniques = techniques
        self.provenance = provenance
        self.confidence = confidence
        self.source = source
    }

    public var duration: Seconds { offset - onset }

    public func isSounding(at time: Seconds) -> Bool { time >= onset && time < offset }
}

public enum ChordQuality: String, Codable, Sendable, CaseIterable {
    case major, minor, power, dominant7, major7, minor7, sus2, sus4, diminished

    /// Intervals in semitones above the root (root included).
    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .power: [0, 7]
        case .dominant7: [0, 4, 7, 10]
        case .major7: [0, 4, 7, 11]
        case .minor7: [0, 3, 7, 10]
        case .sus2: [0, 2, 7]
        case .sus4: [0, 5, 7]
        case .diminished: [0, 3, 6]
        }
    }

    /// Chord-symbol suffix as used in Brazilian cifras / lead sheets.
    public var symbolSuffix: String {
        switch self {
        case .major: ""
        case .minor: "m"
        case .power: "5"
        case .dominant7: "7"
        case .major7: "7M"
        case .minor7: "m7"
        case .sus2: "sus2"
        case .sus4: "sus4"
        case .diminished: "°"
        }
    }
}

public struct Chord: Codable, Sendable, Hashable {
    public let root: PitchClass
    public let quality: ChordQuality
    /// Bass note when different from the root (slash chord).
    public let bass: PitchClass?

    public init(root: PitchClass, quality: ChordQuality, bass: PitchClass? = nil) {
        self.root = root
        self.quality = quality
        self.bass = (bass == root) ? nil : bass
    }

    public var pitchClasses: Set<PitchClass> {
        Set(quality.intervals.map { root.transposed(by: $0) })
    }

    public func symbol(naming: NoteNaming = .letters, preferFlats: Bool = false) -> String {
        var s = naming.name(of: root, preferFlats: preferFlats) + quality.symbolSuffix
        if let bass { s += "/" + naming.name(of: bass, preferFlats: preferFlats) }
        return s
    }
}

/// A chord over a time span. `chord == nil` means "no chord" (silence / unpitched / single line).
public struct ChordEvent: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var start: Seconds
    public var end: Seconds
    public var chord: Chord?
    public var provenance: Provenance
    public var confidence: Confidence
    public var source: AnalysisSource

    public init(id: UUID = UUID(), start: Seconds, end: Seconds, chord: Chord?, provenance: Provenance,
                confidence: Confidence, source: AnalysisSource) {
        precondition(end > start, "A chord span must have positive duration")
        self.id = id
        self.start = start
        self.end = end
        self.chord = chord
        self.provenance = provenance
        self.confidence = confidence
        self.source = source
    }
}

/// A playing technique. Detection is post-MVP; the type exists so renderers and storage are ready.
public struct TechniqueAnnotation: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case bend(cents: Int)
        case release
        case slide(toFret: Int)
        case hammerOn
        case pullOff
        case vibrato
        case palmMute
    }

    public var kind: Kind
    public var confidence: Confidence
    public var source: AnalysisSource

    public init(kind: Kind, confidence: Confidence, source: AnalysisSource) {
        self.kind = kind
        self.confidence = confidence
        self.source = source
    }
}
