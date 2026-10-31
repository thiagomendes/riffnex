import DesignSystem
import MusicCore
import SwiftUI

/// The default practice view: the neck seen from above, like a highway. Each string is a lane,
/// notes travel toward the strike line with their fret number on them, and the chord name rides
/// alongside. By default the low E is on the right (the owner's preference; configurable).
struct HighwayView: View {
    let layout: TabLayout
    let chords: [ChordEvent]
    let beats: [Seconds]
    let bars: [Seconds]
    let time: Seconds
    var lowStringOnRight = true
    /// Seconds of music visible between the strike line and the horizon (scaled by speed upstream).
    var horizon: Seconds = 2.4

    static let stringColors: [Color] = [
        Color(hex: 0xFF5C6C), Color(hex: 0xF5B946), Color(hex: 0x4ADE9B),
        Color(hex: 0x3FE0E8), Color(hex: 0x3D7BFF), Color(hex: 0xB48CFF),
    ]
    static let stringNames = ["Mi", "Lá", "Ré", "Sol", "Si", "mi"]

    var body: some View {
        Canvas { context, size in
            draw(&context, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel("Pista de notas")
        .accessibilityValue(accessibilityText)
    }

    private struct Geometry {
        let strikeY: CGFloat
        let topY: CGFloat
        let laneWidth: CGFloat
        let centerX: CGFloat
    }

    private let perspective: Double = 1.6

    private func depth(_ z: Double) -> Double { (1 + perspective) * z / (1 + perspective * z) }

    private func lane(_ string: Int) -> Double {
        let index = lowStringOnRight ? 5 - string : string
        return Double(index) - 2.5
    }

    private func project(string: Int, z: Double, _ g: Geometry) -> (x: CGFloat, y: CGFloat, scale: CGFloat) {
        let f = depth(min(max(z, 0), 1))
        let scale = CGFloat(1 - 0.68 * f)
        return (g.centerX + CGFloat(lane(string)) * g.laneWidth * scale,
                g.strikeY - (g.strikeY - g.topY) * CGFloat(f), scale)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let g = Geometry(strikeY: size.height * 0.82, topY: size.height * 0.04,
                         laneWidth: min(size.width * 0.145, 64), centerX: size.width / 2)
        let half = g.laneWidth / 2

        // Road.
        let nearL = project(string: lowStringOnRight ? 5 : 0, z: 0, g)
        let nearR = project(string: lowStringOnRight ? 0 : 5, z: 0, g)
        let farL = project(string: lowStringOnRight ? 5 : 0, z: 1, g)
        let farR = project(string: lowStringOnRight ? 0 : 5, z: 1, g)
        var road = Path()
        road.move(to: CGPoint(x: nearL.x - half, y: g.strikeY + 26))
        road.addLine(to: CGPoint(x: nearR.x + half, y: g.strikeY + 26))
        road.addLine(to: CGPoint(x: farR.x + half * 0.32, y: g.topY))
        road.addLine(to: CGPoint(x: farL.x - half * 0.32, y: g.topY))
        road.closeSubpath()
        context.fill(road, with: .linearGradient(Gradient(colors: [RX.Palette.violet.opacity(0.02), RX.Palette.violet.opacity(0.22)]),
                                                 startPoint: CGPoint(x: 0, y: g.topY), endPoint: CGPoint(x: 0, y: g.strikeY + 26)))

        // Beat and bar lines.
        let barSet = Set(bars.map { Int(($0 * 100).rounded()) })
        for beat in beats where beat >= time && beat < time + horizon {
            let z = (beat - time) / horizon
            let a = project(string: lowStringOnRight ? 5 : 0, z: z, g)
            let b = project(string: lowStringOnRight ? 0 : 5, z: z, g)
            let isBar = barSet.contains(Int((beat * 100).rounded())) || barSet.contains(Int((beat * 100).rounded()) - 1)
                || barSet.contains(Int((beat * 100).rounded()) + 1)
            var line = Path()
            line.move(to: CGPoint(x: a.x - half * a.scale, y: a.y))
            line.addLine(to: CGPoint(x: b.x + half * b.scale, y: b.y))
            context.stroke(line, with: .color(RX.Palette.textPrimary.opacity(isBar ? 0.3 : 0.09)), lineWidth: isBar ? 2 : 1)
        }

        // Lanes.
        for string in 0..<6 {
            let a = project(string: string, z: 0, g)
            let b = project(string: string, z: 1, g)
            var line = Path()
            line.move(to: CGPoint(x: a.x, y: g.strikeY + 26))
            line.addLine(to: CGPoint(x: b.x, y: b.y))
            context.stroke(line, with: .color(Self.stringColors[string].opacity(0.33)), lineWidth: 1 + CGFloat(5 - string) * 0.35)
        }

        // Chord names beside the road, at the moment they start.
        let labelSide = lowStringOnRight ? 0 : 5 // the treble side, away from the low-string lane
        for chord in chords where chord.start >= time - 0.2 && chord.start < time + horizon {
            guard let symbol = chord.chord?.symbol() else { continue }
            let z = max(0, (chord.start - time) / horizon)
            let p = project(string: labelSide, z: z, g)
            let text = Text(symbol).font(.system(size: 13 * p.scale + 7, weight: .heavy, design: .rounded))
                .foregroundStyle(RX.Palette.textPrimary.opacity(chord.confidence.level == .low ? 0.45 : 0.85))
            let offset = (half * p.scale + 8) * (lowStringOnRight ? -1 : 1)
            context.draw(text, at: CGPoint(x: p.x + offset, y: p.y), anchor: lowStringOnRight ? .trailing : .leading)
        }

        // Notes: sustains, then heads.
        let visible = layout.notes(from: time - 8, to: time + horizon).filter { $0.offset > time - 0.05 }
        for note in visible {
            let z0 = max(0, (note.onset - time) / horizon)
            let z1 = min(1, (note.offset - time) / horizon)
            guard z1 > z0 else { continue }
            let a = project(string: note.position.string, z: z0, g)
            let b = project(string: note.position.string, z: z1, g)
            var tail = Path()
            tail.move(to: CGPoint(x: a.x, y: a.y))
            tail.addLine(to: CGPoint(x: b.x, y: b.y))
            context.stroke(tail, with: .color(Self.stringColors[note.position.string].opacity(0.4)),
                           style: StrokeStyle(lineWidth: 8 * a.scale, lineCap: .round))
        }
        var soundingStrings = Set<Int>()
        for note in visible {
            if note.onset <= time && time < note.offset { soundingStrings.insert(note.position.string) }
            guard note.onset >= time - 0.12 else { continue }
            let z = (note.onset - time) / horizon
            let p = project(string: note.position.string, z: z, g)
            let width = g.laneWidth * 0.84 * p.scale
            let height = max(14, 30 * p.scale)
            let rect = CGRect(x: p.x - width / 2, y: p.y - height / 2, width: width, height: height)
            let gem = Path(roundedRect: rect, cornerRadius: 8 * p.scale)
            let color = Self.stringColors[note.position.string]
            let low = note.confidence == .low
            context.fill(gem, with: .color(low ? color.opacity(0.45) : color))
            if low {
                context.stroke(gem, with: .color(RX.Palette.textPrimary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            if abs(note.onset - time) < 0.08 {
                context.stroke(gem, with: .color(.white), lineWidth: 2)
            }
            context.draw(Text("\(note.position.fret)")
                .font(.system(size: 18 * p.scale + 4, weight: .heavy, design: .monospaced))
                .foregroundStyle(RX.Palette.base), at: CGPoint(x: p.x, y: p.y))
        }

        // Strike line and string targets.
        var strike = Path()
        strike.move(to: CGPoint(x: nearL.x - half, y: g.strikeY))
        strike.addLine(to: CGPoint(x: nearR.x + half, y: g.strikeY))
        context.stroke(strike, with: .color(RX.Palette.textPrimary.opacity(0.85)), lineWidth: 2)
        for string in 0..<6 {
            let p = project(string: string, z: 0, g)
            let active = soundingStrings.contains(string)
            let radius: CGFloat = active ? 15 : 11
            let circle = Path(ellipseIn: CGRect(x: p.x - radius, y: g.strikeY - radius, width: radius * 2, height: radius * 2))
            context.fill(circle, with: .color(active ? Self.stringColors[string] : RX.Palette.surface))
            context.stroke(circle, with: .color(Self.stringColors[string]), lineWidth: 2)
            context.draw(Text(Self.stringNames[string]).font(.caption2.weight(.semibold))
                .foregroundStyle(RX.Palette.textSecondary), at: CGPoint(x: p.x, y: g.strikeY + 30))
        }
    }

    private var accessibilityText: String {
        let next = layout.upcoming(after: time, horizon: 2)
        guard !next.isEmpty else { return "Nenhuma nota chegando" }
        return next.map { "Corda \($0.position.tabLineNumber(stringCount: 6)), casa \($0.position.fret)" }.joined(separator: "; ")
    }
}

/// Where the hand should be for the next notes: "casas 3–6".
enum HandHint {
    static func text(layout: TabLayout, time: Seconds) -> String {
        let frets = layout.notes(from: time - 0.3, to: time + 1.2).map(\.position.fret).filter { $0 > 0 }
        guard let low = frets.min() else { return "cordas soltas" }
        return "casas \(low)–\(low + 3)"
    }
}
