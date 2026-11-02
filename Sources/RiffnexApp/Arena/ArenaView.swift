import DesignSystem
import MusicCore
import Persistence
import SwiftUI
import UIKit

/// One song: prepares it (separates the guitar) the first time, then opens the arena.
struct SongView: View {
    @Environment(AppModel.self) private var app
    let song: SongRecord

    var body: some View {
        Group {
            if let map = app.prep.maps[song.id] {
                ArenaView(song: song, map: map, app: app)
            } else {
                PrepView(song: song)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await app.prep.load(song.id)
            await app.markOpened(song)
            if app.prep.maps[song.id] == nil, case .none = app.prep.status(for: song.id) {
                app.prep.prepare(song)
            }
        }
    }
}

// MARK: - Arena

struct ArenaView: View {
    @State private var model: ArenaModel
    @State private var touch: Touch?
    @State private var selection: ClosedRange<Seconds>?
    @State private var toast: String?
    @State private var toastID = 0
    @State private var clock = FrameClock()
    @Environment(\.dismiss) private var dismiss

    init(song: SongRecord, map: RiffMap, app: AppModel) {
        _model = State(initialValue: ArenaModel(song: song, map: map, app: app))
    }

    struct Touch {
        enum Mode { case scrub, focus, select, speed, tap, focusOnly }
        var start: CGPoint
        var mode: Mode?
        var focus0 = 0.0
        var time0: Seconds = 0
        var anchor: Seconds = 0
        var angle = 0.0
        var speed = 1.0
        var wasPlaying = false
        var hold: Task<Void, Never>?
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RadialGradient(colors: [RX.Palette.raised, RX.Palette.surface, RX.Palette.base],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: size.height * 0.6)
                    .ignoresSafeArea()
                TimelineView(.animation) { timeline in
                    Canvas { context, canvasSize in
                        let dt = clock.tick(timeline.date)
                        ArenaScene.draw(&context, size: canvasSize, input: sceneInput, fx: model.fx, dt: dt)
                    }
                }
                .contentShape(Rectangle())
                .gesture(arenaGesture(size: size))
                .accessibilityElement()
                .accessibilityLabel(model.loop == nil ? "Fita da música" : "Trecho preso no anel")
                .accessibilityValue("\(TimeFormatting.clock(model.currentTime)), velocidade \(Int(model.speed * 100))%")
                .accessibilityAction(named: Text(model.isPlaying ? "Pausar" : "Tocar")) { model.togglePlay() }

                VStack(spacing: 0) {
                    hud
                    Spacer()
                    if model.loop == nil {
                        hints
                    } else {
                        ringBar
                    }
                    controls
                }
                .padding(.horizontal, RX.Space.m)

                FocusRail(focus: model.focus) { value in
                    model.setFocus(value)
                } onEnd: {
                    if let stop = model.settleFocus() { show(Self.focusName(stop)) }
                }
                .frame(width: 34, height: size.height * 0.34)
                .position(x: size.width - 21, y: size.height * 0.45)

                if let toast {
                    Text(toast)
                        .font(.rxBig(22))
                        .foregroundStyle(RX.brandGradient)
                        .shadow(color: RX.Palette.magenta.opacity(0.6), radius: 10)
                        .position(x: size.width / 2, y: size.height * 0.22)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .background(RX.Palette.base.ignoresSafeArea())
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }

    private var sceneInput: ArenaScene.Input {
        ArenaScene.Input(now: model.currentTime, playing: model.isPlaying, map: model.map, loop: model.loop,
                         focus: model.focus, speed: model.speed, laps: model.laps, ramping: model.ramping,
                         lapsAtSpeed: model.lapsAtThisSpeed, selection: selection)
    }

    // MARK: HUD

