import DesignSystem
import MusicCore
import Persistence
import PlaybackEngine
import SwiftUI

/// The beginner flow once a song is analyzed: choose what to play, then one focused screen.
/// Everything that is not "the next thing to play" lives under "Mais".
struct PracticeRoot: View {
    enum Screen { case home, chords, riff }

    let song: SongRecord
    let analysis: SongAnalysis
    let onShowFullPlayer: () -> Void

    @Environment(AppModel.self) private var app
    @State private var screen: Screen = .home
    @AppStorage("rx.replaceGuitar") private var replaceGuitar = true
    @AppStorage("rx.countIn") private var countIn = true

    private var player: AudioPlayer { app.player }

    var body: some View {
        Group {
            switch screen {
            case .home:
                PracticeHome(song: song, analysis: analysis, replaceGuitar: $replaceGuitar,
                             onChoose: { screen = $0 }, onShowFullPlayer: onShowFullPlayer)
            case .chords:
                ChordsPractice(song: song, analysis: analysis, onBack: leave)
            case .riff:
                RiffPractice(song: song, analysis: analysis, replaceGuitar: replaceGuitar, onBack: leave)
            }
        }
        .task(id: analysis.createdAt) { await app.analysis.preparePractice(for: song.id) }
        .task(id: GridKey(analysis: analysis.createdAt, loaded: player.isLoaded, stems: player.stemNames)) {
            guard player.isLoaded else { return }
            player.setBeatGrid(beats: analysis.rhythm?.beats ?? [], bars: analysis.rhythm?.bars ?? [])
            player.setCountInEnabled(countIn)
            PracticeAudio.applyReplaceGuitar(replaceGuitar, player: player, analysis: analysis)
        }
        .onChange(of: replaceGuitar) { _, value in
            PracticeAudio.applyReplaceGuitar(value, player: player, analysis: analysis)
        }
    }

    private func leave() {
        player.pause()
        player.setLoopEnabled(false)
        PracticeAudio.applyReplaceGuitar(replaceGuitar, player: player, analysis: analysis)
        screen = .home
    }
}

private struct GridKey: Equatable {
    let analysis: Date
    let loaded: Bool
    let stems: [String]
}

/// Which separated tracks stand in for "the guitar": the ones the notes were detected on.
enum PracticeAudio {
    static func replacedStems(_ analysis: SongAnalysis, player: AudioPlayer) -> [String] {
        let sources = analysis.stems?.noteSources ?? ["guitar"]
        return sources.filter(player.stemNames.contains)
    }

    static func applyReplaceGuitar(_ replace: Bool, player: AudioPlayer, analysis: SongAnalysis) {
        for name in replacedStems(analysis, player: player) {
            player.setVolume(replace ? 0 : 1, forStem: name)
        }
    }

    static func stringName(_ string: Int) -> String {
        ["Mi grave", "Lá", "Ré", "Sol", "Si", "Mi agudo"][min(max(string, 0), 5)]
    }

    static func fingerName(_ finger: Finger) -> String {
        switch finger {
        case .open: "corda solta"
        case .index: "dedo 1 (indicador)"
        case .middle: "dedo 2 (médio)"
        case .ring: "dedo 3 (anelar)"
        case .pinky: "dedo 4 (mínimo)"
        }
    }
}

// MARK: Home

private struct PracticeHome: View {
    let song: SongRecord
    let analysis: SongAnalysis
    @Binding var replaceGuitar: Bool
    let onChoose: (PracticeRoot.Screen) -> Void
    let onShowFullPlayer: () -> Void

    @Environment(AppModel.self) private var app
    @State private var showingKey = false
    @State private var showingOverview = false
    @State private var showingMixer = false

