import AnalysisEngine
import DesignSystem
import MusicCore
import Persistence
import SwiftUI

/// The analysis entry point inside the player: a call to action, live progress, a failure, or a
/// compact summary that opens the Song Overview.
struct AnalysisCard: View {
    let song: SongRecord
    @Environment(AppModel.self) private var app
    @State private var showingProgress = false
    @State private var showingOverview = false

    var body: some View {
        let center = app.analysis
        Group {
            switch center.status(for: song.id) {
            case .none:
                callToAction
            case .queued:
                row(icon: "hourglass", title: "Na fila para análise", subtitle: "Começa assim que a anterior terminar.") {
                    Button("Cancelar") { center.cancel(song.id) }.font(.footnote.weight(.semibold))
                }
            case .running(let job):
                Button { showingProgress = true } label: { RunningRow(job: job) }
                    .buttonStyle(.plain)
            case .failed(let message):
                row(icon: "exclamationmark.triangle.fill", title: "A análise não terminou", subtitle: message) {
                    Button("Tentar de novo") { center.analyze(song) }.font(.footnote.weight(.semibold))
                }
            case .done:
                if let analysis = center.analyses[song.id] {
                    Button { showingOverview = true } label: { SummaryRow(analysis: analysis) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(RX.Space.m)
        .background(RoundedRectangle(cornerRadius: RX.Radius.control).fill(RX.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: RX.Radius.control).stroke(RX.Palette.hairline))
        .task { await center.load(song.id) }
        .sheet(isPresented: $showingProgress) {
            AnalysisProgressView(song: song)
                .presentationDetents([.medium, .large])
                .presentationBackground(RX.Palette.surface)
        }
        .sheet(isPresented: $showingOverview) {
            if let analysis = center.analyses[song.id] {
                SongOverviewView(song: song, analysis: analysis)
                    .presentationBackground(RX.Palette.base)
            }
        }
        .sensoryFeedback(.success, trigger: center.analyses[song.id] != nil)
    }

    private var callToAction: some View {
        HStack(spacing: RX.Space.m) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.title2)
                .foregroundStyle(RX.brandGradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("Descubra notas e acordes").font(.subheadline.weight(.semibold))
                    .foregroundStyle(RX.Palette.textPrimary)
                Text("Análise no próprio iPhone. Nada sai do aparelho.")
                    .font(.caption).foregroundStyle(RX.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Analisar") {
                app.analysis.analyze(song)
                showingProgress = true
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(RX.Palette.violet)
        }
    }

    private func row(icon: String, title: String, subtitle: String,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: RX.Space.m) {
            Image(systemName: icon).font(.title3).foregroundStyle(RX.Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(RX.Palette.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(RX.Palette.textSecondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

private struct RunningRow: View {
    let job: AnalysisCenter.Job

    var body: some View {
        HStack(spacing: RX.Space.m) {
            ProgressView().tint(RX.Palette.cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text(AnalysisText.title(job.stage)).font(.subheadline.weight(.semibold))
                    .foregroundStyle(RX.Palette.textPrimary)
                if let fraction = job.fraction {
                    ProgressView(value: fraction).tint(RX.Palette.cyan)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Analisando… \(TimeFormatting.clock(context.date.timeIntervalSince(job.startedAt)))")
                            .font(.caption.monospacedDigit()).foregroundStyle(RX.Palette.textSecondary)
                    }
                }
            }
            Image(systemName: "chevron.up").font(.caption).foregroundStyle(RX.Palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Mostra o progresso detalhado")
    }
}

private struct SummaryRow: View {
    let analysis: SongAnalysis

    var body: some View {
        HStack(spacing: RX.Space.s) {
            VStack(alignment: .leading, spacing: RX.Space.xxs) {
                HStack(spacing: RX.Space.s) {
                    if let bpm = analysis.rhythm?.beatsPerMinute {
                        Fact(value: "\(Int(bpm.rounded()))", label: "BPM est.")
                    }
                    if let key = analysis.mainKey {
                        Fact(value: key.name(), label: "tom est.")
                    }
                    Fact(value: "\(Set(analysis.chords.compactMap(\.chord)).count)", label: "acordes")
                    Fact(value: "\(analysis.notes.count)", label: "notas")
                }
                RXStatusPill(AnalysisText.qualityTitle(analysis.quality.level),
                             kind: AnalysisText.qualityPill(analysis.quality.level))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(RX.Palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Abre a visão geral da música")
    }
}

private struct Fact: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.rxChord(.headline)).foregroundStyle(RX.Palette.textPrimary)
            Text(label).font(.caption2).foregroundStyle(RX.Palette.textTertiary)
        }
    }
}

/// Stage-by-stage progress. Determinate bars only where the stage reports real progress.
struct AnalysisProgressView: View {
    let song: SongRecord
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let status = app.analysis.status(for: song.id)
        VStack(alignment: .leading, spacing: RX.Space.l) {
            HStack {
                Text("Análise").font(.rxDisplay(.title2)).foregroundStyle(RX.Palette.textPrimary)
                Spacer()
                Button("Fechar") { dismiss() }.font(.subheadline.weight(.semibold))
            }
            switch status {
            case .running(let job):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Tempo decorrido \(TimeFormatting.clock(context.date.timeIntervalSince(job.startedAt)))")
                        .font(.footnote.monospacedDigit()).foregroundStyle(RX.Palette.textSecondary)
                }
                VStack(alignment: .leading, spacing: RX.Space.m) {
                    ForEach(AnalysisCoordinator.Stage.allCases, id: \.self) { stage in
                        StageRow(stage: stage, job: job)
                    }
                }
                Text("Pode continuar usando o app. Se você sair dele por muito tempo, o iOS pode interromper a análise; nada incompleto é salvo e você pode recomeçar.")
                    .font(.caption).foregroundStyle(RX.Palette.textTertiary)
                Button("Cancelar análise", role: .destructive) {
                    app.analysis.cancel(song.id)
                    dismiss()
                }
                .buttonStyle(RXSecondaryButtonStyle())
            case .done:
                Label("Análise concluída", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(RX.Palette.success)
                    .font(.headline)
            case .failed(let message):
                Text(message).foregroundStyle(RX.Palette.error)
            case .queued:
                Text("Na fila.").foregroundStyle(RX.Palette.textSecondary)
            case .none:
                Text("Nenhuma análise em andamento.").foregroundStyle(RX.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(RX.Space.screenMargin)
    }
}

private struct StageRow: View {
    let stage: AnalysisCoordinator.Stage
    let job: AnalysisCenter.Job

    var body: some View {
        let reached = job.stages.keys.contains(stage)
        let value = job.stages[stage] ?? nil
        let finished = isFinished(reached: reached, value: value)
        HStack(alignment: .top, spacing: RX.Space.s) {
            Image(systemName: finished ? "checkmark.circle.fill" : (reached ? "circle.dotted" : "circle"))
                .foregroundStyle(finished ? RX.Palette.success : (reached ? RX.Palette.cyan : RX.Palette.textTertiary))
                .symbolEffect(.pulse, isActive: reached && !finished)
            VStack(alignment: .leading, spacing: 4) {
                Text(AnalysisText.title(stage)).font(.subheadline.weight(.semibold))
                    .foregroundStyle(reached ? RX.Palette.textPrimary : RX.Palette.textTertiary)
                Text(AnalysisText.detail(stage)).font(.caption).foregroundStyle(RX.Palette.textSecondary)
                if reached && !finished {
                    if let value {
                        ProgressView(value: value).tint(RX.Palette.cyan)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(RX.Palette.cyan)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(finished ? "concluída" : (reached ? (value.map { "\(Int($0 * 100)) por cento" } ?? "em andamento") : "aguardando"))
    }

    private func isFinished(reached: Bool, value: Double?) -> Bool {
        guard reached else { return false }
        let order = AnalysisCoordinator.Stage.allCases
        let mine = order.firstIndex(of: stage) ?? 0
        if stage == .musicUnderstanding {
            // Runs alongside note detection; done once assembling starts.
            return job.stages.keys.contains(.assembling)
        }
        if let value, value >= 1 { return true }
        let later = order.dropFirst(mine + 1).filter { $0 != .musicUnderstanding }
        return later.contains { job.stages.keys.contains($0) }
    }
}

// MARK: Song Overview

struct SongOverviewView: View {
    let song: SongRecord
    let analysis: SongAnalysis
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReanalysis = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.l) {
                    facts
                    sectionsBlock
                    chordsBlock
                    qualityBlock
                    provenanceBlock
                }
                .padding(RX.Space.screenMargin)
            }
            .background(RXBackground())
            .navigationTitle("Visão geral")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Analisar de novo") { confirmingReanalysis = true }
                }
            }
            .confirmationDialog("Analisar de novo?", isPresented: $confirmingReanalysis, titleVisibility: .visible) {
                Button("Analisar de novo") {
                    app.analysis.analyze(song)
                    dismiss()
                }
            } message: {
                Text("O resultado atual continua salvo até a nova análise terminar.")
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            Text(song.title).font(.rxDisplay(.title2)).foregroundStyle(RX.Palette.textPrimary)
            HStack(spacing: RX.Space.l) {
                BigFact(value: analysis.rhythm?.beatsPerMinute.map { "\(Int($0.rounded()))" } ?? "—",
                        label: "BPM estimado")
                BigFact(value: analysis.mainKey?.name() ?? "—", label: "Tom estimado")
                BigFact(value: "\(analysis.notes.count)", label: "Notas")
            }
            Text("Tempo e tom vêm do Music Understanding da Apple, que não informa o quanto tem certeza; por isso dizemos “estimado”.")
                .font(.caption).foregroundStyle(RX.Palette.textTertiary)
        }
    }

    private var sectionsBlock: some View {
        Block(title: "Seções") {
            SectionStrip(sections: analysis.sections, duration: analysis.duration)
                .frame(height: 44)
            ForEach(analysis.sections) { section in
                HStack {
                    Text(AnalysisText.sectionName(section)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(RX.Palette.textPrimary)
                    Text(section.isChordal ? "acordes" : "linha / riff").font(.caption)
                        .foregroundStyle(RX.Palette.textSecondary)
                    Spacer()
                    Text("\(TimeFormatting.clock(section.start)) – \(TimeFormatting.clock(section.end))")
                        .font(.caption.monospacedDigit()).foregroundStyle(RX.Palette.textSecondary)
                }
            }
            if analysis.sections.count <= 1 {
                Text("Não identificamos seções distintas.").font(.caption).foregroundStyle(RX.Palette.textTertiary)
            } else {
                Text("Os limites das seções vêm do Music Understanding; as letras (A, B, A′) comparam o que é tocado em cada uma.")
                    .font(.caption).foregroundStyle(RX.Palette.textTertiary)
            }
        }
    }

    private var chordsBlock: some View {
        let sequence = Self.compactSequence(analysis.chords)
        return Block(title: "Acordes") {
            if sequence.isEmpty {
                Text("Nenhum acorde claro: a guitarra parece tocar linhas de uma nota (riffs ou melodia).")
                    .font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RX.Space.xs) {
                        ForEach(Array(sequence.enumerated()), id: \.offset) { _, event in
                            Text(event.chord?.symbol() ?? "")
                                .font(.rxChord(.headline))
                                .foregroundStyle(event.confidence.level == .low ? RX.Palette.textTertiary : RX.Palette.textPrimary)
                                .padding(.horizontal, RX.Space.s)
                                .padding(.vertical, RX.Space.xs)
                                .background(Capsule().fill(RX.Palette.raised))
                                .overlay(Capsule().stroke(event.confidence.level == .low ? RX.Palette.hairline : RX.Palette.violet.opacity(0.5),
                                                          style: StrokeStyle(lineWidth: 1, dash: event.confidence.level == .low ? [3, 3] : [])))
                                .accessibilityLabel("\(event.chord?.symbol() ?? ""), confiança \(AnalysisText.confidence(event.confidence.level))")
                        }
                    }
                }
                Text("Acordes inferidos a partir das notas detectadas, batida a batida. Contorno tracejado = confiança baixa.")
                    .font(.caption).foregroundStyle(RX.Palette.textTertiary)
            }
        }
    }

    private var qualityBlock: some View {
        Block(title: "Qualidade da análise") {
            RXStatusPill(AnalysisText.qualityTitle(analysis.quality.level), kind: AnalysisText.qualityPill(analysis.quality.level))
            if analysis.quality.reasons.isEmpty {
                Text("Sinais consistentes: grade de tempo estável, tom estimado e notas com boa confiança na maior parte.")
                    .font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
            }
            ForEach(analysis.quality.reasons, id: \.self) { reason in
                Label(AnalysisText.reason(reason), systemImage: "info.circle")
                    .font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
            }
            ForEach(analysis.stageErrors.sorted(by: { $0.key < $1.key }), id: \.key) { stage, message in
                Label("\(AnalysisText.stageError(stage)): \(message)", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(RX.Palette.warning)
            }
            let low = Int((analysis.quality.metrics.lowConfidenceFraction * 100).rounded())
            Text("\(low)% das notas com confiança baixa. Os níveis de confiança são heurísticos, não probabilidades calibradas.")
                .font(.caption).foregroundStyle(RX.Palette.textTertiary)
        }
    }

    private var provenanceBlock: some View {
        Block(title: "Como foi feito") {
            ForEach(analysis.components, id: \.self) { source in
                HStack {
                    Text(Self.componentName(source.component)).font(.footnote).foregroundStyle(RX.Palette.textSecondary)
                    Spacer()
                    Text(source.version).font(.caption2.monospaced()).foregroundStyle(RX.Palette.textTertiary)
                }
            }
            ForEach(analysis.timings, id: \.stage) { timing in
                HStack {
                    Text(Self.timingName(timing.stage)).font(.footnote).foregroundStyle(RX.Palette.textSecondary)
                    Spacer()
                    Text(String(format: "%.1f s", timing.seconds)).font(.caption.monospacedDigit())
                        .foregroundStyle(RX.Palette.textTertiary)
                }
            }
            Text("Analisado em \(analysis.createdAt.formatted(date: .abbreviated, time: .shortened)), inteiramente no iPhone.")
                .font(.caption).foregroundStyle(RX.Palette.textTertiary)
        }
    }

    static func compactSequence(_ chords: [ChordEvent]) -> [ChordEvent] {
        var result: [ChordEvent] = []
        for event in chords where event.chord != nil {
            if result.last?.chord != event.chord { result.append(event) }
        }
        return result
    }

    static func componentName(_ component: AnalysisSource.Component) -> String {
        switch component {
        case .basicPitch: "Notas: Basic Pitch (Spotify) + limpeza RIFFNEX"
        case .musicUnderstanding: "Tempo, tom e seções: Music Understanding"
        case .chordEstimator: "Acordes: estimador RIFFNEX"
        case .fingeringOptimizer: "Digitação"
        case .user: "Edição do usuário"
        }
    }

    static func timingName(_ stage: String) -> String {
        switch stage {
        case "decoding": "Leitura do áudio"
        case "modelLoad": "Preparo do modelo"
        case "notes": "Detecção de notas"
        case "musicUnderstanding": "Music Understanding"
        case "postprocess": "Acordes e seções"
        default: stage
        }
    }
}

private struct BigFact: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.rxChord(.title)).foregroundStyle(RX.brandGradient)
            Text(label).font(.caption).foregroundStyle(RX.Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Block<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(RX.Palette.textTertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RX.Space.m)
        .background(RoundedRectangle(cornerRadius: RX.Radius.control).fill(RX.Palette.surface))
    }
}

/// Proportional strip of the song's sections, labeled with their letters.
struct SectionStrip: View {
    let sections: [SongSection]
    let duration: Seconds
    var highlightTime: Seconds?

    private static let colors: [Color] = [RX.Palette.violet, RX.Palette.blue, RX.Palette.cyan, RX.Palette.success, RX.Palette.warning]

    var body: some View {
        GeometryReader { geometry in
            let total = max(duration, 0.001)
            ZStack(alignment: .leading) {
                ForEach(sections) { section in
                    let x = geometry.size.width * section.start / total
                    let width = max(2, geometry.size.width * (section.end - section.start) / total - 2)
                    let active = highlightTime.map { section.start <= $0 && $0 < section.end } ?? true
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color(for: section).opacity(active ? 0.85 : 0.3))
                        .overlay(
                            Text(section.kind == .lettered ? section.letter : "")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(RX.Palette.base)
                        )
                        .frame(width: width)
                        .offset(x: x)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Seções: " + sections.map(AnalysisText.sectionName).joined(separator: ", "))
    }

    private func color(for section: SongSection) -> Color {
        guard section.kind == .lettered, let first = section.letter.unicodeScalars.first else { return RX.Palette.textTertiary }
        let index = Int(first.value) - 65
        return Self.colors[((index % Self.colors.count) + Self.colors.count) % Self.colors.count]
    }
}

/// The chord sounding now (and the next one), for the player.
struct CurrentChordView: View {
    let analysis: SongAnalysis
    let time: Seconds

    var body: some View {
        let current = analysis.chords.first { $0.start <= time && time < $0.end }
        let next = analysis.chords.first { $0.start > time && $0.chord != nil }
        HStack(alignment: .firstTextBaseline, spacing: RX.Space.m) {
            Text(current?.chord?.symbol() ?? "—")
                .font(.rxChord(.largeTitle))
                .foregroundStyle(current == nil ? RX.Palette.textTertiary : RX.Palette.textPrimary)
                .opacity(current?.confidence.level == .low ? 0.6 : 1)
                .contentTransition(.numericText())
                .animation(RX.Motion.touch, value: current?.id)
            if let nextChord = next?.chord, let start = next?.start, start - time < 4 {
                Text("depois \(nextChord.symbol())").font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
            }
            Spacer()
            if let section = analysis.sections.first(where: { $0.start <= time && time < $0.end }), section.kind == .lettered {
                Text(AnalysisText.sectionName(section)).font(.caption.weight(.semibold))
                    .foregroundStyle(RX.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(current?.chord.map { "Acorde atual \($0.symbol())" } ?? "Sem acorde agora")
    }
}