    private var hud: some View {
        HStack(spacing: RX.Space.s) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.bold))
                    .foregroundStyle(RX.Palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(RX.Palette.surface.opacity(0.8)))
            }
            .accessibilityLabel("Voltar para a biblioteca")
            VStack(alignment: .leading, spacing: 3) {
                Text(model.song.title.uppercased())
                    .font(.rxHUD(17, weight: .heavy))
                    .foregroundStyle(RX.Palette.textPrimary)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Treino nesta música: \(TimeFormatting.clock(model.practicedSeconds + model.player.pendingPracticedSeconds))")
                        .font(.rxHUD(10, weight: .medium))
                        .foregroundStyle(RX.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Label("Separada", systemImage: "checkmark")
                .font(.rxHUD(10))
                .foregroundStyle(RX.Palette.cyan)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(RX.Palette.cyan.opacity(0.45)))
                .accessibilityLabel("Guitarra separada")
        }
        .padding(.top, RX.Space.xs)
    }

    private var hints: some View {
        HStack(spacing: RX.Space.xs) {
            HintChip(symbol: "arrow.up.and.down", text: "foco")
            HintChip(symbol: "arrow.left.and.right", text: "andar")
            HintChip(symbol: "hand.tap", text: "segure e arraste: prender o riff")
        }
        .padding(.bottom, RX.Space.m)
        .allowsHitTesting(false)
    }

    private var ringBar: some View {
        HStack(spacing: RX.Space.s) {
            Button { model.setRamping(!model.ramping) } label: {
                Text(model.ramping ? "Subindo · parar" : "Subir sozinho")
            }
            .buttonStyle(ArenaButtonStyle(prominent: !model.ramping, active: model.ramping))
            .accessibilityHint("Aumenta a velocidade 5% a cada duas voltas, até a velocidade real.")
            Button("Soltar") { model.releaseRiff() }
                .buttonStyle(ArenaButtonStyle(prominent: false, active: false))
                .accessibilityHint("Solta o trecho e volta para a música inteira.")
        }
        .padding(.bottom, RX.Space.m)
    }

    private var controls: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text("\(TimeFormatting.clock(model.currentTime)) / \(TimeFormatting.clock(model.duration))")
                    .font(.rxHUD(12, weight: .medium).monospacedDigit())
                    .foregroundStyle(RX.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(RX.Palette.textPrimary)
                    .frame(width: 76, height: 76)
                    .background(
                        Circle().fill(RadialGradient(colors: [RX.Palette.raised, RX.Palette.surface], center: .center, startRadius: 0, endRadius: 40))
                    )
                    .overlay(Circle().strokeBorder(RX.Palette.magenta, lineWidth: 2))
                    .shadow(color: RX.Palette.magenta.opacity(0.55), radius: 14)
            }
            .accessibilityLabel(model.isPlaying ? "Pausar" : "Tocar")
            Button { model.cycleSpeed(); show("\(Int(model.speed * 100))%") } label: {
                Text("\(Int((model.speed * 100).rounded()))%")
                    .font(.rxHUD(13).monospacedDigit())
                    .foregroundStyle(RX.Palette.fireLight)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(RX.Palette.fireLight.opacity(0.4)))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("Velocidade \(Int(model.speed * 100))%. Toque para mudar.")
        }
        .padding(.bottom, RX.Space.s)
    }

    // MARK: Gestures

    private func arenaGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if touch == nil { begin(at: value.startLocation, size: size) }
                moved(value, size: size)
            }
            .onEnded { _ in ended() }
    }

    private func begin(at point: CGPoint, size: CGSize) {
        let g = ArenaGeometry(size: size)
        var t = Touch(start: point)
        if model.loop != nil {
            let c = g.ringCenter
            let d = hypot(point.x - c.x, point.y - c.y)
            if d > g.ringRadius * 0.7, d < g.meterRadius + 50 {
                t.mode = .speed
                t.angle = atan2(Double(point.y - c.y), Double(point.x - c.x))
                t.speed = model.speed
            } else if d <= g.ringRadius * 0.7 {
                t.mode = .tap
            } else {
                t.mode = .focusOnly
            }
            touch = t
            return
        }
        t.hold = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled, touch != nil, touch?.mode == nil else { return }
            touch?.wasPlaying = model.isPlaying
            model.pause()
            let at = g.time(atX: point.x, now: model.currentTime)
            let anchor = model.map.beats.isEmpty ? at : model.map.beat(atOrBefore: at + 0.01)
            touch?.anchor = anchor
            touch?.mode = .select
            if let region = model.region(from: anchor, to: anchor) { selection = region.start...region.end }
            UISelectionFeedbackGenerator().selectionChanged()
        }
        touch = t
    }

    private func moved(_ value: DragGesture.Value, size: CGSize) {
        guard var t = touch else { return }
        let g = ArenaGeometry(size: size)
        let dx = value.location.x - t.start.x, dy = value.location.y - t.start.y
        if t.mode == nil || t.mode == .focusOnly {
            guard hypot(dx, dy) >= 8 else { return }
            t.hold?.cancel()
            if t.mode == .focusOnly || abs(dy) > abs(dx) {
                t.mode = .focus
                t.focus0 = model.focus
            } else {
                t.mode = .scrub
                t.time0 = model.currentTime
                t.wasPlaying = model.isPlaying
                model.pause()
            }
        }
        switch t.mode {
        case .scrub:
            model.seek(to: t.time0 - Double(dx / ArenaGeometry.pointsPerSecond))
        case .focus:
            model.setFocus(t.focus0 - Double(dy) / 130)
        case .select:
            let at = g.time(atX: value.location.x, now: model.currentTime)
            if let region = model.region(from: t.anchor, to: at) { selection = region.start...region.end }
        case .speed:
            let c = g.ringCenter
            let angle = atan2(Double(value.location.y - c.y), Double(value.location.x - c.x))
            var delta = angle - t.angle
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            t.angle = angle
            t.speed = min(max(t.speed + delta / (2 * .pi) * 0.6, ArenaModel.speedRange.lowerBound), ArenaModel.speedRange.upperBound)
            model.stopRamp()
            model.setSpeed(t.speed)
        default:
            break
        }
        touch = t
    }

    private func ended() {
        guard let t = touch else { return }
        t.hold?.cancel()
        switch t.mode {
        case .scrub:
            if t.wasPlaying { model.togglePlay() }
        case .focus:
            if let stop = model.settleFocus() { show(Self.focusName(stop)) }
        case .select:
            if let selection, let region = LoopRegion(start: selection.lowerBound, end: selection.upperBound, duration: model.duration) {
                model.catchRiff(region)
                show("Riff preso · " + ArenaScene.selectionLabel(selection, map: model.map).lowercased())
            }
            selection = nil
        case nil, .tap:
            model.togglePlay()
        case .speed, .focusOnly:
            break
        }
        touch = nil
    }

    static func focusName(_ stop: Double) -> String {
        stop > 0.5 ? "Só guitarra" : stop < -0.5 ? "Sua vez" : "Tudo junto"
    }

    private func show(_ text: String) {
        toastID += 1
        let id = toastID
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1300))
            if toastID == id { withAnimation(.easeIn(duration: 0.25)) { toast = nil } }
        }
    }
}

