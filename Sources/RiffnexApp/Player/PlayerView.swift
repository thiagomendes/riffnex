import DesignSystem
import MusicCore
import Persistence
import PlaybackEngine
import SwiftUI

/// Practice player: precise seek, pitch-preserving speed, gapless A–B loop and a waveform timeline,
/// plus the analysis card and (once analyzed) the current chord and section. It becomes the
/// transport of the Learning Studio in M3.
struct PlayerView: View {
    let song: SongRecord

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var loadError: String?
    @State private var restored = false
    @State private var practicedBefore: Double = 0
    @State private var showingSpeed = false

    private var player: AudioPlayer { app.player }
    /// Once the Studio panel is showing, the header and waveform shrink to make room for it.
    private var compact: Bool { app.analysis.analyses[song.id] != nil }

    var body: some View {
        ZStack {
            RXBackground()
            VStack(spacing: RX.Space.m) {
                header
                AnalysisCard(song: song)
                Spacer(minLength: 0)
                if let analysis = app.analysis.analyses[song.id] {
                    StudioPanel(song: song, analysis: analysis)
                }
                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(RX.Palette.error)
                        .multilineTextAlignment(.center)
                }
                timeline
                transport
                loopRow
                Spacer(minLength: 0)
                practiceFooter
            }
            .padding(.horizontal, RX.Space.screenMargin)
            .padding(.bottom, RX.Space.m)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await restore() }
        .onDisappear { Task { await persist(pausing: true) } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await persist(pausing: false) } }
        }
        .sheet(isPresented: $showingSpeed) {
            SpeedSheet(rate: player.rate) { player.setRate($0) }
                .presentationDetents([.height(260)])
                .presentationBackground(RX.Palette.surface)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: RX.Space.m) {
            SongArtwork(imageURL: app.artworkURL(for: song), waveform: app.waveforms[song.id], seed: song.id,
                        cornerRadius: RX.Radius.control)
                .frame(width: compact ? 52 : 88, height: compact ? 52 : 88)
                .shadow(color: RX.Palette.violet.opacity(0.35), radius: 18, y: 6)
            VStack(alignment: .leading, spacing: RX.Space.xxs) {
                Text(song.title)
                    .font(.rxDisplay(.title2))
                    .foregroundStyle(RX.Palette.textPrimary)
                    .lineLimit(2)
                if let artist = song.artist {
                    Text(artist).font(.subheadline).foregroundStyle(RX.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, RX.Space.s)
        .accessibilityElement(children: .combine)
    }

    private var timeline: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            let time = player.currentTime
            let duration = max(player.duration, 0.001)
            VStack(spacing: RX.Space.xs) {
                WaveformTimeline(
                    waveform: app.waveforms[song.id],
                    progress: time / duration,
                    loop: player.loop.map { ($0.start / duration)...($0.end / duration) },
                    loopEnabled: player.loopEnabled,
                    onScrub: { fraction in player.seek(to: fraction * duration) },
                    onLoopChange: { lower, upper in
                        player.setLoop(LoopRegion(start: lower * duration, end: upper * duration, duration: duration)
                            ?? player.loop)
                    }
                )
                .frame(height: compact ? 72 : 120)
                .accessibilityElement()
                .accessibilityLabel("Linha do tempo")
                .accessibilityValue("\(TimeFormatting.clock(time)) de \(TimeFormatting.clock(duration))")
                .accessibilityAdjustableAction { direction in
                    player.skip(by: direction == .increment ? 5 : -5)
                }

                HStack {
                    Text(TimeFormatting.clock(time))
                    Spacer()
                    Text("-" + TimeFormatting.clock(max(0, duration - time)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(RX.Palette.textSecondary)
                .accessibilityHidden(true)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            TransportButton(symbol: "repeat", label: player.loopEnabled ? "Desligar loop" : "Ligar loop",
                            active: player.loopEnabled) { toggleLoop() }
            Spacer()
            TransportButton(symbol: "gobackward.5", label: "Voltar 5 segundos") { player.skip(by: -5) }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(RX.Palette.base)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(RX.brandGradient))
                    .shadow(color: RX.Palette.blue.opacity(0.45), radius: 16, y: 6)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pausar" : "Tocar")
            .disabled(!player.isLoaded)
            Spacer()
            TransportButton(symbol: "goforward.5", label: "Avançar 5 segundos") { player.skip(by: 5) }
            Spacer()
            Button {
                showingSpeed = true
            } label: {
                Text("\(Int((player.rate * 100).rounded()))%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(player.rate == 1 ? RX.Palette.textSecondary : RX.Palette.cyan)
                    .frame(width: 56, height: 44)
            }
            .accessibilityLabel("Velocidade")
            .accessibilityValue("\(Int((player.rate * 100).rounded())) por cento")
        }
    }

    @ViewBuilder private var loopRow: some View {
        if let loop = player.loop {
            HStack(spacing: RX.Space.s) {
                Image(systemName: "repeat")
                    .foregroundStyle(player.loopEnabled ? RX.Palette.blue : RX.Palette.textTertiary)
                Text("Loop \(TimeFormatting.clock(loop.start)) – \(TimeFormatting.clock(loop.end))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(RX.Palette.textSecondary)
                Spacer()
                Button("Limpar") { player.setLoop(nil) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RX.Palette.textSecondary)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, RX.Space.m)
            .background(RoundedRectangle(cornerRadius: RX.Radius.control, style: .continuous).fill(RX.Palette.surface))
            .accessibilityElement(children: .contain)
        } else {
            Text("Toque em  \(Image(systemName: "repeat"))  para repetir um trecho. Arraste as alças na onda para ajustá-lo.")
                .font(.footnote)
                .foregroundStyle(RX.Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var practiceFooter: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("Tempo praticado nesta música: \(formatPractice(practicedBefore))")
                .font(.caption)
                .foregroundStyle(RX.Palette.textTertiary)
        }
    }

    // MARK: Actions

    private func toggleLoop() {
        if player.loop == nil {
            let region = LoopRegion.around(player.currentTime, length: 8, duration: player.duration)
            player.setLoop(region)
            player.setLoopEnabled(region != nil)
        } else {
            player.setLoopEnabled(!player.loopEnabled)
        }
    }

    private func restore() async {
        guard !restored else { return }
        restored = true
        do {
            try player.load(url: app.audioURL(for: song), title: song.title, artist: song.artist)
        } catch {
            loadError = "Não foi possível abrir o áudio: \(error.localizedDescription)"
            return
        }
        let state = await app.studioState(for: song)
        practicedBefore = state.practicedSeconds
        player.setRate(state.rate)
        if let loop = state.loop, loop.end <= player.duration { player.setLoop(loop) }
        player.seek(to: min(state.position, player.duration))
        if state.loopEnabled { player.setLoopEnabled(true) }
        await app.markOpened(song)
    }

    private func persist(pausing: Bool) async {
        guard restored, loadError == nil else { return }
        if pausing { player.pause() }
        practicedBefore += player.takePracticedSeconds()
        let state = StudioState(position: player.currentTime, rate: player.rate, loop: player.loop,
                                loopEnabled: player.loopEnabled, practicedSeconds: practicedBefore)
        await app.save(state, for: song)
    }

    private func formatPractice(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

private struct TransportButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(active ? RX.Palette.blue : RX.Palette.textPrimary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(active ? RX.Palette.blue.opacity(0.16) : RX.Palette.raised))
        }
        .accessibilityLabel(label)
    }
}

/// Waveform with a draggable playhead and loop handles.
private struct WaveformTimeline: View {
    let waveform: WaveformOverview?
    let progress: Double
    let loop: ClosedRange<Double>?
    let loopEnabled: Bool
    let onScrub: (Double) -> Void
    let onLoopChange: (Double, Double) -> Void

    private enum DragTarget { case scrub, lower, upper }
    @State private var dragTarget: DragTarget?
    @State private var handleTick = 0

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .topLeading) {
                WaveformBars(waveform: waveform, progress: progress, loop: loop, loopEnabled: loopEnabled)
                if let loop {
                    handle(at: loop.lowerBound * width, height: geometry.size.height)
                    handle(at: loop.upperBound * width, height: geometry.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        if dragTarget == nil {
                            dragTarget = target(forStartX: value.startLocation.x, width: width)
                        }
                        switch dragTarget {
                        case .lower:
                            if let loop { onLoopChange(min(fraction, loop.upperBound), loop.upperBound) }
                        case .upper:
                            if let loop { onLoopChange(loop.lowerBound, max(fraction, loop.lowerBound)) }
                        case .scrub, .none:
                            onScrub(fraction)
                        }
                    }
                    .onEnded { _ in
                        if dragTarget == .lower || dragTarget == .upper { handleTick += 1 }
                        dragTarget = nil
                    }
            )
            .sensoryFeedback(.selection, trigger: handleTick)
        }
    }

    private func target(forStartX x: CGFloat, width: CGFloat) -> DragTarget {
        guard let loop else { return .scrub }
        let lower = loop.lowerBound * width
        let upper = loop.upperBound * width
        let hit: CGFloat = 24
        if abs(x - lower) <= hit && abs(x - lower) <= abs(x - upper) { return .lower }
        if abs(x - upper) <= hit { return .upper }
        return .scrub
    }

    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(RX.Palette.blue)
            .frame(width: 6, height: height + 12)
            .overlay(Capsule().stroke(RX.Palette.textPrimary.opacity(0.6), lineWidth: 1))
            .offset(x: x - 3, y: -6)
            .allowsHitTesting(false)
    }
}

private struct SpeedSheet: View {
    @State var rate: Double
    let onChange: (Double) -> Void

    private let presets: [Double] = [0.5, 0.7, 0.85, 1.0]

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Velocidade")
                    .font(.headline)
                    .foregroundStyle(RX.Palette.textPrimary)
                Spacer()
                Text("\(Int((rate * 100).rounded()))%")
                    .font(.rxDisplay(.title2).monospacedDigit())
                    .foregroundStyle(RX.brandGradient)
            }
            Slider(value: $rate, in: 0.25...1.25, step: 0.05)
                .tint(RX.Palette.cyan)
                .accessibilityValue("\(Int((rate * 100).rounded())) por cento")
            HStack(spacing: RX.Space.xs) {
                ForEach(presets, id: \.self) { preset in
                    Button("\(Int(preset * 100))%") { rate = preset }
                        .buttonStyle(RXSecondaryButtonStyle())
                        .overlay(
                            RoundedRectangle(cornerRadius: RX.Radius.chip, style: .continuous)
                                .stroke(RX.Palette.cyan, lineWidth: abs(rate - preset) < 0.001 ? 1.5 : 0)
                        )
                }
            }
            Text("O tom é preservado em qualquer velocidade.")
                .font(.caption)
                .foregroundStyle(RX.Palette.textTertiary)
        }
        .padding(RX.Space.l)
        .onChange(of: rate) { _, newValue in onChange(newValue) }
        .sensoryFeedback(.selection, trigger: rate)
    }
}
