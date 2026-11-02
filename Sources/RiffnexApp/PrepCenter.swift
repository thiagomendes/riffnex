import AnalysisEngine
import Foundation
import MusicCore
import Observation
import os
import Persistence
import UIKit

/// Prepares songs for practice (separates the guitar and measures the song), one at a time,
/// with real progress. Results are stored atomically; a cancelled or interrupted preparation
/// leaves nothing behind.
@MainActor
@Observable
final class PrepCenter {
    struct Job: Equatable {
        var songID: UUID
        var stage: RiffPreparer.Stage
        /// Overall 0…1: separation is ~95% of the work.
        var fraction: Double
        var startedAt: Date
        /// Memory iOS still allows the app (MB): at the start and now. Diagnostics for crashes.
        var startMemoryMB: Double = StemSeparator.availableMemoryMB
        var memoryMB: Double = StemSeparator.availableMemoryMB
    }

    /// Saved at every step of a preparation and removed when it ends. If the app is killed
    /// mid-way, the next launch finds it and can say where it stopped and how much memory was left.
    struct Breadcrumb: Codable {
        var songID: UUID
        var percent: Int
        var startMemoryMB: Int
        var memoryMB: Int
    }

    enum Status: Equatable {
        case none
        case queued
        case running(Job)
        case failed(String)
        case ready
    }

    private(set) var maps: [UUID: RiffMap] = [:]
    private(set) var current: Job?
    private(set) var queue: [UUID] = []
    private(set) var failures: [UUID: String] = [:]
    private var known: Set<UUID> = []

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let preparer = RiffPreparer()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let log = Logger(subsystem: RXLog.subsystem, category: "prep-center")

    nonisolated static let stemsDirectoryName = "Stems"

    static let breadcrumbKey = "rx.prep.breadcrumb"

    init(store: LibraryStore) {
        self.store = store
        if let data = UserDefaults.standard.data(forKey: Self.breadcrumbKey),
           let crumb = try? JSONDecoder().decode(Breadcrumb.self, from: data) {
            failures[crumb.songID] = "Na última tentativa o app fechou em \(crumb.percent)%. Memória livre para o app: \(crumb.startMemoryMB) MB no início, \(crumb.memoryMB) MB no fim. Me mande esses números. Toque em Tentar de novo para recomeçar."
            UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey)
        }
    }

    func status(for id: UUID) -> Status {
        if let current, current.songID == id { return .running(current) }
        if queue.contains(id) { return .queued }
        if let failure = failures[id] { return .failed(failure) }
        return maps[id] != nil ? .ready : .none
    }

    /// Loads the stored map once per song (only if its separated instruments are still on disk).
    func load(_ id: UUID) async {
        guard !known.contains(id) else { return }
        known.insert(id)
        guard let map = await store.riffMap(for: id) else { return }
        let folder = store.folder(for: id).appendingPathComponent(map.stemsDirectory, isDirectory: true)
        let complete = map.stemNames.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0).m4a").path)
        }
        if complete { maps[id] = map }
    }

    func prepare(_ song: SongRecord) {
        failures[song.id] = nil
        guard current?.songID != song.id, !queue.contains(song.id), maps[song.id] == nil else { return }
        queue.append(song.id)
        runNextIfIdle()
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        if current?.songID == id { task?.cancel() }
    }

    func forget(_ id: UUID) {
        cancel(id)
        maps[id] = nil
        failures[id] = nil
        known.remove(id)
    }

    // MARK: Running

    private func runNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        current = Job(songID: id, stage: .separating, fraction: 0, startedAt: Date())
        beginBackgroundTime()
        task = Task { [weak self, preparer, store] in
            guard let song = await store.song(id) else {
                await MainActor.run { self?.finish(id, result: .failure(LibraryError.unknownSong(id))) }
                return
            }
            // Stems go to a fresh folder and replace the old ones only on success,
            // so a cancelled run never leaves half-written instruments behind.
            let folder = store.folder(for: id)
            let pending = folder.appendingPathComponent("Stems-\(UUID().uuidString)", isDirectory: true)
            do {
                let map = try await preparer.prepare(fileURL: store.audioURL(for: song), stemsDirectory: pending,
                                                     directoryName: PrepCenter.stemsDirectoryName) { update in
                    Task { @MainActor in self?.apply(update, for: id) }
                }
                try Task.checkCancellation()
                let final = folder.appendingPathComponent(PrepCenter.stemsDirectoryName, isDirectory: true)
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: pending, to: final)
                try await store.save(map, for: id)
                // Files from the previous version of the app (note analysis) are no longer used.
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("analysis.json"))
                await MainActor.run { self?.finish(id, result: .success(map)) }
            } catch {
                try? FileManager.default.removeItem(at: pending)
                await MainActor.run { self?.finish(id, result: .failure(error)) }
            }
        }
    }

    private func apply(_ update: RiffPreparer.Update, for id: UUID) {
        guard var job = current, job.songID == id else { return }
        job.stage = update.stage
        let part = update.fraction ?? 0
        job.fraction = update.stage == .separating ? 0.95 * part : 0.95 + 0.05 * part
        job.memoryMB = update.availableMemoryMB
        let percentChanged = Int(job.fraction * 100) != Int((current?.fraction ?? -1) * 100)
        current = job
        if percentChanged {
            let crumb = Breadcrumb(songID: id, percent: Int(job.fraction * 100), startMemoryMB: Int(job.startMemoryMB),
                                   memoryMB: Int(job.memoryMB))
            if let data = try? JSONEncoder().encode(crumb) { UserDefaults.standard.set(data, forKey: Self.breadcrumbKey) }
        }
    }

    private func finish(_ id: UUID, result: Result<RiffMap, any Error>) {
        UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey)
        switch result {
        case .success(let map):
            maps[id] = map
            known.insert(id)
            log.info("Prepared \(id, privacy: .public) in \(map.separationSeconds, privacy: .public)s")
        case .failure(let error) where error is CancellationError:
            log.info("Preparation cancelled for \(id, privacy: .public)")
        case .failure(let error):
            if failures[id] == nil { failures[id] = error.localizedDescription }
            log.error("Preparation failed: \(error.localizedDescription, privacy: .public)")
        }
        current = nil
        task = nil
        endBackgroundTime()
        runNextIfIdle()
    }

    /// Asks iOS for extra time if the user leaves the app mid-preparation. If that time runs out,
    /// the preparation is cancelled cleanly (nothing partial is saved) and can be restarted.
    private func beginBackgroundTime() {
        // Keep the screen on: separation takes minutes and auto-lock would stop it.
        UIApplication.shared.isIdleTimerDisabled = true
        guard backgroundTask == .invalid else { return }
        // iOS calls the expiration handler on the main thread and terminates the app unless the task is
        // ended before the handler returns, so everything here runs synchronously.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RIFFNEX preparation") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let id = self.current?.songID {
                    self.failures[id] = "Parou porque o RIFFNEX saiu da tela. Deixe o app aberto e toque para recomeçar."
                }
                self.task?.cancel()
                self.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
