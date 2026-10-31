# RIFFNEX — Phase C: Architecture

> Status: **Draft for approval** · Last updated: 2026-10-31

## 1. Platform baseline

| Item | Choice |
|---|---|
| Language | Swift 6, strict concurrency (Swift 6 language mode) |
| UI | SwiftUI and the Observation framework (`@Observable`). UIKit only where needed (document picker interop is handled by `.fileImporter`) |
| Minimum OS | **iOS 27** (pending decision D1; see discovery doc) |
| Devices | iPhone first. iPad runs the same layout scaled |
| Project | **XcodeGen** `project.yml` plus local Swift packages. The `.xcodeproj` is generated and not committed |
| Backend | **None** for MVP |

## 2. Module structure

One app target plus one local package, `RiffnexKit`, with a few targets. Dependencies point downward only.

```
RiffnexApp (app target: features & composition root)
 ├─ Features/ Onboarding · Library · Import · Analysis · Overview · Studio · Settings
 │
 └─ RiffnexKit (local SwiftPM package)
     ├─ DesignSystem      SwiftUI tokens, typography, components, FretboardView (Canvas)
     ├─ Persistence       SwiftData models + AnalysisStore (versioned JSON files)
     ├─ PlaybackEngine    AVAudioEngine playback, time-stretch, looping, metronome, clock
     ├─ AnalysisEngine    pipeline stages: decode, MusicUnderstanding, BasicPitch, chords
     └─ MusicCore         ★ pure Swift, Foundation only: domain model, theory, fingering, tab layout
```

| Target | Depends on | Apple frameworks | Builds on Linux? |
|---|---|---|---|
| `MusicCore` | — | Foundation only | **Yes.** The domain, theory and fingering tests can run in this container if a Swift toolchain becomes available. |
| `AnalysisEngine` | MusicCore | AVFoundation, Accelerate, CoreML, MusicUnderstanding | No |
| `PlaybackEngine` | MusicCore | AVFoundation | No |
| `Persistence` | MusicCore | SwiftData | No |
| `DesignSystem` | MusicCore | SwiftUI, CoreHaptics | No |

Rationale:
- `MusicCore` holds the logic most likely to be wrong in subtle ways (pitch math, chord classification, the fingering optimizer, tab layout). It is kept free of platform APIs so it is fast to test exhaustively.
- Feature modules stay in the app target until a real reason to split appears. That avoids speculative modularization.
- Dependency injection is done with plain initializer injection behind small protocols, only at **I/O seams**: the audio decoder, transcription model, rhythm analyzer, store and clock. Composition happens in `AppEnvironment`, and test doubles live only in test targets. **No mock implementations are compiled into the app.** Release builds cannot fall back to fakes.

## 3. Domain model (MusicCore)

### 3.1 Layers of truth

```
Transcription  (what the audio contains)        ← detected + inferred
     │
Arrangement    (how to play it on a given tuning) ← recommended (+ user-edited)
```

Changing tuning or handedness, or picking an alternative position, recomputes only the **Arrangement** and never touches the **Transcription**.

### 3.2 Core types (abridged)

