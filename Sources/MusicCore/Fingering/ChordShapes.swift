import Foundation

/// A chord shape on a 6-string guitar: one entry per string from the low E (index 0), `nil` = muted.
public struct ChordShape: Sendable, Hashable, Codable {
    public let frets: [Int?]
    /// Finger per string (0 = open, 1–4), `nil` for muted strings.
    public let fingers: [Int?]
    /// Fret of a full or partial barre, if any.
    public let barreFret: Int?
    public let name: String

    public init(frets: [Int?], fingers: [Int?], barreFret: Int? = nil, name: String) {
        self.frets = frets
        self.fingers = fingers
        self.barreFret = barreFret
        self.name = name
    }

    /// Lowest fretted fret (for the diagram's starting fret), or 1 for all-open shapes.
    public var baseFret: Int { frets.compactMap { $0 }.filter { $0 > 0 }.min() ?? 1 }
    public var maxFret: Int { frets.compactMap { $0 }.max() ?? 0 }

    /// Pitch classes the shape sounds in a tuning (for verification).
    public func pitchClasses(in tuning: Tuning) -> Set<PitchClass> {
        Set(zip(tuning.openStrings, frets).compactMap { open, fret in fret.map { open.transposed(by: $0)?.pitchClass } ?? nil })
    }
}

/// Chord diagrams for beginners: common open shapes first, then movable E-form and A-form barre
/// and power-chord shapes for any root. Standard tuning only (other tunings get no diagram rather
/// than a wrong one).
public enum ChordShapes {
    private typealias Template = (frets: [Int?], fingers: [Int?])

    /// Open shapes by symbol (standard tuning).
    private static let open: [String: Template] = [
        "C": ([nil, 3, 2, 0, 1, 0], [nil, 3, 2, 0, 1, 0]),
        "D": ([nil, nil, 0, 2, 3, 2], [nil, nil, 0, 1, 3, 2]),
        "E": ([0, 2, 2, 1, 0, 0], [0, 2, 3, 1, 0, 0]),
        "G": ([3, 2, 0, 0, 0, 3], [2, 1, 0, 0, 0, 3]),
        "A": ([nil, 0, 2, 2, 2, 0], [nil, 0, 1, 2, 3, 0]),
        "Am": ([nil, 0, 2, 2, 1, 0], [nil, 0, 2, 3, 1, 0]),
        "Dm": ([nil, nil, 0, 2, 3, 1], [nil, nil, 0, 2, 3, 1]),
        "Em": ([0, 2, 2, 0, 0, 0], [0, 2, 3, 0, 0, 0]),
        "C7": ([nil, 3, 2, 3, 1, 0], [nil, 3, 2, 4, 1, 0]),
        "D7": ([nil, nil, 0, 2, 1, 2], [nil, nil, 0, 2, 1, 3]),
        "E7": ([0, 2, 0, 1, 0, 0], [0, 2, 0, 1, 0, 0]),
        "G7": ([3, 2, 0, 0, 0, 1], [3, 2, 0, 0, 0, 1]),
        "A7": ([nil, 0, 2, 0, 2, 0], [nil, 0, 2, 0, 3, 0]),
        "B7": ([nil, 2, 1, 2, 0, 2], [nil, 2, 1, 3, 0, 4]),
        "Am7": ([nil, 0, 2, 0, 1, 0], [nil, 0, 2, 0, 1, 0]),
        "Em7": ([0, 2, 0, 0, 0, 0], [0, 2, 0, 0, 0, 0]),
        "Dm7": ([nil, nil, 0, 2, 1, 1], [nil, nil, 0, 2, 1, 1]),
        "C7M": ([nil, 3, 2, 0, 0, 0], [nil, 3, 2, 0, 0, 0]),
        "D7M": ([nil, nil, 0, 2, 2, 2], [nil, nil, 0, 1, 1, 1]),
        "G7M": ([3, 2, 0, 0, 0, 2], [3, 2, 0, 0, 0, 1]),
        "A7M": ([nil, 0, 2, 1, 2, 0], [nil, 0, 2, 1, 3, 0]),
        "E5": ([0, 2, 2, nil, nil, nil], [0, 1, 1, nil, nil, nil]),
        "A5": ([nil, 0, 2, 2, nil, nil], [nil, 0, 1, 1, nil, nil]),
        "D5": ([nil, nil, 0, 2, 3, nil], [nil, nil, 0, 1, 2, nil]),
        "Esus4": ([0, 2, 2, 2, 0, 0], [0, 2, 3, 4, 0, 0]),
        "Asus4": ([nil, 0, 2, 2, 3, 0], [nil, 0, 1, 2, 3, 0]),
        "Dsus4": ([nil, nil, 0, 2, 3, 3], [nil, nil, 0, 1, 2, 3]),
        "Asus2": ([nil, 0, 2, 2, 0, 0], [nil, 0, 1, 2, 0, 0]),
        "Dsus2": ([nil, nil, 0, 2, 3, 0], [nil, nil, 0, 1, 3, 0]),
    ]

