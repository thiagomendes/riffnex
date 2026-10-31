import Foundation

/// Which finger frets a note. Open strings need no finger.
public enum Finger: Int, Codable, Sendable, Hashable, CaseIterable {
    case open = 0, index, middle, ring, pinky
}

/// One detected note with a recommended place to play it.
public struct ArrangedNote: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { noteID }
    public let noteID: UUID
    public let onset: Seconds
    public let offset: Seconds
    public let pitch: MIDINote
    public let position: FretPosition
    public let finger: Finger
    /// The index finger lies across two or more strings at this fret.
    public let isBarre: Bool
    /// Fret of the index finger for the group this note belongs to (1-based), or nil if all open.
    public let handPosition: Int?
    /// Copied from the detected note, so the fretboard can style uncertain notes.
    public let confidence: Confidence.Level
    /// Always `.recommended`: a playable suggestion, not a claim about the original performance.
    public var provenance: Provenance { .recommended }
}

/// A recommended way to play a song's detected notes on a given tuning.
public struct Arrangement: Codable, Sendable, Equatable {
    public static let version = "fingering-1"

    public let tuning: Tuning
    public let notes: [ArrangedNote]
    /// Notes that cannot be played on this tuning (out of range, or too many simultaneous notes).
    public let unplayable: [UUID]
    public let source: AnalysisSource

    /// Notes sounding at `time` (onset ≤ time < offset).
    public func sounding(at time: Seconds) -> [ArrangedNote] {
        notes.filter { $0.onset <= time && time < $0.offset }
    }
}

/// Weights for the fingering dynamic program. Defaults are tuned on canonical cases in
/// `FingeringOptimizerTests` (pentatonic box, power-chord riffs, the demo riff).
public struct FingeringCostModel: Sendable, Equatable {
    /// Notes whose onsets are this close are played together.
    public var groupingWindow: Seconds = 0.03
    public var maxFret: Int = 22
    /// Largest fretted span (max − min fret). A span equal to this costs `stretchPenalty` extra.
    public var maxSpan: Int = 4
    public var spanWeight: Double = 0.6
    public var stretchPenalty: Double = 2.5
    /// Per fret above the 5th, per note (mild: high positions are fine when the music is there).
    public var highFretWeight: Double = 0.08
    /// Bonus (negative cost) per open string in the group.
    public var openStringBonus: Double = 0.35
    /// Per unused string between used strings in one group.
    public var stringSkipWeight: Double = 1.0
    /// Per fret the hand moves between groups.
    public var shiftWeight: Double = 1.0
    /// Extra shift cost scaled by 1 / time gap, so fast shifts cost more.
    public var fastShiftWeight: Double = 0.08
    /// Shift cost multiplier across a phrase boundary (moving there is natural).
    public var phraseBoundaryShiftFactor: Double = 0.4
    /// Per string of movement of the group's mean string.
    public var stringCrossWeight: Double = 0.15
    /// Prefer the index finger on the lowest fretted note (hand position at the lowest fret).
    public var handOffsetWeight: Double = 0.12
    /// Candidates kept per group after static scoring.
    public var maxCandidates: Int = 48

    public init() {}
}

/// Viterbi search over time-ordered note groups for the least-effort way to play them
/// (architecture doc §5). Positions are a recommendation; transcription never depends on them.
public struct FingeringOptimizer: Sendable {
    public var tuning: Tuning
    public var cost: FingeringCostModel

    public init(tuning: Tuning = .standard, cost: FingeringCostModel = FingeringCostModel()) {
        self.tuning = tuning
        self.cost = cost
    }

    struct Group {
        let onset: Seconds
        let notes: [NoteEvent]
    }

    /// One way to play a group with the hand at `hand` (index-finger fret).
    struct State {
        let positions: [FretPosition] // aligned with the group's notes
        let hand: Int
        let staticCost: Double
        let meanString: Double
        let fretted: Bool
    }

