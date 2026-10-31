# RIFFNEX — Phase C: Architecture

> Status: **Draft for approval** · Last updated: 2026-10-31

## 1. Platform baseline

| Item | Choice |
|---|---|
| Language | Swift 6, strict concurrency (Swift 6 language mode) |
| UI | SwiftUI and the Observation framework (`@Observable`). UIKit only where needed (document picker interop is handled by `.fileImporter`) |
| Minimum OS | **iOS 27** if the owner's iPhone 14 Plus runs it (pending D1); otherwise the custom-DSP fallback |
| Devices | The owner's iPhone 14 Plus (A15, 60 Hz display; no ProMotion) |
| Project | **SwiftPM package + `xtool.yml`** (no `.xcodeproj`; see §1.1) |
| Backend | **None** for MVP |

### 1.1 Building without a Mac (xtool)

The owner has no Mac. The toolchain is [xtool](https://github.com/xtool-org/xtool) (MIT), a cross-platform replacement for Xcode. It builds SwiftPM packages into iOS apps and signs and installs them on Linux or Windows (through WSL). Facts were checked against its README and Linux installation docs on 2026-10-31; xtool is at v1.24.0 with frequent releases.

| Need | How |
|---|---|
| iOS SDK | xtool extracts it from **Xcode 27.1 `.xip`**. The owner downloads it with their own Apple ID. The SDK is about 7 GB, or smaller with `--slim`. |
| Toolchain | Swift 6.4 for Linux |
| Signing | Apple ID. A free account works through Apple's private APIs, and **free provisioning profiles expire after 7 days**, so the app must be reinstalled weekly. A paid account uses an App Store Connect API key. |
| Install | USB via `usbmuxd`. On WSL this needs USB passthrough (`usbipd`). |
| **Cannot run in this cloud container** | There is no USB link to the iPhone, and swift.org is blocked here. Apple ID credentials must never be handled by Claude. |

**Build pipeline:**
1. **CI (GitHub Actions, macOS runner, Xcode 27):** compiles the app and runs the package unit tests on the iOS simulator. This gives every increment an automated, verifiable build that I can trigger and read.
2. **Owner's PC (xtool):** runs `xtool dev` to build, sign and install over USB. Alternatively, it can sign and install the `.ipa` produced by CI **[to verify: `xtool install` re-signs an unsigned IPA]**.

**Design constraints from SwiftPM + xtool** (each one is validated in the M0 toolchain spike):

| Area | Risk | Decision |
|---|---|---|
| SwiftData `@Model` macros | xtool issue #149 (“Is it possible to use SwiftData?”) is still open | **Do not use SwiftData.** Use a Codable JSON store (§7). It is simpler, fully testable, and portable. |
| `@Observable` | Issue #197 reports failures (Swift 6.2.3). v1.20.0 claims SwiftUI macro support. | Verify in the spike. Fall back to `ObservableObject`. |
| Asset catalogs (`actool`) | Issue #310 is open on WSL2 | Colors and gradients are defined in code (DesignSystem). The app icon goes through xtool's mechanism **[to verify]**. |
| Core ML `.mlpackage` | Build-time compilation needs Xcode's `coremlc` | Bundle `nmp.mlpackage` as a raw resource and compile it **on device at first launch** with `MLModel.compileModel(at:)`, then cache the compiled `.mlmodelc`. This is a documented Core ML API. |
| String Catalogs (`.xcstrings`) | Unknown under xtool | Verify in the spike. Fall back to `pt-BR.lproj/Localizable.strings`, which SwiftPM supports natively. |
| Previews, LLDB, XCUITest | Not available or not documented | No `#Preview`. Logs use `os.Logger` plus an **in-app log viewer** (OSLogStore, current process). UI tests are deferred. |

## 2. Module structure

One app target plus one local package, `RiffnexKit`, with a few targets. Dependencies point downward only.

```
RiffnexApp (app target: features & composition root)
 ├─ Features/ Onboarding · Library · Import · Analysis · Overview · Studio · Settings
 │
 └─ RiffnexKit (local SwiftPM package)
     ├─ DesignSystem      SwiftUI tokens, typography, components, FretboardView (Canvas)
     ├─ Persistence       LibraryStore + AnalysisStore (versioned Codable JSON files)
     ├─ PlaybackEngine    AVAudioEngine playback, time-stretch, looping, metronome, clock
     ├─ AnalysisEngine    pipeline stages: decode, MusicUnderstanding, BasicPitch, chords
     └─ MusicCore         ★ pure Swift, Foundation only: domain model, theory, fingering, tab layout
```

| Target | Depends on | Apple frameworks | Builds on Linux? |
|---|---|---|---|
| `MusicCore` | — | Foundation only | **Yes.** The domain, theory and fingering tests can run in this container if a Swift toolchain becomes available. |
| `AnalysisEngine` | MusicCore | AVFoundation, Accelerate, CoreML, MusicUnderstanding | No |
| `PlaybackEngine` | MusicCore | AVFoundation | No |
| `Persistence` | MusicCore | Foundation only | **Yes** |
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
| 8 | Persist | `SongAnalysis` JSON (atomic write) plus an `AnalysisRecord` summary in the library index | — | Fatal |

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

> **Found in M0 CI (Xcode 27.1 / iOS 27.1 SDK):** `AVAudioEngine.connect(_:to:format:)` and `AVAudioPlayerNode.play()` are **deprecated in iOS 27.0**. They still work, but M1 must look up the replacement API in the iOS 27 SDK before building the PlaybackEngine on them.

## 7. Persistence

| Data | Store | Why |
|---|---|---|
| `Song` + `AnalysisRecord` summary (title, artist, duration, file name, content hash, dates, status, BPM, key, quality) | `library.json`: one index file, loaded at launch and written atomically by the `LibraryStore` actor | A personal library is dozens of songs (KB of data). No query engine needed. |
| `SongAnalysis` (notes, chords, contours, sections) | **Versioned JSON file** per song | Large immutable payload; loads atomically and versions cleanly |
| `StudioState` (position, loop, speed, mode), `Bookmark`, `UserFingeringOverride` | `Songs/<uuid>/user-state.json` | Kept separate so re-analysis never overwrites user state |
| `PracticeSession` (post-MVP, measured values only) | `Songs/<uuid>/practice.json` | |
| Imported audio | `Application Support/Songs/<uuid>/` | Private, not visible in Files, excluded from iCloud backup (re-importable; saves the user's quota) |

Every file carries `schemaVersion`. Migrations are explicit decode-old → encode-new functions with tests. Writes are atomic (`Data.write(options: .atomic)`), so a crash can never leave a half-written file. Deleting a song removes its audio, analysis JSON, caches and user state.

## 8. Dependencies

| Dependency | Use | License | Justification |
|---|---|---|---|
| Basic Pitch Core ML model (`nmp.mlpackage`, ~270 KB) | Note transcription | Apache-2.0 | Best size-to-quality polyphonic transcription available on-device. Attribution is shown in Settings › Licenses, with the NOTICE included. |
| xtool (dev tool) | Build, sign and install without a Mac | MIT | The only practical path to the owner's iPhone without a Mac. Not shipped. |
| swift-snapshot-testing (test only, optional) | Visual regression of design-system components | MIT | Catches UI regressions in the fretboard renderer |

Everything else is Apple frameworks: SwiftUI, Observation, AVFoundation, Accelerate, Core ML, MusicUnderstanding, Core Haptics, BackgroundTasks, MediaPlayer and os. **No analytics or ad SDKs.**

## 9. Testing strategy

| Level | What | Where it runs |
|---|---|---|
| Unit (MusicCore) | Pitch and interval math, tuning and capo, chord templates, power-chord rules, the fingering DP (invariants plus canonical riffs), tab layout and measure quantization, Codable round-trips | macOS / iOS simulator; Linux when a toolchain is available |
| Unit (AnalysisEngine) | The Swift note decoder against **golden vectors** from the Python `basic-pitch` reference (same activations in, same notes out), chord Viterbi, beat-sync pooling, gating | iOS simulator / macOS |
| Integration (pipeline) | **Synthesized fixtures** with known ground truth, generated by `tools/fixtures` (Karplus-Strong plucked strings plus click tracks; original and rights-free): single-note riffs, power-chord progressions, open chords, and tempo-ramp clicks. Assertions use mir_eval-style metrics, with thresholds set from *measured* baselines. | iOS simulator |
| Accuracy harness (not a CI gate at first) | GuitarSet (CC BY 4.0): note onset F1, chord accuracy, and tempo error per `pipelineVersion`. Results go to `docs/quality/` with the exact numbers. **These are the only accuracy numbers RIFFNEX may quote.** | macOS (scripted) |
| Playback | Clock math (rate, loop, seek, latency offset) as pure functions; engine smoke test on the simulator | iOS simulator |
| UI (XCUITest) | **Deferred.** It needs an Xcode project host, which xtool doesn't provide. Until then: view models are unit-tested, plus a manual on-device checklist per milestone. | — |
| Performance | In-app **Diagnostics**: per-stage analysis wall-time (`ContinuousClock`), a frame-time and hitch counter driven by `CADisplayLink` in the Studio, and memory high-water mark (`task_vm_info`). MetricKit daily reports. There is no Instruments without a Mac, so numbers come from the device itself. | Owner's iPhone, per milestone |

**Observability:** `os.Logger` per subsystem (`analysis`, `playback`, `persistence`, `ui`) and `OSSignposter` intervals around each pipeline stage. `MetricKit` covers hangs, crashes and energy. A Debug-only **Diagnostics** screen shows stage timings and outcomes for each song. No remote telemetry in the MVP.

## 10. Privacy, legal & App Store

> Current distribution: **personal device only** (no App Store). Store-specific items below are kept for future reference but are not MVP work.

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
| ADR-7 | Codable JSON files for library, analysis and user state | SwiftData; GRDB/SQLite | SwiftData macros are unproven under xtool. A personal library is small. Plain files are simplest and testable on Linux. |
| ADR-8 | Pure-Swift `MusicCore` module | Single app target | The highest-risk logic is fully testable in isolation, including on Linux. |
| ADR-9 | SwiftPM + xtool, with macOS CI for verification | XcodeGen/Xcode (needs a Mac) | The owner has no Mac. CI on GitHub's macOS runners gives automated compile and test evidence. |
| ADR-10 | Compile the Core ML model on device at first launch | Precompiled `.mlmodelc` from Xcode | No `coremlc` outside Xcode. `MLModel.compileModel(at:)` is a public API, and the result is cached. |
