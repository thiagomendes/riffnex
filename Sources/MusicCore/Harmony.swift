import Foundation

/// The song's key, e.g. F♯ minor.
public struct SongKey: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        /// Apple's Music Understanding, on the full song.
        case musicUnderstanding
        /// Estimated from the guitar's guessed notes (fallback).
        case notes
    }

    public var tonic: PitchClass
    public var minor: Bool
    public var source: Source

    public init(tonic: PitchClass, minor: Bool, source: Source) {
        self.tonic = tonic
        self.minor = minor
        self.source = source
    }

    /// "F♯m", "E", "B♭" (flats for keys usually written with flats).
    public var name: String {
        let flats: Set<PitchClass> = minor ? [.f, .aSharp, .dSharp, .gSharp, .c, .g, .d] : [.f, .aSharp, .dSharp, .gSharp, .cSharp]
        let letter = NoteNaming.letters.name(of: tonic, preferFlats: flats.contains(tonic) && tonic.isAccidental)
        return letter + (minor ? "m" : "")
    }
}

extension PitchClass {
    var isAccidental: Bool { [.cSharp, .dSharp, .fSharp, .gSharp, .aSharp].contains(self) }
}

public enum KeyFinder {
    // Krumhansl–Kessler key profiles.
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Key from the guessed notes (duration × strength per pitch class, best-correlated profile).
    public static func estimate(_ notes: [DetectedNote]) -> SongKey? {
        var weights = [Double](repeating: 0, count: 12)
        for note in notes where note.sure { weights[note.midi % 12] += (note.end - note.start) * note.amplitude }
        guard weights.reduce(0, +) > 0 else { return nil }
        var best: (score: Double, key: SongKey)?
        for tonic in 0..<12 {
            for minor in [false, true] {
                let profile = minor ? minorProfile : majorProfile
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                let score = correlation(weights, rotated)
                if best == nil || score > best!.score {
                    best = (score, SongKey(tonic: PitchClass(rawValue: tonic)!, minor: minor, source: .notes))
                }
            }
        }
        return best?.key
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for (x, y) in zip(a, b) {
            num += (x - ma) * (y - mb)
            da += (x - ma) * (x - ma)
            db += (y - mb) * (y - mb)
        }
        return num / max((da * db).squareRoot(), 1e-12)
    }
}

/// What the guitar is built on at each moment: the root of its chord or riff, with a simple quality.
public struct RootSpan: Codable, Sendable, Equatable {
    public enum Quality: String, Codable, Sendable {
        /// Root and fifth, no third: the rock "power chord" (E5).
        case power
        case major
        case minor
        /// A single note line: only the root is shown.
        case single
    }

    public var start: Seconds
    public var end: Seconds
    public var root: PitchClass
    public var quality: Quality

    public init(start: Seconds, end: Seconds, root: PitchClass, quality: Quality) {
        self.start = start
        self.end = end
        self.root = root
        self.quality = quality
    }

    /// "E5", "G", "Am", "D".
    public var name: String {
        let letter = NoteNaming.letters.name(of: root)
        switch quality {
        case .power: return letter + "5"
        case .minor: return letter + "m"
        case .major, .single: return letter
        }
    }
}

public enum RootTrack {
    /// One root per beat (or per half second without beats), from the lowest strong guitar note,
    /// smoothed so a passing note does not flicker the label, then merged into spans.
    public static func build(_ notes: [DetectedNote], beats: [Seconds], duration: Seconds) -> [RootSpan] {
        let sure = notes.filter(\.sure)
        guard !sure.isEmpty, duration > 0 else { return [] }
        var edges = beats.filter { $0 >= 0 && $0 < duration }
        if edges.count < 4 { edges = Array(stride(from: 0.0, to: duration, by: 0.5)) }
        if edges.first ?? 0 > 0 { edges.insert(0, at: 0) }
        edges.append(duration)

        var perBeat: [(start: Seconds, end: Seconds, root: Int?, quality: RootSpan.Quality)] = []
        for i in 0..<(edges.count - 1) {
            let a = edges[i], b = edges[i + 1]
            var weight = [Double](repeating: 0, count: 12)
            var bass: (midi: Int, weight: Double)?
            for note in sure where note.end > a && note.start < b {
                let overlap = min(note.end, b) - max(note.start, a)
                let w = overlap * note.amplitude
                weight[note.midi % 12] += w
                if w > 0.02 * (b - a), bass == nil || note.midi < bass!.midi { bass = (note.midi, w) }
            }
            guard let root = bass?.midi else {
                perBeat.append((a, b, nil, .single))
                continue
            }
            let total = weight.reduce(0, +)
            func has(_ interval: Int) -> Bool { weight[(root + interval) % 12] > 0.2 * total }
            let quality: RootSpan.Quality
            if has(4) { quality = .major } else if has(3) { quality = .minor } else if has(7) { quality = .power } else { quality = .single }
            perBeat.append((a, b, root % 12, quality))
        }

        // Median-of-three on the root: one odd beat between two equal ones takes their root.
        if perBeat.count >= 3 {
            for i in 1..<(perBeat.count - 1) {
                let prev = perBeat[i - 1], next = perBeat[i + 1]
                if let p = prev.root, p == next.root, perBeat[i].root != p {
                    perBeat[i].root = p
                    perBeat[i].quality = prev.quality
                }
            }
        }

        var spans: [RootSpan] = []
        for beat in perBeat {
            guard let root = beat.root, let pitch = PitchClass(rawValue: root) else { continue }
            if var last = spans.last, last.root == pitch, abs(last.end - beat.start) < 1e-6 {
                // Keep the strongest description seen (a power chord stays a power chord over a held note).
                if last.quality == .single { last.quality = beat.quality }
                last.end = beat.end
                spans[spans.count - 1] = last
            } else {
                spans.append(RootSpan(start: beat.start, end: beat.end, root: pitch, quality: beat.quality))
            }
        }
        return spans
    }

    /// The span sounding at `time`, and the next different one.
    public static func at(_ time: Seconds, in spans: [RootSpan]) -> (current: RootSpan?, next: RootSpan?) {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].end <= time { lo = mid + 1 } else { hi = mid }
        }
        let current = lo < spans.count && spans[lo].start <= time ? spans[lo] : nil
        let nextIndex = current == nil ? lo : lo + 1
        return (current, nextIndex < spans.count ? spans[nextIndex] : nil)
    }
}
