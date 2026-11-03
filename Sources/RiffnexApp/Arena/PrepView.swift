import DesignSystem
import MusicCore
import Persistence
import SwiftUI

/// Shown while a song's guitar is being separated: the original waveform, scanned by a cyan line
/// that turns it into guitar (fire) as the real progress advances.
struct PrepView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let song: SongRecord

    var body: some View {
        let status = app.prep.status(for: song.id)
        ZStack {
            RadialGradient(colors: [RX.Palette.raised, RX.Palette.surface, RX.Palette.base],
                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: RX.Space.l) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.bold))
                            .foregroundStyle(RX.Palette.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(RX.Palette.surface.opacity(0.8)))
                    }
                    .accessibilityLabel("Voltar para a biblioteca")
                    Spacer()
                }
                Text(song.title.uppercased())
                    .font(.rxHUD(24, weight: .heavy))
                    .foregroundStyle(RX.Palette.textPrimary)
                    .lineLimit(2)
                Spacer()
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(&context, size: size, fraction: fraction(status), date: timeline.date)
                    }
                }
                .frame(height: 220)
                .accessibilityHidden(true)
                message(status)
                Spacer()
            }
            .padding(.horizontal, RX.Space.screenMargin)
            .padding(.bottom, RX.Space.xl)
        }
    }

    private func fraction(_ status: PrepCenter.Status) -> Double {
        if case .running(let job) = status { return job.fraction }
        return 0
    }

    @ViewBuilder
    private func message(_ status: PrepCenter.Status) -> some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            switch status {
            case .running(let job):
                let percent = Int(job.fraction * 100)
                Text(verbatim: job.stage == .separating ? "SEPARANDO A GUITARRA \(percent)%" : "MEDINDO O RIFF \(percent)%")
                    .font(.rxHUD(18, weight: .heavy))
                    .foregroundStyle(RX.Palette.textPrimary)
                    .monospacedDigit()
                Text("Na primeira vez leva alguns minutos, e tudo acontece no próprio iPhone. Deixe o RIFFNEX aberto. A tela fica acesa sozinha até terminar.")
                    .font(.subheadline)
                    .foregroundStyle(RX.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .queued:
                Text("NA FILA")
                    .font(.rxHUD(18, weight: .heavy))
                    .foregroundStyle(RX.Palette.textPrimary)
                Text("Outra música está sendo separada. Esta começa logo depois.")
                    .font(.subheadline)
                    .foregroundStyle(RX.Palette.textSecondary)
            case .failed(let reason):
                Text("NÃO DEU CERTO")
                    .font(.rxHUD(18, weight: .heavy))
                    .foregroundStyle(RX.Palette.error)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(RX.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Tentar de novo") { app.prep.prepare(song) }
                    .buttonStyle(ArenaButtonStyle(prominent: true, active: false))
            case .none, .ready:
                Text("PREPARANDO")
                    .font(.rxHUD(18, weight: .heavy))
                    .foregroundStyle(RX.Palette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, fraction: Double, date: Date) {
        let peaks = app.waveforms[song.id]?.peaks ?? []
        let columns = max(1, Int(size.width / 3))
        let mid = size.height / 2
        let scanX = size.width * fraction
        var merged = Path(), guitar = Path(), band = Path()
        for i in 0..<columns {
            let x = CGFloat(i) * 3 + 1
            let peak: CGFloat
            if peaks.isEmpty {
                peak = 0.2
            } else {
                let lo = i * peaks.count / columns, hi = max(lo + 1, (i + 1) * peaks.count / columns)
                peak = CGFloat(peaks[lo..<min(hi, peaks.count)].max() ?? 0)
            }
            let h = max(1, peak * mid * 0.9)
            if x > scanX {
                merged.move(to: CGPoint(x: x, y: mid - h)); merged.addLine(to: CGPoint(x: x, y: mid + h))
            } else {
                // Separated part: an impression of the split, not a measurement (that comes after).
                band.move(to: CGPoint(x: x, y: mid - h)); band.addLine(to: CGPoint(x: x, y: mid + h))
                guitar.move(to: CGPoint(x: x, y: mid - h * 0.6)); guitar.addLine(to: CGPoint(x: x, y: mid + h * 0.6))
            }
        }
        let style = StrokeStyle(lineWidth: 2, lineCap: .round)
        context.stroke(merged, with: .color(RX.Palette.textTertiary), style: style)
        context.stroke(band, with: .color(RX.Palette.cyan.opacity(0.7)), style: style)
        context.stroke(guitar, with: .color(RX.Palette.fire), style: style)
        if fraction > 0 {
            var glow = context
            glow.addFilter(.shadow(color: RX.Palette.cyan, radius: 10))
            let flicker = 0.75 + 0.25 * sin(date.timeIntervalSinceReferenceDate * 9)
            glow.fill(Path(CGRect(x: scanX, y: 0, width: 2, height: size.height)), with: .color(RX.Palette.cyan.opacity(flicker)))
        }
    }
}
