import Foundation

/// Where a musical fact came from. Shown to the user; never collapsed into a single "AI" label.
public enum Provenance: String, Codable, Sendable, CaseIterable {
    /// Produced directly from the audio by a model or analyzer.
    case detected
    /// Derived from detected data by music-theory rules.
    case inferred
    /// A playability recommendation (e.g. fingering), not a claim about the original performance.
    case recommended
    /// Set or corrected by the user.
    case userEdited
}

/// A source-specific confidence score.
///
/// `raw` is whatever the producing component emits (e.g. a mean model activation). It is **not**
/// a probability unless `isCalibrated` is true. UI must show `level`, never `raw` as a percentage,
/// while uncalibrated.
public struct Confidence: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable, Comparable, CaseIterable {
        case low, medium, high

        private var order: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.order < rhs.order }
    }

    public let raw: Double
    public let isCalibrated: Bool
    public let level: Level

    /// Thresholds are owned by the producing component and documented there.
    public init(raw: Double, isCalibrated: Bool = false, thresholds: (medium: Double, high: Double)) {
        precondition(thresholds.medium <= thresholds.high)
        let clamped = min(max(raw, 0), 1)
        self.raw = clamped
        self.isCalibrated = isCalibrated
        self.level = clamped >= thresholds.high ? .high : (clamped >= thresholds.medium ? .medium : .low)
    }

    public init(raw: Double, isCalibrated: Bool, level: Level) {
        self.raw = min(max(raw, 0), 1)
        self.isCalibrated = isCalibrated
        self.level = level
    }
}

/// Which component (and version) produced a result. Persisted with every event so results can be
/// traced and re-generated when a component is upgraded.
public struct AnalysisSource: Codable, Sendable, Hashable {
    public enum Component: String, Codable, Sendable {
        case basicPitch
        case musicUnderstanding
        case chordEstimator
        case stemSeparator
        case fingeringOptimizer
        case user
    }

    public let component: Component
    /// Model hash or algorithm version string.
    public let version: String

    public init(component: Component, version: String) {
        self.component = component
        self.version = version
    }
}
