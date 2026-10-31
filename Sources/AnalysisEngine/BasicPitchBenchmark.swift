import CoreML
import Foundation
import MusicCore

/// Measures Basic Pitch inference speed on this device for each Core ML compute-unit option, using
/// consecutive windows of a real song. The first window of each option is reported separately
/// because it includes Core ML's one-time device specialization.
public enum BasicPitchBenchmark {
    public struct Result: Sendable, Identifiable {
        public var id: String { units.identifier }
        public let units: MLComputeUnits
        public let loadSeconds: Double
        public let firstWindowSeconds: Double
        /// Mean of the remaining windows.
        public let steadyWindowSeconds: Double
        public let windows: Int

        /// Seconds of audio processed per second of compute in steady state (> 1 = faster than real time).
        public var realTimeFactor: Double {
            let audioPerWindow = Double(BasicPitchTiming.windowHopSamples) / BasicPitchTiming.sampleRate
            return steadyWindowSeconds > 0 ? audioPerWindow / steadyWindowSeconds : 0
        }
    }

    public static let candidates: [MLComputeUnits] = [.all, .cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly]

    public static func run(fileURL: URL, windows: Int = 8, units: [MLComputeUnits] = candidates,
                           onProgress: @escaping @Sendable (String) -> Void) async throws -> [Result] {
        let decoded = try AudioDecoder.decodeMono(url: fileURL, sampleRate: BasicPitchModel.Constants.sampleRate)
        let available = BasicPitchTiming.windowCount(forSamples: decoded.samples.count)
        let count = max(2, min(windows, available))
        var window = [Float](repeating: 0, count: BasicPitchModel.Constants.windowSamples)
        var results: [Result] = []
        for option in units {
            try Task.checkCancellation()
            onProgress("Carregando com \(option.displayName)…")
            // A fresh model instance per option, so nothing is shared between configurations.
            let model = BasicPitchModel()
            let load = try await model.load(computeUnits: option)
            var times: [Double] = []
            for index in 0..<count {
                try Task.checkCancellation()
                AnalysisCoordinator.fillWindow(&window, from: decoded.samples,
                                               start: BasicPitchTiming.windowStartSample(index % available))
                let output = try await model.activations(for: window, computeUnits: option)
                times.append(output.seconds)
                onProgress("\(option.displayName): janela \(index + 1)/\(count)")
            }
            let steady = times.dropFirst()
            results.append(Result(units: option, loadSeconds: load.loadSeconds + (load.compileSeconds ?? 0),
                                  firstWindowSeconds: times.first ?? 0,
                                  steadyWindowSeconds: steady.reduce(0, +) / Double(max(steady.count, 1)),
                                  windows: count))
        }
        return results
    }
}

extension MLComputeUnits {
    public var displayName: String {
        switch self {
        case .all: "Todos (CPU+GPU+ANE)"
        case .cpuAndNeuralEngine: "CPU + Neural Engine"
        case .cpuAndGPU: "CPU + GPU"
        case .cpuOnly: "Só CPU"
        @unknown default: "Desconhecido"
        }
    }
}
