import DesignSystem
import MusicCore
import SwiftUI

/// The fretboard hero: a window of frets that follows the recommended hand position, with the
/// notes sounding now (filled, finger number), the next notes (hollow, fading in), and dashed
/// outlines for low-confidence notes. Drawn with Canvas, driven per frame by the player clock.
struct FretboardView: View {
    let layout: TabLayout
    let time: Seconds
    var leftHanded = false
    var windowFrets = 6
    var anticipation: Seconds = 1.0

    var body: some View {
        Canvas { context, size in
            draw(&context, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel("Braço da guitarra")
        .accessibilityValue(accessibilityDescription)
    }

    private var stringCount: Int { layout.arrangement.tuning.stringCount }
    private var maxFret: Int { layout.arrangement.tuning.fretCount }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let nutWidth: CGFloat = 26 // room for open-string markers left of the first visible fret
        let board = CGRect(x: nutWidth, y: 10, width: size.width - nutWidth - 8, height: size.height - 34)
        let start = min(max(0, layout.windowStart(at: time, windowFrets: windowFrets)), Double(max(0, maxFret - windowFrets)))
        let fretWidth = board.width / CGFloat(windowFrets)

        func x(forFretLine fret: Double) -> CGFloat {
            let value = board.minX + CGFloat(fret - start) * fretWidth
            return leftHanded ? size.width - value : value
        }
        func y(forString string: Int) -> CGFloat {
            // High e on top, like tablature.
            let spacing = board.height / CGFloat(max(stringCount - 1, 1))
            return board.minY + spacing * CGFloat(stringCount - 1 - string)
        }
        func center(_ position: FretPosition) -> CGPoint {
            if position.fret == 0 {
                let nutX = x(forFretLine: max(start, 0))
                return CGPoint(x: nutX + (leftHanded ? 13 : -13), y: y(forString: position.string))
            }
            return CGPoint(x: x(forFretLine: Double(position.fret) - 0.5), y: y(forString: position.string))
        }

        // Wood.
        let wood = Path(roundedRect: board.insetBy(dx: 0, dy: -8), cornerRadius: 10)
        context.fill(wood, with: .linearGradient(Gradient(colors: [RX.Palette.fretboardTop, RX.Palette.fretboardBottom]),
                                                 startPoint: CGPoint(x: board.midX, y: board.minY),
                                                 endPoint: CGPoint(x: board.midX, y: board.maxY)))

        // Inlays and fret wires for the visible range.
        let firstFret = Int(start.rounded(.down))
        for fret in firstFret...(firstFret + windowFrets + 1) where fret >= 0 && fret <= maxFret {
            let lineX = x(forFretLine: Double(fret))
            guard lineX >= 0, lineX <= size.width else { continue }
            if [3, 5, 7, 9, 15, 17, 19, 21].contains(fret) || fret == 12 || fret == 24 {
                let inlayX = x(forFretLine: Double(fret) - 0.5)
                let dots: [CGFloat] = fret % 12 == 0 ? [board.minY + board.height * 0.3, board.minY + board.height * 0.7] : [board.midY]
                for dotY in dots {
                    context.fill(Path(ellipseIn: CGRect(x: inlayX - 4, y: dotY - 4, width: 8, height: 8)),
                                 with: .color(RX.Palette.fret.opacity(0.35)))
                }
            }
            let isNut = fret == 0
            context.fill(Path(CGRect(x: lineX - (isNut ? 2.5 : 1), y: board.minY - 6, width: isNut ? 5 : 2, height: board.height + 12)),
                         with: .color(isNut ? RX.Palette.string.opacity(0.8) : RX.Palette.fret))
            if fret > 0 {
                let labelX = x(forFretLine: Double(fret) - 0.5)
                context.draw(Text("\(fret)").font(.caption2.monospacedDigit()).foregroundStyle(RX.Palette.textTertiary),
                             at: CGPoint(x: labelX, y: board.maxY + 18))
            }
        }

        // Strings (thicker = lower).
        for string in 0..<stringCount {
            let thickness = 1 + CGFloat(stringCount - 1 - string) * 0.35
            let stringY = y(forString: string)
            context.fill(Path(CGRect(x: 0, y: stringY - thickness / 2, width: size.width, height: thickness)),
                         with: .color(RX.Palette.string.opacity(0.35 + 0.06 * Double(stringCount - 1 - string))))
        }

        // Upcoming notes: hollow rings that fill in as their onset approaches.
        let soundingIDs = Set(layout.sounding(at: time).map(\.noteID))
        for note in layout.upcoming(after: time, horizon: anticipation) where !soundingIDs.contains(note.noteID) {
            let p = center(note.position)
            guard p.x > -20, p.x < size.width + 20 else { continue }
            let progress = 1 - min(max((note.onset - time) / anticipation, 0), 1)
            let radius: CGFloat = 13
            let ring = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(RX.Palette.cyan.opacity(0.25 + 0.55 * progress)),
                           style: StrokeStyle(lineWidth: 2, dash: note.confidence == .low ? [3, 3] : []))
            if note.position.fret > 0 {
                context.draw(Text("\(note.finger.rawValue)").font(.caption.bold()).foregroundStyle(RX.Palette.cyan.opacity(0.4 + 0.5 * progress)), at: p)
            }
        }

        // Sounding notes.
        for note in layout.sounding(at: time) {
            let p = center(note.position)
            guard p.x > -20, p.x < size.width + 20 else { continue }
            let elapsed = time - note.onset
            let attack = max(0, 1 - elapsed / 0.18) // brief bloom on the attack
            let radius: CGFloat = 14 + CGFloat(attack) * 4
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect.insetBy(dx: -8, dy: -8)), with: .color(RX.Palette.cyan.opacity(0.18 + 0.2 * attack)))
            let low = note.confidence == .low
            context.fill(Path(ellipseIn: rect), with: .color(low ? RX.Palette.cyan.opacity(0.45) : RX.Palette.cyan))
            if low {
                context.stroke(Path(ellipseIn: rect), with: .color(RX.Palette.textPrimary.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            let label = note.position.fret == 0 ? "0" : "\(note.finger.rawValue)"
            context.draw(Text(label).font(.subheadline.bold()).foregroundStyle(RX.Palette.base), at: p)
        }

        // Barre: a bar under the index finger across the strings it covers.
        let barre = layout.sounding(at: time).filter(\.isBarre)
        if let fret = barre.first?.position.fret, barre.count >= 2 {
            let strings = barre.map(\.position.string)
            let barX = x(forFretLine: Double(fret) - 0.5)
            let top = y(forString: strings.max()!)
            let bottom = y(forString: strings.min()!)
            context.fill(Path(roundedRect: CGRect(x: barX - 5, y: top - 6, width: 10, height: bottom - top + 12), cornerRadius: 5),
                         with: .color(RX.Palette.violet.opacity(0.6)))
        }
    }

    private var accessibilityDescription: String {
        let sounding = layout.sounding(at: time)
        guard !sounding.isEmpty else { return "Nenhuma nota agora" }
        return sounding.map { note in
            let stringNumber = note.position.tabLineNumber(stringCount: stringCount)
            let fret = note.position.fret == 0 ? "solta" : "casa \(note.position.fret), dedo \(note.finger.rawValue)"
            return "Corda \(stringNumber), \(fret), \(NoteNaming.letters.name(of: note.pitch)), recomendada"
        }.joined(separator: "; ")
    }
}

/// Scrolling tablature with a fixed playhead at 30% of the width.
struct TabStripView: View {
    let layout: TabLayout
    let time: Seconds
    var secondsVisible: Seconds = 6
    var onSeek: ((Seconds) -> Void)?

