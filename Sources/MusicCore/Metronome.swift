import Foundation

/// Sample-accurate click generator that runs in the **song's frame domain**: it sits next to the
/// song player, before the time-pitch unit, so clicks follow seeks, loops and speed changes with
/// no clock conversion. Pure Swift so it can be tested exhaustively; the audio node only copies
/// its output into the render buffer.
public struct MetronomeRenderer: Sendable {
    public struct Grid: Sendable, Equatable {
        /// Beat positions in song frames, ascending.
        public var beats: [Int64]
        /// Subset of `beats` that start a bar (accented).
        public var downbeats: Set<Int64>

        public init(beats: [Int64], downbeats: Set<Int64>) {
            self.beats = beats
            self.downbeats = downbeats
        }

        public init(beatTimes: [Seconds], barTimes: [Seconds], sampleRate: Double) {
            let beats = beatTimes.map { Int64(($0 * sampleRate).rounded()) }.sorted()
            // Accent a beat when a bar line lies within 30 ms of it.
            let tolerance = Int64(0.03 * sampleRate)
            let bars = barTimes.map { Int64(($0 * sampleRate).rounded()) }
            let downbeats = Set(beats.filter { beat in bars.contains { abs($0 - beat) <= tolerance } })
            self.init(beats: beats, downbeats: downbeats)
        }
    }

    public let sampleRate: Double
    public var grid: Grid
    public var enabled = true
    public var volume: Float = 0.6

    /// Next song frame to render. Negative frames are the count-in before `songStart`.
    public private(set) var cursor: Int64 = 0
    public private(set) var armed = false
    /// Count-in: clicks at `countInStart + k · countInInterval` for k < countInBeats, all before `songStart`.
    private var countInStart: Int64 = 0
    private var countInInterval: Int64 = 0
    private var countInBeats = 0
    private var songStart: Int64 = 0
    private var loop: (start: Int64, end: Int64)?

    // Click synthesis state (carries across buffers).
    private var clickRemaining = 0
    private var clickPhase = 0.0
    private var clickFrequency = 1_000.0
    private var clickAmplitude: Float = 0
    private var clickLength: Int { Int(0.035 * sampleRate) }

    public init(sampleRate: Double, grid: Grid = Grid(beats: [], downbeats: [])) {
        self.sampleRate = sampleRate
        self.grid = grid
    }

    /// Starts rendering from `frame`. With `countInBeats > 0`, first plays that many clicks spaced
    /// `interval` frames apart; the song itself starts after them (the player must delay its start
    /// by `countInBeats · interval` frames).
    public mutating func start(at frame: Int64, loop: (start: Int64, end: Int64)?, countInBeats: Int = 0, interval: Int64 = 0) {
        self.loop = loop.flatMap { $0.end > $0.start ? $0 : nil }
        songStart = frame
        self.countInBeats = interval > 0 ? max(0, countInBeats) : 0
        countInInterval = interval
        let lead = Int64(self.countInBeats) * interval
        countInStart = frame - lead
        cursor = frame - lead
        armed = true
        clickRemaining = 0
    }

    public mutating func stop() {
        armed = false
        clickRemaining = 0
    }

    /// Frames of silence the song player must wait before its first sample (the count-in length).
    public var leadFrames: Int64 { Int64(countInBeats) * countInInterval }

    /// Renders `count` frames of mono click audio into `output` (overwriting it).
    public mutating func render(_ count: Int, into output: inout [Float]) {
        if output.count < count { output = [Float](repeating: 0, count: count) }
        for i in 0..<count { output[i] = 0 }
        guard armed else { return }
        for i in 0..<count {
            let frame = cursor
            if enabled, let accent = clickAccent(at: frame) { trigger(accent: accent) }
            if clickRemaining > 0 {
                let t = Double(clickLength - clickRemaining) / sampleRate
                let envelope = exp(-t * 90)
                output[i] = clickAmplitude * Float(envelope * sin(clickPhase))
                clickPhase += 2 * .pi * clickFrequency / sampleRate
                clickRemaining -= 1
            }
            advance()
        }
    }

    /// The click (if any) that starts exactly at `frame`: true = accented.
    func clickAccent(at frame: Int64) -> Bool? {
        if frame < songStart {
            guard countInBeats > 0, frame >= countInStart, (frame - countInStart) % countInInterval == 0 else { return nil }
            return (frame - countInStart) / countInInterval == 0
        }
        guard Self.contains(grid.beats, frame) else { return nil }
        return grid.downbeats.contains(frame)
    }

    private mutating func trigger(accent: Bool) {
        clickRemaining = clickLength
        clickPhase = 0
        clickFrequency = accent ? 1_600 : 1_100
        clickAmplitude = volume * (accent ? 1 : 0.7)
    }

    /// Mirrors the song player's scheduling: when playback started before the loop end, it wraps
    /// from the loop end back to the loop start; otherwise it plays straight on.
    private mutating func advance() {
        cursor += 1
        if let loop, songStart < loop.end, cursor == loop.end { cursor = loop.start }
    }

    /// Clicks that would sound in [from, to) — for tests and the UI's beat indicator.
    public func clickFrames(from: Int64, to: Int64) -> [Int64] {
        let lower = Self.firstIndex(grid.beats, notBelow: from)
        let upper = Self.firstIndex(grid.beats, notBelow: to)
        return Array(grid.beats[lower..<max(lower, upper)])
    }

    static func contains(_ sorted: [Int64], _ value: Int64) -> Bool {
        let index = firstIndex(sorted, notBelow: value)
        return index < sorted.count && sorted[index] == value
    }

    static func firstIndex(_ sorted: [Int64], notBelow value: Int64) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
