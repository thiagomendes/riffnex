import Foundation

/// Onset-only note precision / recall / F1, equivalent to
/// `mir_eval.transcription.precision_recall_f1_overlap(..., offset_ratio=None)` for integer MIDI
/// pitches: a reference and an estimated note match when their pitches are equal and their
/// onsets are within `onsetTolerance`; matching is a maximum bipartite matching.
public enum TranscriptionMetrics {
    public struct Score: Sendable, Equatable, CustomStringConvertible {
        public let precision: Double
        public let recall: Double
        public let f1: Double
        public let matched: Int
        public let reference: Int
        public let estimated: Int

        public var description: String {
            String(format: "P %.2f R %.2f F1 %.2f (%d/%d ref, %d est)", precision, recall, f1, matched, reference, estimated)
        }
    }

    public struct Note: Sendable, Equatable {
        public let onset: Double
        public let pitch: Int

        public init(onset: Double, pitch: Int) {
            self.onset = onset
            self.pitch = pitch
        }
    }

    public static func score(reference: [Note], estimated: [Note], onsetTolerance: Double = 0.05) -> Score {
        // Adjacency: reference index → candidate estimate indices.
        let adjacency: [[Int]] = reference.map { r in
            estimated.indices.filter { estimated[$0].pitch == r.pitch && abs(estimated[$0].onset - r.onset) <= onsetTolerance + 1e-9 }
        }
        var matchOfEstimate = [Int?](repeating: nil, count: estimated.count)

        func augment(_ r: Int, _ visited: inout [Bool]) -> Bool {
            for e in adjacency[r] where !visited[e] {
                visited[e] = true
                if matchOfEstimate[e] == nil || augment(matchOfEstimate[e]!, &visited) {
                    matchOfEstimate[e] = r
                    return true
                }
            }
            return false
        }

        var matched = 0
        for r in reference.indices {
            var visited = [Bool](repeating: false, count: estimated.count)
            if augment(r, &visited) { matched += 1 }
        }
        let precision = estimated.isEmpty ? 0 : Double(matched) / Double(estimated.count)
        let recall = reference.isEmpty ? 0 : Double(matched) / Double(reference.count)
        let f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        return Score(precision: precision, recall: recall, f1: f1, matched: matched,
                     reference: reference.count, estimated: estimated.count)
    }
}
