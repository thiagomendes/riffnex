import Foundation

/// A loop region in seconds of the original audio. Always valid: `0 <= start < end <= duration`
/// and at least `minimumLength` long.
public struct LoopRegion: Codable, Sendable, Hashable {
    public static let minimumLength: Seconds = 0.25

    public let start: Seconds
    public let end: Seconds

    /// Clamps into `0...duration`. Returns `nil` when the clamped region is shorter than `minimumLength`.
    public init?(start: Seconds, end: Seconds, duration: Seconds) {
        guard start.isFinite, end.isFinite, duration > 0 else { return nil }
        let lower = min(max(0, min(start, end)), duration)
        let upper = min(max(0, max(start, end)), duration)
        guard upper - lower >= Self.minimumLength else { return nil }
        self.start = lower
        self.end = upper
    }

    public var length: Seconds { end - start }

    public func contains(_ time: Seconds) -> Bool { time >= start && time < end }

    /// A region of `length` seconds centered on `time`, shifted to fit inside the song.
    public static func around(_ time: Seconds, length: Seconds, duration: Seconds) -> LoopRegion? {
        let length = min(length, duration)
        var start = time - length / 2
        start = min(max(0, start), max(0, duration - length))
        return LoopRegion(start: start, end: start + length, duration: duration)
    }
}

/// Converts between "frames rendered since playback was scheduled" and the position in the file.
///
/// The playback engine schedules audio as: `[startFrame, loopEnd)` followed by `[loopStart, loopEnd)`
/// repeated (when a loop is active and `startFrame < loopEnd`), or `[startFrame, fileLength)` otherwise.
/// The player node reports how many source frames it has rendered; this maps that count back to
/// the file position. Pure and deterministic so it can be tested exhaustively.
public enum PlaybackPosition {
    public struct FrameLoop: Sendable, Hashable {
        public let start: Int64
        public let end: Int64

        public init(start: Int64, end: Int64) {
            precondition(end > start, "Loop must have positive length")
            self.start = start
            self.end = end
        }

        public var length: Int64 { end - start }
    }

    public static func fileFrame(
        renderedFrames: Int64,
        startFrame: Int64,
        loop: FrameLoop?,
        fileLength: Int64
    ) -> Int64 {
        let rendered = max(0, renderedFrames)
        if let loop, startFrame < loop.end {
            let firstPass = loop.end - startFrame
            if rendered < firstPass { return startFrame + rendered }
            return loop.start + (rendered - firstPass) % loop.length
        }
        return min(startFrame + rendered, fileLength)
    }

    /// Converts seconds to a frame index clamped to the file.
    public static func frame(for seconds: Seconds, sampleRate: Double, fileLength: Int64) -> Int64 {
        guard seconds.isFinite, sampleRate > 0 else { return 0 }
        return min(max(0, Int64((seconds * sampleRate).rounded())), fileLength)
    }
}

/// A compact, normalized overview of a song's loudness for drawing waveforms and artwork.
public struct WaveformOverview: Codable, Sendable, Hashable {
    /// Peak amplitude per bucket, normalized so the loudest bucket is 1.
    public let peaks: [Float]
    public let duration: Seconds

    public init(peaks: [Float], duration: Seconds) {
        self.peaks = peaks
        self.duration = duration
    }

    public static func make(samples: [Float], sampleRate: Double, bucketCount: Int) -> WaveformOverview {
        precondition(bucketCount > 0, "bucketCount must be positive")
        let duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        guard !samples.isEmpty else {
            return WaveformOverview(peaks: [Float](repeating: 0, count: bucketCount), duration: duration)
        }
        var peaks = [Float](repeating: 0, count: bucketCount)
        let count = samples.count
        for bucket in 0..<bucketCount {
            let lower = bucket * count / bucketCount
            let upper = max(lower + 1, (bucket + 1) * count / bucketCount)
            var peak: Float = 0
            for i in lower..<min(upper, count) {
                let value = abs(samples[i])
                if value > peak { peak = value }
            }
            peaks[bucket] = peak
        }
        let maximum = peaks.max() ?? 0
        if maximum > 0 {
            for i in peaks.indices { peaks[i] /= maximum }
        }
        return WaveformOverview(peaks: peaks, duration: duration)
    }
}

public enum TimeFormatting {
    /// "1:05", "12:30", "1:02:03". Negative and non-finite values render as "0:00".
    public static func clock(_ seconds: Seconds) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):" + pad(minutes) + ":" + pad(secs)
        }
        return "\(minutes):" + pad(secs)
    }

    private static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
