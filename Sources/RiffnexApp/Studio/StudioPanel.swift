import DesignSystem
import MusicCore
import Persistence
import PlaybackEngine
import SwiftUI

/// The practice surface once a song is analyzed, built for beginners: pick Riff or Chords, pick a
/// part of the song (it loops), pick a speed, play. Everything else lives under "Mais".
struct StudioPanel: View {
    enum Mode: String, CaseIterable {
        case riff = "Riff"
        case chords = "Acordes"
    }

    enum RiffView: String, CaseIterable {
        case highway = "Pista"
        case neck = "Braço"
        case tab = "Tab"
    }

    let song: SongRecord
    let analysis: SongAnalysis
    @Environment(AppModel.self) private var app
    @State private var mode: Mode?
    @AppStorage("rx.riffView") private var riffView = RiffView.highway.rawValue
    @AppStorage("rx.lowStringOnRight") private var lowStringOnRight = true
    @AppStorage("rx.countIn") private var countIn = true
    @State private var inspected: [ArrangedNote]?
    @State private var selectedSection: Int? // index into analysis.sections; nil = whole song
    @State private var showingMixer = false

    private var player: AudioPlayer { app.player }
    private var effectiveMode: Mode { mode ?? suggestedMode }

    /// Chords when most of the song is chordal, otherwise riff.
    private var suggestedMode: Mode {
        let chordal = analysis.sections.filter(\.isChordal).map { $0.end - $0.start }.reduce(0, +)
        return chordal > analysis.duration / 2 ? .chords : .riff
    }

    var body: some View {
        VStack(spacing: RX.Space.s) {
            HStack {
                Picker("O que aprender", selection: Binding(get: { effectiveMode }, set: { mode = $0 })) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                Spacer()
                if !player.stemNames.isEmpty {
                    Button {
                        showingMixer = true
                    } label: {
                        Label("Instrumentos", systemImage: "slider.vertical.3")
                            .font(.footnote.weight(.semibold))
                    }
                    .accessibilityHint("Aumente ou abaixe cada instrumento")
                }
                moreMenu
            }
            sectionChips
            TimelineView(.animation(paused: !player.isPlaying)) { _ in
                let time = player.currentTime
                ZStack(alignment: .topLeading) {
                    hero(time: time)
                    if let beats = player.countInBeatsRemaining {
                        Text("\(beats)")
                            .font(.rxDisplay(.largeTitle))
                            .foregroundStyle(RX.brandGradient)
                            .padding(RX.Space.s)
                            .background(Circle().fill(RX.Palette.base.opacity(0.7)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("Contagem: \(beats)")
                    }
                }
            }
            .frame(height: effectiveMode == .riff ? 270 : 230)
            speedChips
        }
        .sheet(isPresented: $showingMixer) {
            StemMixerSheet(player: player)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { inspected = nil } })) {
            if let notes = inspected, let layout = app.analysis.layouts[song.id] {
                NoteInfoSheet(notes: notes, tuning: layout.arrangement.tuning)
                    .presentationDetents([.medium, .large])
            }
        }
        .task(id: analysis.createdAt) { await app.analysis.prepareLayout(for: song.id) }
        .task(id: GridKey(analysis: analysis.createdAt, loaded: player.isLoaded)) {
            // The player resets its grid on load, so (re)apply it whenever either side changes.
            guard player.isLoaded else { return }
            player.setBeatGrid(beats: analysis.rhythm?.beats ?? [], bars: analysis.rhythm?.bars ?? [])
            player.setCountInEnabled(countIn)
        }
    }

    // MARK: Hero

