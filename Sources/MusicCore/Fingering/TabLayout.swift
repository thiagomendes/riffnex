import Foundation

/// Time-based layout shared by the tab strip and the fretboard: bar lines, hand-position
/// following, and which notes are sounding or coming up.
public struct TabLayout: Sendable {
    public let arrangement: Arrangement
    public let barLines: [Seconds]
    /// Notes sorted by onset.
    let sorted: [ArrangedNote]
    let onsets: [Seconds]

    public init(arrangement: Arrangement, rhythm: RhythmGrid?, duration: Seconds) {
        self.arrangement = arrangement
        self.barLines = Self.barLines(rhythm: rhythm, duration: duration)
        self.sorted = arrangement.notes.sorted { ($0.onset, $0.position.string) < ($1.onset, $1.position.string) }
        self.onsets = sorted.map(\.onset)
    }

    /// Bars from Music Understanding; otherwise every 4 beats; otherwise none (the tab then shows
    /// no bar lines rather than invented ones).
    public static func barLines(rhythm: RhythmGrid?, duration: Seconds) -> [Seconds] {
        guard let rhythm else { return [] }
        if rhythm.bars.count >= 2 { return rhythm.bars.filter { $0 >= 0 && $0 <= duration } }
        guard rhythm.beats.count >= 8 else { return [] }
        return stride(from: 0, to: rhythm.beats.count, by: 4).map { rhythm.beats[$0] }.filter { $0 <= duration }
    }

    /// Notes with onset in [start, end).
    public func notes(from start: Seconds, to end: Seconds) -> ArraySlice<ArrangedNote> {
        let lower = firstIndex(notBelow: start)
        let upper = firstIndex(notBelow: end)
        return sorted[lower..<max(lower, upper)]
    }

    /// Notes sounding at `time`. Looks back far enough to catch long notes.
    public func sounding(at time: Seconds, lookBack: Seconds = 8) -> [ArrangedNote] {
        notes(from: time - lookBack, to: time + 0.0001).filter { $0.offset > time }
    }

    /// The next notes to play after `time` (the next onset group), within `horizon`.
    public func upcoming(after time: Seconds, horizon: Seconds) -> [ArrangedNote] {
        let index = firstIndex(notBelow: time + 0.0001)
        guard index < sorted.count, sorted[index].onset - time <= horizon else { return [] }
        return Array(notes(from: time + 0.0001, to: time + horizon))
    }

    /// Lowest fret the fretboard window should show at `time`: follows the hand of the current
    /// group, gliding to the next group's hand position during the `glide` before its onset.
    public func windowStart(at time: Seconds, glide: Seconds = 0.35, windowFrets: Int = 6) -> Double {
        func start(for hand: Int) -> Double { Double(max(0, hand - 1)) }
        let index = firstIndex(notBelow: time + 0.0001)
        let previousHand = sorted[..<index].last(where: { $0.handPosition != nil })?.handPosition
        let nextNote = sorted[index...].first(where: { $0.handPosition != nil })
        let current = previousHand.map(start) ?? nextNote.flatMap(\.handPosition).map(start) ?? 0
        guard let nextNote, let nextHand = nextNote.handPosition else { return current }
        let remaining = nextNote.onset - time
        guard remaining < glide else { return current }
        let t = 1 - max(0, remaining) / glide
        let eased = t * t * (3 - 2 * t)
        return current + (start(for: nextHand) - current) * eased
    }

    func firstIndex(notBelow value: Seconds) -> Int {
        var low = 0
        var high = onsets.count
        while low < high {
            let mid = (low + high) / 2
            if onsets[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
