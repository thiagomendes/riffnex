import DesignSystem
import MusicCore
import SwiftUI

/// Chord mode: the chord to play now as a big diagram, the next one smaller, and a bar that
/// empties until the change. Diagrams use the same orientation as the highway (low E on the
/// right by default), seen from above.
struct ChordModeView: View {
    let chords: [ChordEvent]
    let time: Seconds
    var lowStringOnRight = true

    var body: some View {
        let playable = chords.filter { $0.chord != nil }
        let current = playable.first { $0.start <= time && time < $0.end }
        let next = playable.first { $0.start > time }
        HStack(alignment: .bottom, spacing: RX.Space.l) {
            VStack(alignment: .leading, spacing: RX.Space.xs) {
                if let current, let chord = current.chord {
                    Text(chord.symbol()).font(.rxChord(.largeTitle)).foregroundStyle(RX.Palette.textPrimary)
                    ChordDiagramView(chord: chord, lowStringOnRight: lowStringOnRight)
                        .frame(width: 150, height: 170)
                        .opacity(current.confidence.level == .low ? 0.6 : 1)
                    ProgressView(value: min(max((time - current.start) / max(current.end - current.start, 0.01), 0), 1))
                        .tint(RX.Palette.cyan)
                        .frame(width: 150)
                        .accessibilityLabel("Tempo até a troca de acorde")
                } else {
                    Text("—").font(.rxChord(.largeTitle)).foregroundStyle(RX.Palette.textTertiary)
                    Text(next == nil ? "Sem acordes nesta parte" : "Sem acorde agora: prepare o próximo")
                        .font(.footnote).foregroundStyle(RX.Palette.textSecondary)
                        .frame(width: 150, height: 170, alignment: .topLeading)
                }
            }
            if let next, let chord = next.chord {
                VStack(alignment: .leading, spacing: RX.Space.xs) {
                    Text("depois").font(.caption).foregroundStyle(RX.Palette.textTertiary)
                    Text(chord.symbol()).font(.rxChord(.title2)).foregroundStyle(RX.Palette.textSecondary)
                    ChordDiagramView(chord: chord, lowStringOnRight: lowStringOnRight)
                        .frame(width: 90, height: 104)
                        .opacity(0.75)
                    Text("em \(max(0, Int((next.start - time).rounded(.up)))) s")
                        .font(.caption.monospacedDigit()).foregroundStyle(RX.Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A chord box seen from above: strings as vertical lines (in highway order), frets as rows,
/// dots with finger numbers, × for muted and ○ for open strings.
struct ChordDiagramView: View {
    let chord: Chord
    var lowStringOnRight = true

    var body: some View {
        Canvas { context, size in
            guard let shape = ChordShapes.shape(for: chord) else {
                context.draw(Text("sem desenho\npara este acorde").font(.caption2).foregroundStyle(RX.Palette.textTertiary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            draw(&context, size: size, shape: shape)
        }
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        guard let shape = ChordShapes.shape(for: chord) else { return "\(chord.symbol()), sem desenho" }
        let parts = shape.frets.enumerated().reversed().map { index, fret -> String in
            let number = 6 - index
            guard let fret else { return "corda \(number) abafada" }
            return fret == 0 ? "corda \(number) solta" : "corda \(number) casa \(fret)"
        }
        return "\(chord.symbol()): " + parts.joined(separator: ", ")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, shape: ChordShape) {
        let top: CGFloat = 18
        let rows = 4
        let base = shape.maxFret <= 4 ? 1 : shape.baseFret
        let left: CGFloat = base > 1 ? 22 : 10
        let width = size.width - left - 10
        let height = size.height - top - 6
        let spacing = width / 5
        let rowHeight = height / CGFloat(rows)
        func x(_ string: Int) -> CGFloat { left + spacing * CGFloat(lowStringOnRight ? 5 - string : string) }

        for row in 0...rows {
            let y = top + CGFloat(row) * rowHeight
            let isNut = row == 0 && base == 1
            context.fill(Path(CGRect(x: left, y: y - (isNut ? 2 : 0.5), width: width, height: isNut ? 4 : 1)),
                         with: .color(RX.Palette.textSecondary.opacity(isNut ? 0.9 : 0.5)))
        }
        for string in 0..<6 {
            context.fill(Path(CGRect(x: x(string) - 0.75, y: top, width: 1.5, height: height)),
                         with: .color(HighwayView.stringColors[string].opacity(0.7)))
        }
        if base > 1 {
            context.draw(Text("\(base)").font(.caption2.monospacedDigit()).foregroundStyle(RX.Palette.textTertiary),
                         at: CGPoint(x: 8, y: top + rowHeight / 2))
        }
        if let barre = shape.barreFret, barre >= base {
            let strings = shape.frets.enumerated().filter { $0.element == barre && shape.fingers[$0.offset] == 1 }.map(\.offset)
            if let lo = strings.min(), let hi = strings.max(), hi > lo {
                let y = top + (CGFloat(barre - base) + 0.5) * rowHeight
                let x0 = min(x(lo), x(hi))
                let x1 = max(x(lo), x(hi))
                context.fill(Path(roundedRect: CGRect(x: x0 - 7, y: y - 7, width: x1 - x0 + 14, height: 14), cornerRadius: 7),
                             with: .color(RX.Palette.violet))
            }
        }
        for string in 0..<6 {
            let cx = x(string)
            switch shape.frets[string] {
            case nil:
                context.draw(Text("×").font(.caption.bold()).foregroundStyle(RX.Palette.textTertiary), at: CGPoint(x: cx, y: 8))
            case 0?:
                context.stroke(Path(ellipseIn: CGRect(x: cx - 5, y: 3, width: 10, height: 10)),
                               with: .color(RX.Palette.textSecondary), lineWidth: 1.5)
            case let fret?:
                let y = top + (CGFloat(fret - base) + 0.5) * rowHeight
                let radius = min(spacing, rowHeight) * 0.36
                context.fill(Path(ellipseIn: CGRect(x: cx - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(HighwayView.stringColors[string]))
                if let finger = shape.fingers[string], finger > 0 {
                    context.draw(Text("\(finger)").font(.system(size: radius * 1.2, weight: .heavy, design: .rounded))
                        .foregroundStyle(RX.Palette.base), at: CGPoint(x: cx, y: y))
                }
            }
        }
    }
}