    public func arrange(notes: [NoteEvent], phraseBoundaries: [Seconds] = []) -> Arrangement {
        var unplayable: [UUID] = []
        let playable = notes.filter { note in
            let ok = !tuning.positions(for: note.pitch).filter { $0.fret <= min(cost.maxFret, tuning.fretCount) }.isEmpty
            if !ok { unplayable.append(note.id) }
            return ok
        }
        var groups = makeGroups(playable)

        // Each group's states. Groups with no playable assignment drop their weakest notes until one exists.
        var states: [[State]] = []
        var keptGroups: [Group] = []
        for index in groups.indices {
            var group = groups[index]
            var candidates = self.states(for: group)
            while candidates.isEmpty, group.notes.count > 1 {
                let weakest = group.notes.min { ($0.amplitude, $0.pitch.value) < ($1.amplitude, $1.pitch.value) }!
                unplayable.append(weakest.id)
                group = Group(onset: group.onset, notes: group.notes.filter { $0.id != weakest.id })
                candidates = self.states(for: group)
            }
            guard !candidates.isEmpty else {
                unplayable.append(contentsOf: group.notes.map(\.id))
                continue
            }
            groups[index] = group
            keptGroups.append(group)
            states.append(candidates)
        }

        let path = viterbi(groups: keptGroups, states: states, boundaries: phraseBoundaries.sorted())

        var arranged: [ArrangedNote] = []
        for (groupIndex, group) in keptGroups.enumerated() {
            let state = states[groupIndex][path[groupIndex]]
            let frettedAtHand = state.positions.filter { $0.fret > 0 && $0.fret == state.hand }.count
            for (note, position) in zip(group.notes, state.positions) {
                let finger: Finger
                if position.fret == 0 {
                    finger = .open
                } else {
                    finger = Finger(rawValue: min(max(position.fret - state.hand + 1, 1), 4)) ?? .index
                }
                arranged.append(ArrangedNote(noteID: note.id, onset: note.onset, offset: note.offset, pitch: note.pitch,
                                             position: position, finger: finger,
                                             isBarre: finger == .index && frettedAtHand >= 2,
                                             handPosition: state.fretted ? state.hand : nil,
                                             confidence: note.confidence.level))
            }
        }
        return Arrangement(tuning: tuning, notes: arranged, unplayable: unplayable,
                           source: AnalysisSource(component: .fingeringOptimizer, version: Arrangement.version))
    }

    // MARK: Grouping

    func makeGroups(_ notes: [NoteEvent]) -> [Group] {
        let sorted = notes.sorted { ($0.onset, $0.pitch.value) < ($1.onset, $1.pitch.value) }
        var groups: [Group] = []
        var current: [NoteEvent] = []
        for note in sorted {
            if let first = current.first, note.onset - first.onset > cost.groupingWindow {
                groups.append(Group(onset: first.onset, notes: current))
                current = []
            }
            // A repeated pitch inside one group cannot be played twice at once; keep the louder.
            if let existing = current.firstIndex(where: { $0.pitch == note.pitch }) {
                if note.amplitude > current[existing].amplitude { current[existing] = note }
                continue
            }
            current.append(note)
        }
        if let first = current.first { groups.append(Group(onset: first.onset, notes: current)) }
        // More notes than strings: keep the loudest that fit.
        return groups.map { group in
            guard group.notes.count > tuning.stringCount else { return group }
            let loudest = group.notes.sorted { $0.amplitude > $1.amplitude }.prefix(tuning.stringCount)
            let ids = Set(loudest.map(\.id))
            return Group(onset: group.onset, notes: group.notes.filter { ids.contains($0.id) })
        }
    }

    // MARK: Candidates

