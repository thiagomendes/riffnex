import AnalysisEngine
import CoreML
import DesignSystem
import SwiftUI

/// Measures Basic Pitch on this iPhone for every compute-unit option and lets the fastest one be
/// used for analysis. Numbers shown are measured here, not estimated.
struct BenchmarkSection: View {
    @State private var results: [BasicPitchBenchmark.Result] = []
    @State private var progress = BenchmarkProgress()
    @State private var running = false
    @State private var error: String?
    @AppStorage(AnalysisCenter.computeUnitsKey) private var chosen = MLComputeUnits.all.identifier
    @State private var separationReport: String?
    @State private var separating = false

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            Text("Velocidade da detecção de notas")
                .font(.headline).foregroundStyle(RX.Palette.textPrimary)
            Text("Roda 8 janelas de 2 s da música demo em cada combinação de processadores. A primeira janela inclui a preparação única do Core ML e aparece separada.")
                .font(.footnote).foregroundStyle(RX.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await run() }
            } label: {
                Label(running ? (progress.message ?? "Medindo…") : "Medir agora", systemImage: "speedometer")
            }
            .buttonStyle(RXSecondaryButtonStyle())
            .disabled(running)

            if let error {
                Text(error).font(.footnote).foregroundStyle(RX.Palette.error)
            }
            ForEach(results) { result in
                let isChosen = result.units.identifier == chosen
                Button {
                    chosen = result.units.identifier
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isChosen ? RX.Palette.success : RX.Palette.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.units.displayName).font(.subheadline.weight(.semibold))
                                .foregroundStyle(RX.Palette.textPrimary)
                            Text(String(format: "1ª janela %.0f ms · depois %.0f ms/janela · carga %.1f s",
                                        result.firstWindowSeconds * 1000, result.steadyWindowSeconds * 1000, result.loadSeconds))
                                .font(.caption.monospacedDigit()).foregroundStyle(RX.Palette.textSecondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f×", result.realTimeFactor))
                            .font(.rxChord(.headline)).foregroundStyle(RX.Palette.cyan)
                            .accessibilityLabel(String(format: "%.1f vezes o tempo real", result.realTimeFactor))
                    }
                }
                .buttonStyle(.plain)
            }
            separationBlock
            if !results.isEmpty {
                Text("“×” = segundos de música processados por segundo. Toque numa linha para usá-la nas análises. Atual: \(MLComputeUnits(identifier: chosen)?.displayName ?? chosen).")
                    .font(.caption).foregroundStyle(RX.Palette.textTertiary)
            }
        }
        .padding(RX.Space.m)
        .background(RoundedRectangle(cornerRadius: RX.Radius.panel, style: .continuous).fill(RX.Palette.surface))
    }

    private var separationBlock: some View {
        VStack(alignment: .leading, spacing: RX.Space.xs) {
            Text("Separação de instrumentos").font(.subheadline.weight(.semibold)).foregroundStyle(RX.Palette.textPrimary)
            Button {
                Task { await runSeparation() }
            } label: {
                Label(separating ? (progress.message ?? "Separando…") : "Medir separação (demo)", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(RXSecondaryButtonStyle())
            .disabled(separating || running)
            if let separationReport {
                Text(separationReport).font(.caption.monospacedDigit()).foregroundStyle(RX.Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, RX.Space.s)
    }

    private func runSeparation() async {
        guard let url = AppResources.demoSongURL else { return }
        separating = true
        defer { separating = false; progress.message = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let units = MLComputeUnits(identifier: chosen) ?? .all
        let progress = self.progress
        do {
            let separator = StemSeparator()
            let load = try await separator.load(computeUnits: units)
            let result = try await separator.separate(fileURL: url, into: directory, computeUnits: units) { p in
                Task { @MainActor in progress.message = "Separando… \(p.segment)/\(p.segments)" }
            }
            let perSegment = result.segmentSeconds.reduce(0, +) / Double(max(result.segmentSeconds.count, 1))
            let factor = result.duration / max(result.seconds, 0.001)
            separationReport = String(format: "Preparo do modelo %.1f s · %.1f s de música em %.1f s (%.2f× o tempo real) · %.2f s por trecho de 7,8 s · %@",
                                      load, result.duration, result.seconds, factor, perSegment, units.displayName)
                + "\nUma música de 4 min levaria cerca de \(Int((240 / factor).rounded())) s."
        } catch {
            separationReport = "Falhou: \(error.localizedDescription)"
        }
    }

    private func run() async {
        guard let url = AppResources.demoSongURL else {
            error = "Música demo não encontrada no pacote."
            return
        }
        running = true
        error = nil
        results = []
        defer { running = false; progress.message = nil }
        let progress = self.progress
        do {
            let measured = try await BasicPitchBenchmark.run(fileURL: url) { message in
                Task { @MainActor in progress.message = message }
            }
            results = measured
            if let fastest = measured.min(by: { $0.steadyWindowSeconds < $1.steadyWindowSeconds }) {
                chosen = fastest.units.identifier
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class BenchmarkProgress {
    var message: String?
}