```swift
public typealias Seconds = Double                 // always relative to the original audio

public struct MIDINote: Hashable, Codable, Sendable { public let value: UInt8 }   // 0...127
public enum PitchClass: Int, Codable, Sendable, CaseIterable { case c, cSharp, d, /* … */ b }

public enum Provenance: String, Codable, Sendable {
    case detected      // directly produced by a model/analyzer from the audio
    case inferred      // derived by music-theory rules from detected data
    case recommended   // produced by the fingering optimizer
    case userEdited
}

public struct Confidence: Codable, Sendable, Hashable {
    public let raw: Float           // source-specific score in 0...1 (e.g. mean model activation); NOT a probability
    public let isCalibrated: Bool   // true only after calibration against GuitarSet
    public var level: Level         // .high / .medium / .low via documented thresholds
    public enum Level: String, Codable, Sendable { case high, medium, low }
}

public struct Source: Codable, Sendable, Hashable {     // provenance of the *analysis*
    public let component: Component                      // .basicPitch, .musicUnderstanding, .chordEstimator, .fingeringOptimizer, .user
    public let version: String                          // model hash / algorithm version
}

public struct NoteEvent: Identifiable, Codable, Sendable {
    public let id: UUID
    public var onset: Seconds, offset: Seconds
    public var pitch: MIDINote
    public var amplitude: Float                  // from model activation
    public var pitchContourCents: [Float]?       // from contour output, at 86 fps; enables bend detection later
    public var techniques: [TechniqueAnnotation] // empty in MVP
    public var provenance: Provenance            // .detected
    public var confidence: Confidence
    public var source: Source
}

public struct ChordEvent: Identifiable, Codable, Sendable {
    public let id: UUID
    public var start: Seconds, end: Seconds
    public var root: PitchClass, quality: ChordQuality, bass: PitchClass?
    public var provenance: Provenance            // .detected (template match) or .inferred (theory rule)
    public var confidence: Confidence
    public var source: Source
}

public enum ChordQuality: String, Codable, Sendable {
    case major, minor, power /* "5" */, dominant7, major7, minor7, sus2, sus4, diminished, noChord
}

public struct TechniqueAnnotation: Codable, Sendable {
    public enum Kind: Codable, Sendable { case bend(cents: Int), release, slide(toFret: Int), hammerOn, pullOff, vibrato, palmMute }
    public var kind: Kind; public var confidence: Confidence; public var source: Source
}

public struct Tuning: Codable, Sendable, Hashable {
    public let name: String
    public let openStrings: [MIDINote]           // index 0 = lowest string; count 6 for MVP, model allows 7/8
    public var capo: Int
    public static let standard = Tuning(name: "E Standard", openStrings: [40,45,50,55,59,64].map(MIDINote.init), capo: 0)
}

public struct FretPosition: Codable, Sendable, Hashable { public let string: Int; public let fret: Int }
public enum Finger: Int, Codable, Sendable { case open = 0, index, middle, ring, pinky, thumb }

public struct FingeredNote: Codable, Sendable {
    public let noteID: UUID
    public var position: FretPosition
    public var finger: Finger?
    public var alternatives: [FretPosition]
    public var provenance: Provenance            // .recommended or .userEdited
}

public struct Arrangement: Codable, Sendable {
    public let tuning: Tuning
    public var notes: [FingeredNote]
    public var chordShapes: [UUID: ChordShape]   // keyed by ChordEvent.id
    public var handPositions: [(time: Seconds, fret: Int)]   // drives fretboard follow
    public let source: Source
}

public struct SongAnalysis: Codable, Sendable {  // persisted as JSON
    public let schemaVersion: Int
    public let pipelineVersion: String
    public let audioContentHash: String
    public let duration: Seconds
    public var tempo: TempoEstimate?             // global BPM + beat/bar grid
    public var keys: [KeyRegion]                 // time-ranged key signatures
    public var sections: [Section]               // from structure, with similarity labels A/B/A′
    public var notes: [NoteEvent]
    public var chords: [ChordEvent]
    public var quality: AnalysisQualityReport    // the measured signals behind the Overview's quality level
    public var stageOutcomes: [StageOutcome]     // what ran, what failed, timings
}
```

Invariants are enforced by tests:
- Every `FingeredNote`'s position sounds the same pitch as its note for the arrangement's tuning and capo.
- At most one note per string at a time.
- `onset < offset`.
- All times fall within `[0, duration]`.

## 4. Audio analysis pipeline

```
Import ──► Decode & normalize ──┬──► Music Understanding (rhythm · key · structure · instrumentActivity)
                                │                         │
                                └──► Basic Pitch (Core ML) │
                                       windowed inference  │
                                       → note decoding     │
                                             │             │
                                             ▼             ▼
                                   Guitar-range gating ◄── beat grid / instrument activity
                                             │
                                   Chord & power-chord estimation (beat-synchronous)
                                             │
                                   Section labeling (A/B/A′) · phrase boundaries
                                             │
                                   Fingering optimizer → Arrangement
                                             │
                                   Quality report → persist SongAnalysis
```

