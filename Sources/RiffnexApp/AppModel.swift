import AnalysisEngine
import Foundation
import MusicCore
import Observation
import os
import Persistence
import PlaybackEngine

/// App-wide state: the library, imports in progress and the single audio player.
@MainActor
@Observable
final class AppModel {
    enum ImportState: Equatable {
        case idle
        case importing(fileName: String)
        case failed(message: String)
        case duplicate(existing: SongRecord)
    }

    private(set) var songs: [SongRecord] = []
    private(set) var waveforms: [UUID: WaveformOverview] = [:]
    private(set) var isBootstrapped = false
    private(set) var libraryError: String?
    var importState: ImportState = .idle

    let player = AudioPlayer()
    let store: LibraryStore

    @ObservationIgnored private var importTask: Task<Void, Never>?
    private let log = Logger(subsystem: RXLog.subsystem, category: "library")

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        store = LibraryStore(rootURL: base.appendingPathComponent("Library", isDirectory: true))
    }

    /// The most recently opened song, for "Continuar praticando".
    var continueSong: SongRecord? {
        songs.filter { $0.lastOpenedAt != nil }.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        guard !isBootstrapped else { return }
        do {
            try await store.load()
            if !(await store.demoSeeded) { await seedDemo() }
            await refresh()
        } catch {
            libraryError = error.localizedDescription
            log.error("Library load failed: \(error.localizedDescription, privacy: .public)")
        }
        isBootstrapped = true
    }

    private func refresh() async {
        let all = await store.songs
        songs = all.sorted { $0.importedAt > $1.importedAt }
        for song in all where waveforms[song.id] == nil {
            waveforms[song.id] = await store.waveform(for: song.id)
        }
    }

    /// Adds the bundled original demo riff on first launch. It goes through the same importer as user files.
    private func seedDemo() async {
        guard let url = AppResources.demoSongURL else { return }
        do {
            let hash = try AudioImporter.contentHash(of: url)
            let id = UUID()
            let imported = try await AudioImporter.importAudio(from: url, into: store.folder(for: id))
            let song = SongRecord(id: id, title: imported.inspection.title, artist: imported.inspection.artist,
                                  duration: imported.inspection.duration, audioFileName: imported.audioFileName,
                                  contentHash: hash, isDemo: true)
            try await store.save(imported.waveform, for: id)
            try await store.add(song)
        } catch {
            log.error("Demo seeding failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Import

    func importFile(at pickedURL: URL) {
        importTask?.cancel()
        importState = .importing(fileName: pickedURL.lastPathComponent)
        importTask = Task { [weak self] in
            await self?.performImport(pickedURL)
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importState = .idle
    }

    private func performImport(_ pickedURL: URL) async {
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }
        do {
            let hash = try await Task.detached(priority: .userInitiated) {
                try AudioImporter.contentHash(of: pickedURL)
            }.value
            try Task.checkCancellation()
            if let existing = await store.song(withHash: hash) {
                importState = .duplicate(existing: existing)
                return
            }
            let id = UUID()
            let imported = try await AudioImporter.importAudio(from: pickedURL, into: store.folder(for: id))
            try Task.checkCancellation()
            var hasArtwork = false
            if let artwork = imported.inspection.artworkData {
                hasArtwork = (try? artwork.write(to: store.artworkURL(for: id), options: .atomic)) != nil
            }
            let song = SongRecord(id: id, title: imported.inspection.title, artist: imported.inspection.artist,
                                  duration: imported.inspection.duration, audioFileName: imported.audioFileName,
                                  contentHash: hash, hasArtwork: hasArtwork)
            try await store.save(imported.waveform, for: id)
            try await store.add(song)
            await refresh()
            importState = .idle
        } catch is CancellationError {
            importState = .idle
        } catch {
            importState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Songs

    func delete(_ song: SongRecord) async {
        do {
            try await store.remove(song.id)
            waveforms[song.id] = nil
            await refresh()
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func markOpened(_ song: SongRecord) async {
        try? await store.markOpened(song.id)
        await refresh()
    }

    func studioState(for song: SongRecord) async -> StudioState {
        await store.studioState(for: song.id)
    }

    func save(_ state: StudioState, for song: SongRecord) async {
        try? await store.save(state, for: song.id)
    }

    func audioURL(for song: SongRecord) -> URL { store.audioURL(for: song) }

    func artworkURL(for song: SongRecord) -> URL? { song.hasArtwork ? store.artworkURL(for: song.id) : nil }
}
