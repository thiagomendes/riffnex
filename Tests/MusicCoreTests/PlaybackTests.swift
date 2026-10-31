import Foundation
import Testing
@testable import MusicCore

@Suite("LoopRegion")
struct LoopRegionTests {
    @Test func clampsAndOrders() throws {
        let region = try #require(LoopRegion(start: 12, end: -3, duration: 10))
        #expect(region.start == 0)
        #expect(region.end == 10)
        #expect(region.length == 10)
    }

    @Test func rejectsTooShortOrInvalid() {
        #expect(LoopRegion(start: 1, end: 1.1, duration: 10) == nil)
        #expect(LoopRegion(start: .nan, end: 2, duration: 10) == nil)
        #expect(LoopRegion(start: 0, end: 2, duration: 0) == nil)
        #expect(LoopRegion(start: 11, end: 12, duration: 10) == nil) // entirely past the end
    }

    @Test func aroundStaysInside() throws {
        let nearStart = try #require(LoopRegion.around(0.5, length: 8, duration: 30))
        #expect(nearStart.start == 0 && nearStart.end == 8)
        let nearEnd = try #require(LoopRegion.around(29, length: 8, duration: 30))
        #expect(nearEnd.start == 22 && nearEnd.end == 30)
        let middle = try #require(LoopRegion.around(15, length: 8, duration: 30))
        #expect(middle.start == 11 && middle.end == 19)
        let tiny = try #require(LoopRegion.around(1, length: 8, duration: 3))
        #expect(tiny.start == 0 && tiny.end == 3)
        #expect(middle.contains(11) && !middle.contains(19))
    }
}

@Suite("PlaybackPosition")
struct PlaybackPositionTests {
    let fileLength: Int64 = 1_000

    @Test func linearWithoutLoop() {
        #expect(PlaybackPosition.fileFrame(renderedFrames: 0, startFrame: 100, loop: nil, fileLength: fileLength) == 100)
        #expect(PlaybackPosition.fileFrame(renderedFrames: 250, startFrame: 100, loop: nil, fileLength: fileLength) == 350)
        #expect(PlaybackPosition.fileFrame(renderedFrames: 5_000, startFrame: 100, loop: nil, fileLength: fileLength) == 1_000)
        #expect(PlaybackPosition.fileFrame(renderedFrames: -10, startFrame: 100, loop: nil, fileLength: fileLength) == 100)
    }

    @Test func wrapsInsideLoop() {
        let loop = PlaybackPosition.FrameLoop(start: 200, end: 300)
        // Start inside the loop at 250: 50 frames to the loop end, then wrap to 200.
        #expect(PlaybackPosition.fileFrame(renderedFrames: 49, startFrame: 250, loop: loop, fileLength: fileLength) == 299)
        #expect(PlaybackPosition.fileFrame(renderedFrames: 50, startFrame: 250, loop: loop, fileLength: fileLength) == 200)
        #expect(PlaybackPosition.fileFrame(renderedFrames: 175, startFrame: 250, loop: loop, fileLength: fileLength) == 225)
        #expect(PlaybackPosition.fileFrame(renderedFrames: 50 + 100 * 7 + 3, startFrame: 250, loop: loop, fileLength: fileLength) == 203)
    }

    @Test func startBeforeLoopPlaysIntoIt() {
        let loop = PlaybackPosition.FrameLoop(start: 200, end: 300)
        #expect(PlaybackPosition.fileFrame(renderedFrames: 150, startFrame: 100, loop: loop, fileLength: fileLength) == 250)
        #expect(PlaybackPosition.fileFrame(renderedFrames: 200, startFrame: 100, loop: loop, fileLength: fileLength) == 200)
    }

    @Test func startAfterLoopIgnoresIt() {
        let loop = PlaybackPosition.FrameLoop(start: 200, end: 300)
        #expect(PlaybackPosition.fileFrame(renderedFrames: 100, startFrame: 400, loop: loop, fileLength: fileLength) == 500)
    }

    /// Invariant: the mapped position always stays inside the file and, once looping, inside the loop.
    @Test func staysInBounds() {
        let loop = PlaybackPosition.FrameLoop(start: 123, end: 457)
        for start in stride(from: Int64(0), to: 1_000, by: 37) {
            for rendered in stride(from: Int64(0), to: 5_000, by: 53) {
                let frame = PlaybackPosition.fileFrame(renderedFrames: rendered, startFrame: start, loop: loop, fileLength: fileLength)
                #expect(frame >= 0 && frame <= fileLength)
                if start < loop.end && rendered >= loop.end - start {
                    #expect(frame >= loop.start && frame < loop.end)
                }
            }
        }
    }

    @Test func secondsToFrames() {
        #expect(PlaybackPosition.frame(for: 1.5, sampleRate: 44_100, fileLength: 1_000_000) == 66_150)
        #expect(PlaybackPosition.frame(for: -1, sampleRate: 44_100, fileLength: 1_000_000) == 0)
        #expect(PlaybackPosition.frame(for: 100, sampleRate: 44_100, fileLength: 1_000) == 1_000)
        #expect(PlaybackPosition.frame(for: .nan, sampleRate: 44_100, fileLength: 1_000) == 0)
    }
}

@Suite("Waveform & time")
struct WaveformTests {
    @Test func normalizedPeaks() {
        var samples = [Float](repeating: 0.1, count: 1_000)
        samples[750] = -0.5
        let overview = WaveformOverview.make(samples: samples, sampleRate: 100, bucketCount: 4)
        #expect(overview.peaks.count == 4)
        #expect(overview.duration == 10)
        #expect(overview.peaks[3] == 1)
        #expect(abs(overview.peaks[0] - 0.2) < 1e-6)
    }

    @Test func emptyAndShortInputs() {
        #expect(WaveformOverview.make(samples: [], sampleRate: 100, bucketCount: 8).peaks == [Float](repeating: 0, count: 8))
        let few = WaveformOverview.make(samples: [0.5, -1], sampleRate: 100, bucketCount: 8)
        #expect(few.peaks.count == 8)
        #expect(few.peaks.max() == 1)
    }

    @Test func clockFormatting() {
        #expect(TimeFormatting.clock(0) == "0:00")
        #expect(TimeFormatting.clock(65.9) == "1:05")
        #expect(TimeFormatting.clock(750) == "12:30")
        #expect(TimeFormatting.clock(3723) == "1:02:03")
        #expect(TimeFormatting.clock(-3) == "0:00")
        #expect(TimeFormatting.clock(.infinity) == "0:00")
    }
}
