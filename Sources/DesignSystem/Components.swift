import SwiftUI

/// Primary call-to-action: large, thumb-reachable, brand gradient highlight.
public struct RXPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(RX.Palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, RX.Space.l)
            .background {
                RoundedRectangle(cornerRadius: RX.Radius.control, style: .continuous)
                    .fill(RX.Palette.raised)
                    .overlay {
                        RoundedRectangle(cornerRadius: RX.Radius.control, style: .continuous)
                            .fill(RX.brandGradient)
                            .opacity(isEnabled ? 0.9 : 0.25)
                    }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(RX.Motion.touch, value: configuration.isPressed)
    }
}

/// Secondary action: quiet raised surface.
public struct RXSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RX.Palette.textPrimary)
            .padding(.horizontal, RX.Space.m)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: RX.Radius.chip, style: .continuous)
                    .fill(RX.Palette.raised)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(RX.Motion.touch, value: configuration.isPressed)
    }
}

/// A status pill (e.g. analysis state). Color is never the only cue: always pairs with a symbol.
public struct RXStatusPill: View {
    public enum Kind: Sendable { case neutral, running, success, warning, failure }

    let text: String
    let kind: Kind

    public init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, RX.Space.xs)
        .padding(.vertical, RX.Space.xxs)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch kind {
        case .neutral: "circle"
        case .running: "waveform"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .neutral: RX.Palette.textSecondary
        case .running: RX.Palette.blue
        case .success: RX.Palette.success
        case .warning: RX.Palette.warning
        case .failure: RX.Palette.error
        }
    }
}

/// Full-screen app background with the subtle violet light source.
public struct RXBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            RX.Palette.base
            RadialGradient(
                colors: [RX.Palette.violet.opacity(0.16), .clear],
                center: UnitPoint(x: 0.3, y: 0.0), startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}
