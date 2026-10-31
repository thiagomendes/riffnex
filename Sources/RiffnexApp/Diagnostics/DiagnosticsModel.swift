import AnalysisEngine
import AVFoundation
import Foundation
import Observation
import os

/// M0 toolchain spike. Each check exercises one capability RIFFNEX depends on, on the real
/// device, and reports what actually happened: measured values or the real error. Nothing here
/// is simulated; a check that cannot run says so.
@MainActor
@Observable
final class DiagnosticsModel {
    enum CheckID: String, CaseIterable, Identifiable {
        case observation, localization, demoResource, decode, coreML, musicUnderstanding, playback
        var id: String { rawValue }

        var title: String {
            switch self {
            case .observation: "SwiftUI + Observation"
            case .localization: "Textos em português (pt-BR)"
            case .demoResource: "Música de demonstração no pacote"
            case .decode: "Decodificação de áudio"
            case .coreML: "Modelo de notas (Basic Pitch / Core ML)"
            case .musicUnderstanding: "Ritmo e tonalidade (Music Understanding)"
            case .playback: "Reprodução (AVAudioEngine)"
            }
        }
    }

    enum Status: Equatable {
        case idle, running, passed, failed
    }

    struct CheckState {
        var status: Status = .idle
        var detail: String = "Ainda não executado."
    }

    private(set) var states: [CheckID: CheckState] = Dictionary(uniqueKeysWithValues: CheckID.allCases.map { ($0, CheckState()) })
    private(set) var isRunningAll = false
    private(set) var musicUnderstandingJSON: String?
    private(set) var importReport: String?
    private(set) var isPlaying = false

    private let model = BasicPitchModel()
    private let player = DemoPlayer()
    private let log = Logger(subsystem: RXLog.subsystem, category: "diagnostics")

    func state(_ id: CheckID) -> CheckState { states[id] ?? CheckState() }

    private func set(_ id: CheckID, _ status: Status, _ detail: String) {
        states[id] = CheckState(status: status, detail: detail)
        switch status {
        case .failed: log.error("\(id.rawValue, privacy: .public) failed: \(detail, privacy: .public)")
        case .passed: log.info("\(id.rawValue, privacy: .public) passed: \(detail, privacy: .public)")
        default: break
        }
    }

    func runAll() async {
        isRunningAll = true
        defer { isRunningAll = false }
        for id in CheckID.allCases where id != .playback {
            await run(id)
        }
    }

    func run(_ id: CheckID) async {
        set(id, .running, "Executando…")
        switch id {
        case .observation:
            // If this text updates on screen, the @Observable macro expanded and SwiftUI observed it.
            set(id, .passed, "Macro @Observable compilou e a interface reagiu à mudança de estado.")
        case .localization:
            checkLocalization()
        case .demoResource:
            checkDemoResource()
        case .decode:
            await checkDecode()
        case .coreML:
            await checkCoreML()
        case .musicUnderstanding:
            await checkMusicUnderstanding(url: AppResources.demoSongURL, label: "música de demonstração")
        case .playback:
            togglePlayback()
        }
    }

    // MARK: Checks

    private func checkLocalization() {
        let value = tr("diagnostics.localization.probe")
        let localizations = Bundle.module.localizations.joined(separator: ", ")
        if value == "Localização OK" {
            set(.localization, .passed, "Tabela pt-BR carregada do pacote do módulo (localizações: \(localizations)).")
        } else {
            set(.localization, .failed, "A chave não foi traduzida (retornou “\(value)”). Localizações no pacote: \(localizations.isEmpty ? "nenhuma" : localizations).")
        }
    }

