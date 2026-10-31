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
    private var known: Set<UUID> = []

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let coordinator = AnalysisCoordinator()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let log = Logger(subsystem: RXLog.subsystem, category: "analysis-center")

    static let computeUnitsKey = "rx.computeUnits"

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

    func forget(_ id: UUID) {
        cancel(id)
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
            do {
                let analysis = try await coordinator.analyze(fileURL: store.audioURL(for: song),
                                                             options: .init(computeUnits: units)) { update in
                    Task { @MainActor in self?.apply(update, for: id) }
                }
                try Task.checkCancellation()
                try await store.save(analysis, for: id)
                await MainActor.run { self?.finish(id, result: .success(analysis)) }
            } catch {
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
