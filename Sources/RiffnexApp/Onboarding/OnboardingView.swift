import DesignSystem
import SwiftUI
import UIKit

/// First-run story in three beats — IMPORTE · DESCUBRA · TOQUE — told as one continuous animation:
/// a sound wave condenses into notes and chords, and the notes land on a guitar neck.
/// No permissions are requested here.
struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private let pages: [(word: String, title: String, detail: String)] = [
        ("IMPORTE", "Traga a sua música.",
         "Escolha arquivos de áudio que são seus, direto do app Arquivos. Tudo fica no seu iPhone."),
        ("DESCUBRA", "Revele notas, riffs e acordes.",
         "O RIFFNEX escuta a música no próprio aparelho e mostra o que encontrou — e o quanto tem certeza."),
        ("TOQUE", "Aprenda na sua guitarra de verdade.",
         "Veja onde tocar cada nota no braço, desacelere sem mudar o tom e repita o trecho difícil em loop."),
    ]

    var body: some View {
        ZStack {
            RXBackground()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Pular") { onFinish() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RX.Palette.textSecondary)
                        .frame(minHeight: 44)
                        .opacity(page < pages.count - 1 ? 1 : 0)
                        .accessibilityHidden(page == pages.count - 1)
                }
                .padding(.horizontal, RX.Space.screenMargin)

                visual
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .padding(.top, RX.Space.s)
                    .accessibilityHidden(true)

                Spacer(minLength: RX.Space.l)

                text
                    .padding(.horizontal, RX.Space.screenMargin)

                Spacer(minLength: RX.Space.l)

                PageDots(count: pages.count, current: page)
                    .padding(.bottom, RX.Space.l)

                Button {
                    advance()
                } label: {
                    Text(page < pages.count - 1 ? "Continuar" : "Começar")
                }
                .buttonStyle(RXPrimaryButtonStyle())
                .padding(.horizontal, RX.Space.screenMargin)
                .padding(.bottom, RX.Space.l)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.width < -50 { advance() }
                if value.translation.width > 50, page > 0 { go(to: page - 1) }
            }
        )
        .sensoryFeedback(.selection, trigger: page)
    }

    @ViewBuilder private var visual: some View {
        if reduceMotion {
            OnboardingVisual(target: Double(page), animateTime: false)
                .id(page)
                .transition(.opacity)
        } else {
            OnboardingVisual(target: Double(page), animateTime: true)
        }
    }

    private var text: some View {
        VStack(spacing: RX.Space.s) {
            Text(pages[page].word)
                .font(.rxDisplay(.largeTitle))
                .tracking(4)
                .foregroundStyle(RX.brandGradient)
            Text(pages[page].title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(RX.Palette.textPrimary)
            Text(pages[page].detail)
                .font(.body)
                .foregroundStyle(RX.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .id(page)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 12)),
                                removal: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func advance() {
        if page < pages.count - 1 { go(to: page + 1) } else { onFinish() }
    }

    private func go(to newPage: Int) {
        let animation = reduceMotion ? Animation.easeInOut(duration: 0.25) : Animation.spring(response: 0.9, dampingFraction: 0.86)
        withAnimation(animation) { page = newPage }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: RX.Space.xs) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(RX.brandGradient) : AnyShapeStyle(RX.Palette.textTertiary))
                    .frame(width: index == current ? 24 : 8, height: 8)
            }
        }
        .animation(RX.Motion.touch, value: current)
        .accessibilityElement()
        .accessibilityLabel("Página \(current + 1) de \(count)")
    }
}

/// The morphing scene. Progress 0 → 1 → 2 maps to wave → notes & chords → fretboard.
/// Progress is eased by hand inside the TimelineView (no Animatable conformance, which is not
/// main-actor safe under Swift 6), and the same timeline drives the living pulse.
private struct OnboardingVisual: View {
    let target: Double
    let animateTime: Bool

    @State private var from: Double = 0
    @State private var to: Double = 0
    @State private var startedAt = Date.distantPast
    private let transitionDuration = 0.9

    private static let count = 18
    // A small original riff: (string from low E = 0, fret) for each note in scene 3.
    private static let riff: [(string: Int, fret: Int)] = [
        (0, 0), (0, 3), (1, 0), (1, 2), (2, 0), (2, 2), (3, 0), (3, 2), (4, 0),
        (4, 3), (5, 0), (5, 3), (2, 2), (1, 2), (0, 3), (3, 2), (4, 3), (5, 0),
    ]
    private static let melody: [Double] = [0.2, 0.35, 0.5, 0.4, 0.62, 0.55, 0.7, 0.45, 0.8,
                                           0.6, 0.9, 0.75, 0.5, 0.35, 0.3, 0.55, 0.7, 0.85]

    var body: some View {
        TimelineView(.animation(paused: !animateTime)) { timeline in
            let time = animateTime ? timeline.date.timeIntervalSinceReferenceDate : 0
            let progress = animateTime ? progress(at: timeline.date) : target
            Canvas { context, size in
                draw(in: &context, size: size, time: time, progress: progress)
            }
        }
        .onAppear {
            from = target
            to = target
        }
        .onChange(of: target) { _, newValue in
            from = progress(at: Date())
            to = newValue
            startedAt = Date()
        }
    }

