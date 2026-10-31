import SwiftUI

/// RIFFNEX design tokens (see docs/02-design-system.md §2).
/// Colors are defined in code because asset catalogs are not reliable under xtool.
public enum RX {
    // MARK: Color

    public enum Palette {
        public static let base = Color(hex: 0x07070A)
        public static let surface = Color(hex: 0x0E0F14)
        public static let raised = Color(hex: 0x161721)
        public static let hairline = Color.white.opacity(0.08)

        public static let textPrimary = Color(hex: 0xF4F4F7)
        public static let textSecondary = Color(hex: 0xF4F4F7).opacity(0.64)
        public static let textTertiary = Color(hex: 0xF4F4F7).opacity(0.40)

        /// "Riff": brand, primary actions, upcoming notes.
        public static let violet = Color(hex: 0x7C5CFF)
        /// "Pulse": timeline, playhead, loop region.
        public static let blue = Color(hex: 0x3D7BFF)
        /// "Signal": sounding now.
        public static let cyan = Color(hex: 0x3FE0E8)

        public static let success = Color(hex: 0x4ADE9B)
        public static let warning = Color(hex: 0xF5B946)
        public static let error = Color(hex: 0xFF5C6C)

        public static let fretboardTop = Color(hex: 0x121219)
        public static let fretboardBottom = Color(hex: 0x0B0B10)
        public static let fret = Color(hex: 0x8E93A6).opacity(0.55)
        public static let string = Color(hex: 0xC9CCD8)
    }

    public static let brandGradient = LinearGradient(
        colors: [Palette.violet, Palette.blue, Palette.cyan],
        startPoint: .leading, endPoint: .trailing
    )

    // MARK: Spacing (4-pt grid)

    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
        public static let xxxl: CGFloat = 64
        public static let screenMargin: CGFloat = 20
    }

    public enum Radius {
        public static let chip: CGFloat = 10
        public static let control: CGFloat = 16
        public static let panel: CGFloat = 24
        public static let hero: CGFloat = 32
    }

    // MARK: Motion

    public enum Motion {
        /// Touch response: buttons, chips, mode switch.
        public static let touch = Animation.spring(response: 0.32, dampingFraction: 0.86)
        /// Spatial transitions between screens and large layout changes.
        public static let spatial = Animation.spring(response: 0.55, dampingFraction: 0.9)
        /// Rare celebratory moments.
        public static let celebrate = Animation.spring(response: 0.45, dampingFraction: 0.62)

        /// Returns a cross-fade when Reduce Motion is on.
        public static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.2) : animation
        }
    }
}

public extension Color {
    /// 0xRRGGBB in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: Typography

public extension Font {
    /// Wide display type: song titles and onboarding words.
    static func rxDisplay(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .default, weight: .bold).width(.expanded)
    }

    /// Chord symbols: rounded, legible from a music stand.
    static func rxChord(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .rounded, weight: .semibold)
    }

    /// Tablature digits.
    static func rxTab(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .monospaced, weight: .medium)
    }
}