| # | Stage | Implementation | Output | Failure policy |
|---|---|---|---|---|
| 0 | Import | Copy from a security-scoped URL to `Application Support/Songs/<uuid>/`. Validate with `AVURLAsset` (playable, has audio track, not protected, 5 s–15 min). Compute SHA-256 content hash. | `Song` record | Fatal, with a specific error |
| 1 | Decode | `AVAudioFile` read in chunks → `AVAudioConverter` to mono float32 at 22,050 Hz. Peak-normalize the analysis copy only. Also compute the waveform overview (min/max per bucket). | `AnalysisAudio`, `WaveformOverview` | Fatal |
| 2 | Rhythm / key / structure | `MusicUnderstandingSession(asset:)` → `analyze(for: [.rhythm, .key, .structure, .instrumentActivity])`. Convert `CMTime` to `Seconds`. | Beat and bar grid, BPM, key regions, sections and phrases, instrument activity | Non-fatal. Missing results show as *indisponível*, and chords fall back to fixed-hop frames instead of beats. |
| 3 | Notes | Basic Pitch `nmp.mlpackage`, using windows of 43,844 samples with 30-frame overlap (as in the reference), batched. The **Swift port of `output_to_notes_polyphonic`** handles onset peak-picking, the frame and onset thresholds, minimum note length (11 frames), energy tolerance and inferred onsets. It is validated against reference outputs produced with the Python package on the same audio. | `[NoteEvent]` with amplitude, contour and confidence | Fatal for the Studio. Overview still shows rhythm and key. |
| 4 | Gating | Keep MIDI 40…(highest open string + 24) for the current tuning. If instrument activity includes guitar **[to verify]**, attenuate the confidence of notes in guitar-silent regions. Gating counts feed the quality report. | Filtered notes, gating stats | — |
| 5 | Chords | Pitch-class profiles per beat, computed from the Basic Pitch note activations (folded to 12 classes and bass-weighted) → cosine match against the templates for `ChordQuality` → **Viterbi smoothing** (a self-transition prior favoring chord changes on bar lines). **Power chords:** root and fifth energy present, third below a threshold relative to the root, and/or simultaneous notes forming intervals {0, 7, 12}. | `[ChordEvent]` | Non-fatal |
| 6 | Sections | Sections and phrases come from Music Understanding. Labels A/B/A′ come from chord-sequence similarity between sections. | `[Section]` | Non-fatal. With no structure, fixed 4/8-bar segments are labeled as *estimated*. |
| 7 | Fingering | See §5 | `Arrangement` | Fatal for the Studio |
| 8 | Persist | `SongAnalysis` JSON (atomic write) plus an `AnalysisRecord` summary in SwiftData | — | Fatal |

**Concurrency and lifecycle**
- `AnalysisCoordinator` is an `actor`. Each stage is an `async throws` function. Stages 2 and 3 run concurrently in a `TaskGroup`.
- Progress is an `AsyncStream<AnalysisProgress>` carrying real counters, namely decoded frames and inference windows, where they exist.
- Cancellation is cooperative, with `Task.checkCancellation()` between chunks and windows. `MusicUnderstandingSession.cancel()` is called on cancel.
- **Checkpoints:** stage outputs are cached under `Caches/Analysis/<contentHash>/<stage>-<version>`, so a re-run after a crash, backgrounding or a pipeline upgrade only redoes what changed.
- **Background:** user-initiated analysis is submitted as a `BGContinuedProcessingTaskRequest` **[to verify, iOS 26+ API]** with system-visible progress. Otherwise analysis pauses on background and resumes from the checkpoint.
- Core ML compute units are chosen per device after measurement. The default is `.all`, with fallback to `.cpuAndGPU` if Neural Engine (ANE) compilation fails.
- Memory: 5 min of mono float32 at 22,050 Hz is about 26 MB. Model windows stream through, and no full-resolution posteriorgram is held beyond what note decoding needs.

## 5. Fingering optimizer (MusicCore)

A dynamic program over time-ordered **note groups**, where notes whose onsets fall within 30 ms of each other are grouped.

1. **Candidates per group:** every assignment of the group's pitches to distinct strings with `0 ≤ fret ≤ 22` (configurable) and a fretted span of 4 frets or fewer (5 with a stretch penalty). The search prunes to the top K = 48 by static cost. Chord-symbol groups also seed candidates from a **shape library** (open shapes, CAGED barre shapes, and power-chord shapes on the 6th, 5th and 4th strings).
2. **Static cost** (per candidate): span, high-fret penalty (mild), open-string preference (stronger at slower tempos), string-skip penalty within the group, and unplayable-finger configurations.
3. **Transition cost** (between consecutive candidates): hand-position shift (|Δ index-finger fret|, weighted by the inverse of the time gap), string-crossing distance, and a penalty for changing position mid-phrase (phrase boundaries come from stage 6).
4. **Viterbi** over groups gives the globally minimal-cost path, at O(N·K²).
5. **Fingers:** within a hand position *p*, finger = `fret − p + 1`, clamped to 1…4. A barre is set when the index finger covers 2 or more strings at the same fret. Open strings get `.open`.
6. **User constraints:** a chosen alternative pins that group, and the DP re-runs over the enclosing phrase only.

