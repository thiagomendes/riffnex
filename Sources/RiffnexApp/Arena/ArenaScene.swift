import DesignSystem
import MusicCore
import SwiftUI

/// Where things are on the practice screen, shared by drawing and gestures.
struct ArenaGeometry {
    let size: CGSize
    /// Tape pixels per second of music.
    static let pointsPerSecond: CGFloat = 74

    var cx: CGFloat { size.width / 2 }
    /// Tape baseline.
    var cy: CGFloat { size.height * 0.47 }
    var maxHeight: CGFloat { min(size.height * 0.14, 112) }
    var ringRadius: CGFloat { min(size.width * 0.23, size.height * 0.18) }
    var ringDepth: CGFloat { ringRadius * 0.36 }
    var ringCenter: CGPoint { CGPoint(x: cx, y: size.height * 0.46) }
    /// Speed meter radius.
    var meterRadius: CGFloat { ringRadius + ringDepth + 22 }

    func time(atX x: CGFloat, now: Seconds) -> Seconds { now + Double((x - cx) / Self.pointsPerSecond) }
    func x(for time: Seconds, now: Seconds) -> CGFloat { cx + CGFloat(time - now) * Self.pointsPerSecond }
}

/// Draws one frame of the arena: the tape (guitar in fire, band in cyan), the loop curling into a
/// ring, the speed meter, sparks on guitar attacks and the floor grid pulsing with the beat.
enum ArenaScene {
    struct Input {
        var now: Seconds
        var playing: Bool
        var map: RiffMap
        var loop: LoopRegion?
        var focus: Double
        var speed: Double
        var laps: Int
        var ramping: Bool
        var lapsAtSpeed: Int
        var selection: ClosedRange<Seconds>?
    }

    static func draw(_ context: inout GraphicsContext, size: CGSize, input: Input, fx: ArenaFX, dt: Double) {
        let g = ArenaGeometry(size: size)
        step(fx, dt: dt)
        let e = ease(fx.ring)
        let pulse = input.playing ? exp(-(input.map.beatPhase(at: input.now) ?? 1) * 7) : 0
        if fx.shake > 0 {
            context.translateBy(x: CGFloat(Double.random(in: -3...3) * fx.shake), y: CGFloat(Double.random(in: -3...3) * fx.shake))
        }
        let guitarAlpha = 0.12 + 0.88 * ArenaModel.guitarLevel(input.focus)
        let bandAlpha = 0.1 + 0.9 * ArenaModel.bandLevel(input.focus)

        drawFloor(&context, g: g, input: input, pulse: pulse)
        if e < 0.99 { drawTape(&context, g: g, input: input, alpha: 1 - e, guitarAlpha: guitarAlpha, bandAlpha: bandAlpha, pulse: pulse) }
        if let loop = input.loop ?? fx.lastLoop {
            if input.loop != nil { fx.lastLoop = input.loop }
            drawLoop(&context, g: g, input: input, loop: loop, e: e, guitarAlpha: guitarAlpha, bandAlpha: bandAlpha, pulse: pulse)
            if e > 0.02 { drawRingHUD(&context, g: g, input: input, e: e) }
        }
        if fx.ring == 0, fx.ringTarget == 0 { fx.lastLoop = nil }
        emitAndDrawParticles(&context, g: g, input: input, fx: fx, e: e)
        drawBanner(&context, g: g, fx: fx)
    }

    // MARK: Animation state

    private static func step(_ fx: ArenaFX, dt: Double) {
        fx.ring += (fx.ringTarget - fx.ring) * min(1, dt * 5.5)
        if abs(fx.ringTarget - fx.ring) < 0.002 { fx.ring = fx.ringTarget }
        fx.bannerLife = max(0, fx.bannerLife - dt * 0.7)
        fx.shake = max(0, fx.shake - dt * 3)
        let k = dt * 60
        fx.particles = fx.particles.compactMap { p -> ArenaFX.Particle? in
            var p = p
            p.x += p.vx * k
            p.y += p.vy * k
            p.vy += 0.08 * k
            p.vx *= pow(0.985, k)
            p.life -= dt * 1.3
            return p.life > 0 ? p : nil
        }
    }

    static func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: Floor