    private var material: PracticeMaterial? { app.analysis.practice[song.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RX.Space.l) {
                header
                if app.analysis.status(for: song.id) != .done {
                    AnalysisCard(song: song) // a re-analysis (e.g. separating instruments) in progress
                }
                Text("O que você quer tocar?")
                    .font(.rxDisplay(.title))
                    .foregroundStyle(RX.Palette.textPrimary)
                chordsCard
                riffCard
                keyCard
                replaceRow
                HStack {
                    Spacer()
                    Menu {
                        Button("Visão completa (onda, braço, tab)", action: onShowFullPlayer)
                        Button("Visão geral da análise") { showingOverview = true }
                        if !app.player.stemNames.isEmpty {
                            Button("Volume de cada instrumento") { showingMixer = true }
                        }
                    } label: {
                        Label("Mais", systemImage: "ellipsis.circle").font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, RX.Space.screenMargin)
            .padding(.vertical, RX.Space.m)
        }
        .sheet(isPresented: $showingOverview) {
            SongOverviewView(song: song, analysis: analysis).presentationBackground(RX.Palette.base)
        }
        .sheet(isPresented: $showingMixer) {
            StemMixerSheet(player: app.player).presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title).font(.rxDisplay(.title2)).foregroundStyle(RX.Palette.textPrimary).lineLimit(2)
            Text([song.artist, analysis.mainKey?.name(), analysis.rhythm?.beatsPerMinute.map { "\(Int($0.rounded())) BPM" }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
        }
    }

    private var chordsCard: some View {
        let chords = material?.chordsInOrder ?? []
        return choiceCard(title: "Acordes", badge: "MAIS FÁCIL", highlighted: true,
                          detail: "Acompanhe a música trocando de acorde no tempo certo. Um desenho de acorde por vez.",
                          footnote: chords.isEmpty ? "Nenhum acorde claro nesta música." : "Nesta música: " + chords.prefix(6).map { $0.symbol() }.joined(separator: ", "),
                          enabled: !chords.isEmpty) { onChoose(.chords) }
    }

    private var riffCard: some View {
        let phrases = material?.phrases.count ?? 0
        let footnote: String
        if material == nil {
            footnote = "Preparando…"
        } else if phrases == 0 {
            footnote = "Nenhuma linha clara foi encontrada."
        } else if let section = material?.riffSections.first {
            footnote = "Nesta música: riff na \(AnalysisText.sectionName(section)) · \(phrases) frases no total"
        } else {
            footnote = "\(phrases) frases"
        }
        return choiceCard(title: "Riff principal", badge: nil, highlighted: false,
                          detail: "A linha mais marcante, uma nota de cada vez, com a casa e o dedo.",
                          footnote: footnote, enabled: phrases > 0) { onChoose(.riff) }
    }

    private func choiceCard(title: String, badge: String?, highlighted: Bool, detail: String, footnote: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: RX.Space.xs) {
                HStack {
                    Text(title).font(.rxDisplay(.title3)).foregroundStyle(RX.Palette.textPrimary)
                    Spacer()
                    if let badge {
                        Text(badge).font(.caption2.weight(.heavy)).foregroundStyle(RX.Palette.base)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(RX.Palette.cyan))
                    }
                }
                Text(detail).font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text(footnote).font(.footnote).foregroundStyle(RX.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RX.Space.m)
            .background(RoundedRectangle(cornerRadius: RX.Radius.panel).fill(RX.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: RX.Radius.panel).stroke(highlighted ? RX.Palette.violet : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    @ViewBuilder private var keyCard: some View {
        if let key = material?.key {
            VStack(alignment: .leading, spacing: RX.Space.s) {
                HStack {
                    Text("Tom e notas").font(.headline).foregroundStyle(RX.Palette.textPrimary)
                    Spacer()
                    Text(key.key.name()).font(.rxChord(.title2)).foregroundStyle(RX.brandGradient)
                    Text("estimado").font(.caption2).foregroundStyle(RX.Palette.textTertiary)
                }
                noteRow(title: "Escala", names: key.names(key.scale), highlight: key.names([key.key.tonic]))
                noteRow(title: "Pentatônica", names: key.names(key.pentatonic), highlight: key.names([key.key.tonic]))
                if !key.chords.isEmpty {
                    noteRow(title: "Acordes", names: key.chords.prefix(8).map { $0.symbol(preferFlats: key.prefersFlats) }, highlight: [])
                }
                Text("Para improvisar: a pentatônica de \(key.key.name()) cabe em quase toda a música.")
                    .font(.caption).foregroundStyle(RX.Palette.textTertiary)
            }
            .padding(RX.Space.m)
            .background(RoundedRectangle(cornerRadius: RX.Radius.panel).fill(RX.Palette.surface))
        }
    }

    private func noteRow(title: String, names: [String], highlight: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(RX.Palette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        let isTonic = highlight.contains(name)
                        Text(name).font(.subheadline.weight(.bold))
                            .foregroundStyle(isTonic ? RX.Palette.base : RX.Palette.textPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(isTonic ? RX.Palette.cyan : RX.Palette.raised))
                    }
                }
            }
        }
    }

    @ViewBuilder private var replaceRow: some View {
        if app.player.stemNames.isEmpty {
            HStack(spacing: RX.Space.s) {
                Image(systemName: "guitars").foregroundStyle(RX.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tocar no lugar da guitarra").font(.subheadline.weight(.semibold)).foregroundStyle(RX.Palette.textPrimary)
                    Text("Precisa separar os instrumentos desta música.").font(.caption).foregroundStyle(RX.Palette.textSecondary)
                }
                Spacer()
                Button("Separar") { app.analysis.analyze(song) }
                    .font(.footnote.weight(.semibold)).buttonStyle(.bordered).tint(RX.Palette.violet)
            }
            .padding(RX.Space.m)
            .background(RoundedRectangle(cornerRadius: RX.Radius.control).fill(RX.Palette.surface))
        } else {
            Toggle(isOn: $replaceGuitar) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tocar no lugar da guitarra").font(.subheadline.weight(.semibold)).foregroundStyle(RX.Palette.textPrimary)
                    Text("A guitarra original sai da música; o resto da banda continua.")
                        .font(.caption).foregroundStyle(RX.Palette.textSecondary)
                }
            }
            .tint(RX.Palette.violet)
            .padding(RX.Space.m)
            .background(RoundedRectangle(cornerRadius: RX.Radius.control).fill(RX.Palette.surface))
        }
    }
}