    /// Movable shapes relative to the root fret `r` on the 6th (E-form) or 5th (A-form) string.
    private static func movable(_ quality: ChordQuality, eForm: Bool) -> Template? {
        // Offsets per string relative to the root fret; nil = muted.
        switch (quality, eForm) {
        case (.major, true): return ([0, 2, 2, 1, 0, 0], [1, 3, 4, 2, 1, 1])
        case (.minor, true): return ([0, 2, 2, 0, 0, 0], [1, 3, 4, 1, 1, 1])
        case (.dominant7, true): return ([0, 2, 0, 1, 0, 0], [1, 3, 1, 2, 1, 1])
        case (.minor7, true): return ([0, 2, 0, 0, 0, 0], [1, 3, 1, 1, 1, 1])
        case (.power, true): return ([0, 2, 2, nil, nil, nil], [1, 3, 4, nil, nil, nil])
        case (.sus4, true): return ([0, 2, 2, 2, 0, 0], [1, 2, 3, 4, 1, 1])
        case (.major, false): return ([nil, 0, 2, 2, 2, 0], [nil, 1, 3, 3, 3, 1])
        case (.minor, false): return ([nil, 0, 2, 2, 1, 0], [nil, 1, 3, 4, 2, 1])
        case (.dominant7, false): return ([nil, 0, 2, 0, 2, 0], [nil, 1, 3, 1, 4, 1])
        case (.minor7, false): return ([nil, 0, 2, 0, 1, 0], [nil, 1, 3, 1, 2, 1])
        case (.major7, false): return ([nil, 0, 2, 1, 2, 0], [nil, 1, 3, 2, 4, 1])
        case (.power, false): return ([nil, 0, 2, 2, nil, nil], [nil, 1, 3, 4, nil, nil])
        case (.sus2, false): return ([nil, 0, 2, 2, 0, 0], [nil, 1, 3, 4, 1, 1])
        case (.sus4, false): return ([nil, 0, 2, 2, 3, 0], [nil, 1, 2, 3, 4, 1])
        default: return nil
        }
    }

    /// Easiest shape for `chord` in standard tuning: an open shape if one exists, otherwise the
    /// lower of the E-form and A-form movable shapes. `nil` when no verified shape exists.
    public static func shape(for chord: Chord, tuning: Tuning = .standard) -> ChordShape? {
        guard tuning.openStrings.map(\.value) == Tuning.standard.openStrings.map(\.value), tuning.capo == 0 else { return nil }
        let base = Chord(root: chord.root, quality: chord.quality)
        let name = base.symbol()
        var candidates: [ChordShape] = []
        if let t = open[name] ?? open[base.symbol(preferFlats: true)] {
            candidates.append(ChordShape(frets: t.frets, fingers: t.fingers, name: name))
        }
        for eForm in [true, false] {
            guard let t = movable(chord.quality, eForm: eForm) else { continue }
            let openRoot: PitchClass = eForm ? .e : .a
            var rootFret = openRoot.interval(to: chord.root)
            if rootFret == 0 { rootFret = 12 } // open forms are covered above; avoid fret 0 "barres"
            if rootFret + 4 > tuning.fretCount { continue }
            let frets = t.frets.map { $0.map { $0 + rootFret } }
            candidates.append(ChordShape(frets: frets, fingers: t.fingers, barreFret: rootFret, name: name))
        }
        // Keep only shapes that really sound the chord's pitch classes (guards the tables above).
        let wanted = base.pitchClasses
        let valid = candidates.filter { $0.pitchClasses(in: tuning) == wanted }
        return valid.min { lhs, rhs in
            let l = (lhs.barreFret == nil ? 0 : 1, lhs.maxFret)
            let r = (rhs.barreFret == nil ? 0 : 1, rhs.maxFret)
            return l < r
        }
    }
}