Weights live in one `FingeringCostModel` struct with documented defaults and are unit-tested on canonical cases. For example, an E-minor pentatonic box should stay in position 12 or position 0, not zig-zag. A G5–A5–C5 riff should land on the 6th/5th-string power-chord shapes.

## 6. Playback engine

- `AVAudioEngine`: `AVAudioPlayerNode` → `AVAudioUnitTimePitch` (rate 0.25–1.25, pitch preserved) → main mixer. A separate `AVAudioSourceNode` **metronome** synthesizes clicks sample-accurately from the beat grid, mapped through the current rate.
- **Looping:** `scheduleSegment` for the loop region, with the next iteration pre-scheduled on completion for gapless loops. Count-in is scheduled by starting the player at a future `AVAudioTime` while the metronome plays the count.
- **Clock:** `PlaybackClock.currentTime` is derived from `playerNode.lastRenderTime` → `playerTime(forNodeTime:)`, plus the segment start offset, mapped to song seconds. It compensates for `outputLatency` so visuals match what the ear hears. UI reads the clock **per frame** in `TimelineView`. It is not pushed through Observation at 60–120 Hz.
- **Session:** `.playback` category (`.playAndRecord` once Practice ships). Handles interruptions (pauses and offers to resume), route changes (pauses when headphones are unplugged), and media services reset (rebuilds the graph). `MPNowPlayingInfoCenter` and remote commands are supported. Background audio mode is enabled so practice continues with the screen locked.

## 7. Persistence