/// Measures the time between frames for the canvas animation.
final class FrameClock {
    private var last: Date?

    func tick(_ date: Date) -> Double {
        defer { last = date }
        guard let last else { return 1.0 / 60 }
        return min(0.05, max(0, date.timeIntervalSince(last)))
    }
}

// MARK: - Pieces

struct FocusRail: View {
    let focus: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let y = (1 - focus) / 2 * h
            ZStack(alignment: .topTrailing) {
                Capsule()
                    .fill(LinearGradient(colors: [RX.Palette.fire, RX.Palette.hairline, RX.Palette.cyan], startPoint: .top, endPoint: .bottom))
                    .frame(width: 3)
                    .shadow(color: RX.Palette.magenta.opacity(0.4), radius: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 4)
                    .fill(RX.Palette.textPrimary)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(45))
                    .shadow(color: .white.opacity(0.6), radius: 8)
                    .position(x: proxy.size.width / 2, y: y)
                Text(ArenaView.focusName(focus > 0.5 ? 1 : focus < -0.5 ? -1 : 0).uppercased())
                    .font(.rxHUD(9))
                    .foregroundStyle(RX.Palette.textPrimary)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(RX.Palette.surface.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(RX.Palette.hairline))
                    .position(x: -40, y: y)
                    .opacity([1.0, 0, -1].contains(focus) ? 1 : 0.6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onChange(1 - 2 * min(max(value.location.y / h, 0), 1)) }
                    .onEnded { _ in onEnd() }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Foco")
        .accessibilityValue(ArenaView.focusName(focus))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(1, focus.rounded() + 1))
            case .decrement: onChange(max(-1, focus.rounded() - 1))
            @unknown default: break
            }
            onEnd()
        }
    }
}

struct HintChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.rxHUD(10, weight: .medium))
            .foregroundStyle(RX.Palette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 4).fill(RX.Palette.surface.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(RX.Palette.hairline))
    }
}

struct ArenaButtonStyle: ButtonStyle {
    let prominent: Bool
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rxHUD(12))
            .textCase(.uppercase)
            .foregroundStyle(prominent ? Color(hex: 0x1A0610) : active ? RX.Palette.magenta : RX.Palette.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 6).fill(RX.brandGradient)
                        .shadow(color: RX.Palette.fire.opacity(0.45), radius: 12)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(active ? RX.Palette.magenta.opacity(0.15) : RX.Palette.surface.opacity(0.9))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? RX.Palette.magenta : RX.Palette.hairline))
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
