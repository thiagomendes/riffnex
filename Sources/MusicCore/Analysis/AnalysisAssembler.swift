import Foundation

/// The pure half of the analysis pipeline: from model activations and Music Understanding's
/// result to a `SongAnalysis`. Everything after model inference lives here so it can be tested on
/// Linux against the golden fixtures; the AnalysisEngine only adds audio decoding and inference.
public enum AnalysisAssembler {
    public struct Input: Sendable {
        public var duration: Seconds
        public var notes: ActivationMatrix
        public var onsets: ActivationMatrix
        public var musicUnderstanding: MusicUnderstandingResult?
        public var musicUnderstandingVersion: String
        public var basicPitchVersion: String
        public var tuning: Tuning
        public var decoderParameters: NoteDecoder.Parameters
        public var timings: [StageTiming]

        public init(duration: Seconds, notes: ActivationMatrix, onsets: ActivationMatrix,
                    musicUnderstanding: MusicUnderstandingResult?, musicUnderstandingVersion: String,
                    basicPitchVersion: String, tuning: Tuning = .standard,
                    decoderParameters: NoteDecoder.Parameters = .reference, timings: [StageTiming] = []) {
            self.duration = duration
            self.notes = notes
            self.onsets = onsets
            self.musicUnderstanding = musicUnderstanding
            self.musicUnderstandingVersion = musicUnderstandingVersion
            self.basicPitchVersion = basicPitchVersion
            self.tuning = tuning
            self.decoderParameters = decoderParameters
            self.timings = timings
        }
    }

    /// Version of RIFFNEX's own post-processing; bump when any step's behavior changes.
    public static let postProcessingVersion = "rx-notes-1"

    public static func assemble(_ input: Input, createdAt: Date = Date()) -> SongAnalysis {
        let clock = ContinuousClock()
        let start = clock.now

        let decoded = NoteDecoder.decode(notes: input.notes, onsets: input.onsets, parameters: input.decoderParameters)
        let processor = NotePostProcessor(parameters: .guitar(tuning: input.tuning))
        let (frameNotes, noteReport) = processor.process(decoded, onsets: input.onsets)
        let noteSource = AnalysisSource(component: .basicPitch,
                                        version: "\(input.basicPitchVersion)+\(postProcessingVersion)")
        let notes = frameNotes.compactMap { $0.noteEvent(source: noteSource) }
            .filter { $0.onset < input.duration }

        let mu = input.musicUnderstanding
        let rhythm = mu?.rhythmGrid(version: input.musicUnderstandingVersion)
        let keys = mu?.keySpans(version: input.musicUnderstandingVersion) ?? []
        let activity = mu?.activity(duration: input.duration)

        let chords = ChordEstimator().estimate(notes: notes, beats: rhythm?.beats ?? [], duration: input.duration)
        let sections = SectionLabeler().label(ranges: mu?.sectionRanges ?? [], notes: notes, chords: chords,
                                              duration: input.duration)
        let quality = QualityReport.assess(duration: input.duration, notes: notes, chords: chords, rhythm: rhythm,
                                           keys: keys, activity: activity)

        var timings = input.timings
        timings.append(StageTiming(stage: "postprocess", seconds: Self.seconds(clock.now - start)))

        var components = [noteSource, AnalysisSource(component: .chordEstimator, version: ChordEstimator.version)]
        if mu != nil {
            components.append(AnalysisSource(component: .musicUnderstanding, version: input.musicUnderstandingVersion))
        }
        return SongAnalysis(createdAt: createdAt, duration: input.duration, rhythm: rhythm, keys: keys,
                            sections: sections, notes: notes, chords: chords, activity: activity, quality: quality,
                            noteReport: noteReport, timings: timings, components: components)
    }

    static func seconds(_ duration: Duration) -> Double {
        let (s, atto) = duration.components
        return Double(s) + Double(atto) / 1e18
    }
}