    var body: some View {
        Canvas { context, size in
            draw(&context, size: size)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8).onChanged { value in
                // Dragging the tab scrubs: left drag moves forward in time.
                let perPoint = secondsVisible / 360
                onSeek?(max(0, time - Double(value.translation.width - lastTranslation) * perPoint))
                lastTranslation = value.translation.width
            }.onEnded { _ in lastTranslation = 0 }
        )
        .accessibilityElement()
        .accessibilityLabel("Tablatura")
        .accessibilityValue(layout.sounding(at: time).map { "corda \($0.position.tabLineNumber(stringCount: layout.arrangement.tuning.stringCount)) casa \($0.position.fret)" }.joined(separator: ", "))
    }

    @State private var lastTranslation: CGFloat = 0

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let strings = layout.arrangement.tuning.stringCount
        let top: CGFloat = 12
        let spacing = (size.height - 2 * top) / CGFloat(max(strings - 1, 1))
        let pointsPerSecond = size.width / secondsVisible
        let playheadX = size.width * 0.3
        func x(_ t: Seconds) -> CGFloat { playheadX + CGFloat(t - time) * pointsPerSecond }
        func y(_ string: Int) -> CGFloat { top + spacing * CGFloat(strings - 1 - string) }

        for string in 0..<strings {
            context.fill(Path(CGRect(x: 0, y: y(string) - 0.5, width: size.width, height: 1)),
                         with: .color(RX.Palette.string.opacity(0.3)))
        }
        let from = time - 0.3 * secondsVisible
        let to = time + 0.7 * secondsVisible
        for bar in layout.barLines where bar >= from && bar <= to {
            context.fill(Path(CGRect(x: x(bar) - 0.5, y: y(strings - 1), width: 1, height: y(0) - y(strings - 1))),
                         with: .color(RX.Palette.textTertiary))
        }
        for note in layout.notes(from: from - 2, to: to) {
            let noteX = x(note.onset)
            guard noteX > -30, noteX < size.width + 30 else { continue }
            let past = note.offset < time
            let now = note.onset <= time && time < note.offset
            let sustainEnd = min(x(note.offset), size.width)
            if sustainEnd > noteX + 12 {
                context.fill(Path(CGRect(x: noteX + 8, y: y(note.position.string) - 1.5, width: sustainEnd - noteX - 8, height: 3)),
                             with: .color((now ? RX.Palette.cyan : RX.Palette.violet).opacity(past ? 0.15 : 0.35)))
            }
            let label = Text("\(note.position.fret)")
                .font(.rxTab(.subheadline).weight(.bold))
                .foregroundStyle(now ? RX.Palette.cyan : (past ? RX.Palette.textTertiary : RX.Palette.textPrimary))
            let resolved = context.resolve(label)
            let labelSize = resolved.measure(in: size)
            let background = CGRect(x: noteX - labelSize.width / 2 - 3, y: y(note.position.string) - labelSize.height / 2,
                                    width: labelSize.width + 6, height: labelSize.height)
            context.fill(Path(roundedRect: background, cornerRadius: 4), with: .color(RX.Palette.surface))
            if note.confidence == .low {
                context.stroke(Path(roundedRect: background, cornerRadius: 4), with: .color(RX.Palette.textTertiary),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            context.draw(resolved, at: CGPoint(x: noteX, y: y(note.position.string)))
        }
        context.fill(Path(CGRect(x: playheadX - 1, y: 0, width: 2, height: size.height)), with: .color(RX.Palette.cyan.opacity(0.8)))
    }
}
