import DesignSystem
import SwiftUI

/// About two seconds of brand on a cold launch: the ring's segments light up one by one, the
/// playhead drops in, the name appears, and everything dissolves into the library.
/// A tap skips it. With Reduce Motion it is a short fade.
struct SplashView: View {
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = 0
    @State private var needle = false
    @State private var name = false
    @State private var leaving = false

    private static let segments = 12

    var body: some View {
        ZStack {
            RadialGradient(colors: [RX.Palette.raised, RX.Palette.surface, RX.Palette.base],
                           center: .center, startRadius: 0, endRadius: 460)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                ZStack {
                    ForEach(0..<Self.segments, id: \.self) { i in
                        RingSegment(index: i, count: Self.segments)
                            .stroke(Self.color(i), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .shadow(color: Self.color(i).opacity(0.8), radius: i < lit ? 10 : 0)
                            .opacity(i < lit ? 1 : 0.08)
                            .scaleEffect(i < lit ? 1 : 0.92)
                    }
                    Circle()
                        .stroke(RX.Palette.cyan, style: StrokeStyle(lineWidth: 5, dash: [4, 6]))
                        .frame(width: 92, height: 92)
                        .opacity(name ? 0.9 : 0)
                        .rotationEffect(.degrees(name ? 30 : 0))
                    Circle().fill(Color(hex: 0xFFF4E6)).frame(width: 14, height: 14)
                        .shadow(color: RX.Palette.fireLight, radius: 12)
                        .opacity(needle ? 1 : 0)
                    Capsule().fill(.white).frame(width: 6, height: 46)
                        .shadow(color: RX.Palette.magenta, radius: 10)
                        .offset(y: needle ? -92 : -150)
                        .opacity(needle ? 1 : 0)
                }
                .frame(width: 220, height: 220)
                VStack(spacing: 8) {
                    Text("RIFFNEX")
                        .font(.rxHUD(30, weight: .heavy))
                        .tracking(6)
                        .foregroundStyle(RX.brandGradient)
                    Text("Aprenda riffs de ouvido")
                        .font(.rxHUD(12, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(RX.Palette.textSecondary)
                }
                .opacity(name ? 1 : 0)
                .offset(y: name ? 0 : 12)
            }
            .scaleEffect(leaving ? 1.08 : 1)
        }
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement()
        .accessibilityLabel("RIFFNEX")
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            lit = Self.segments; needle = true; name = true
            try? await Task.sleep(for: .milliseconds(500))
            finish()
            return
        }
        for i in 1...Self.segments {
            withAnimation(.easeOut(duration: 0.28)) { lit = i }
            try? await Task.sleep(for: .milliseconds(75))
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { needle = true }
        try? await Task.sleep(for: .milliseconds(220))
        withAnimation(.easeOut(duration: 0.6)) { name = true }
        // Hold the finished picture for a moment before dissolving into the library.
        try? await Task.sleep(for: .milliseconds(1000))
        finish()
    }

    private func finish() {
        guard !leaving else { return }
        withAnimation(.easeIn(duration: 0.45)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(460))
            done()
        }
    }

    /// Yellow to orange to magenta around the ring, like the speed meter.
    static func color(_ i: Int) -> Color {
        i < 5 ? RX.Palette.fireLight : i < 9 ? RX.Palette.fire : RX.Palette.magenta
    }
}

/// One of the ring's segments, clockwise from the top.
private struct RingSegment: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let span = 360.0 / Double(count)
        let start = -90 + Double(index) * span + 6
        let end = -90 + Double(index + 1) * span - 6
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2 - 8,
                    startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        return path
    }
}
