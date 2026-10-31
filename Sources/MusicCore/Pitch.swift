import Foundation

/// A MIDI note number (0...127). Middle C (C4) = 60, A4 = 69 = 440 Hz.
public struct MIDINote: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let value: Int

    /// Returns `nil` when `value` is outside 0...127.
    public init?(_ value: Int) {
        guard (0...127).contains(value) else { return nil }
        self.value = value
    }

    /// For literals known to be valid at compile time. Traps on invalid input.
    public init(unchecked value: Int) {
        precondition((0...127).contains(value), "MIDI note out of range: \(value)")
        self.value = value
    }

    public var pitchClass: PitchClass { PitchClass(rawValue: value % 12)! }

    /// Scientific pitch notation octave (C4 = 60).
    public var octave: Int { value / 12 - 1 }

    /// Equal-tempered frequency in Hz.
    public func frequency(referenceA4: Double = 440) -> Double {
        referenceA4 * pow(2, Double(value - 69) / 12)
    }

    /// Nearest MIDI note for a frequency, plus the deviation in cents (-50...50).
    public static func nearest(toFrequency hz: Double, referenceA4: Double = 440) -> (note: MIDINote, cents: Double)? {
        guard hz > 0, hz.isFinite else { return nil }
        let exact = 69 + 12 * log2(hz / referenceA4)
        let rounded = exact.rounded()
        guard let note = MIDINote(Int(rounded)) else { return nil }
        return (note, (exact - rounded) * 100)
    }

    public func transposed(by semitones: Int) -> MIDINote? { MIDINote(value + semitones) }

    public static func < (lhs: MIDINote, rhs: MIDINote) -> Bool { lhs.value < rhs.value }

    public var description: String { NoteNaming.letters.name(of: self) }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard let note = MIDINote(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "MIDI note out of range: \(raw)"))
        }
        self = note
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The twelve pitch classes. Raw value = semitones above C.
public enum PitchClass: Int, CaseIterable, Codable, Sendable, Hashable {
    case c = 0, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b

    public func transposed(by semitones: Int) -> PitchClass {
        PitchClass(rawValue: ((rawValue + semitones) % 12 + 12) % 12)!
    }

    /// Ascending interval in semitones (0...11) from `self` up to `other`.
    public func interval(to other: PitchClass) -> Int {
        ((other.rawValue - rawValue) % 12 + 12) % 12
    }
}

/// How note names are displayed. Brazilian chord charts (cifras) use letters; solfège is optional.
public enum NoteNaming: String, Codable, Sendable, CaseIterable {
    case letters
    case solfege

    private static let letterNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    private static let flatLetterNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
    private static let solfegeNames = ["Dó", "Dó♯", "Ré", "Ré♯", "Mi", "Fá", "Fá♯", "Sol", "Sol♯", "Lá", "Lá♯", "Si"]
    private static let flatSolfegeNames = ["Dó", "Ré♭", "Ré", "Mi♭", "Mi", "Fá", "Sol♭", "Sol", "Lá♭", "Lá", "Si♭", "Si"]

    public func name(of pitchClass: PitchClass, preferFlats: Bool = false) -> String {
        let table: [String] = switch (self, preferFlats) {
        case (.letters, false): Self.letterNames
        case (.letters, true): Self.flatLetterNames
        case (.solfege, false): Self.solfegeNames
        case (.solfege, true): Self.flatSolfegeNames
        }
        return table[pitchClass.rawValue]
    }

    /// e.g. "E2" / "Mi 2".
    public func name(of note: MIDINote, preferFlats: Bool = false) -> String {
        let base = name(of: note.pitchClass, preferFlats: preferFlats)
        return self == .letters ? "\(base)\(note.octave)" : "\(base) \(note.octave)"
    }
}
