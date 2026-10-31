import Foundation

/// A position on the fretboard.
///
/// `string` is 0-based **from the lowest-pitched string** (0 = low E in standard tuning),
/// matching `Tuning.openStrings`. Use `tabLineNumber(stringCount:)` for the conventional
/// tablature numbering where 1 = highest string.
public struct FretPosition: Hashable, Codable, Sendable, CustomStringConvertible {
    public let string: Int
    public let fret: Int

    public init(string: Int, fret: Int) {
        self.string = string
        self.fret = fret
    }

    public var isOpen: Bool { fret == 0 }

    /// Conventional guitar string number: 1 = highest string, `stringCount` = lowest.
    public func tabLineNumber(stringCount: Int) -> Int { stringCount - string }

    public var description: String { "s\(string)f\(fret)" }
}

/// A guitar tuning: open-string pitches from lowest to highest, plus capo.
public struct Tuning: Hashable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Open-string pitches, index 0 = lowest string. MVP UI uses 6 strings; the model allows 4...9.
    public let openStrings: [MIDINote]
    /// Capo fret (0 = no capo). Fret numbers in `FretPosition` are relative to the nut, not the capo.
    public let capo: Int
    /// Highest playable fret.
    public let fretCount: Int

    public init(name: String, openStrings: [MIDINote], capo: Int = 0, fretCount: Int = 22) {
        precondition((4...9).contains(openStrings.count), "Unsupported string count")
        precondition(capo >= 0 && capo < fretCount, "Invalid capo")
        self.name = name
        self.openStrings = openStrings
        self.capo = capo
        self.fretCount = fretCount
    }

    public var stringCount: Int { openStrings.count }

    public static let standard = Tuning(name: "E Standard", openStrings: [40, 45, 50, 55, 59, 64].map(MIDINote.init(unchecked:)))
    public static let dropD = Tuning(name: "Drop D", openStrings: [38, 45, 50, 55, 59, 64].map(MIDINote.init(unchecked:)))
    public static let halfStepDown = Tuning(name: "E♭ Standard", openStrings: [39, 44, 49, 54, 58, 63].map(MIDINote.init(unchecked:)))

    /// Lowest and highest sounding pitches on this instrument (respecting the capo).
    public var range: ClosedRange<MIDINote> {
        let low = openStrings.map(\.value).min()! + capo
        let high = openStrings.map(\.value).max()! + fretCount
        return MIDINote(unchecked: low)...MIDINote(unchecked: min(high, 127))
    }

    /// Sounding pitch at a position, or `nil` if the position is not playable
    /// (string out of range, fret beyond the neck, or behind the capo).
    public func pitch(at position: FretPosition) -> MIDINote? {
        guard openStrings.indices.contains(position.string),
              position.fret >= 0, position.fret <= fretCount else { return nil }
        // With a capo, the open string sounds at the capo fret; frets below it are unreachable.
        let effectiveFret = position.fret == 0 ? capo : position.fret
        guard effectiveFret >= capo else { return nil }
        return openStrings[position.string].transposed(by: effectiveFret)
    }

    /// Every playable position that sounds `note`, ordered from lowest string to highest.
    /// With a capo, the open position is reported as fret 0 (sounding at the capo).
    public func positions(for note: MIDINote) -> [FretPosition] {
        openStrings.indices.compactMap { string in
            let semitonesAboveOpen = note.value - openStrings[string].value
            if semitonesAboveOpen == capo { return FretPosition(string: string, fret: 0) }
            guard semitonesAboveOpen > capo, semitonesAboveOpen <= fretCount else { return nil }
            return FretPosition(string: string, fret: semitonesAboveOpen)
        }
    }
}
