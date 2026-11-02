import DesignSystem
import MusicCore
import SwiftUI

/// The guitar neck on the arena floor, Guitar Hero style: six coloured lanes in perspective (low E on
/// the right), guessed notes travelling toward targets on the strike line with their fret number,
/// a flame on every hit. Notes the model was unsure about are hollow; when a riff is caught in the
/// ring, its notes repeat with the loop.
enum NeckScene {
    /// Seconds of music between the horizon and the strike line.
    static let lookahead: Seconds = 2.4

    /// One colour per string, low E first.
    static let laneColors: [Color] = [
        Color(hex: 0xFF4D5E), Color(hex: 0xFF8A2B), Color(hex: 0xFFC83D),
        Color(hex: 0x3DE38A), Color(hex: 0x33C8FF), Color(hex: 0xB46BFF),
    ]

    struct Placed {
        var note: GuessedNote
        var start: Seconds
        var end: Seconds
    }

    private struct Frame {
        let size: CGSize
        let now: Seconds
        var horizon: CGFloat { size.height * 0.62 }
        var strike: CGFloat { size.height * 0.84 }
        var bottomHalf: CGFloat { size.width * 0.44 }
        var topHalf: CGFloat { size.width * 0.085 }
        var cx: CGFloat { size.width / 2 }
        /// Bottom edge of the neck, a little past the strike line.
        var near: Double { -0.1 }

        func depth(_ t: Seconds) -> Double { (t - now) / NeckScene.lookahead }
        func perspective(_ z: Double) -> CGFloat {
            let a = 0.55
            let z = max(z, near)
            return CGFloat((1 + a) * z / (z + a))
        }
        func y(_ z: Double) -> CGFloat { strike - (strike - horizon) * perspective(z) }
        func halfWidth(_ z: Double) -> CGFloat { bottomHalf + (topHalf - bottomHalf) * perspective(z) }
        /// String 0 (low E) on the right, 5 (high e) on the left.
        func x(string: Int, z: Double) -> CGFloat {
            let u = CGFloat(string) / 5
            return cx + halfWidth(z) * (1 - 2 * u) * 0.84
        }
        func scale(_ z: Double) -> CGFloat { 1 - 0.7 * perspective(max(z, 0)) }
    }

    static func draw(_ context: inout GraphicsContext, size: CGSize, now: Seconds, loop: LoopRegion?, notes: NeckNotes,
                     map: RiffMap, pulse: Double, guitarAlpha: Double) {
        let f = Frame(size: size, now: now)
        let visible = placed(notes: notes, now: now, loop: loop)
        drawBody(&context, f, pulse: pulse)
        drawFrets(&context, f, map: map, loop: loop)
        drawLanes(&context, f, visible: visible, guitarAlpha: guitarAlpha)
        drawTargets(&context, f, visible: visible, pulse: pulse, guitarAlpha: guitarAlpha)
        drawNotes(&context, f, visible: visible, guitarAlpha: guitarAlpha)
        drawHand(&context, f, visible: visible)
        drawTag(&context, f)
    }

    // MARK: Layers