    private func progress(at date: Date) -> Double {
        let k = smooth(date.timeIntervalSince(startedAt) / transitionDuration)
        return from + (to - from) * k
    }

    private func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double, progress: Double) {
        let t1 = smooth(progress)
        let t2 = smooth(progress - 1)
        let w = size.width
        let h = size.height

        // Fretboard (scene 3).
        let board = CGRect(x: w * 0.08, y: h * 0.18, width: w * 0.84, height: h * 0.64)
        let fretCount = 5
        let fretWidth = board.width / CGFloat(fretCount)
        if t2 > 0 {
            context.opacity = t2
            context.fill(Path(roundedRect: board, cornerRadius: 14),
                         with: .linearGradient(Gradient(colors: [RX.Palette.fretboardTop, RX.Palette.fretboardBottom]),
                                               startPoint: board.origin, endPoint: CGPoint(x: board.minX, y: board.maxY)))
            for f in 1..<fretCount {
                let x = board.minX + CGFloat(f) * fretWidth
                context.fill(Path(CGRect(x: x - 1, y: board.minY + 6, width: 2, height: board.height - 12)),
                             with: .color(RX.Palette.fret))
            }
            for s in 0..<6 {
                let y = stringY(s, board)
                let thickness = 1 + CGFloat(5 - s) * 0.35
                context.fill(Path(CGRect(x: board.minX + 4, y: y - thickness / 2, width: board.width - 8, height: thickness)),
                             with: .color(RX.Palette.string.opacity(0.45 + 0.05 * Double(5 - s))))
            }
            context.opacity = 1
        }

        // Chord symbols (scene 2).
        let chordAlpha = t1 * (1 - t2)
        if chordAlpha > 0.01 {
            context.opacity = chordAlpha
            for (i, name) in ["Em", "G5", "A5", "D"].enumerated() {
                let x = w * (0.16 + 0.23 * Double(i))
                context.draw(Text(name).font(.rxChord(.title3)).foregroundStyle(RX.Palette.textPrimary),
                             at: CGPoint(x: x, y: h * 0.1))
            }
            context.opacity = 1
        }

        let active = Int(time * 3).quotientAndRemainder(dividingBy: Self.count).remainder
        for i in 0..<Self.count {
            let fraction = Double(i) / Double(Self.count - 1)
            // A: waveform bar.
            let pulse = 0.6 + 0.4 * sin(time * 2.2 + Double(i) * 0.7)
            let envelope = 0.35 + 0.65 * sin(fraction * .pi)
            let barHeight = h * 0.55 * envelope * pulse
            let ax = w * (0.1 + 0.8 * fraction)
            let ay = h * 0.5
            // B: note dot on a pitch contour.
            let by = h * (0.82 - 0.6 * Self.melody[i])
            // C: position on the neck.
            let (string, fret) = Self.riff[i]
            let cx = fret == 0 ? board.minX - 2 : board.minX + (CGFloat(fret) - 0.5) * fretWidth
            let cy = stringY(string, board)

            let x = lerp(lerp(ax, ax, t1), cx, t2)
            let y = lerp(lerp(ay, by, t1), cy, t2)
            let width = lerp(5, 16, t1)
            let height = lerp(barHeight, 16, t1)
            let rect = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)

            let isActive = t2 > 0.5 && i == active
            let base = colorAt(fraction)
            let color = t2 > 0 ? mix(base, RX.Palette.cyan, t2 * (isActive ? 1 : 0.35)) : base
            if isActive {
                let glow = rect.insetBy(dx: -10, dy: -10)
                context.fill(Path(ellipseIn: glow), with: .color(RX.Palette.cyan.opacity(0.25)))
            }
            context.fill(Path(roundedRect: rect, cornerRadius: min(width, height) / 2), with: .color(color))
        }
    }

    private func stringY(_ string: Int, _ board: CGRect) -> CGFloat {
        // High e on top (index 5 at the top), matching tablature.
        let spacing = board.height / 7
        return board.minY + spacing * CGFloat(6 - string)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    private func colorAt(_ t: Double) -> Color {
        t < 0.5 ? mix(RX.Palette.violet, RX.Palette.blue, t * 2) : mix(RX.Palette.blue, RX.Palette.cyan, (t - 0.5) * 2)
    }

    private func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = UIColor(a).cgColor.components ?? [0, 0, 0, 1]
        let cb = UIColor(b).cgColor.components ?? [0, 0, 0, 1]
        func c(_ i: Int) -> Double {
            let x = Double(ca.count > i ? ca[i] : 0)
            let y = Double(cb.count > i ? cb[i] : 0)
            return x + (y - x) * min(max(t, 0), 1)
        }
        return Color(.sRGB, red: c(0), green: c(1), blue: c(2), opacity: 1)
    }
}