    @ViewBuilder private func hero(time: Seconds) -> some View {
        if effectiveMode == .chords {
            VStack(alignment: .leading, spacing: RX.Space.s) {
                ChordModeView(chords: analysis.chords, time: time, lowStringOnRight: lowStringOnRight)
                if !analysis.chords.contains(where: { $0.chord != nil }) {
                    Text("Nenhum acorde claro foi encontrado nesta música. Experimente o modo Riff.")
                        .font(.footnote).foregroundStyle(RX.Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let layout = app.analysis.layouts[song.id] {
            switch RiffView(rawValue: riffView) ?? .highway {
            case .highway:
                HighwayView(layout: layout, chords: analysis.chords, beats: analysis.rhythm?.beats ?? [],
                            bars: analysis.rhythm?.bars ?? [], time: time, lowStringOnRight: lowStringOnRight,
                            horizon: 2.4 * max(player.rate, 0.5))
                    .overlay(alignment: .topTrailing) {
                        Text(HandHint.text(layout: layout, time: time))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(RX.Palette.base)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Capsule().fill(RX.Palette.cyan))
                            .accessibilityLabel("Posição da mão: \(HandHint.text(layout: layout, time: time))")
                    }
                    .overlay(alignment: .topLeading) {
                        CurrentChordView(analysis: analysis, time: time).frame(maxWidth: 220, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { inspect(layout) }
            case .neck:
                VStack(spacing: RX.Space.s) {
                    CurrentChordView(analysis: analysis, time: time)
                    FretboardView(layout: layout, time: time, leftHanded: false)
                        .contentShape(Rectangle())
                        .onTapGesture { inspect(layout) }
                }
            case .tab:
                VStack(spacing: RX.Space.s) {
                    CurrentChordView(analysis: analysis, time: time)
                    TabStripView(layout: layout, time: time) { player.seek(to: $0) }
                }
            }
        } else {
            ProgressView("Calculando onde tocar cada nota…")
                .tint(RX.Palette.cyan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Controls

    private var sectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RX.Space.xs) {
                chip(title: "Música inteira", detail: TimeFormatting.clock(analysis.duration), selected: selectedSection == nil) {
                    selectedSection = nil
                    player.setLoopEnabled(false)
                }
                ForEach(Array(analysis.sections.enumerated()), id: \.offset) { index, section in
                    if section.kind != .silent {
                        chip(title: AnalysisText.sectionName(section) + (section.isChordal ? " · acordes" : " · riff"),
                             detail: "\(TimeFormatting.clock(section.start))–\(TimeFormatting.clock(section.end))",
                             selected: selectedSection == index) {
                            practice(section: section, index: index)
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Trechos da música")
    }

    private func chip(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote.weight(.semibold))
                Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(RX.Palette.textSecondary)
            }
            .padding(.horizontal, RX.Space.s).padding(.vertical, RX.Space.xs)
            .background(RoundedRectangle(cornerRadius: RX.Radius.chip).fill(selected ? RX.Palette.violet.opacity(0.35) : RX.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: RX.Radius.chip).stroke(selected ? RX.Palette.violet : RX.Palette.hairline))
        }
        .buttonStyle(.plain)
        .foregroundStyle(RX.Palette.textPrimary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func practice(section: SongSection, index: Int) {
        selectedSection = index
        if mode == nil { mode = section.isChordal ? .chords : .riff }
        guard let loop = LoopRegion(start: section.start, end: section.end, duration: player.duration) else { return }
        player.setLoop(loop)
        player.setLoopEnabled(true)
        player.seek(to: section.start)
    }

    private var speedChips: some View {
        HStack(spacing: RX.Space.xs) {
            Text("Velocidade").font(.caption).foregroundStyle(RX.Palette.textTertiary)
            ForEach([0.5, 0.75, 1.0], id: \.self) { value in
                let selected = abs(player.rate - value) < 0.01
                Button("\(Int(value * 100))%") { player.setRate(value) }
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, RX.Space.s).padding(.vertical, 6)
                    .background(Capsule().fill(selected ? RX.Palette.cyan : RX.Palette.raised))
                    .foregroundStyle(selected ? RX.Palette.base : RX.Palette.textPrimary)
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
    }

    private var moreMenu: some View {
        Menu {
            if effectiveMode == .riff {
                Picker("Visão", selection: $riffView) {
                    ForEach(RiffView.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
            Toggle("Contagem 1·2·3·4 antes de tocar", isOn: Binding(get: { countIn }, set: {
                countIn = $0
                player.setCountInEnabled($0)
            }))
            .disabled(!player.hasBeatGrid)
            Toggle("Metrônomo", isOn: Binding(get: { player.metronomeEnabled }, set: { player.setMetronomeEnabled($0) }))
                .disabled(!player.hasBeatGrid)
            Toggle("Corda grave (Mi) à direita", isOn: $lowStringOnRight)
            if let layout = app.analysis.layouts[song.id] {
                Button("Detalhes das notas agora") { inspect(layout) }
            }
        } label: {
            Label("Mais", systemImage: "slider.horizontal.3")
                .font(.footnote.weight(.semibold))
        }
    }
}

extension StudioPanel {
    fileprivate func inspect(_ layout: TabLayout) {
        let time = player.currentTime
        player.pause()
        // If nothing is sounding exactly now, show the notes that start next.
        let sounding = layout.sounding(at: time)
        inspected = sounding.isEmpty ? layout.upcoming(after: time, horizon: 2) : sounding
    }
}

private struct GridKey: Equatable {
    let analysis: Date
    let loaded: Bool
}
