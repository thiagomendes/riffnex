import AnalysisEngine
import DesignSystem
import Persistence
import SwiftUI

/// What the app does, where its parts come from, privacy, support, and the space each song uses.
struct AboutView: View {
    @Environment(AppModel.self) private var app
    @State private var sizes: [UUID: Int64] = [:]
    @State private var pendingRemoval: SongRecord?

    private static let privacyURL = URL(string: "https://riffnex.tmdevlab.com/privacidade/")!
    private static let supportURL = URL(string: "https://riffnex.tmdevlab.com/suporte/")!

    var body: some View {
        ZStack {
            RXBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.l) {
                    intro
                    storage
                    links
                    licenses
                    Text("Versão \(Self.version)")
                        .font(.rxHUD(10, weight: .medium))
                        .foregroundStyle(RX.Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RX.Space.screenMargin)
                .padding(.vertical, RX.Space.l)
            }
        }
        .navigationTitle("Sobre")
        .navigationBarTitleDisplayMode(.inline)
        .task { measure() }
        .confirmationDialog("O que fazer com “\(pendingRemoval?.title ?? "")”?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { song in
            Button("Liberar espaço") {
                Task {
                    await app.prep.removePreparation(song.id)
                    measure()
                }
            }
            Button("Remover da biblioteca", role: .destructive) {
                Task {
                    await app.delete(song)
                    measure()
                }
            }
        } message: { _ in
            Text("Liberar espaço apaga só os instrumentos separados. A música fica na biblioteca, com os riffs salvos, e é separada de novo quando você abrir. Remover da biblioteca apaga a música do app. O arquivo original não é afetado.")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            Text("RIFFNEX")
                .font(.rxHUD(26, weight: .heavy))
                .foregroundStyle(RX.brandGradient)
            Text("Aprenda riffs de ouvido com as suas músicas. O RIFFNEX separa a guitarra do resto da banda, e você ouve só ela, desacelera e repete cada trecho até conseguir tocar.")
            Text("Tudo acontece no seu iPhone. As músicas não saem do aparelho, e o app não coleta nenhum dado.")
            Text("Um app do TM Dev Lab.")
        }
        .font(.subheadline)
        .foregroundStyle(RX.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var storage: some View {
        let prepared = app.songs.filter { (sizes[$0.id] ?? 0) > 0 }
        let total = prepared.reduce(Int64(0)) { $0 + (sizes[$1.id] ?? 0) }
        return section("Espaço usado") {
            if prepared.isEmpty {
                Text("Nenhuma música separada ainda.").foregroundStyle(RX.Palette.textTertiary)
            } else {
                Text("Instrumentos separados: \(Self.format(total)) no total.")
                    .foregroundStyle(RX.Palette.textSecondary)
                ForEach(prepared) { song in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).foregroundStyle(RX.Palette.textPrimary).lineLimit(1)
                            Text(Self.format(sizes[song.id] ?? 0)).font(.footnote.monospacedDigit())
                                .foregroundStyle(RX.Palette.textTertiary)
                        }
                        Spacer()
                        Button("Opções") { pendingRemoval = song }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(RX.Palette.cyan)
                            .accessibilityLabel("Liberar espaço ou remover \(song.title)")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var links: some View {
        section("Privacidade e suporte") {
            Link(destination: Self.privacyURL) { linkRow("Política de privacidade", symbol: "hand.raised") }
            Link(destination: Self.supportURL) { linkRow("Ajuda e contato", symbol: "questionmark.circle") }
        }
    }

    private var licenses: some View {
        section("Feito com") {
            ForEach(Licenses.all) { notice in
                DisclosureGroup {
                    Text(notice.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(RX.Palette.textTertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, RX.Space.xs)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.name).foregroundStyle(RX.Palette.textPrimary)
                        Text(notice.use).font(.footnote).foregroundStyle(RX.Palette.textTertiary)
                    }
                }
                .tint(RX.Palette.textSecondary)
            }
            Text("O tempo, os compassos e o tom vêm do Music Understanding, da Apple, também no aparelho.")
                .font(.footnote)
                .foregroundStyle(RX.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            Text(title.uppercased()).font(.rxHUD(10)).foregroundStyle(RX.Palette.textTertiary)
            VStack(alignment: .leading, spacing: RX.Space.s) { content() }
                .font(.subheadline)
                .padding(RX.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: RX.Radius.control).fill(RX.Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: RX.Radius.control).strokeBorder(RX.Palette.hairline))
        }
    }

    private func linkRow(_ title: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(RX.Palette.cyan).frame(width: 24)
            Text(title).foregroundStyle(RX.Palette.textPrimary)
            Spacer()
            Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(RX.Palette.textTertiary)
        }
    }

    private func measure() {
        var result: [UUID: Int64] = [:]
        for song in app.songs { result[song.id] = app.prep.separatedBytes(song.id) }
        sizes = result
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
