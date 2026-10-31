import AVFoundation
import Foundation
import MusicUnderstanding
import os

/// M0 toolchain spike: runs Apple's Music Understanding framework (iOS 27+) on a file and returns
/// the raw result as JSON, so we can see exactly what the framework reports on a real device before
/// designing the M2 adapter around it. All result types are Codable per Apple's documentation.
public enum MusicUnderstandingProbe {
    private static let log = Logger(subsystem: RXLog.subsystem, category: "music-understanding")

    public struct Report: Sendable {
        public let seconds: Double
        public let json: String
    }

    public static func analyze(fileURL: URL) async throws -> Report {
        let asset = AVURLAsset(url: fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let clock = ContinuousClock()
        let start = clock.now
        let session = try await MusicUnderstandingSession(asset: asset)
        let result = try await session.analyze(for: [.rhythm, .key, .structure, .instrumentActivity])
        let elapsed = (clock.now - start).seconds
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(result), as: UTF8.self)
        log.info("Music Understanding finished in \(elapsed, privacy: .public)s, \(json.count, privacy: .public) chars")
        return Report(seconds: elapsed, json: json)
    }
}