    private static func drawBody(_ context: inout GraphicsContext, _ f: Frame, pulse: Double) {
        // Glow where the neck meets the horizon.
        context.fill(Path(ellipseIn: CGRect(x: f.cx - f.size.width * 0.35, y: f.horizon - 40, width: f.size.width * 0.7, height: 80)),
                     with: .radialGradient(Gradient(colors: [RX.Palette.magenta.opacity(0.28 + 0.2 * pulse), .clear]),
                                           center: CGPoint(x: f.cx, y: f.horizon), startRadius: 0, endRadius: f.size.width * 0.35))
        let bottom = f.y(f.near)
        var body = Path()
        body.move(to: CGPoint(x: f.cx - f.topHalf, y: f.horizon))
        body.addLine(to: CGPoint(x: f.cx + f.topHalf, y: f.horizon))
        body.addLine(to: CGPoint(x: f.cx + f.halfWidth(f.near), y: bottom))
        body.addLine(to: CGPoint(x: f.cx - f.halfWidth(f.near), y: bottom))
        body.closeSubpath()
        context.fill(body, with: .linearGradient(
            Gradient(stops: [.init(color: Color(hex: 0x120B2E).opacity(0.3), location: 0),
                             .init(color: Color(hex: 0x1A1040).opacity(0.92), location: 0.55),
                             .init(color: Color(hex: 0x0C0820), location: 1)]),
            startPoint: CGPoint(x: 0, y: f.horizon), endPoint: CGPoint(x: 0, y: bottom)))

        // Side rails with light running toward you.
        for side in [-1.0, 1.0] {
            var rail = Path()
            rail.move(to: CGPoint(x: f.cx + CGFloat(side) * f.topHalf, y: f.horizon))
            rail.addLine(to: CGPoint(x: f.cx + CGFloat(side) * f.halfWidth(f.near), y: bottom))
            var glow = context
            glow.addFilter(.shadow(color: RX.Palette.magenta, radius: 6))
            glow.stroke(rail, with: .linearGradient(Gradient(colors: [RX.Palette.magenta.opacity(0.2), RX.Palette.magenta]),
                                                    startPoint: CGPoint(x: 0, y: f.horizon), endPoint: CGPoint(x: 0, y: bottom)),
                        lineWidth: 2.5)
            for k in 0..<4 {
                let z = 1 - ((f.now * 0.9 + Double(k) / 4).truncatingRemainder(dividingBy: 1))
                let y0 = f.y(z), y1 = f.y(z - 0.06)
                let x0 = f.cx + CGFloat(side) * f.halfWidth(z), x1 = f.cx + CGFloat(side) * f.halfWidth(z - 0.06)
                var streak = Path()
                streak.move(to: CGPoint(x: x0, y: y0))
                streak.addLine(to: CGPoint(x: x1, y: y1))
                context.stroke(streak, with: .color(.white.opacity(0.75 * (1 - z * 0.7))),
                               style: StrokeStyle(lineWidth: 3 * f.scale(z) + 1, lineCap: .round))
            }
        }
    }

