import Foundation
import MusicCore

/// One imported song. Paths are relative to the song's folder so the library survives container moves.
public struct SongRecord: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var title: String
    public var artist: String?
    public var duration: Seconds
    /// File name of the private audio copy inside the song folder (e.g. "audio.m4a").
    public var audioFileName: String
    /// SHA-256 of the original file bytes, hex-encoded. Used to detect duplicate imports.
    public var contentHash: String
    public var importedAt: Date
    public var lastOpenedAt: Date?
    public var hasArtwork: Bool
    public var isDemo: Bool

    public init(id: UUID = UUID(), title: String, artist: String?, duration: Seconds, audioFileName: String,
                contentHash: String, importedAt: Date = Date(), lastOpenedAt: Date? = nil,
                hasArtwork: Bool = false, isDemo: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.audioFileName = audioFileName
        self.contentHash = contentHash
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
        self.hasArtwork = hasArtwork
        self.isDemo = isDemo
    }
}

/// Per-song practice state, restored when the song is reopened.
public struct StudioState: Codable, Sendable, Hashable {
    public var position: Seconds
    /// Playback rate, 0.25...1.25.
    public var rate: Double
    public var loop: LoopRegion?
    public var loopEnabled: Bool
    /// Seconds of audio actually played in this song (measured while playing).
    public var practicedSeconds: Double

    public static let rateRange: ClosedRange<Double> = 0.25...1.25

    public init(position: Seconds = 0, rate: Double = 1, loop: LoopRegion? = nil, loopEnabled: Bool = false,
                practicedSeconds: Double = 0) {
        self.position = max(0, position)
        self.rate = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        self.loop = loop
        self.loopEnabled = loopEnabled && loop != nil
        self.practicedSeconds = max(0, practicedSeconds)
    }
}

public enum LibraryError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case unknownSong(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "A biblioteca foi salva por uma versão mais nova do app (esquema \(version))."
        case .unknownSong: "Música não encontrada na biblioteca."
        }
    }
}

/// Stores the library as plain JSON files:
///
///     <root>/library.json                 index of songs (versioned)
///     <root>/Songs/<uuid>/<audio file>    private copy of the imported audio
///     <root>/Songs/<uuid>/waveform.json   overview for drawing
///     <root>/Songs/<uuid>/state.json      StudioState
///     <root>/Songs/<uuid>/artwork.jpg     embedded artwork, when the file had one
///
/// Every write is atomic, so a crash never leaves a half-written file.
public actor LibraryStore {
    public static let schemaVersion = 1

    private struct IndexFile: Codable {
        var schemaVersion: Int
        var songs: [SongRecord]
        var demoSeeded: Bool
    }

    public nonisolated let rootURL: URL
    private var index = IndexFile(schemaVersion: LibraryStore.schemaVersion, songs: [], demoSeeded: false)
    private var loaded = false

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: Paths

    public nonisolated var songsDirectory: URL { rootURL.appendingPathComponent("Songs", isDirectory: true) }
    private nonisolated var indexURL: URL { rootURL.appendingPathComponent("library.json") }

    public nonisolated func folder(for id: UUID) -> URL {
        songsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public nonisolated func audioURL(for song: SongRecord) -> URL {
        folder(for: song.id).appendingPathComponent(song.audioFileName)
    }

    public nonisolated func waveformURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("waveform.json")
    }

    public nonisolated func artworkURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("artwork.jpg")
    }

    public nonisolated func analysisURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("analysis.json")
    }

    private nonisolated func stateURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("state.json")
    }

    // MARK: Loading

    /// Loads the index from disk (once). A missing file means an empty library.
    @discardableResult
    public func load() throws -> [SongRecord] {
        if loaded { return index.songs }
        try FileManager.default.createDirectory(at: songsDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let data = try Data(contentsOf: indexURL)
            let decoded = try Self.decoder.decode(IndexFile.self, from: data)
            guard decoded.schemaVersion <= Self.schemaVersion else {
                throw LibraryError.unsupportedSchema(decoded.schemaVersion)
            }
            index = decoded
        }
        loaded = true
        return index.songs
    }

    public var songs: [SongRecord] { index.songs }

    public var demoSeeded: Bool { index.demoSeeded }

    public func song(_ id: UUID) -> SongRecord? { index.songs.first { $0.id == id } }

    public func song(withHash hash: String) -> SongRecord? { index.songs.first { $0.contentHash == hash } }

    // MARK: Mutations

    /// Adds a song whose folder has already been populated by the importer.
    public func add(_ song: SongRecord) throws {
        try load()
        index.songs.removeAll { $0.id == song.id }
        index.songs.append(song)
        if song.isDemo { index.demoSeeded = true }
        try saveIndex()
    }

    public func update(_ song: SongRecord) throws {
        try load()
        guard let i = index.songs.firstIndex(where: { $0.id == song.id }) else { throw LibraryError.unknownSong(song.id) }
        index.songs[i] = song
        try saveIndex()
    }

    public func markOpened(_ id: UUID, at date: Date = Date()) throws {
        guard var song = self.song(id) else { throw LibraryError.unknownSong(id) }
        song.lastOpenedAt = date
        try update(song)
    }

    /// Removes the song and everything stored for it.
    public func remove(_ id: UUID) throws {
        try load()
        index.songs.removeAll { $0.id == id }
        try saveIndex()
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Per-song files

    public func studioState(for id: UUID) -> StudioState {
        guard let data = try? Data(contentsOf: stateURL(for: id)),
              let state = try? Self.decoder.decode(StudioState.self, from: data) else { return StudioState() }
        return state
    }

    public func save(_ state: StudioState, for id: UUID) throws {
        try write(state, to: stateURL(for: id))
    }

    public func waveform(for id: UUID) -> WaveformOverview? {
        guard let data = try? Data(contentsOf: waveformURL(for: id)) else { return nil }
        return try? Self.decoder.decode(WaveformOverview.self, from: data)
    }

    public func save(_ waveform: WaveformOverview, for id: UUID) throws {
        try write(waveform, to: waveformURL(for: id))
    }

    /// The stored analysis, or `nil` if there is none or it was written with a different schema
    /// (the caller then offers to analyze again — we never show results we cannot read faithfully).
    public func analysis(for id: UUID) -> SongAnalysis? {
        guard let data = try? Data(contentsOf: analysisURL(for: id)),
              let analysis = try? Self.decoder.decode(SongAnalysis.self, from: data),
              analysis.schemaVersion == SongAnalysis.currentSchemaVersion else { return nil }
        return analysis
    }

    public func hasAnalysis(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: analysisURL(for: id).path)
    }

    /// Written atomically, so a cancelled or crashed analysis never leaves a partial file.
    public func save(_ analysis: SongAnalysis, for id: UUID) throws {
        guard song(id) != nil else { throw LibraryError.unknownSong(id) }
        try write(analysis, to: analysisURL(for: id))
    }

    public func removeAnalysis(for id: UUID) throws {
        let url = analysisURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    // MARK: Private

    private func saveIndex() throws {
        try write(index, to: indexURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
