import DesignSystem
import MusicCore
import Persistence
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Binding var path: [SongRecord]
    @State private var showingImporter = false
    @State private var songPendingDeletion: SongRecord?

    var body: some View {
        ZStack {
            RXBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.xl) {
                    header
                    if !app.isBootstrapped {
                        ProgressView().tint(RX.Palette.violet).frame(maxWidth: .infinity).padding(.top, RX.Space.xxl)
                    } else if app.songs.isEmpty {
                        EmptyLibrary()
                    } else {
                        if let song = app.continueSong {
                            ContinueCard(song: song, waveform: app.waveforms[song.id], artworkURL: app.artworkURL(for: song)) {
                                path.append(song)
                            }
                        }
                        library
                    }
                }
                .padding(.horizontal, RX.Space.screenMargin)
                .padding(.top, RX.Space.s)
                .padding(.bottom, 140)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { importBar }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { app.importFile(at: url) }
        }
        .overlay { if case .importing(let name) = app.importState { ImportingOverlay(fileName: name) { app.cancelImport() } } }
        .alert("Não foi possível importar", isPresented: failureBinding) {
            Button("OK", role: .cancel) { app.importState = .idle }
        } message: {
            if case .failed(let message) = app.importState { Text(message) }
        }
        .alert("Essa música já está na biblioteca", isPresented: duplicateBinding) {
            Button("Abrir") {
                if case .duplicate(let song) = app.importState { path.append(song) }
                app.importState = .idle
            }
            Button("OK", role: .cancel) { app.importState = .idle }
        } message: {
            if case .duplicate(let song) = app.importState { Text("“\(song.title)” foi importada antes. O arquivo é idêntico.") }
        }
        .confirmationDialog("Remover esta música?", isPresented: deletionBinding, titleVisibility: .visible,
                            presenting: songPendingDeletion) { song in
            Button("Remover “\(song.title)”", role: .destructive) {
                Task { await app.delete(song) }
            }
        } message: { _ in
            Text("A cópia do áudio e o progresso nesta música serão apagados do iPhone. O arquivo original não é afetado.")
        }
    }

    private var header: some View {
        HStack {
            Text("RIFFNEX")
                .font(.footnote.weight(.heavy).width(.expanded))
                .tracking(3)
                .foregroundStyle(RX.Palette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            NavigationLink {
                DiagnosticsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(RX.Palette.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Ajustes e diagnóstico")
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            Text("Sua biblioteca")
                .font(.title3.weight(.semibold))
                .foregroundStyle(RX.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            LazyVStack(spacing: RX.Space.xs) {
                ForEach(app.songs) { song in
                    Button { path.append(song) } label: {
                        SongRow(song: song, waveform: app.waveforms[song.id], artworkURL: app.artworkURL(for: song))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { songPendingDeletion = song } label: {
                            Label("Remover", systemImage: "trash")
                        }
                    }
                    .accessibilityAction(named: "Remover") { songPendingDeletion = song }
                }
            }
        }
    }

    private var importBar: some View {
        VStack(spacing: RX.Space.xs) {
            Button {
                showingImporter = true
            } label: {
                Label("Importar música", systemImage: "plus")
            }
            .buttonStyle(RXPrimaryButtonStyle())
            .disabled(!app.isBootstrapped)
            Text("Importe apenas músicas que você tem o direito de usar.")
                .font(.caption2)
                .foregroundStyle(RX.Palette.textTertiary)
        }
        .padding(.horizontal, RX.Space.screenMargin)
        .padding(.top, RX.Space.s)
        .padding(.bottom, RX.Space.xs)
        .background(
            LinearGradient(colors: [RX.Palette.base.opacity(0), RX.Palette.base], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { if case .failed = app.importState { true } else { false } },
                set: { if !$0 { app.importState = .idle } })
    }

    private var duplicateBinding: Binding<Bool> {
        Binding(get: { if case .duplicate = app.importState { true } else { false } },
                set: { if !$0, case .duplicate = app.importState { app.importState = .idle } })
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { songPendingDeletion != nil }, set: { if !$0 { songPendingDeletion = nil } })
    }
}

private struct EmptyLibrary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            VStack(alignment: .leading, spacing: RX.Space.xxs) {
                Text("Da escuta").foregroundStyle(RX.Palette.textPrimary)
                Text("ao toque.").foregroundStyle(RX.brandGradient)
            }
            .font(.rxDisplay(.largeTitle))
            .padding(.top, RX.Space.xxl)
            Text("Sua biblioteca está vazia. Importe uma música que é sua para começar.")
                .font(.body)
                .foregroundStyle(RX.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ContinueCard: View {
    let song: SongRecord
    let waveform: WaveformOverview?
    let artworkURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: RX.Space.m) {
                Text("Continuar praticando")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(RX.Palette.textSecondary)
                HStack(spacing: RX.Space.m) {
                    SongArtwork(imageURL: artworkURL, waveform: waveform, seed: song.id, cornerRadius: RX.Radius.control)
                        .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: RX.Space.xxs) {
                        Text(song.title)
                            .font(.rxDisplay(.title3))
                            .foregroundStyle(RX.Palette.textPrimary)
                            .lineLimit(2)
                        if let artist = song.artist {
                            Text(artist).font(.subheadline).foregroundStyle(RX.Palette.textSecondary).lineLimit(1)
                        }
                        Label("Retomar", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RX.Palette.cyan)
                            .padding(.top, RX.Space.xxs)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(RX.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RX.Radius.panel, style: .continuous)
                    .fill(RX.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: RX.Radius.panel, style: .continuous)
                            .strokeBorder(RX.brandGradient, lineWidth: 1)
                            .opacity(0.35)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continuar praticando \(song.title)")
    }
}

private struct SongRow: View {
    let song: SongRecord
    let waveform: WaveformOverview?
    let artworkURL: URL?

    var body: some View {
        HStack(spacing: RX.Space.s) {
            SongArtwork(imageURL: artworkURL, waveform: waveform, seed: song.id, cornerRadius: RX.Radius.chip)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: RX.Space.xs) {
                    Text(song.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(RX.Palette.textPrimary)
                        .lineLimit(1)
                    if song.isDemo {
                        Text("DEMO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(RX.Palette.violet)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(RX.Palette.violet.opacity(0.16)))
                    }
                }
                Text([song.artist, TimeFormatting.clock(song.duration)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(RX.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RX.Palette.textTertiary)
        }
        .padding(RX.Space.s)
        .background(RoundedRectangle(cornerRadius: RX.Radius.control, style: .continuous).fill(RX.Palette.surface))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ImportingOverlay: View {
    let fileName: String
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: RX.Space.m) {
                ProgressView().controlSize(.large).tint(RX.Palette.cyan)
                Text("Importando")
                    .font(.headline)
                    .foregroundStyle(RX.Palette.textPrimary)
                Text(fileName)
                    .font(.footnote)
                    .foregroundStyle(RX.Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Verificando o arquivo, copiando para o iPhone e desenhando a onda sonora.")
                    .font(.caption)
                    .foregroundStyle(RX.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                Button("Cancelar", role: .cancel, action: cancel)
                    .buttonStyle(RXSecondaryButtonStyle())
            }
            .padding(RX.Space.l)
            .frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: RX.Radius.panel, style: .continuous).fill(RX.Palette.raised))
        }
        .accessibilityElement(children: .contain)
    }
}