    func states(for group: Group) -> [State] {
        let maxFret = min(cost.maxFret, tuning.fretCount)
        let options = group.notes.map { note in tuning.positions(for: note.pitch).filter { $0.fret <= maxFret } }
        var assignments: [[FretPosition]] = []
        var current: [FretPosition] = []
        var used = Set<Int>()

        func search(_ index: Int) {
            if assignments.count >= 4096 { return }
            if index == options.count {
                assignments.append(current)
                return
            }
            for position in options[index] where !used.contains(position.string) {
                // Early span check on fretted notes.
                let frets = (current + [position]).map(\.fret).filter { $0 > 0 }
                if let lo = frets.min(), let hi = frets.max(), hi - lo > cost.maxSpan { continue }
                used.insert(position.string)
                current.append(position)
                search(index + 1)
                current.removeLast()
                used.remove(position.string)
            }
        }
        search(0)

        var scored: [(positions: [FretPosition], cost: Double)] = []
        for positions in assignments {
            if let c = staticCost(positions) { scored.append((positions, c)) }
        }
        scored.sort { $0.cost < $1.cost }
        let kept = scored.prefix(cost.maxCandidates)

        var result: [State] = []
        for candidate in kept {
            let frets = candidate.positions.map(\.fret).filter { $0 > 0 }
            let meanString = Double(candidate.positions.map(\.string).reduce(0, +)) / Double(max(candidate.positions.count, 1))
            if let lo = frets.min(), let hi = frets.max() {
                // The hand (index finger) can sit anywhere that keeps every fretted note under fingers 1–4.
                let lowest = min(lo, max(1, hi - 3)) // a 5-fret stretch keeps the index at the lowest fret
                for hand in lowest...lo {
                    let offset = Double(lo - hand) * cost.handOffsetWeight
                    result.append(State(positions: candidate.positions, hand: hand, staticCost: candidate.cost + offset,
                                        meanString: meanString, fretted: true))
                }
            } else {
                // All open: the hand is free; offer the common positions so it can stay where it is.
                for hand in [1, 2, 3, 5, 7, 9, 12] {
                    result.append(State(positions: candidate.positions, hand: hand, staticCost: candidate.cost,
                                        meanString: meanString, fretted: false))
                }
            }
        }
        return result
    }

    /// Static cost of an assignment, or nil when it is not playable by one hand.
    func staticCost(_ positions: [FretPosition]) -> Double? {
        let fretted = positions.filter { $0.fret > 0 }
        var total = 0.0
        if let lo = fretted.map(\.fret).min(), let hi = fretted.map(\.fret).max() {
            let span = hi - lo
            guard span <= cost.maxSpan else { return nil }
            total += Double(max(0, span - 2)) * cost.spanWeight
            if span == cost.maxSpan { total += cost.stretchPenalty }
            // Fingers: the index at the lowest fret (it may barre), plus one per distinct higher fret
            // (a finger may cover several strings on its fret, as in A-shape power chords).
            let distinctAbove = Set(fretted.filter { $0.fret > lo }.map(\.fret)).count
            guard 1 + distinctAbove <= 4 else { return nil }
        }
        for position in fretted { total += Double(max(0, position.fret - 5)) * cost.highFretWeight }
        total -= Double(positions.count - fretted.count) * cost.openStringBonus
        if positions.count > 1 {
            let strings = positions.map(\.string)
            let used = Set(strings)
            let skips = (strings.min()!...strings.max()!).filter { !used.contains($0) }.count
            total += Double(skips) * cost.stringSkipWeight
        }
        return total
    }

    // MARK: Viterbi

    func viterbi(groups: [Group], states: [[State]], boundaries: [Seconds]) -> [Int] {
        guard !groups.isEmpty else { return [] }
        var best = states[0].map(\.staticCost)
        var back: [[Int]] = [Array(repeating: 0, count: states[0].count)]

        for step in 1..<groups.count {
            let gap = max(groups[step].onset - groups[step - 1].onset, 0.02)
            let crossesBoundary = boundaries.contains { $0 > groups[step - 1].onset && $0 <= groups[step].onset }
            let shiftFactor = crossesBoundary ? cost.phraseBoundaryShiftFactor : 1
            let previous = states[step - 1]
            var next = [Double](repeating: .infinity, count: states[step].count)
            var pointers = [Int](repeating: 0, count: states[step].count)
            for (j, state) in states[step].enumerated() {
                for (i, from) in previous.enumerated() {
                    let shift = Double(abs(state.hand - from.hand))
                    let transition = shiftFactor * shift * (cost.shiftWeight + cost.fastShiftWeight / gap)
                        + abs(state.meanString - from.meanString) * cost.stringCrossWeight
                    let total = best[i] + transition
                    if total < next[j] {
                        next[j] = total
                        pointers[j] = i
                    }
                }
                next[j] += state.staticCost
            }
            best = next
            back.append(pointers)
        }

        var state = best.indices.min { best[$0] < best[$1] }!
        var path = [Int](repeating: 0, count: groups.count)
        for step in stride(from: groups.count - 1, through: 0, by: -1) {
            path[step] = state
            state = back[step][state]
        }
        return path
    }
}
