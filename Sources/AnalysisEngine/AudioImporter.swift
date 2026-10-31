import AVFoundation
import CryptoKit
import Foundation
import MusicCore
import os

/// Validates a user-chosen audio file, copies it into the app's private storage and extracts what
/// the library needs (title, artist, duration, artwork, waveform). Nothing here is simulated:
/// every value comes from the file.
public enum AudioImporter {
    public static let durationRange: ClosedRange<Double> = 5...(15 * 60)
    public static let waveformBuckets = 600

    public enum ImportError: Error, Equatable, LocalizedError {
        case unreadable
        case noAudioTrack
        case protectedContent
        case tooShort(seconds: Double)
        case tooLong(seconds: Double)
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                "Não foi possível ler este arquivo como áudio. Formatos suportados: MP3, M4A/AAC, WAV, AIFF e CAF."
            case .noAudioTrack:
                "Este arquivo não contém uma faixa de áudio."
            case .protectedContent:
                "Este arquivo está protegido por DRM e não pode ser usado."
            case .tooShort(let seconds):
                "Arquivo muito curto (\(TimeFormatting.clock(seconds))). O mínimo é 5 segundos."
            case .tooLong(let seconds):
                "Arquivo muito longo (\(TimeFormatting.clock(seconds))). O máximo é 15 minutos."
            case .copyFailed(let detail):
                "Não foi possível copiar o arquivo: \(detail)"
            }
        }
    }

    public struct Inspection: Sendable {
        public let title: String
        public let artist: String?
        public let duration: Double
        public let artworkData: Data?
    }

    public struct ImportedAudio: Sendable {
        public let audioFileName: String
        public let inspection: Inspection
        public let waveform: WaveformOverview
    }

    private static let log = Logger(subsystem: RXLog.subsystem, category: "import")

    // MARK: Hash

    /// SHA-256 of the file bytes, streamed in 1 MB chunks, hex-encoded.
    public static func contentHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Inspection

    /// Validates the file and reads its metadata. Throws `ImportError` with a user-facing message.
    public static func inspect(_ url: URL) async throws -> Inspection {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let playable: Bool
        let protected: Bool
        do {
            (duration, playable, protected) = try await asset.load(.duration, .isPlayable, .hasProtectedContent)
        } catch {
            log.error("Inspection failed: \(error.localizedDescription, privacy: .public)")
            throw ImportError.unreadable
        }
        if protected { throw ImportError.protectedContent }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else { throw ImportError.noAudioTrack }
        guard playable, duration.isNumeric else { throw ImportError.unreadable }
        let seconds = duration.seconds
        if seconds < durationRange.lowerBound { throw ImportError.tooShort(seconds: seconds) }
        if seconds > durationRange.upperBound { throw ImportError.tooLong(seconds: seconds) }

        // Metadata is optional: a file without tags still imports, titled by its file name.
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let title = await stringValue(in: metadata, for: .commonIdentifierTitle)
        let artist = await stringValue(in: metadata, for: .commonIdentifierArtist)
        let artwork = await dataValue(in: metadata, for: .commonIdentifierArtwork)

        return Inspection(title: title ?? fallbackTitle(for: url), artist: artist, duration: seconds, artworkData: artwork)
    }

    /// "My_Song-final.mp3" → "My Song-final".
    public static func fallbackTitle(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "Sem título" : base
    }

    private static func stringValue(in items: [AVMetadataItem], for identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dataValue(in items: [AVMetadataItem], for identifier: AVMetadataIdentifier) async -> Data? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { return nil }
        return try? await item.load(.dataValue)
    }

    // MARK: Import

    /// Inspects `source`, copies it into `folder` as `audio.<ext>`, and computes the waveform.
    /// On failure, `folder` is removed so no partial song is left behind.
    public static func importAudio(from source: URL, into folder: URL) async throws -> ImportedAudio {
        let inspection = try await inspect(source)
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let fileName = "audio.\(ext)"
        var destination = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            // The audio is the user's own file and can be re-imported, so keep it out of iCloud backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try destination.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw ImportError.copyFailed(error.localizedDescription)
        }

        do {
            try Task.checkCancellation()
            let copied = destination
            let decoded = try await Task.detached(priority: .userInitiated) {
                try AudioDecoder.decodeMono(url: copied, sampleRate: 11_025)
            }.value
            let waveform = WaveformOverview.make(samples: decoded.samples, sampleRate: decoded.sampleRate,
                                                 bucketCount: waveformBuckets)
            log.info("Imported \(fileName, privacy: .public): \(inspection.duration, privacy: .public)s")
            return ImportedAudio(audioFileName: fileName, inspection: inspection, waveform: waveform)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if error is CancellationError { throw error }
            throw ImportError.unreadable
        }
    }
}
