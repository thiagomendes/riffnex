import Foundation
import Testing
@testable import MusicCore

@Suite("Metronome renderer")
struct MetronomeTests {
    /// Frames where a click starts (first non-zero sample after silence).
    func onsets(_ samples: [Float]) -> [Int] {
        var result: [Int] = []
        var silentRun = 1_000
        for (i, s) in samples.enumerated() {
            if s != 0 {
                if silentRun > 40 { result.append(i) }
                silentRun = 0
            } else {
                silentRun += 1
            }
        }
        return result
    }

    func render(_ renderer: inout MetronomeRenderer, frames: Int, chunk: Int = 256) -> [Float] {
        var out: [Float] = []
        var buffer = [Float](repeating: 0, count: chunk)
        var remaining = frames
        while remaining > 0 {
            let n = min(chunk, remaining)
            renderer.render(n, into: &buffer)
            out.append(contentsOf: buffer.prefix(n))
            remaining -= n
        }
        return out
    }

    let rate = 1_000.0 // 1 kHz keeps the numbers readable

    @Test func clicksOnBeatsAcrossBuffers() {
        var m = MetronomeRenderer(sampleRate: rate, grid: .init(beats: [100, 600, 1100], downbeats: [100]))
        m.start(at: 0, loop: nil)
        let out = render(&m, frames: 1500, chunk: 97)
        // Click synthesis starts at sin(0) = 0, so the first audible sample is one frame later.
        #expect(onsets(out) == [101, 601, 1101])
    }

    @Test func silentWhenDisabledOrStopped() {
        var m = MetronomeRenderer(sampleRate: rate, grid: .init(beats: [10], downbeats: []))
        m.start(at: 0, loop: nil)
        m.enabled = false
        #expect(render(&m, frames: 100).allSatisfy { $0 == 0 })
        m.enabled = true
        m.stop()
        #expect(render(&m, frames: 100).allSatisfy { $0 == 0 })
    }

    @Test func countInPrecedesTheSong() {
        var m = MetronomeRenderer(sampleRate: rate, grid: .init(beats: [2000, 2500], downbeats: [2000]))
        m.start(at: 2000, loop: nil, countInBeats: 4, interval: 500)
        #expect(m.leadFrames == 2000)
        let out = render(&m, frames: 3000)
        // Four count-in clicks, then the song's beats at 2000 and 2500 (rendered 2000 frames later).
        #expect(onsets(out) == [1, 501, 1001, 1501, 2001, 2501])
    }

    @Test func wrapsWithTheLoop() {
        var m = MetronomeRenderer(sampleRate: rate, grid: .init(beats: [100, 300, 500], downbeats: []))
        m.start(at: 0, loop: (start: 200, end: 400))
        let out = render(&m, frames: 800)
        // 0→400 plays beats 100 and 300; then the 200–400 loop repeats beat 300 every 200 frames.
        #expect(onsets(out) == [101, 301, 501, 701])
        #expect(m.cursor >= 200 && m.cursor < 400)
    }

    @Test func gridFromSeconds() {
        let grid = MetronomeRenderer.Grid(beatTimes: [0, 0.5, 1.0, 1.5, 2.0], barTimes: [0.01, 2.0], sampleRate: 1000)
        #expect(grid.beats == [0, 500, 1000, 1500, 2000])
        #expect(grid.downbeats == [0, 2000])
    }

    @Test func delayShiftsEverythingLater() {
        var m = MetronomeRenderer(sampleRate: rate, grid: .init(beats: [100, 600], downbeats: []))
        m.start(at: 0, loop: nil)
        m.delay(frames: 250)
        let out = render(&m, frames: 1000, chunk: 64)
        #expect(onsets(out) == [351, 851])
    }
}
