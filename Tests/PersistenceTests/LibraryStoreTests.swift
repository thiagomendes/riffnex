import Foundation
import MusicCore
import Testing
@testable import Persistence

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("riffnex-tests-\(UUID().uuidString)", isDirectory: true)
}

private func makeSong(hash: String = "abc", demo: Bool = false) -> SongRecord {
    SongRecord(title: "Riff", artist: nil, duration: 21.5, audioFileName: "audio.m4a", contentHash: hash,
               importedAt: Date(timeIntervalSince1970: 1_700_000_000), isDemo: demo)
}

@Suite("LibraryStore")
struct LibraryStoreTests {
    @Test func emptyLibraryLoads() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let songs = try await store.load()
        #expect(songs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.songsDirectory.path))
    }

    @Test func addPersistsAcrossInstances() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = makeSong()
        try await LibraryStore(rootURL: root).add(song)

        let reopened = LibraryStore(rootURL: root)
        let songs = try await reopened.load()
        #expect(songs == [song])
        #expect(await reopened.song(withHash: "abc")?.id == song.id)
        #expect(await reopened.song(withHash: "zzz") == nil)
    }

    @Test func demoFlagIsRemembered() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        try await store.load()
        #expect(await store.demoSeeded == false)
        let demo = makeSong(demo: true)
        try await store.add(demo)
        try await store.remove(demo.id)
        // Deleting the demo must not bring it back on the next launch.
        let reopened = LibraryStore(rootURL: root)
        try await reopened.load()
        #expect(await reopened.demoSeeded == true)
    }

    @Test func removeDeletesFolder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let song = makeSong()
        let folder = store.folder(for: song.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.audioURL(for: song))
        try await store.add(song)
        try await store.save(StudioState(position: 3), for: song.id)

        try await store.remove(song.id)
        #expect(await store.songs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func studioStateRoundTripAndDefaults() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let id = UUID()
        #expect(await store.studioState(for: id) == StudioState())

        let loop = try #require(LoopRegion(start: 2, end: 6, duration: 21.5))
        let state = StudioState(position: 4.25, rate: 0.7, loop: loop, loopEnabled: true, practicedSeconds: 12)
        try await store.save(state, for: id)
        #expect(await store.studioState(for: id) == state)
    }

    @Test func studioStateClampsValues() {
        let state = StudioState(position: -4, rate: 9, loop: nil, loopEnabled: true, practicedSeconds: -1)
        #expect(state.position == 0)
        #expect(state.rate == 1.25)
        #expect(state.loopEnabled == false) // cannot enable a loop that does not exist
        #expect(state.practicedSeconds == 0)
    }

    @Test func markOpenedAndUpdate() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        var song = makeSong()
        try await store.add(song)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.markOpened(song.id, at: date)
        #expect(await store.song(song.id)?.lastOpenedAt == date)

        song.title = "Novo título"
        song.lastOpenedAt = date
        try await store.update(song)
        #expect(await store.song(song.id)?.title == "Novo título")
        await #expect(throws: LibraryError.unknownSong(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)) {
            try await store.markOpened(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        }
    }

    @Test func waveformRoundTrip() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let id = UUID()
        #expect(await store.waveform(for: id) == nil)
        let waveform = WaveformOverview(peaks: [0, 0.5, 1], duration: 3)
        try await store.save(waveform, for: id)
        #expect(await store.waveform(for: id) == waveform)
    }

    @Test func rejectsNewerSchema() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = #"{"schemaVersion": 99, "songs": [], "demoSeeded": false}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("library.json"))
        await #expect(throws: LibraryError.unsupportedSchema(99)) {
            try await LibraryStore(rootURL: root).load()
        }
    }
}
