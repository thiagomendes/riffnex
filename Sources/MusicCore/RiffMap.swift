import Foundation

/// Everything the practice screen needs about one song, computed once on the device after the
/// guitar is separated: loudness envelopes of the guitar and of the rest of the band (to draw the
/// tape and the ring), guitar attacks (for the sparks), and the beat grid and sections from Music
/// Understanding (to snap loops and pulse with the music).
///
/// Nothing here claims to know notes: envelopes and attacks are measured directly on the audio.
public struct RiffMap: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public struct Span: Codable, Sendable, Equatable {
        public var start: Seconds
        public var end: Seconds

        public init(start: Seconds, end: Seconds) {
            self.start = start
            self.end = end
        }
    }

    public var schemaVersion: Int
    public var createdAt: Date
    public var duration: Seconds
    /// Tempo, beats and bar starts (empty when Music Understanding found none).
    public var beatsPerMinute: Double?
    public var beats: [Seconds]
    public var bars: [Seconds]
    public var sections: [Span]
    /// Envelope values per second.
    public var envelopeRate: Double
    /// 0…1 loudness of the separated guitar and of everything else, on a shared scale.
    public var guitar: [Float]
    public var band: [Float]
    /// Times where the guitar is attacked (picked notes or chords).
    public var guitarAttacks: [Seconds]
    /// Folder (inside the song folder) holding the separated instruments, and their names.
    public var stemsDirectory: String
    public var stemNames: [String]
    /// Stems that make up "the guitar" for the focus control.
    public var guitarStems: [String]
    public var separationSeconds: Double
    /// Non-fatal problems, in Portuguese, shown nowhere by default (diagnostics only).
    public var notes: [String]

    public init(schemaVersion: Int = RiffMap.currentSchemaVersion, createdAt: Date = Date(), duration: Seconds,
                beatsPerMinute: Double?, beats: [Seconds], bars: [Seconds], sections: [Span], envelopeRate: Double,
                guitar: [Float], band: [Float], guitarAttacks: [Seconds], stemsDirectory: String,
                stemNames: [String], guitarStems: [String], separationSeconds: Double, notes: [String] = []) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.duration = duration
        self.beatsPerMinute = beatsPerMinute
        self.beats = beats
        self.bars = bars
        self.sections = sections
        self.envelopeRate = envelopeRate
        self.guitar = guitar
        self.band = band
        self.guitarAttacks = guitarAttacks
        self.stemsDirectory = stemsDirectory
        self.stemNames = stemNames
        self.guitarStems = guitarStems
        self.separationSeconds = separationSeconds
        self.notes = notes
    }

    // MARK: Reading

    /// Linear interpolation of an envelope at `time` (0 outside the song).
    public static func value(_ envelope: [Float], rate: Double, at time: Seconds) -> Float {
        guard !envelope.isEmpty, rate > 0, time >= 0 else { return 0 }
        let x = time * rate
        let i = Int(x)
        guard i < envelope.count else { return 0 }
        let f = Float(x - Double(i))
        let next = i + 1 < envelope.count ? envelope[i + 1] : envelope[i]
        return envelope[i] * (1 - f) + next * f
    }

    public func guitarLevel(at time: Seconds) -> Float { Self.value(guitar, rate: envelopeRate, at: time) }
    public func bandLevel(at time: Seconds) -> Float { Self.value(band, rate: envelopeRate, at: time) }

    /// Nearest beat to `time` (or `time` itself without a beat grid).
    public func snapToBeat(_ time: Seconds) -> Seconds {
        BeatGrid.nearest(time, in: beats) ?? time
    }

    /// The beat at or before `time`.
    public func beat(atOrBefore time: Seconds) -> Seconds {
        BeatGrid.atOrBefore(time, in: beats) ?? time
    }

    /// Median beat length, if there is a grid.
    public var beatLength: Seconds? {
        BeatGrid.medianInterval(beats)
    }

    /// Position inside the current beat, 0…1 (for pulsing with the music).
    public func beatPhase(at time: Seconds) -> Double? {
        guard let previous = BeatGrid.atOrBefore(time, in: beats), let length = beatLength, length > 0 else { return nil }
        let next = BeatGrid.after(time, in: beats) ?? previous + length
        let span = max(next - previous, 1e-3)
        return min(max((time - previous) / span, 0), 1)
    }

    /// Guitar attacks with `from < t <= to`.
    public func attacks(after from: Seconds, upTo to: Seconds) -> ArraySlice<Seconds> {
        guard to > from else { return [] }
        let lower = BeatGrid.firstIndex(after: from, in: guitarAttacks)
        var upper = lower
        while upper < guitarAttacks.count, guitarAttacks[upper] <= to { upper += 1 }
        return guitarAttacks[lower..<upper]
    }
}

/// Small helpers over sorted time lists.
public enum BeatGrid {
    /// Index of the first element strictly greater than `time`.
    public static func firstIndex(after time: Seconds, in times: [Seconds]) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public static func atOrBefore(_ time: Seconds, in times: [Seconds]) -> Seconds? {
        let i = firstIndex(after: time, in: times)
        return i > 0 ? times[i - 1] : nil
    }