// MARK: Shared chrome

private struct PracticeTopBar: View {
    let title: String
    let onBack: () -> Void
    @Environment(AppModel.self) private var app
    @AppStorage("rx.countIn") private var countIn = true
    @AppStorage("rx.lowStringOnRight") private var lowStringOnRight = true
    @State private var showingMixer = false

    private var player: AudioPlayer { app.player }

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.headline)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(RX.Palette.raised))
            }
            .accessibilityLabel("Voltar à escolha")
            Spacer()
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(RX.Palette.textSecondary)
            Spacer()
            Menu {
                Toggle("Contagem 1·2·3·4 antes de tocar", isOn: Binding(get: { countIn }, set: {
                    countIn = $0
                    player.setCountInEnabled($0)
                }))
                .disabled(!player.hasBeatGrid)
                Toggle("Metrônomo", isOn: Binding(get: { player.metronomeEnabled }, set: { player.setMetronomeEnabled($0) }))
                    .disabled(!player.hasBeatGrid)
                Toggle("Corda Mi grave à direita", isOn: $lowStringOnRight)
                if !player.stemNames.isEmpty {
                    Button("Volume de cada instrumento") { showingMixer = true }
                }
            } label: {
                Text("Mais").font(.subheadline.weight(.semibold))
                    .frame(height: 44).padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(RX.Palette.raised))
            }
        }
        .foregroundStyle(RX.Palette.textPrimary)
        .sheet(isPresented: $showingMixer) {
            StemMixerSheet(player: player).presentationDetents([.medium, .large])
        }
    }
}

private struct PracticeControls: View {
    let repeatTitle: String
    let repeating: Bool
    let onRepeat: () -> Void
    @Environment(AppModel.self) private var app

    private var player: AudioPlayer { app.player }

