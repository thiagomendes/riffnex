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
            if !results.isEmpty {
                Text("“×” = segundos de música processados por segundo. Toque numa linha para usá-la nas análises. Atual: \(MLComputeUnits(identifier: chosen)?.displayName ?? chosen).")
                    .font(.caption).foregroundStyle(RX.Palette.textTertiary)
            }
        }
        .padding(RX.Space.m)
        .background(RoundedRectangle(cornerRadius: RX.Radius.panel, style: .continuous).fill(RX.Palette.surface))
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