    public static func after(_ time: Seconds, in times: [Seconds]) -> Seconds? {
        let i = firstIndex(after: time, in: times)
        return i < times.count ? times[i] : nil
    }

    public static func nearest(_ time: Seconds, in times: [Seconds]) -> Seconds? {
        let i = firstIndex(after: time, in: times)
        let candidates = [i > 0 ? times[i - 1] : nil, i < times.count ? times[i] : nil].compactMap { $0 }
        return candidates.min { abs($0 - time) < abs($1 - time) }
    }

    public static func medianInterval(_ times: [Seconds]) -> Seconds? {
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !intervals.isEmpty else { return nil }
        return intervals[intervals.count / 2]
    }
}

/// Pure measurements used to build a `RiffMap` from decoded stems.
public enum RiffMapBuilder {
    /// RMS loudness of `samples` in consecutive windows of `1/rate` seconds.
    public static func rms(_ samples: [Float], sampleRate: Double, rate: Double) -> [Float] {
        guard sampleRate > 0, rate > 0, !samples.isEmpty else { return [] }
        let hop = max(1, Int((sampleRate / rate).rounded()))
        let count = (samples.count + hop - 1) / hop
        var out = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { s in
            for k in 0..<count {
                let start = k * hop, end = min(start + hop, s.count)
                var sum: Float = 0
                for i in start..<end { sum += s[i] * s[i] }
                out[k] = (sum / Float(max(1, end - start))).squareRoot()
            }
        }
        return out
    }

    /// Combines RMS envelopes of uncorrelated sources (energies add).
    public static func combine(_ envelopes: [[Float]]) -> [Float] {
        let count = envelopes.map(\.count).max() ?? 0
        var out = [Float](repeating: 0, count: count)
        for envelope in envelopes {
            for i in envelope.indices { out[i] += envelope[i] * envelope[i] }
        }
        return out.map { $0.squareRoot() }
    }

    /// Maps both envelopes to 0…1 on one shared scale, so a quiet guitar looks quiet next to the band.
    /// The reference is a high percentile of the louder of the two, then a gentle compression.
    public static func normalize(guitar: [Float], band: [Float], percentile: Double = 0.98) -> (guitar: [Float], band: [Float]) {
        let all = (guitar + band).filter { $0 > 0 }.sorted()
        guard !all.isEmpty else { return (guitar.map { _ in 0 }, band.map { _ in 0 }) }
        let reference = max(all[min(all.count - 1, Int(Double(all.count - 1) * percentile))], 1e-6)
        func map(_ x: Float) -> Float { min(1, (x / reference).squareRoot()) }
        return (guitar.map(map), band.map(map))
    }

    /// Attack times from an envelope: rises in loudness that stand out from their surroundings.
    /// - Parameters:
    ///   - envelope: RMS envelope at `rate` values per second.
    ///   - minGap: shortest time between two attacks.
    ///   - sensitivity: how far above the local average a rise must be.
    public static func attacks(envelope: [Float], rate: Double, minGap: Seconds = 0.07,
                               sensitivity: Float = 1.5, floor: Float = 0.02) -> [Seconds] {
        guard envelope.count > 2, rate > 0 else { return [] }
        let peak = envelope.max() ?? 0
        guard peak > 0 else { return [] }
        // Rise per frame on a log-like scale, so quiet and loud passages count alike.
        let compressed = envelope.map { Float(log1p(100 * Double($0 / peak))) }
        var flux = [Float](repeating: 0, count: compressed.count)
        for i in 1..<compressed.count { flux[i] = max(0, compressed[i] - compressed[i - 1]) }
        let half = max(1, Int(0.25 * rate))
        var times: [Seconds] = []
        var last = -Double.infinity
        for i in 1..<(flux.count - 1) {
            guard flux[i] > 0, flux[i] >= flux[i - 1], flux[i] > flux[i + 1] else { continue }
            guard envelope[i] >= floor * peak else { continue }
            let lo = max(0, i - half), hi = min(flux.count, i + half + 1)
            var mean: Float = 0
            for j in lo..<hi { mean += flux[j] }
            mean /= Float(hi - lo)
            guard flux[i] > sensitivity * mean, flux[i] > 0.05 else { continue }
            let t = Double(i) / rate
            if t - last >= minGap {
                times.append(t)
                last = t
            }
        }
        return times
    }

    /// Bars from beats when Music Understanding gave beats but no bars: every 4th beat.
    public static func bars(fromBeats beats: [Seconds], beatsPerBar: Int = 4) -> [Seconds] {
        stride(from: 0, to: beats.count, by: max(1, beatsPerBar)).map { beats[$0] }
    }
}

extension RiffMapBuilder {
    /// Which separated instruments count as "the guitar". The separator sometimes hears a guitar
    /// as piano or "other" (clean or synth-like tones), so a pitched stem louder than the guitar
    /// stem joins it; the guitar stem itself is always included.
    public static func guitarStems(energy: [String: Double]) -> [String] {
        let guitar = energy["guitar"] ?? 0
        var stems = ["guitar"]
        for name in ["piano", "other"] where (energy[name] ?? 0) > guitar && (energy[name] ?? 0) > 0 {
            stems.append(name)
        }
        return stems
    }
}