| Data | Store | Why |
|---|---|---|
| `Song` (title, artist, duration, file name, content hash, import date, last opened, analysis status) | SwiftData | Small, queryable, drives the library UI |
| `AnalysisRecord` (pipeline version, date, BPM, key, quality level, path to JSON) | SwiftData | Summaries for list and overview without loading the JSON |
| `SongAnalysis` (notes, chords, contours, sections) | **Versioned JSON file** per song | Large arrays are a poor fit for SwiftData rows. Loads atomically and versions cleanly. |
| `StudioState` (position, loop, speed, mode), `Bookmark`, `UserFingeringOverride` | SwiftData | User state, needs to survive re-analysis |
| `PracticeSession` (post-MVP, measured values only) | SwiftData | |
| Imported audio | `Application Support/Songs/<uuid>/` | Private, not visible in Files, excluded from iCloud backup (re-importable; saves the user's quota) |

The schema uses `VersionedSchema` and a `SchemaMigrationPlan` from day one. Deleting a song removes its audio, analysis JSON, caches and user state.

## 8. Dependencies

| Dependency | Use | License | Justification |
|---|---|---|---|
| Basic Pitch Core ML model (`nmp.mlpackage`, ~270 KB) | Note transcription | Apache-2.0 | Best size-to-quality polyphonic transcription available on-device. Attribution is shown in Settings › Licenses, with the NOTICE included. |
| XcodeGen (dev tool) | Project generation | MIT | Keeps the project diffable and reviewable. Not shipped. |
| swift-snapshot-testing (test only, optional) | Visual regression of design-system components | MIT | Catches UI regressions in the fretboard renderer |

Everything else is Apple frameworks: SwiftUI, SwiftData, Observation, AVFoundation, Accelerate, Core ML, MusicUnderstanding, Core Haptics, BackgroundTasks, MediaPlayer and os. **No analytics or ad SDKs.**

## 9. Testing strategy

| Level | What | Where it runs |
|---|---|---|
| Unit (MusicCore) | Pitch and interval math, tuning and capo, chord templates, power-chord rules, the fingering DP (invariants plus canonical riffs), tab layout and measure quantization, Codable round-trips | macOS / iOS simulator; Linux when a toolchain is available |
| Unit (AnalysisEngine) | The Swift note decoder against **golden vectors** from the Python `basic-pitch` reference (same activations in, same notes out), chord Viterbi, beat-sync pooling, gating | iOS simulator / macOS |
| Integration (pipeline) | **Synthesized fixtures** with known ground truth, generated by `tools/fixtures` (Karplus-Strong plucked strings plus click tracks; original and rights-free): single-note riffs, power-chord progressions, open chords, and tempo-ramp clicks. Assertions use mir_eval-style metrics, with thresholds set from *measured* baselines. | iOS simulator |
| Accuracy harness (not a CI gate at first) | GuitarSet (CC BY 4.0): note onset F1, chord accuracy, and tempo error per `pipelineVersion`. Results go to `docs/quality/` with the exact numbers. **These are the only accuracy numbers RIFFNEX may quote.** | macOS (scripted) |
| Playback | Clock math (rate, loop, seek, latency offset) as pure functions; engine smoke test on the simulator | iOS simulator |
| UI (XCUITest) | Onboarding → import (a test-only launch argument injects a fixture URL; compiled only in the `UITests` configuration) → analysis completes → Studio play, pause, loop and speed | iOS simulator |
| Performance | `XCTMetric` for analysis wall-time on a 3-minute fixture; Instruments (Animation Hitches) for the Studio at 120 Hz; memory high-water mark | Device (manual, per milestone) |

**Observability:** `os.Logger` per subsystem (`analysis`, `playback`, `persistence`, `ui`) and `OSSignposter` intervals around each pipeline stage. `MetricKit` covers hangs, crashes and energy. A Debug-only **Diagnostics** screen shows stage timings and outcomes for each song. No remote telemetry in the MVP.

## 10. Privacy, legal & App Store

- **Audio stays on device**, and the MVP has no network calls for analysis. The privacy nutrition label is “Data Not Collected”.
- **Rights:** there is a reminder at import. The app offers no sharing or export of transcriptions or audio in the MVP, which reduces exposure under guideline 5.2. There are no streaming-service integrations; Spotify and Apple Music audio cannot legally or technically be extracted.
- **Microphone** (post-MVP): requested just in time, after an explainer. Practice audio is processed in memory and **not recorded** unless the user explicitly saves a take.
- **Privacy manifest** (`PrivacyInfo.xcprivacy`) declares the required-reason APIs we use (file timestamps, UserDefaults).
- **Third-party licenses:** the Basic Pitch Apache-2.0 LICENSE and NOTICE are bundled and displayed. The GuitarSet license (CC BY 4.0) applies only to the evaluation harness, and its data is not shipped.
- **Future server option** (source separation): opt-in per song, with an explicit consent dialog. Audio is deleted after processing, with a documented retention window. It requires a legal review before implementation.

## 11. Decision log

| ID | Decision | Alternatives | Why |
|---|---|---|---|
| ADR-1 | On-device only, no backend for MVP | Server transcription; hybrid | All MVP capabilities run on-device. Better privacy, no inference cost, works offline. |
| ADR-2 | Music Understanding for rhythm, key and structure; iOS 27 minimum | Custom DSP for iOS 18+ | Saves about one milestone of DSP work and maintenance, at platform quality. *Pending D1.* |
| ADR-3 | Basic Pitch for notes | Custom CNN, TabCNN, MT3 | Tiny, permissive license, official Core ML artifact, polyphonic, provides bend contours. |
| ADR-4 | Custom chord estimator on Basic Pitch activations | Chroma from a separate FFT; ML chord model | Reuses data we already have, is transparent and testable, and is good enough for the MVP vocabulary. Upgrade path exists. |
| ADR-5 | Fingering as DP optimization, separate from transcription | Take positions from a tab model | Positions are a recommendation, not a fact. The DP is explainable and constraint-aware. |
| ADR-6 | SwiftUI Canvas for the fretboard | Metal, SpriteKit | Scene complexity is low, and Canvas keeps accessibility and text simple. Metal is the escalation path if profiling demands it. |
| ADR-7 | SwiftData for library and state; JSON files for analysis payloads | All SwiftData; GRDB/SQLite | Native and simple. Large immutable payloads stay out of the object graph. |
| ADR-8 | Pure-Swift `MusicCore` module | Single app target | The highest-risk logic is fully testable in isolation, including on Linux. |
| ADR-9 | XcodeGen | Committed `.xcodeproj`; Tuist | Reviewable project definition with minimal tooling. |
