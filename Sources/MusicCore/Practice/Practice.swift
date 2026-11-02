import Foundation

/// The single line a beginner learns in Riff mode: one note at a time, taken from the detected
/// notes (which can hold several instruments and chords at once).
///
/// Rule ("skyline by loudness"): notes starting within `groupWindow` of each other form a group;
/// the loudest note of the group wins (ties: the higher one). A chosen note is cut where the
/// next one starts, so the line never has two notes at once. Notes quieter than
/// `minAmplitude` are left out: a beginner should not chase notes we are unsure of.
public enum MainLine {
    public struct Parameters: Sendable {
        public var groupWindow: Seconds = 0.05
        public var minAmplitude: Double = 0.35
        public var minDuration: Seconds = 0.06

        public init() {}
    }

    public static func extract(from notes: [NoteEvent], parameters: Parameters = Parameters()) -> [NoteEvent] {
        let candidates = notes.filter { $0.amplitude >= parameters.minAmplitude }
            .sorted { ($0.onset, -$0.amplitude) < ($1.onset, -$1.amplitude) }
        var line: [NoteEvent] = []
        var index = 0
        while index < candidates.count {
            let start = candidates[index].onset
            var best = candidates[index]
            var next = index + 1
            while next < candidates.count, candidates[next].onset - start <= parameters.groupWindow {
                let other = candidates[next]
                if other.amplitude > best.amplitude || (other.amplitude == best.amplitude && other.pitch > best.pitch) {
                    best = other
                }
                next += 1
            }
            if var previous = line.last, previous.offset > best.onset {
                previous.offset = best.onset
                if previous.offset - previous.onset >= parameters.minDuration {
                    line[line.count - 1] = previous
                } else {
                    line.removeLast()
                }
            }
            line.append(best)
            index = next
        }
        return line.filter { $0.offset - $0.onset >= parameters.minDuration }
    }
}

/// A short piece of the main line to learn on its own.
public struct Phrase: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let start: Seconds
    public let end: Seconds
    public let noteIDs: [UUID]

    public init(index: Int, start: Seconds, end: Seconds, noteIDs: [UUID]) {
        self.index = index
        self.start = start
        self.end = end
        self.noteIDs = noteIDs
    }
}

public enum PhraseSplitter {
    /// Splits the line into phrases of `barsPerPhrase` bars when there is a bar grid, otherwise at
    /// silences longer than `gap`. Phrases without notes are dropped; each phrase starts a little
    /// before its first note and ends a little after its last, so a loop catches the attack.
    public static func split(line: [NoteEvent], bars: [Seconds], duration: Seconds,
                             barsPerPhrase: Int = 2, gap: Seconds = 0.8) -> [Phrase] {
        let sorted = line.sorted { $0.onset < $1.onset }
        guard !sorted.isEmpty else { return [] }
        var boundaries: [Seconds] = []
        if bars.count >= 2 {
            boundaries = stride(from: 0, to: bars.count, by: max(1, barsPerPhrase)).map { bars[$0] }
            boundaries.append(duration)
            if let first = boundaries.first, first > 0 { boundaries.insert(0, at: 0) }
        } else {
            boundaries = [0]
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.onset - a.offset > gap {
                boundaries.append((a.offset + b.onset) / 2)
            }
            boundaries.append(duration)
        }
        var phrases: [Phrase] = []
        for (lo, hi) in zip(boundaries, boundaries.dropFirst()) where hi > lo {
            let inside = sorted.filter { $0.onset >= lo && $0.onset < hi }
            guard let first = inside.first, let last = inside.last else { continue }
            let start = max(lo, first.onset - 0.15)
            let end = min(duration, max(hi, last.offset + 0.1))
            phrases.append(Phrase(index: phrases.count, start: start, end: max(end, start + 0.5), noteIDs: inside.map(\.id)))
        }
        return phrases
    }
}

/// "Tom e notas": the key, its scale and the chords the song uses — useful on its own to a
/// musician who wants to improvise or find the song by ear.
public struct KeySummary: Sendable, Equatable {
    public let key: KeySpan
    public let scale: [PitchClass]
    public let pentatonic: [PitchClass]
    public let chords: [Chord]

    public init(key: KeySpan, chords: [ChordEvent]) {
        self.key = key
        let steps = key.mode == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
        scale = steps.map { key.tonic.transposed(by: $0) }
        let penta = key.mode == .major ? [0, 2, 4, 7, 9] : [0, 3, 5, 7, 10]
        pentatonic = penta.map { key.tonic.transposed(by: $0) }
        // Chords by how long they sound, longest first (the song's "main" chords lead).
        var time: [Chord: Seconds] = [:]
        for event in chords {
            guard let chord = event.chord else { continue }
            time[chord, default: 0] += event.end - event.start
        }
        self.chords = time.sorted { $0.value > $1.value }.map(\.key)
    }

    public var prefersFlats: Bool { KeySpan.prefersFlats(tonic: key.tonic, mode: key.mode) }

    public func names(_ classes: [PitchClass], naming: NoteNaming = .letters) -> [String] {
        classes.map { naming.name(of: $0, preferFlats: prefersFlats) }
    }
}

/// Where the playhead is in the bar: beat number (1-based) and beats per bar, from the grid.
public enum BeatPosition {
    public static func at(_ time: Seconds, beats: [Seconds], bars: [Seconds]) -> (beat: Int, beatsPerBar: Int)? {
        guard beats.count >= 2, let current = beats.lastIndex(where: { $0 <= time + 0.02 }) else { return nil }
        let barStart = bars.last(where: { $0 <= beats[current] + 0.03 }) ?? beats[0]
        let inBar = beats.filter { $0 >= barStart - 0.03 && $0 <= beats[current] + 0.02 }.count
        var perBar = 4
        if let barIndex = bars.firstIndex(where: { abs($0 - barStart) < 0.03 }), barIndex + 1 < bars.count {
            let next = bars[barIndex + 1]
            let count = beats.filter { $0 >= barStart - 0.03 && $0 < next - 0.03 }.count
            if (2...7).contains(count) { perBar = count }
        }
        return (min(max(inBar, 1), perBar), perBar)
    }

    /// Whole beats from `time` until `target` (at least 0).
    public static func beats(from time: Seconds, until target: Seconds, beats: [Seconds]) -> Int {
        beats.filter { $0 > time + 0.02 && $0 <= target + 0.02 }.count
    }
}
