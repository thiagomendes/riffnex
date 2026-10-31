import DesignSystem
import PlaybackEngine
import SwiftUI

/// Per-instrument volumes while playing. The separation is an estimate: some sound of one
/// instrument always leaks into the others.
struct StemMixerSheet: View {
    let player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    static func displayName(_ stem: String) -> String {
        switch stem {
        case "guitar": "Guitarra"
        case "bass": "Baixo"
        case "drums": "Bateria"
        case "vocals": "Voz"
        case "piano": "Piano e teclados"
        case "other": "Outros"
        default: stem
        }
    }

    static func symbol(_ stem: String) -> String {
        switch stem {
        case "guitar": "guitars"
        case "bass": "waveform.path"
        case "drums": "circle.hexagongrid"
        case "vocals": "music.mic"
        case "piano": "pianokeys"
        default: "music.note"
        }
    }

    private struct Preset: Identifiable {
        let id: String
        let volumes: (String) -> Float
    }

    private let presets: [Preset] = [
        Preset(id: "Tudo") { _ in 1 },
        Preset(id: "Sem guitarra") { $0 == "guitar" ? 0 : 1 },
        Preset(id: "Só guitarra") { $0 == "guitar" ? 1 : 0 },
        Preset(id: "Sem voz") { $0 == "vocals" ? 0 : 1 },
        Preset(id: "Guitarra + bateria") { ["guitar", "drums"].contains($0) ? 1 : 0.15 },
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: RX.Space.xs) {
                            ForEach(presets) { preset in
                                Button(preset.id) {
                                    for name in player.stemNames { player.setVolume(preset.volumes(name), forStem: name) }
                                }
                                .font(.footnote.weight(.semibold))
                                .buttonStyle(.bordered)
                                .tint(RX.Palette.violet)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(player.stemNames, id: \.self) { name in
                        let volume = player.stemVolumes[name] ?? 1
                        HStack(spacing: RX.Space.s) {
                            Button {
                                player.setVolume(volume > 0 ? 0 : 1, forStem: name)
                            } label: {
                                Image(systemName: volume > 0 ? Self.symbol(name) : "speaker.slash")
                                    .frame(width: 28)
                                    .foregroundStyle(volume > 0 ? RX.Palette.cyan : RX.Palette.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(volume > 0 ? "Silenciar \(Self.displayName(name))" : "Ligar \(Self.displayName(name))")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.displayName(name)).font(.subheadline.weight(.semibold))
                                Slider(value: Binding(get: { Double(player.stemVolumes[name] ?? 1) },
                                                      set: { player.setVolume(Float($0), forStem: name) }), in: 0...1)
                                    .tint(RX.Palette.cyan)
                                    .accessibilityLabel("Volume de \(Self.displayName(name))")
                            }
                        }
                        .listRowBackground(RX.Palette.raised)
                    }
                } footer: {
                    Text("Instrumentos separados no próprio iPhone (Demucs). A separação não é perfeita: um pouco de cada instrumento vaza para os outros.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(RX.Palette.surface)
            .navigationTitle("Instrumentos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}
