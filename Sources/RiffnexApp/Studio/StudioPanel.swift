import DesignSystem
import MusicCore
import Persistence
import PlaybackEngine
import SwiftUI

/// The Learning Studio surface inside the player once a song is analyzed: current chord and
/// section, and a hero that is either the fretboard or the tab (`Braço · Tab`).
struct StudioPanel: View {
    enum Mode: String, CaseIterable {
        case neck = "Braço"
        case tab = "Tab"
    }

    let song: SongRecord
    let analysis: SongAnalysis
    @Environment(AppModel.self) private var app
    @AppStorage("rx.studioMode") private var mode = Mode.neck.rawValue
    @AppStorage("rx.leftHanded") private var leftHanded = false

    private var player: AudioPlayer { app.player }

    var body: some View {
        VStack(spacing: RX.Space.s) {
            HStack {
                Picker("Modo", selection: $mode) {
                    ForEach(Mode.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Spacer()
                Toggle(isOn: $leftHanded) {
                    Image(systemName: "hand.raised")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Canhoto")
                .opacity(mode == Mode.neck.rawValue ? 1 : 0)
            }
            TimelineView(.animation(paused: !player.isPlaying)) { _ in
                let time = player.currentTime
                VStack(spacing: RX.Space.s) {
                    CurrentChordView(analysis: analysis, time: time)
                    if let layout = app.analysis.layouts[song.id] {
                        if mode == Mode.tab.rawValue {
                            TabStripView(layout: layout, time: time) { player.seek(to: $0) }
                                .frame(height: 120)
                        } else {
                            FretboardView(layout: layout, time: time, leftHanded: leftHanded)
                                .frame(height: 170)
                        }
                    } else {
                        ProgressView("Calculando digitação…")
                            .tint(RX.Palette.cyan)
                            .frame(height: 120)
                    }
                    SectionStrip(sections: analysis.sections, duration: analysis.duration, highlightTime: time)
                        .frame(height: 16)
                }
            }
            if let layout = app.analysis.layouts[song.id], !layout.arrangement.unplayable.isEmpty {
                Text("\(layout.arrangement.unplayable.count) notas fora do alcance desta afinação foram omitidas.")
                    .font(.caption2).foregroundStyle(RX.Palette.textTertiary)
            }
            Text("Posições e dedos são uma sugestão tocável, não necessariamente como foi gravado.")
                .font(.caption2).foregroundStyle(RX.Palette.textTertiary)
        }
        .task(id: analysis.createdAt) { await app.analysis.prepareLayout(for: song.id) }
    }
}
