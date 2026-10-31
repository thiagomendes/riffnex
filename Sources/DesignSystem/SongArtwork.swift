import MusicCore
import SwiftUI
import UIKit

/// Song artwork: the file's embedded image when it has one, otherwise a cover generated from the
/// song's own waveform (a radial plot in the brand gradient), so every song gets a unique, meaningful image.
public struct SongArtwork: View {
    let imageURL: URL?
    let waveform: WaveformOverview?
    let seed: UUID
    let cornerRadius: CGFloat

    public init(imageURL: URL?, waveform: WaveformOverview?, seed: UUID, cornerRadius: CGFloat = RX.Radius.control) {
        self.imageURL = imageURL
        self.waveform = waveform
        self.seed = seed
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        ZStack {
            if let imageURL, let image = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                GeneratedCover(waveform: waveform, seed: seed)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct GeneratedCover: View {
    let waveform: WaveformOverview?
    let seed: UUID

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [RX.Palette.raised, RX.Palette.base]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let inner = radius * 0.22
            let peaks = sampledPeaks(count: 72)
            // Rotate by a per-song angle so covers with similar loudness still differ.
            let rotation = Double(seed.uuid.0) / 255 * .pi * 2

            for (i, peak) in peaks.enumerated() {
                let angle = CGFloat(rotation + Double(i) / Double(peaks.count) * .pi * 2)
                let length = inner + (radius * 0.72 - inner) * CGFloat(0.15 + 0.85 * peak)
                var path = Path()
                path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
                let t = Double(i) / Double(peaks.count)
                let color = t < 0.5
                    ? blend(RX.Palette.violet, RX.Palette.blue, t * 2)
                    : blend(RX.Palette.blue, RX.Palette.cyan, (t - 0.5) * 2)
                context.stroke(path, with: .color(color.opacity(0.9)),
                               style: StrokeStyle(lineWidth: max(1.5, radius * 0.035), lineCap: .round))
            }
            let dot = CGRect(x: center.x - inner * 0.35, y: center.y - inner * 0.35, width: inner * 0.7, height: inner * 0.7)
            context.fill(Path(ellipseIn: dot), with: .color(RX.Palette.cyan))
        }
    }

    private func sampledPeaks(count: Int) -> [Float] {
        guard let peaks = waveform?.peaks, !peaks.isEmpty else {
            return (0..<count).map { Float(0.3 + 0.2 * sin(Double($0) * 0.7)) }
        }
        return (0..<count).map { i in
            let lower = i * peaks.count / count
            let upper = max(lower + 1, (i + 1) * peaks.count / count)
            return peaks[lower..<min(upper, peaks.count)].max() ?? 0
        }
    }

    private func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ra = UIColor(a).cgColor.components ?? [0, 0, 0, 1]
        let rb = UIColor(b).cgColor.components ?? [0, 0, 0, 1]
        func channel(_ i: Int) -> Double {
            let x = Double(ra.count > i ? ra[i] : 0)
            let y = Double(rb.count > i ? rb[i] : 0)
            return x + (y - x) * t
        }
        return Color(.sRGB, red: channel(0), green: channel(1), blue: channel(2), opacity: 1)
    }
}

/// Bars for a waveform overview, with a played portion and an optional loop region.
public struct WaveformBars: View {
    let waveform: WaveformOverview?
    let progress: Double
    let loop: ClosedRange<Double>?
    let loopEnabled: Bool

    /// `progress` and `loop` are fractions of the song (0...1).
    public init(waveform: WaveformOverview?, progress: Double, loop: ClosedRange<Double>?, loopEnabled: Bool) {
        self.waveform = waveform
        self.progress = progress
        self.loop = loop
        self.loopEnabled = loopEnabled
    }

    public var body: some View {
        Canvas { context, size in
            let peaks = waveform?.peaks ?? []
            let barCount = max(1, Int(size.width / 4))
            let barWidth = max(1.5, size.width / CGFloat(barCount) * 0.62)

            if let loop {
                let x0 = size.width * loop.lowerBound
                let x1 = size.width * loop.upperBound
                let rect = CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 6),
                             with: .color(RX.Palette.blue.opacity(loopEnabled ? 0.22 : 0.10)))
            }

            for i in 0..<barCount {
                let fraction = (Double(i) + 0.5) / Double(barCount)
                let peak: Float
                if peaks.isEmpty {
                    peak = 0.08
                } else {
                    let lower = i * peaks.count / barCount
                    let upper = max(lower + 1, (i + 1) * peaks.count / barCount)
                    peak = peaks[lower..<min(upper, peaks.count)].max() ?? 0
                }
                let height = max(3, size.height * CGFloat(0.08 + 0.92 * peak))
                let x = size.width * fraction - barWidth / 2
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                let played = fraction <= progress
                let color = played ? RX.Palette.cyan : RX.Palette.textPrimary.opacity(0.28)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }

            let playheadX = size.width * min(max(progress, 0), 1)
            let line = CGRect(x: playheadX - 1, y: 0, width: 2, height: size.height)
            context.fill(Path(roundedRect: line, cornerRadius: 1), with: .color(RX.Palette.textPrimary))
        }
    }
}