    private static func drawFloor(_ context: inout GraphicsContext, g: ArenaGeometry, input: Input, pulse: Double) {
        let horizon = g.size.height * 0.63, bottom = g.size.height * 0.86
        var rays = Path()
        for i in -8...8 {
            rays.move(to: CGPoint(x: g.cx + CGFloat(i) * 6, y: horizon))
            rays.addLine(to: CGPoint(x: g.cx + CGFloat(i) * g.size.width * 0.16, y: bottom))
        }
        context.stroke(rays, with: .color(RX.Palette.magenta.opacity(0.18 + 0.22 * pulse)), lineWidth: 1)
        let travel: Double
        if let length = input.map.beatLength, length > 0 {
            travel = (input.now / length).truncatingRemainder(dividingBy: 1)
        } else {
            travel = (input.now * 1.6).truncatingRemainder(dividingBy: 1)
        }
        for k in 0..<7 {
            let z = (Double(k) + travel) / 7
            let y = horizon + (bottom - horizon) * CGFloat(z * z)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: g.size.width, y: y))
            context.stroke(line, with: .color(RX.Palette.magenta.opacity((0.06 + 0.26 * z) * (0.7 + 0.6 * pulse))), lineWidth: 1)
        }
        let fade = Gradient(stops: [.init(color: RX.Palette.surface, location: 0),
                                    .init(color: RX.Palette.surface.opacity(0), location: 0.25),
                                    .init(color: RX.Palette.base.opacity(0.9), location: 1)])
        context.fill(Path(CGRect(x: 0, y: horizon - 4, width: g.size.width, height: bottom - horizon + 4)),
                     with: .linearGradient(fade, startPoint: CGPoint(x: 0, y: horizon - 4), endPoint: CGPoint(x: 0, y: bottom)))
    }

    // MARK: Tape

    private static func drawTape(_ context: inout GraphicsContext, g: ArenaGeometry, input: Input, alpha: Double,
                                 guitarAlpha: Double, bandAlpha: Double, pulse: Double) {
        let now = input.now, map = input.map
        let visible = Double(g.cx / ArenaGeometry.pointsPerSecond)

        // Bar ticks and numbers.
        let tickY = g.cy + g.maxHeight + 14
        var minor = Path(), major = Path()
        let lo = BeatGrid.firstIndex(after: now - visible - 1, in: map.beats)
        let hi = BeatGrid.firstIndex(after: now + visible + 1, in: map.beats)
        if lo < hi {
            for beat in map.beats[lo..<hi] {
                let x = g.x(for: beat, now: now)
                minor.addRect(CGRect(x: x, y: tickY, width: 1, height: 5))
            }
        }
        let barLo = BeatGrid.firstIndex(after: now - visible - 1, in: map.bars)
        let barHi = BeatGrid.firstIndex(after: now + visible + 1, in: map.bars)
        if barLo < barHi {
            for index in barLo..<barHi {
                let x = g.x(for: map.bars[index], now: now)
                major.addRect(CGRect(x: x, y: tickY, width: 1, height: 10))
                context.draw(Text("\(index + 1)").font(.rxHUD(9, weight: .semibold)).foregroundStyle(RX.Palette.textTertiary.opacity(alpha)),
                             at: CGPoint(x: x + 4, y: tickY + 8), anchor: .leading)
            }
        }
        context.fill(minor, with: .color(RX.Palette.hairline.opacity(alpha)))
        context.fill(major, with: .color(RX.Palette.textTertiary.opacity(alpha)))

        // Section starts: a thin rail above the tape, broken at each new section.
        let railY = g.cy - g.maxHeight - 24
        for (index, section) in map.sections.enumerated() {
            let xa = g.x(for: section.start, now: now), xb = g.x(for: section.end, now: now)
            guard xb > 0, xa < g.size.width else { continue }
            context.fill(Path(CGRect(x: xa, y: railY, width: max(0, xb - xa - 4), height: 2)), with: .color(RX.Palette.hairline.opacity(alpha)))
            context.draw(Text("PARTE \(index + 1)").font(.rxHUD(9)).foregroundStyle(RX.Palette.textTertiary.opacity(alpha)),
                         at: CGPoint(x: max(16, min(xa + 4, xb - 70)), y: railY - 8), anchor: .leading)
        }

        // Waveform columns.
        var bandPast = Path(), bandNext = Path(), guitarPast = Path(), guitarNext = Path()
        var x: CGFloat = 1
        while x < g.size.width {
            let t = g.time(atX: x, now: now)
            defer { x += 3 }
            guard t >= 0, t <= map.duration else { continue }
            if let loop = input.loop, loop.contains(t) { continue }
            let hb = CGFloat(map.bandLevel(at: t)) * g.maxHeight
            let hg = CGFloat(map.guitarLevel(at: t)) * g.maxHeight * 0.8
            let past = t < now
            if hb > 0.5 {
                if past { addBar(&bandPast, x: x, y: g.cy, half: hb) } else { addBar(&bandNext, x: x, y: g.cy, half: hb) }
            }
            if hg > 0.5 {
                if past { addBar(&guitarPast, x: x, y: g.cy, half: hg) } else { addBar(&guitarNext, x: x, y: g.cy, half: hg) }
            }
        }
        glowStroke(&context, bandPast, color: RX.Palette.cyan, alpha: alpha * bandAlpha * 0.85)
        glowStroke(&context, bandNext, color: RX.Palette.cyan, alpha: alpha * bandAlpha * 0.38)
        glowStroke(&context, guitarPast, color: RX.Palette.fire, alpha: alpha * guitarAlpha)
        glowStroke(&context, guitarNext, color: RX.Palette.fire, alpha: alpha * guitarAlpha * 0.5)

        // Selection being drawn.
        if let selection = input.selection {
            let xa = g.x(for: selection.lowerBound, now: now), xb = g.x(for: selection.upperBound, now: now)
            let rect = CGRect(x: xa, y: g.cy - g.maxHeight - 14, width: xb - xa, height: g.maxHeight * 2 + 28)
            context.fill(Path(rect), with: .color(RX.Palette.fire.opacity(0.14)))
            context.fill(Path(CGRect(x: xa, y: rect.minY, width: 2, height: rect.height)), with: .color(RX.Palette.fireLight))
            context.fill(Path(CGRect(x: xb - 2, y: rect.minY, width: 2, height: rect.height)), with: .color(RX.Palette.fireLight))
            context.draw(Text(selectionLabel(selection, map: map)).font(.rxHUD(11)).foregroundStyle(RX.Palette.fireLight),
                         at: CGPoint(x: (xa + xb) / 2, y: rect.minY - 10))
        }

        // Laser playhead.
        let head = CGRect(x: g.cx - 1, y: g.cy - g.maxHeight - 16, width: 2, height: g.maxHeight * 2 + 32)
        var glow = context
        glow.addFilter(.shadow(color: RX.Palette.magenta, radius: CGFloat(6 + 6 * pulse)))
        glow.fill(Path(head), with: .color(RX.Palette.textPrimary.opacity(alpha)))
        var notch = Path()
        notch.move(to: CGPoint(x: g.cx - 7, y: head.minY - 5))
        notch.addLine(to: CGPoint(x: g.cx + 7, y: head.minY - 5))
        notch.addLine(to: CGPoint(x: g.cx, y: head.minY + 4))
        notch.closeSubpath()
        context.fill(notch, with: .color(RX.Palette.textPrimary.opacity(alpha)))
    }

    static func selectionLabel(_ selection: ClosedRange<Seconds>, map: RiffMap) -> String {
        guard let beat = map.beatLength, beat > 0 else { return String(format: "%.1f s", selection.upperBound - selection.lowerBound) }
        let beats = Int(((selection.upperBound - selection.lowerBound) / beat).rounded())
        if beats >= 4, beats % 4 == 0 { return beats == 4 ? "1 COMPASSO" : "\(beats / 4) COMPASSOS" }
        return beats == 1 ? "1 TEMPO" : "\(beats) TEMPOS"
    }

    private static func addBar(_ path: inout Path, x: CGFloat, y: CGFloat, half: CGFloat) {
        path.move(to: CGPoint(x: x, y: y - half))
        path.addLine(to: CGPoint(x: x, y: y + half))
    }

    private static func glowStroke(_ context: inout GraphicsContext, _ path: Path, color: Color, alpha: Double, width: CGFloat = 2) {
        guard alpha > 0.005, !path.isEmpty else { return }
        var glow = context
        glow.blendMode = .plusLighter
        glow.stroke(path, with: .color(color.opacity(alpha * 0.16)), style: StrokeStyle(lineWidth: width * 3, lineCap: .round))
        context.stroke(path, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    // MARK: Ring

    private static func drawLoop(_ context: inout GraphicsContext, g: ArenaGeometry, input: Input, loop: LoopRegion, e: Double,
                                 guitarAlpha: Double, bandAlpha: Double, pulse: Double) {
        let n = 200, now = input.now, map = input.map
        let k = g.ringDepth / g.maxHeight
        let scale = 1 + 0.035 * pulse * e
        let c = g.ringCenter
        var band = Path(), guitar = Path()
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(e) }
        for i in 0..<n {
            let t = loop.start + (Double(i) + 0.5) / Double(n) * loop.length
            let xl = g.x(for: t, now: now)
            var d = (t - now).truncatingRemainder(dividingBy: loop.length)
            if d < 0 { d += loop.length }
            let theta = -Double.pi / 2 + d / loop.length * 2 * .pi
            let cs = CGFloat(cos(theta)), sn = CGFloat(sin(theta))
            func segment(_ h: CGFloat, into path: inout Path) {
                guard h > 0.004 else { return }
                let outer = (g.ringRadius + h * g.maxHeight * k) * scale
                let inner = (g.ringRadius - h * g.maxHeight * k * 0.55) * scale
                path.move(to: CGPoint(x: lerp(xl, c.x + cs * outer), y: lerp(g.cy - h * g.maxHeight, c.y + sn * outer)))
                path.addLine(to: CGPoint(x: lerp(xl, c.x + cs * inner), y: lerp(g.cy + h * g.maxHeight, c.y + sn * inner)))
            }
            segment(CGFloat(map.bandLevel(at: t)), into: &band)
            segment(CGFloat(map.guitarLevel(at: t)) * 0.8, into: &guitar)
        }
        let width = 2 + 0.2 * CGFloat(e)
        glowStroke(&context, band, color: RX.Palette.cyan, alpha: bandAlpha * 0.8, width: width)
        glowStroke(&context, guitar, color: RX.Palette.fire, alpha: guitarAlpha, width: width)
    }

    private static func drawRingHUD(_ context: inout GraphicsContext, g: ArenaGeometry, input: Input, e: Double) {
        let c = g.ringCenter
        var hud = context
        hud.opacity = e
        // Speed meter: one segment per 5%, from 40% to 100%.
        let segments = 12, gap = 0.035
        let fraction = (input.speed - 0.4) / 0.6
        for i in 0..<segments {
            let a0 = -Double.pi / 2 + Double(i) / Double(segments) * 2 * .pi + gap
            let a1 = -Double.pi / 2 + Double(i + 1) / Double(segments) * 2 * .pi - gap
            var arc = Path()
            arc.addArc(center: c, radius: g.meterRadius, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            let lit = Double(i + 1) / Double(segments) <= fraction + 1e-6
            let color: Color = !lit ? .white.opacity(0.08) : i >= 10 ? RX.Palette.magenta : i >= 6 ? RX.Palette.fire : RX.Palette.fireLight
            if lit {
                var glow = hud
                glow.addFilter(.shadow(color: color, radius: 5))
                glow.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 7, lineCap: .butt))
            } else {
                hud.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .butt))
            }
        }
        hud.draw(Text("100%").font(.rxHUD(8)).foregroundStyle(RX.Palette.textSecondary), at: CGPoint(x: c.x, y: c.y - g.meterRadius - 12))
        // Playhead at the top of the ring.
        var glow = hud
        glow.addFilter(.shadow(color: RX.Palette.magenta, radius: 8))
        glow.fill(Path(CGRect(x: c.x - 1, y: c.y - g.ringRadius - g.ringDepth - 12, width: 2, height: g.ringDepth * 1.6 + 12)),
                  with: .color(RX.Palette.textPrimary))
        // Laps and speed.
        hud.draw(Text("\(input.laps)").font(.rxBig(g.ringRadius * 0.6))
                    .foregroundStyle(LinearGradient(colors: [.white, RX.Palette.fireLight], startPoint: .top, endPoint: .bottom)),
                 at: CGPoint(x: c.x, y: c.y - g.ringRadius * 0.12))
        hud.draw(Text(input.laps == 1 ? "VOLTA" : "VOLTAS").font(.rxHUD(10)).tracking(3).foregroundStyle(RX.Palette.textTertiary),
                 at: CGPoint(x: c.x, y: c.y + g.ringRadius * 0.3))
        hud.draw(Text("\(Int((input.speed * 100).rounded()))%").font(.rxHUD(15)).foregroundStyle(RX.Palette.fireLight),
                 at: CGPoint(x: c.x, y: c.y + g.ringRadius * 0.52))
        if input.ramping {
            for j in 0..<ArenaModel.lapsPerStep {
                let on = j < input.lapsAtSpeed
                hud.fill(Path(ellipseIn: CGRect(x: c.x - 12 + CGFloat(j) * 16, y: c.y + g.meterRadius + 24, width: 8, height: 8)),
                         with: .color(on ? RX.Palette.magenta : .white.opacity(0.15)))
            }
        } else {
            hud.draw(Text("gire o anel para mudar a velocidade").font(.caption).foregroundStyle(RX.Palette.textTertiary),
                     at: CGPoint(x: c.x, y: c.y + g.meterRadius + 28))
        }
    }

    // MARK: Particles and banner

    private static func emitAndDrawParticles(_ context: inout GraphicsContext, g: ArenaGeometry, input: Input, fx: ArenaFX, e: Double) {
        let ringTop = CGPoint(x: g.cx, y: g.ringCenter.y - g.ringRadius - g.ringDepth)
        for strength in fx.pendingSparks {
            let origin = e > 0.5 ? ringTop : CGPoint(x: g.cx, y: g.cy - CGFloat(strength) * g.maxHeight * 0.8)
            let count = strength > 0.6 ? 10 : 5
            for _ in 0..<count {
                let spread = strength > 0.6 ? 2.6 : 1.6
                let angle = -Double.pi / 2 + Double.random(in: -0.5...0.5) * spread
                let speed = (strength > 0.6 ? 2.4 : 1.4) + Double.random(in: 0...2.6)
                fx.particles.append(ArenaFX.Particle(x: Double(origin.x), y: Double(origin.y), vx: cos(angle) * speed, vy: sin(angle) * speed,
                                                     life: 1, radius: Double.random(in: 1...2.8), hot: Double.random(in: 0...1) < 0.6))
            }
        }
        fx.pendingSparks.removeAll()
        if fx.pendingBurst {
            fx.pendingBurst = false
            for i in 0..<140 {
                let angle = Double.random(in: 0...(2 * .pi)), speed = Double.random(in: 2...8)
                fx.particles.append(ArenaFX.Particle(x: Double(g.ringCenter.x), y: Double(g.ringCenter.y), vx: cos(angle) * speed, vy: sin(angle) * speed,
                                                     life: 1.4, radius: Double.random(in: 1.5...4), hot: i % 2 == 0))
            }
        }
        var sparks = context
        sparks.blendMode = .plusLighter
        for p in fx.particles {
            let color = p.hot ? RX.Palette.fire : RX.Palette.fireLight
            sparks.fill(Path(ellipseIn: CGRect(x: CGFloat(p.x - p.radius), y: CGFloat(p.y - p.radius), width: CGFloat(p.radius * 2), height: CGFloat(p.radius * 2))),
                        with: .color(color.opacity(min(1, max(0, p.life)))))
        }
    }

    private static func drawBanner(_ context: inout GraphicsContext, g: ArenaGeometry, fx: ArenaFX) {
        guard fx.bannerLife > 0 else { return }
        let t = 1 - fx.bannerLife
        let scale = 1 + 0.25 * exp(-t * 8)
        var banner = context
        banner.opacity = min(1, fx.bannerLife * 2)
        banner.translateBy(x: g.cx, y: g.size.height * 0.2)
        banner.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        banner.addFilter(.shadow(color: RX.Palette.magenta, radius: 10))
        banner.draw(Text(fx.bannerText).font(.rxBig(28)).foregroundStyle(RX.brandGradient), at: .zero)
    }
}
