import AnalysisEngine
import CoreML
import Foundation
import MusicCore
import Observation
import os
import Persistence
import UIKit

/// Owns song analyses: loads stored results, runs one analysis at a time, reports real progress,
/// and persists results atomically. A cancelled or interrupted analysis leaves nothing behind.
@MainActor
@Observable
final class AnalysisCenter {
    struct Job: Equatable {
        var songID: UUID
        var stage: AnalysisCoordinator.Stage
        var fraction: Double?
        var detail: String?
        var startedAt: Date
        /// Progress of each stage reached so far (nil = indeterminate).
        var stages: [AnalysisCoordinator.Stage: Double?]
    }

    enum Status: Equatable {
        case none
        case queued
        case running(Job)
        case failed(String)
        case done
    }

    private(set) var analyses: [UUID: SongAnalysis] = [:]
    private(set) var current: Job?
    private(set) var queue: [UUID] = []
    private(set) var failures: [UUID: String] = [:]
    /// Fingering + tab layout per analyzed song, computed off the main actor on first use.
    private(set) var layouts: [UUID: TabLayout] = [:]
    private var known: Set<UUID> = []

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let coordinator = AnalysisCoordinator()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let log = Logger(subsystem: RXLog.subsystem, category: "analysis-center")

    static let computeUnitsKey = "rx.computeUnits"
    nonisolated static let stemsDirectoryName = "Stems"

    init(store: LibraryStore) {
        self.store = store
    }

    var computeUnits: MLComputeUnits {
        UserDefaults.standard.string(forKey: Self.computeUnitsKey).flatMap(MLComputeUnits.init(identifier:)) ?? .all
    }

    func status(for id: UUID) -> Status {
        if let current, current.songID == id { return .running(current) }
        if queue.contains(id) { return .queued }
        if let failure = failures[id] { return .failed(failure) }
        return analyses[id] != nil ? .done : .none
    }

    /// Loads the stored analysis once per song.
    func load(_ id: UUID) async {
        guard !known.contains(id) else { return }
        known.insert(id)
        if let analysis = await store.analysis(for: id) { analyses[id] = analysis }
    }

    func analyze(_ song: SongRecord) {
        failures[song.id] = nil
        guard current?.songID != song.id, !queue.contains(song.id) else { return }
        queue.append(song.id)
        runNextIfIdle()
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        if current?.songID == id { task?.cancel() }
    }

    func prepareLayout(for id: UUID) async {
        guard layouts[id] == nil, let analysis = analyses[id] else { return }
        let layout = await Task.detached(priority: .userInitiated) {
            let arrangement = FingeringOptimizer().arrange(notes: analysis.notes,
                                                           phraseBoundaries: analysis.sections.map(\.start))
            return TabLayout(arrangement: arrangement, rhythm: analysis.rhythm, duration: analysis.duration)
        }.value
        // The analysis may have been replaced meanwhile.
        if analyses[id] == analysis { layouts[id] = layout }
    }

    func forget(_ id: UUID) {
        cancel(id)
        layouts[id] = nil
        analyses[id] = nil
        failures[id] = nil
        known.remove(id)
    }

    // MARK: Running

    private func runNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        current = Job(songID: id, stage: .decoding, fraction: 0, detail: nil, startedAt: Date(), stages: [.decoding: 0])
        beginBackgroundTime()
        let units = computeUnits
        task = Task { [weak self, coordinator, store] in
            guard let song = await store.song(id) else {
                await MainActor.run { self?.finish(id, result: .failure(LibraryError.unknownSong(id))) }
                return
            }
            // Stems go to a fresh folder and replace the old ones only when the analysis succeeds,
            // so a cancelled run never leaves half-written instruments behind.
            let folder = store.folder(for: id)
            let pending = folder.appendingPathComponent("Stems-\(UUID().uuidString)", isDirectory: true)
            do {
                var analysis = try await coordinator.analyze(fileURL: store.audioURL(for: song),
                                                             options: .init(computeUnits: units, stemsDirectory: pending)) { update in
                    Task { @MainActor in self?.apply(update, for: id) }
                }
                try Task.checkCancellation()
                if analysis.stems != nil {
                    let final = folder.appendingPathComponent(AnalysisCenter.stemsDirectoryName, isDirectory: true)
                    try? FileManager.default.removeItem(at: final)
                    try FileManager.default.moveItem(at: pending, to: final)
                    analysis.stems?.directory = AnalysisCenter.stemsDirectoryName
                } else {
                    try? FileManager.default.removeItem(at: pending)
                }
                try await store.save(analysis, for: id)
                await MainActor.run { self?.finish(id, result: .success(analysis)) }
            } catch {
                try? FileManager.default.removeItem(at: pending)
                await MainActor.run { self?.finish(id, result: .failure(error)) }
            }
        }
    }

    private func apply(_ update: AnalysisCoordinator.Update, for id: UUID) {
        guard var job = current, job.songID == id else { return }
        job.stages[update.stage] = update.fraction
        // Music Understanding and notes run in parallel; the headline shows the furthest stage.
        let order = AnalysisCoordinator.Stage.allCases
        if (order.firstIndex(of: update.stage) ?? 0) >= (order.firstIndex(of: job.stage) ?? 0) {
            job.stage = update.stage
            job.fraction = update.fraction
            job.detail = update.detail
        }
        current = job
    }

    private func finish(_ id: UUID, result: Result<SongAnalysis, any Error>) {
        switch result {
        case .success(let analysis):
            analyses[id] = analysis
            layouts[id] = nil
            known.insert(id)
            log.info("Analysis saved for \(id, privacy: .public)")
        case .failure(let error) where error is CancellationError:
            log.info("Analysis cancelled for \(id, privacy: .public)")
        case .failure(let error):
            failures[id] = error.localizedDescription
            log.error("Analysis failed: \(error.localizedDescription, privacy: .public)")
        }
        current = nil
        task = nil
        endBackgroundTime()
        runNextIfIdle()
    }

    /// Asks iOS for extra time if the user leaves the app mid-analysis. If that time runs out,
    /// the analysis is cancelled cleanly (nothing partial is saved) and can be restarted.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RIFFNEX analysis") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let id = self.current?.songID {
                    self.failures[id] = "A análise foi interrompida porque o app ficou em segundo plano. Toque para recomeçar."
                }
                self.task?.cancel()
                self.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
