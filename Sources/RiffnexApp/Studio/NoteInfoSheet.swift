import DesignSystem
import MusicCore
import SwiftUI

/// What we know about the notes under the playhead, and where each fact came from.
struct NoteInfoSheet: View {
    let notes: [ArrangedNote]
    let tuning: Tuning
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if notes.isEmpty {
                    Text("Nenhuma nota soando neste ponto. Toque no braço enquanto uma nota toca.")
                        .foregroundStyle(RX.Palette.textSecondary)
                }
                ForEach(notes.sorted { $0.position.string > $1.position.string }) { note in
                    Section {
                        row("Nota", NoteNaming.letters.name(of: note.pitch) + "  ·  " + NoteNaming.solfege.name(of: note.pitch))
                        row("Onde tocar", place(note.position) + (note.position.fret == 0 ? "" : ", dedo \(note.finger.rawValue)")
                            + (note.isBarre ? " (pestana)" : ""))
                        row("Confiança da detecção", AnalysisText.confidence(note.confidence))
                        let others = tuning.positions(for: note.pitch).filter { $0 != note.position }
                        if !others.isEmpty {
                            row("Também dá em", others.map(place).joined(separator: "; "))
                        }
                    } header: {
                        Text(String(format: "%.2f s", note.onset))
                    } footer: {
                        Text("A nota foi detectada no áudio pelo Basic Pitch. A corda, a casa e o dedo são uma recomendação do RIFFNEX para tocar com pouco esforço, não necessariamente como foi gravado.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RX.Palette.surface)
            .navigationTitle("Notas aqui")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }

    private func place(_ position: FretPosition) -> String {
        let string = position.tabLineNumber(stringCount: tuning.stringCount)
        return position.fret == 0 ? "corda \(string) solta" : "corda \(string), casa \(position.fret)"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(RX.Palette.textSecondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(RX.Palette.textPrimary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
