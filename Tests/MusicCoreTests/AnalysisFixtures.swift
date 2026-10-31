import Foundation
@testable import MusicCore

/// Loads the shared fixtures in `Tests/Fixtures` by path (works on Linux and in the iOS simulator,
/// which can read the host file system).
enum AnalysisFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    static let truthURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/fixtures/riffnex-demo.truth.json")

    struct Activations {
        let notes: ActivationMatrix
        let onsets: ActivationMatrix
    }

    static func activations() throws -> Activations {
        let data = try Data(contentsOf: directory.appendingPathComponent("demo-activations.bin"))
        guard data.count >= 12, data.prefix(4) == Data("RXA1".utf8) else { throw FixtureError.badFormat }
        func u32(_ offset: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        }
        let frames = u32(4)
        let bins = u32(8)
        let count = frames * bins
        guard data.count == 12 + 4 * count else { throw FixtureError.badFormat }
        func matrix(at offset: Int) -> ActivationMatrix {
            let values: [Float] = data.withUnsafeBytes { raw in
                (0..<count).map { i in
                    let q = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 2 * i, as: UInt16.self))
                    return Float(Double(q) / 65535)
                }
            }
            return ActivationMatrix(frames: frames, bins: bins, values: values)
        }
        return Activations(notes: matrix(at: 12), onsets: matrix(at: 12 + 2 * count))
    }

    struct Golden: Decodable {
        struct Config: Decodable {
            let name: String
            let onsetThreshold: Float
            let frameThreshold: Float
            let minNoteFrames: Int
            let inferOnsets: Bool
            let melodia: Bool
            let minMIDI: Int?
            let maxMIDI: Int?
            let notes: [[Double]]

            var parameters: NoteDecoder.Parameters {
                NoteDecoder.Parameters(onsetThreshold: onsetThreshold, frameThreshold: frameThreshold,
                                       minNoteFrames: minNoteFrames, inferOnsets: inferOnsets, melodiaTrick: melodia,
                                       minMIDI: minMIDI, maxMIDI: maxMIDI)
            }
        }

        let samples: Int
        let windows: Int
        let frames: Int
        let configs: [Config]
    }

    static func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(contentsOf: directory.appendingPathComponent("demo-notes.golden.json")))
    }

    struct Truth: Decodable {
        struct Note: Decodable {
            let onset: Double
            let offset: Double
            let midi: Int
        }

        struct ChordSpan: Decodable {
            let start: Double
            let end: Double
            let symbol: String
        }

        let duration: Double
        let beats: [Double]
        let notes: [Note]
        let chords: [ChordSpan]
    }

    static func truth() throws -> Truth {
        try JSONDecoder().decode(Truth.self, from: Data(contentsOf: truthURL))
    }

    static func musicUnderstanding() throws -> MusicUnderstandingResult {
        try MusicUnderstandingResult.decode(Data(contentsOf: directory.appendingPathComponent("demo-music-understanding.json")))
    }

    enum FixtureError: Error { case badFormat }
}
