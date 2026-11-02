import DesignSystem
import MusicCore
import SwiftUI

/// The guitar neck on the arena floor, Guitar Hero style: six strings in perspective (low E on the
/// right), guessed notes travelling toward the strike line with their fret number. Notes the model
/// was unsure about are dimmed; when a riff is caught in the ring, its notes repeat with the loop.
enum NeckScene {
    /// Seconds of music between the horizon and the strike line.
    static let lookahead: Seconds = 2.4

    struct Placed {
        var note: GuessedNote
        var start: Seconds
        var end: Seconds
    }

    static func draw(_ context: inout GraphicsContext, size: CGSize, now: Seconds, loop: LoopRegion?, notes: NoteMap,
                     map: RiffMap, pulse: Double, guitarAlpha: Double) {
        let horizon = size.height * 0.62, strike = size.height * 0.84
        let bottomHalf = size.width * 0.42, topHalf = size.width * 0.09
        let cx = size.width / 2
        // Depth 0 = strike line, 1 = horizon, with perspective.
        func depth(_ t: Seconds) -> Double { (t - now) / lookahead }
        func perspective(_ z: Double) -> CGFloat {
            let a = 0.55
            return CGFloat((1 + a) * z / (z + a))
        }
        func y(_ z: Double) -> CGFloat { strike - (strike - horizon) * perspective(max(z, -0.08)) }
        func halfWidth(_ z: Double) -> CGFloat { bottomHalf + (topHalf - bottomHalf) * perspective(max(z, -0.08)) }
        /// String 0 (low E) on the right, 5 (high e) on the left.
        func x(string: Int, z: Double) -> CGFloat {
            let u = CGFloat(string) / 5
            return cx + halfWidth(z) * (1 - 2 * u) * 0.86
        }

        // Neck body.
        var body = Path()
        body.move(to: CGPoint(x: cx - topHalf, y: horizon))
        body.addLine(to: CGPoint(x: cx + topHalf, y: horizon))
        body.addLine(to: CGPoint(x: cx + bottomHalf, y: strike + 14))
        body.addLine(to: CGPoint(x: cx - bottomHalf, y: strike + 14))
        body.closeSubpath()
        context.fill(body, with: .linearGradient(Gradient(colors: [RX.Palette.base.opacity(0.2), RX.Palette.surface.opacity(0.95)]),
                                                 startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: strike)))
        var edges = Path()
        edges.move(to: CGPoint(x: cx - topHalf, y: horizon)); edges.addLine(to: CGPoint(x: cx - bottomHalf, y: strike + 14))
        edges.move(to: CGPoint(x: cx + topHalf, y: horizon)); edges.addLine(to: CGPoint(x: cx + bottomHalf, y: strike + 14))
        context.stroke(edges, with: .color(RX.Palette.magenta.opacity(0.35 + 0.3 * pulse)), lineWidth: 1.5)

        // Beat lines travelling toward you (like frets passing).
        let lo = BeatGrid.firstIndex(after: now, in: map.beats)
        let hi = BeatGrid.firstIndex(after: now + lookahead, in: map.beats)
        if lo < hi {
            for index in lo..<hi {
                let t = map.beats[index]
                let z = depth(t)
                let isBar = map.bars.contains { abs($0 - t) < 0.02 }
                var line = Path()
                line.move(to: CGPoint(x: cx - halfWidth(z), y: y(z)))
                line.addLine(to: CGPoint(x: cx + halfWidth(z), y: y(z)))
                context.stroke(line, with: .color(RX.Palette.magenta.opacity((isBar ? 0.35 : 0.14) * (1 - z * 0.6))),
                               lineWidth: isBar ? 1.5 : 1)
            }
        }

        // Strings (thicker for the low ones).
        let visible = placed(notes: notes, now: now, loop: loop)
        for string in 0..<6 {
            let active = visible.contains { $0.note.string == string && $0.start <= now && now < $0.end }
            var line = Path()
            line.move(to: CGPoint(x: x(string: string, z: 1), y: horizon))
            line.addLine(to: CGPoint(x: x(string: string, z: -0.08), y: strike + 14))
            let width = CGFloat(2.2 - 0.25 * Double(string))
            if active {
                var glow = context
                glow.addFilter(.shadow(color: RX.Palette.fire, radius: 6))
                glow.stroke(line, with: .color(RX.Palette.fireLight.opacity(guitarAlpha)), lineWidth: width + 0.8)
            } else {
                context.stroke(line, with: .color(RX.Palette.textSecondary.opacity(0.35)), lineWidth: width)
            }
        }

        // Strike line.
        var strikeLine = Path()
        strikeLine.move(to: CGPoint(x: cx - bottomHalf, y: strike))
        strikeLine.addLine(to: CGPoint(x: cx + bottomHalf, y: strike))
        var glow = context
        glow.addFilter(.shadow(color: RX.Palette.magenta, radius: CGFloat(6 + 6 * pulse)))
        glow.stroke(strikeLine, with: .color(RX.Palette.textPrimary.opacity(0.85)), lineWidth: 2)

        // Notes, far to near so near ones draw on top.
        for item in visible.sorted(by: { $0.start > $1.start }) {
            let z0 = depth(item.start), z1 = depth(item.end)
            guard z0 <= 1.02, z1 >= -0.08 else { continue }
            let note = item.note
            let color = note.sure ? RX.Palette.fire : RX.Palette.textSecondary
            let alpha = (note.sure ? 1 : 0.4) * guitarAlpha * min(1, (1.02 - z0) * 4)
            // Sustain tail along the string.
            if z1 - z0 > 0.08 {
                var tail = Path()
                tail.move(to: CGPoint(x: x(string: note.string, z: max(z0, 0)), y: y(max(z0, 0))))
                tail.addLine(to: CGPoint(x: x(string: note.string, z: min(z1, 1)), y: y(min(z1, 1))))
                context.stroke(tail, with: .color(color.opacity(alpha * 0.45)),
                               style: StrokeStyle(lineWidth: 6 * (1 - 0.6 * CGFloat(max(z0, 0))), lineCap: .round))
            }
            guard z0 >= -0.08 else { continue }
            let scale = 1 - 0.68 * perspective(max(z0, 0))
            let center = CGPoint(x: x(string: note.string, z: z0), y: y(z0))
            let gem = CGRect(x: center.x - 15 * scale, y: center.y - 11 * scale, width: 30 * scale, height: 22 * scale)
            let hitting = item.start <= now && now - item.start < 0.12
            var gemContext = context
            if hitting { gemContext.addFilter(.shadow(color: RX.Palette.fireLight, radius: 10)) }
            gemContext.fill(Path(roundedRect: gem, cornerRadius: 6 * scale),
                            with: .color((hitting ? RX.Palette.fireLight : color).opacity(alpha)))
            gemContext.stroke(Path(roundedRect: gem, cornerRadius: 6 * scale),
                              with: .color(.white.opacity(alpha * (note.sure ? 0.7 : 0.3))), lineWidth: 1)
            if scale > 0.45 {
                context.draw(Text("\(note.fret)").font(.rxHUD(13 * scale, weight: .heavy))
                                .foregroundStyle(note.sure ? Color(hex: 0x1A0610) : RX.Palette.textPrimary.opacity(alpha)),
                             at: center)
            }
        }
    }

    /// Notes to show between just behind the strike line and the horizon. Inside a caught riff, the
    /// riff's notes are repeated for the coming laps instead of showing what follows in the song.
    static func placed(notes: NoteMap, now: Seconds, loop: LoopRegion?) -> [Placed] {
        let from = now - 0.2, to = now + lookahead
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