    private func checkDemoResource() {
        guard let url = AppResources.demoSongURL else {
            set(.demoResource, .failed, "riffnex-demo.m4a não está no pacote de recursos.")
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        set(.demoResource, .passed, "Encontrada (\(size / 1024) KB) em \(url.deletingLastPathComponent().lastPathComponent)/.")
    }

    private func checkDecode() async {
        guard let url = AppResources.demoSongURL else {
            set(.decode, .failed, "Sem música de demonstração para decodificar.")
            return
        }
        do {
            let clock = ContinuousClock()
            let start = clock.now
            let result = try await Task.detached(priority: .userInitiated) {
                try AudioDecoder.decodeMono(url: url, sampleRate: BasicPitchModel.Constants.sampleRate)
            }.value
            let elapsed = clock.now - start
            set(.decode, .passed, String(format: "%.2f s de áudio (%.0f Hz, %d canal(is)) → mono 22 050 Hz em %@.",
                                         result.duration, result.sourceSampleRate, result.sourceChannels,
                                         elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))))
        } catch {
            set(.decode, .failed, error.localizedDescription)
        }
    }

    private func checkCoreML() async {
        do {
            let report = try await model.load()
            var detail = report.compiledThisLaunch
                ? String(format: "Compilado no aparelho em %.2f s. ", report.compileSeconds ?? 0)
                : "Usando modelo já compilado (cache). "
            detail += "Entrada \(report.inputShape)."

            // Run one real window: the first ~2 s of the demo song.
            if let url = AppResources.demoSongURL {
                let decoded = try await Task.detached(priority: .userInitiated) {
                    try AudioDecoder.decodeMono(url: url, sampleRate: BasicPitchModel.Constants.sampleRate)
                }.value
                var window = Array(decoded.samples.prefix(BasicPitchModel.Constants.windowSamples))
                window += [Float](repeating: 0, count: BasicPitchModel.Constants.windowSamples - window.count)
                let output = try await model.predictWindow(window)
                detail += String(format: " Inferência de 1 janela: %.0f ms. Notas %@, onsets %@, contorno %@. Ativação máx. de nota: %.2f (MIDI %d). A demo começa em E2 = MIDI 40.",
                                 output.seconds * 1000, "\(output.noteShape)", "\(output.onsetShape)",
                                 "\(output.contourShape)", output.maxNoteActivation, output.strongestMIDI)
            }
            set(.coreML, .passed, detail)
        } catch {
            set(.coreML, .failed, String(describing: error))
        }
    }

    private func checkMusicUnderstanding(url: URL?, label: String) async {
        guard let url else {
            set(.musicUnderstanding, .failed, "Arquivo indisponível.")
            return
        }
        do {
            let report = try await MusicUnderstandingProbe.analyze(fileURL: url)
            musicUnderstandingJSON = report.json
            set(.musicUnderstanding, .passed,
                String(format: "Analisou a %@ em %.2f s. Resultado bruto (JSON, %d caracteres) disponível abaixo.",
                       label, report.seconds, report.json.count))
        } catch {
            set(.musicUnderstanding, .failed, String(describing: error))
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.stop()
            isPlaying = false
            set(.playback, .passed, "Reprodução interrompida.")
            return
        }
        guard let url = AppResources.demoSongURL else {
            set(.playback, .failed, "Sem música de demonstração.")
            return
        }
        do {
            let route = try player.play(url: url)
            isPlaying = true
            set(.playback, .passed, String(format: "Tocando em %@ · %.0f Hz · buffer %.1f ms · latência de saída %.1f ms.",
                                           route.outputPort, route.sampleRate, route.ioBufferMs, route.outputLatencyMs))
        } catch {
            set(.playback, .failed, error.localizedDescription)
        }
    }

    // MARK: Import probe (a user-chosen file)

    /// Inspects a user-picked file and runs Music Understanding on a private copy of it.
    /// Copying first means analysis never depends on the security-scoped URL staying open.
    func inspectImported(_ pickedURL: URL) async {
        importReport = "Lendo arquivo…"
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }
        do {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pickedURL.pathExtension)
            try FileManager.default.copyItem(at: pickedURL, to: copy)
            let asset = AVURLAsset(url: copy)
            let (duration, playable, protected) = try await asset.load(.duration, .isPlayable, .hasProtectedContent)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio).count
            importReport = String(format: "%@ · %.1f s · faixas de áudio: %d · reproduzível: %@ · protegido (DRM): %@",
                                  pickedURL.lastPathComponent, duration.seconds, audioTracks,
                                  playable ? "sim" : "não", protected ? "sim" : "não")
            guard playable, !protected, audioTracks > 0 else { return }
            await checkMusicUnderstanding(url: copy, label: "música importada")
            try? FileManager.default.removeItem(at: copy)
        } catch {
            importReport = "Falha: \(error.localizedDescription)"
        }
    }
}