    private static func drawFrets(_ context: inout GraphicsContext, _ f: Frame, map: RiffMap, loop: LoopRegion?) {
        let times = beatTimes(map: map, now: f.now, loop: loop)
        for (t, isBar) in times {
            let z = f.depth(t)
            guard z >= f.near, z <= 1 else { continue }
            let y = f.y(z), half = f.halfWidth(z)
            var fret = Path()
            fret.move(to: CGPoint(x: f.cx - half, y: y))
            fret.addLine(to: CGPoint(x: f.cx + half, y: y))
            let fade = 1 - z * 0.65
            context.stroke(fret, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.05), .white.opacity((isBar ? 0.55 : 0.22) * fade), .white.opacity(0.05)]),
                startPoint: CGPoint(x: f.cx - half, y: y), endPoint: CGPoint(x: f.cx + half, y: y)),
                lineWidth: (isBar ? 2.2 : 1) * f.scale(z) + 0.5)
            if isBar {
                // Pearl inlays between the frets, like a real neck.
                let r = 4 * f.scale(z) + 1
                for dx in [-0.28, 0.28] {
                    let p = CGPoint(x: f.cx + half * CGFloat(dx), y: y - 10 * f.scale(z))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 0.6, width: 2 * r, height: 1.2 * r)),
                                 with: .color(.white.opacity(0.22 * fade)))
                }
            }
        }
    }

    private static func drawLanes(_ context: inout GraphicsContext, _ f: Frame, visible: [Placed], guitarAlpha: Double) {
        for string in 0..<6 {
            let color = laneColors[string]
            let active = visible.contains { $0.note.string == string && $0.start <= f.now && f.now < $0.end }
            var line = Path()
            line.move(to: CGPoint(x: f.x(string: string, z: 1), y: f.horizon))
            line.addLine(to: CGPoint(x: f.x(string: string, z: f.near), y: f.y(f.near)))
            let width = CGFloat(2.6 - 0.3 * Double(string))
            if active {
                var glow = context
                glow.addFilter(.shadow(color: color, radius: 8))
                glow.stroke(line, with: .color(color.opacity(guitarAlpha)), lineWidth: width + 1.2)
            } else {
                context.stroke(line, with: .linearGradient(Gradient(colors: [color.opacity(0.08), color.opacity(0.45)]),
                                                           startPoint: CGPoint(x: 0, y: f.horizon), endPoint: CGPoint(x: 0, y: f.strike)),
                               lineWidth: width)
            }
        }
    }

    private static func drawTargets(_ context: inout GraphicsContext, _ f: Frame, visible: [Placed], pulse: Double,
                                    guitarAlpha: Double) {
        // The strike line.
        var strike = Path()
        strike.move(to: CGPoint(x: f.cx - f.halfWidth(0), y: f.strike))
        strike.addLine(to: CGPoint(x: f.cx + f.halfWidth(0), y: f.strike))
        var glow = context
        glow.addFilter(.shadow(color: RX.Palette.magenta, radius: CGFloat(5 + 6 * pulse)))
        glow.stroke(strike, with: .color(.white.opacity(0.6)), lineWidth: 1.5)

        for string in 0..<6 {
            let color = laneColors[string]
            let center = CGPoint(x: f.x(string: string, z: 0), y: f.strike)
            let hit = visible.filter { $0.note.string == string && $0.start <= f.now && f.now - $0.start < 0.35 }
                .map { f.now - $0.start }.min()
            let held = visible.contains { $0.note.string == string && $0.start <= f.now && f.now < $0.end }
            let rx: CGFloat = 19, ry: CGFloat = 12
            let ring = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry))
            context.fill(ring, with: .color(Color(hex: 0x07060F).opacity(0.85)))
            if held || hit != nil {
                var lit = context
                lit.addFilter(.shadow(color: color, radius: 12))
                lit.fill(ring, with: .radialGradient(Gradient(colors: [.white, color]), center: center, startRadius: 0, endRadius: rx))
            }
            context.stroke(ring, with: .color(color.opacity(held ? 1 : 0.75)), lineWidth: 2.5)
            context.stroke(Path(ellipseIn: CGRect(x: center.x - rx * 0.55, y: center.y - ry * 0.55, width: rx * 1.1, height: ry * 1.1)),
                           with: .color(color.opacity(0.35)), lineWidth: 1)
            // Flame on the hit: rises and fades in a third of a second.
            if let age = hit {
                let k = 1 - age / 0.35
                let height = CGFloat(70 * (0.4 + 0.6 * k))
                let flame = CGRect(x: center.x - rx * 0.9, y: center.y - height, width: rx * 1.8, height: height)
                var fire = context
                fire.blendMode = .plusLighter
                fire.fill(Path(ellipseIn: flame), with: .linearGradient(
                    Gradient(colors: [.clear, color.opacity(0.5 * k * guitarAlpha), RX.Palette.fireLight.opacity(0.9 * k * guitarAlpha)]),
                    startPoint: CGPoint(x: center.x, y: flame.minY), endPoint: CGPoint(x: center.x, y: flame.maxY)))
                let spread = CGFloat(2 - k)
                fire.fill(Path(ellipseIn: CGRect(x: center.x - rx * 1.6 * spread, y: center.y - ry * 1.2,
                                                 width: rx * 3.2 * spread, height: ry * 2.4)),
                          with: .radialGradient(Gradient(colors: [color.opacity(0.55 * k), .clear]), center: center,
                                                startRadius: 0, endRadius: rx * 2.4))
            }
        }
    }

    private static func drawNotes(_ context: inout GraphicsContext, _ f: Frame, visible: [Placed], guitarAlpha: Double) {
        // Sustain tails first, then gems far to near.
        for item in visible {
            let z0 = max(f.depth(item.start), 0), z1 = min(f.depth(item.end), 1)
            guard z1 - z0 > 0.06 else { continue }
            let color = laneColors[item.note.string]
            var tail = Path()
            tail.move(to: CGPoint(x: f.x(string: item.note.string, z: z0), y: f.y(z0)))
            tail.addLine(to: CGPoint(x: f.x(string: item.note.string, z: z1), y: f.y(z1)))
            let alpha = (item.note.sure ? 0.55 : 0.25) * guitarAlpha
            context.stroke(tail, with: .color(color.opacity(alpha)),
                           style: StrokeStyle(lineWidth: 9 * f.scale(z0), lineCap: .round))
            context.stroke(tail, with: .color(.white.opacity(alpha * 0.8)),
                           style: StrokeStyle(lineWidth: 2 * f.scale(z0), lineCap: .round))
        }
        for item in visible.sorted(by: { $0.start > $1.start }) {
            let z = f.depth(item.start)
            guard z >= -0.04, z <= 1.02 else { continue }
            let note = item.note
            let color = laneColors[note.string]
            let s = f.scale(z)
            let fadeIn = min(1, (1.02 - z) * 5)
            let alpha = guitarAlpha * fadeIn * (z < 0 ? max(0, 1 + z * 25) : 1)
            let center = CGPoint(x: f.x(string: note.string, z: z), y: f.y(z))
            let rx = 17 * s, ry = 11.5 * s
            let gem = CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry)
            if note.sure {
                // Solid gem: dark rim, coloured body, glossy top, the fret number in the middle.
                context.fill(Path(ellipseIn: gem.offsetBy(dx: 0, dy: 3 * s)), with: .color(.black.opacity(0.45 * alpha)))
                var body = context
                body.addFilter(.shadow(color: color.opacity(0.8 * alpha), radius: 6 * s))
                body.fill(Path(ellipseIn: gem), with: .radialGradient(
                    Gradient(colors: [color.opacity(alpha), color.mix(with: .black, by: 0.35).opacity(alpha)]),
                    center: CGPoint(x: center.x, y: center.y - ry * 0.4), startRadius: 0, endRadius: rx * 1.2))
                context.stroke(Path(ellipseIn: gem), with: .color(.white.opacity(0.75 * alpha)), lineWidth: max(1, 1.6 * s))
                context.fill(Path(ellipseIn: CGRect(x: center.x - rx * 0.6, y: center.y - ry * 0.85, width: rx * 1.2, height: ry * 0.75)),
                             with: .color(.white.opacity(0.35 * alpha)))
                if s > 0.42 {
                    context.draw(Text("\(note.fret)").font(.rxBig(14 * s)).foregroundStyle(Color(hex: 0x14081F).opacity(alpha)),
                                 at: CGPoint(x: center.x, y: center.y + 0.5 * s))
                }
                drawLetter(&context, note: note, center: center, ry: ry, scale: s, color: color, alpha: alpha)
            } else {
                // Unsure: hollow, so you know to trust your ear here.
                context.stroke(Path(ellipseIn: gem), with: .color(color.opacity(0.7 * alpha)),
                               style: StrokeStyle(lineWidth: max(1, 2 * s), dash: [4 * s, 3 * s]))
                if s > 0.42 {
                    context.draw(Text("\(note.fret)").font(.rxHUD(12 * s, weight: .heavy)).foregroundStyle(color.opacity(0.8 * alpha)),
                                 at: center)
                }
                drawLetter(&context, note: note, center: center, ry: ry, scale: s, color: color, alpha: alpha * 0.6)
            }
        }
    }

    /// The note's name (E, G♯…) under the gem, once it is close enough to read.
    private static func drawLetter(_ context: inout GraphicsContext, note: GuessedNote, center: CGPoint, ry: CGFloat,
                                   scale: CGFloat, color: Color, alpha: Double) {
        guard scale > 0.55 else { return }
        let name = NoteNaming.letters.name(of: MIDINote(unchecked: note.midi).pitchClass)
        context.draw(Text(name).font(.rxHUD(10 * scale, weight: .heavy)).foregroundStyle(color.opacity(alpha)),
                     at: CGPoint(x: center.x, y: center.y + ry + 8 * scale))
    }

    /// "MÃO NA CASA 5": where the hand should sit for the next notes.
    private static func drawHand(_ context: inout GraphicsContext, _ f: Frame, visible: [Placed]) {
        let upcoming = visible.filter { $0.start >= f.now - 0.1 && $0.start <= f.now + 1.2 && $0.note.fret > 0 && $0.note.sure }
        guard let lowest = upcoming.map(\.note.fret).min() else { return }
        let text = Text("MÃO NA CASA \(lowest)").font(.rxHUD(10)).foregroundStyle(RX.Palette.textPrimary)
        let point = CGPoint(x: f.cx, y: f.strike + 30)
        context.fill(Path(roundedRect: CGRect(x: point.x - 62, y: point.y - 11, width: 124, height: 22), cornerRadius: 4),
                     with: .color(Color(hex: 0x07060F).opacity(0.8)))
        context.stroke(Path(roundedRect: CGRect(x: point.x - 62, y: point.y - 11, width: 124, height: 22), cornerRadius: 4),
                       with: .color(RX.Palette.magenta.opacity(0.6)), lineWidth: 1)
        context.draw(text, at: point)
    }

    /// A quiet reminder at the far end of the neck that all of this is a guess.
    private static func drawTag(_ context: inout GraphicsContext, _ f: Frame) {
        context.draw(Text("NOTAS ESTIMADAS").font(.rxHUD(8)).tracking(2).foregroundStyle(RX.Palette.textTertiary),
                     at: CGPoint(x: f.cx, y: f.horizon - 12))
    }

    // MARK: Time

    /// Beat times on the neck, repeating with a caught riff.
    private static func beatTimes(map: RiffMap, now: Seconds, loop: LoopRegion?) -> [(Seconds, Bool)] {
        let isBar: (Seconds) -> Bool = { t in map.bars.contains { abs($0 - t) < 0.02 } }
        func beats(_ from: Seconds, _ to: Seconds) -> [Seconds] {
            let lo = BeatGrid.firstIndex(after: from, in: map.beats), hi = BeatGrid.firstIndex(after: to, in: map.beats)
            return lo < hi ? Array(map.beats[lo..<hi]) : []
        }
        let to = now + lookahead
        guard let loop, loop.contains(now) else { return beats(now - 0.3, to).map { ($0, isBar($0)) } }
        let inLoop = beats(loop.start - 0.01, loop.end - 0.01)
        var out: [(Seconds, Bool)] = []
        var shift = 0.0
        while loop.start + shift <= to {
            for t in inLoop where t + shift >= now - 0.3 && t + shift <= to { out.append((t + shift, isBar(t))) }
            shift += loop.length
        }
        return out
    }

    /// Notes to show between just behind the strike line and the horizon. Inside a caught riff, the
    /// riff's notes are repeated for the coming laps instead of showing what follows in the song.
    static func placed(notes: NeckNotes, now: Seconds, loop: LoopRegion?) -> [Placed] {
        let from = now - 0.4, to = now + lookahead
        guard let loop, loop.contains(now) else {
            return notes.notes(from: from, to: to).map { Placed(note: $0, start: $0.start, end: $0.end) }
        }
        let inLoop = notes.notes(from: loop.start, to: loop.end).filter { $0.start >= loop.start - 0.02 && $0.start < loop.end }
        var out: [Placed] = []
        var shift = 0.0
        while loop.start + shift <= to {
            for note in inLoop {
                let start = note.start + shift, end = min(note.end, loop.end) + shift
                if end >= from, start <= to { out.append(Placed(note: note, start: start, end: end)) }
            }
            shift += loop.length
        }
        return out
    }
}
