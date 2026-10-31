import AnalysisEngine
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @State private var model = DiagnosticsModel()
    @State private var showingImporter = false
    @State private var logEntries: [RXLog.Entry] = []
    @State private var logError: String?

    var body: some View {
        ZStack {
            RXBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.l) {
                    header

                    Button {
                        Task { await model.runAll() }
                    } label: {
                        Label(model.isRunningAll ? "Verificando…" : "Executar todas as verificações",
                              systemImage: "play.circle.fill")
                    }
                    .buttonStyle(RXPrimaryButtonStyle())
                    .disabled(model.isRunningAll)

                    VStack(spacing: RX.Space.xs) {
                        ForEach(DiagnosticsModel.CheckID.allCases) { id in
                            CheckRow(id: id, state: model.state(id), isPlaying: model.isPlaying) {
                                Task { await model.run(id) }
                            }
                        }
                    }

                    BenchmarkSection()
                    importSection
                    if let json = model.musicUnderstandingJSON { jsonSection(json) }
                    logSection
                }
                .padding(.horizontal, RX.Space.screenMargin)
                .padding(.vertical, RX.Space.l)
            }
        }
        .navigationTitle("Diagnóstico")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                Task { await model.inspectImported(url) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RX.Space.xs) {
            Text("Este iPhone está pronto?")
                .font(.rxDisplay(.title2))
                .foregroundStyle(RX.Palette.textPrimary)
            Text("Cada verificação usa o recurso de verdade e mostra o que foi medido. Envie um print desta tela para continuar o desenvolvimento.")
                .font(.subheadline)
                .foregroundStyle(RX.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            Text("Arquivo seu (opcional)")
                .font(.headline)
                .foregroundStyle(RX.Palette.textPrimary)
            Text("Escolha uma música do app Arquivos para testar a leitura e a análise de ritmo e tonalidade. O arquivo é copiado temporariamente e apagado em seguida.")
                .font(.footnote)
                .foregroundStyle(RX.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showingImporter = true
            } label: {
                Label("Escolher arquivo de áudio", systemImage: "folder")
            }
            .buttonStyle(RXSecondaryButtonStyle())
            if let report = model.importReport {
                Text(report)
                    .font(.footnote.monospaced())
                    .foregroundStyle(RX.Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(RX.Space.m)
        .background(RoundedRectangle(cornerRadius: RX.Radius.panel, style: .continuous).fill(RX.Palette.surface))
    }

    private func jsonSection(_ json: String) -> some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            HStack {
                Text("Resultado bruto do Music Understanding")
                    .font(.headline)
                    .foregroundStyle(RX.Palette.textPrimary)
                Spacer()
                ShareLink(item: json) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Compartilhar JSON")
            }
            ScrollView(.vertical) {
                Text(json)
                    .font(.caption2.monospaced())
                    .foregroundStyle(RX.Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
        .padding(RX.Space.m)
        .background(RoundedRectangle(cornerRadius: RX.Radius.panel, style: .continuous).fill(RX.Palette.surface))
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            HStack {
                Text("Registro (log)")
                    .font(.headline)
                    .foregroundStyle(RX.Palette.textPrimary)
                Spacer()
                Button("Atualizar") { refreshLog() }
                    .buttonStyle(RXSecondaryButtonStyle())
            }
            if let logError {
                Text(logError).font(.footnote).foregroundStyle(RX.Palette.error)
            } else if logEntries.isEmpty {
                Text("Nenhuma entrada ainda.").font(.footnote).foregroundStyle(RX.Palette.textTertiary)
            } else {
                ForEach(logEntries.suffix(40)) { entry in
                    Text("\(entry.date.formatted(date: .omitted, time: .standard)) [\(entry.category)] \(entry.level): \(entry.message)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(entry.level == "error" || entry.level == "fault" ? RX.Palette.error : RX.Palette.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(RX.Space.m)
        .background(RoundedRectangle(cornerRadius: RX.Radius.panel, style: .continuous).fill(RX.Palette.surface))
    }

    private func refreshLog() {
        do {
            logEntries = try RXLog.recentEntries()
            logError = nil
        } catch {
            logError = "Não foi possível ler o log: \(error.localizedDescription)"
        }
    }
}

private struct CheckRow: View {
    let id: DiagnosticsModel.CheckID
    let state: DiagnosticsModel.CheckState
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: RX.Space.s) {
            statusIcon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: RX.Space.xxs) {
                Text(id.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RX.Palette.textPrimary)
                Text(state.detail)
                    .font(.footnote)
                    .foregroundStyle(RX.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: RX.Space.xs)
            Button(action: action) {
                Image(systemName: buttonSymbol)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(id == .playback ? (isPlaying ? "Parar" : "Tocar") : "Executar")
            .disabled(state.status == .running)
        }
        .padding(RX.Space.m)
        .background(RoundedRectangle(cornerRadius: RX.Radius.control, style: .continuous).fill(RX.Palette.surface))
        .accessibilityElement(children: .contain)
    }

    private var buttonSymbol: String {
        if id == .playback { return isPlaying ? "stop.fill" : "play.fill" }
        return "arrow.clockwise"
    }

    @ViewBuilder private var statusIcon: some View {
        switch state.status {
        case .idle:
            Image(systemName: "circle").foregroundStyle(RX.Palette.textTertiary)
                .accessibilityLabel("Não executado")
        case .running:
            ProgressView().tint(RX.Palette.blue)
                .accessibilityLabel("Executando")
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(RX.Palette.success)
                .accessibilityLabel("Funcionou")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(RX.Palette.error)
                .accessibilityLabel("Falhou")
        }
    }
}