    var body: some View {
        HStack {
            Menu {
                ForEach([0.5, 0.6, 0.75, 0.9, 1.0], id: \.self) { value in
                    Button("\(Int(value * 100))%") { player.setRate(value) }
                }
            } label: {
                Text("\(Int((player.rate * 100).rounded()))%").font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 64, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(RX.Palette.raised))
            }
            .accessibilityLabel("Velocidade")
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(RX.Palette.base)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(RX.Palette.violet))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pausar" : "Tocar")
            Spacer()
            Button(action: onRepeat) {
                Text(repeatTitle).font(.subheadline.weight(.bold))
                    .foregroundStyle(repeating ? RX.Palette.base : RX.Palette.textPrimary)
                    .frame(minHeight: 44).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(repeating ? RX.Palette.cyan : RX.Palette.raised))
            }
            .accessibilityAddTraits(repeating ? .isSelected : [])
        }
        .foregroundStyle(RX.Palette.textPrimary)
    }
}

// MARK: Chords

private struct ChordsPractice: View {
    let song: SongRecord
    let analysis: SongAnalysis
    let onBack: () -> Void
    @Environment(AppModel.self) private var app
    @AppStorage("rx.lowStringOnRight") private var lowStringOnRight = true

    private var player: AudioPlayer { app.player }
    private var beats: [Seconds] { analysis.rhythm?.beats ?? [] }
    private var bars: [Seconds] { analysis.rhythm?.bars ?? [] }
    private var chords: [ChordEvent] { analysis.chords.filter { $0.chord != nil } }

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            let time = player.currentTime
            let current = chords.first { $0.start <= time && time < $0.end }
            let next = chords.first { $0.start > time && $0.chord != current?.chord }
            let section = analysis.sections.first { $0.start <= time && time < $0.end }
            VStack(spacing: RX.Space.m) {
                PracticeTopBar(title: "Acordes" + (section.map { " · " + AnalysisText.sectionName($0) } ?? ""), onBack: onBack)
                if let beatsLeft = player.countInBeatsRemaining {
                    Spacer()
                    Text("\(beatsLeft)").font(.system(size: 120, weight: .heavy, design: .rounded)).foregroundStyle(RX.brandGradient)
                    Text("prepare-se").font(.headline).foregroundStyle(RX.Palette.textSecondary)
                    Spacer()
                } else {
                    VStack(spacing: 4) {
                        Text("AGORA").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(RX.Palette.cyan)
                        Text(current?.chord?.symbol() ?? "—").font(.system(size: 72, weight: .heavy, design: .rounded))
                            .foregroundStyle(current == nil ? RX.Palette.textTertiary : RX.Palette.textPrimary)
                            .contentTransition(.numericText())
                    }
                    if let chord = current?.chord {
                        ChordDiagramView(chord: chord, lowStringOnRight: lowStringOnRight)
                            .frame(width: 210, height: 230)
                    } else {
                        Text(next == nil ? "Fim dos acordes." : "Sem acorde agora. Prepare o próximo.")
                            .font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
                            .frame(height: 230)
                    }
                    beatDots(time: time)
                    if let next, let chord = next.chord {
                        HStack(spacing: RX.Space.s) {
                            Text("Próximo").font(.footnote).foregroundStyle(RX.Palette.textSecondary)
                            Text(chord.symbol()).font(.rxChord(.title2)).foregroundStyle(RX.Palette.textPrimary)
                            Text(untilText(time: time, start: next.start)).font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, RX.Space.m).padding(.vertical, RX.Space.s)
                        .background(RoundedRectangle(cornerRadius: RX.Radius.control).fill(RX.Palette.surface))
                    }
                    Spacer(minLength: 0)
                }
                ProgressView(value: min(max(time / max(analysis.duration, 0.1), 0), 1)).tint(RX.Palette.violet)
                PracticeControls(repeatTitle: "Repetir parte", repeating: player.loopEnabled) { toggleRepeat(time: time) }
            }
            .padding(.horizontal, RX.Space.screenMargin)
            .padding(.vertical, RX.Space.s)
        }
    }

    @ViewBuilder private func beatDots(time: Seconds) -> some View {
        if let position = BeatPosition.at(time, beats: beats, bars: bars) {
            HStack(spacing: 14) {
                ForEach(1...position.beatsPerBar, id: \.self) { beat in
                    let on = beat == position.beat && player.isPlaying
                    Text("\(beat)").font(.headline)
                        .foregroundStyle(on ? RX.Palette.base : RX.Palette.textTertiary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(on ? RX.Palette.cyan : RX.Palette.raised))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tempo \(position.beat) de \(position.beatsPerBar)")
        }
    }

    private func untilText(time: Seconds, start: Seconds) -> String {
        let count = BeatPosition.beats(from: time, until: start, beats: beats)
        if !beats.isEmpty { return count <= 1 ? "no próximo tempo" : "em \(count) tempos" }
        return "em \(max(1, Int((start - time).rounded(.up)))) s"
    }

    /// Loops the song part the playhead is in (or turns the loop off).
    private func toggleRepeat(time: Seconds) {
        if player.loopEnabled {
            player.setLoopEnabled(false)
            return
        }
        let section = analysis.sections.first { $0.start <= time && time < $0.end } ?? analysis.sections.first
        guard let section, let loop = LoopRegion(start: section.start, end: section.end, duration: player.duration) else { return }
        player.setLoop(loop)
        player.setLoopEnabled(true)
    }
}

// MARK: Riff

private struct RiffPractice: View {
    enum Step: Int, CaseIterable {
        case listen, slow, alone

        var title: String {
            switch self {
            case .listen: "Ouça"
            case .slow: "Devagar"
            case .alone: "Sem guitarra"
            }
        }

        var detail: String {
            switch self {
            case .listen: "A frase repete com a guitarra original. Siga as notas na pista."
            case .slow: "Toque junto em 60%, por cima da guitarra original."
            case .alone: "Na velocidade normal, sem a guitarra original: só você com a banda."
            }
        }
    }

    let song: SongRecord
    let analysis: SongAnalysis
    let replaceGuitar: Bool
    let onBack: () -> Void

    @Environment(AppModel.self) private var app
    @AppStorage("rx.lowStringOnRight") private var lowStringOnRight = true
    @State private var guided = true
    @State private var step: Step = .listen
    @State private var phraseIndex = 0

    private var player: AudioPlayer { app.player }
    private var material: PracticeMaterial? { app.analysis.practice[song.id] }

    var body: some View {
        VStack(spacing: RX.Space.s) {
            PracticeTopBar(title: "Riff · Frase \(phraseIndex + 1) de \(max(material?.phrases.count ?? 1, 1))", onBack: onBack)
            Picker("Modo", selection: $guided) {
                Text("Passo a passo").tag(true)
                Text("Livre").tag(false)
            }
            .pickerStyle(.segmented)
            if guided { stepChips }
            if let material {
                TimelineView(.animation(paused: !player.isPlaying)) { _ in
                    let time = player.currentTime
                    VStack(spacing: RX.Space.s) {
                        ZStack {
                            HighwayView(layout: material.lineLayout, chords: [], beats: analysis.rhythm?.beats ?? [],
                                        bars: analysis.rhythm?.bars ?? [], time: time, lowStringOnRight: lowStringOnRight,
                                        horizon: 2.4 * max(player.rate, 0.5))
                            if let beats = player.countInBeatsRemaining {
                                Text("\(beats)").font(.system(size: 96, weight: .heavy, design: .rounded))
                                    .foregroundStyle(RX.brandGradient)
                            }
                        }
                        noteCard(layout: material.lineLayout, time: time)
                    }
                }
                phraseBar(material.phrases)
            } else {
                Spacer()
                ProgressView("Preparando a linha do riff…").tint(RX.Palette.cyan)
                Spacer()
            }
            if guided {
                HStack(spacing: RX.Space.s) {
                    Button("Repetir") { restartPhrase() }
                        .buttonStyle(RXSecondaryButtonStyle())
                    Button(step == .alone ? "Saiu bem, próxima frase" : "Saiu bem, próximo") { advance() }
                        .buttonStyle(RXPrimaryButtonStyle())
                }
            } else {
                PracticeControls(repeatTitle: "Repetir frase", repeating: player.loopEnabled) {
                    if player.loopEnabled { player.setLoopEnabled(false) } else { select(phraseIndex, play: false) }
                }
            }
        }
        .padding(.horizontal, RX.Space.screenMargin)
        .padding(.vertical, RX.Space.s)
        .onAppear { if material != nil { configure() } }
        .onChange(of: material?.phrases.count) { _, _ in configure() }
        .onChange(of: guided) { _, _ in configure() }
    }

    private var stepChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    let isCurrent = item == step
                    let done = item.rawValue < step.rawValue
                    Button {
                        step = item
                        configure()
                    } label: {
                        Text("\(item.rawValue + 1) · \(item.title)").font(.footnote.weight(.semibold))
                            .foregroundStyle(isCurrent ? RX.Palette.base : RX.Palette.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(isCurrent ? RX.Palette.violet : (done ? RX.Palette.success.opacity(0.25) : RX.Palette.raised)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
            Text(step.detail).font(.caption).foregroundStyle(RX.Palette.textSecondary)
        }
    }

    @ViewBuilder private func noteCard(layout: TabLayout, time: Seconds) -> some View {
        let note = layout.sounding(at: time).first ?? layout.upcoming(after: time, horizon: 4).first
        if let note {
            HStack(spacing: RX.Space.s) {
                Text("\(note.position.fret)").font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(RX.Palette.base)
                    .frame(width: 54, height: 54)
                    .background(RoundedRectangle(cornerRadius: 14).fill(HighwayView.stringColors[note.position.string]))
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.position.fret == 0
                         ? "Corda \(PracticeAudio.stringName(note.position.string)) solta"
                         : "Corda \(PracticeAudio.stringName(note.position.string)), casa \(note.position.fret)")
                        .font(.headline).foregroundStyle(RX.Palette.textPrimary)
                    Text(PracticeAudio.fingerName(note.finger).capitalizedFirst
                         + (note.handPosition.map { " · mão na casa \($0)" } ?? ""))
                        .font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(RX.Space.s)
            .background(RoundedRectangle(cornerRadius: RX.Radius.control).fill(RX.Palette.raised))
            .accessibilityElement(children: .combine)
        }
    }

    private func phraseBar(_ phrases: [Phrase]) -> some View {
        HStack(spacing: 4) {
            ForEach(phrases) { phrase in
                Button {
                    select(phrase.index, play: false)
                } label: {
                    Capsule().fill(phrase.index == phraseIndex ? RX.Palette.cyan : (phrase.index < phraseIndex ? RX.Palette.violet : RX.Palette.raised))
                        .frame(height: 8)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Frase \(phrase.index + 1)")
            }
        }
    }

    // MARK: Flow

    private var phrases: [Phrase] { material?.phrases ?? [] }

    private func configure() {
        guard !phrases.isEmpty else { return }
        phraseIndex = min(phraseIndex, phrases.count - 1)
        select(phraseIndex, play: false)
    }

    private func select(_ index: Int, play: Bool) {
        guard phrases.indices.contains(index) else { return }
        phraseIndex = index
        let phrase = phrases[index]
        player.pause()
        if guided {
            switch step {
            case .listen:
                player.setRate(1)
                PracticeAudio.applyReplaceGuitar(false, player: player, analysis: analysis)
            case .slow:
                player.setRate(0.6)
                PracticeAudio.applyReplaceGuitar(false, player: player, analysis: analysis)
            case .alone:
                player.setRate(1)
                PracticeAudio.applyReplaceGuitar(true, player: player, analysis: analysis)
            }
        } else {
            PracticeAudio.applyReplaceGuitar(replaceGuitar, player: player, analysis: analysis)
        }
        if let loop = LoopRegion(start: phrase.start, end: phrase.end, duration: player.duration) {
            player.setLoop(loop)
            player.setLoopEnabled(true)
        }
        player.seek(to: phrase.start)
        if play { player.play() }
    }

    private func restartPhrase() {
        select(phraseIndex, play: true)
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
            select(phraseIndex, play: true)
        } else {
            step = .listen
            select(min(phraseIndex + 1, phrases.count - 1), play: true)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
