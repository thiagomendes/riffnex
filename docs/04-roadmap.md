# RIFFNEX — MVP Scope & Milestone Plan

> Status: **Draft for approval** · Last updated: 2026-10-31

## 1. MVP: what's in

The MVP is one end-to-end vertical slice. It is complete when a user can do all of the following with a real file:

1. Go through onboarding (IMPORT · DISCOVER · PLAY), with no permission prompts.
2. Import an MP3, WAV or M4A file they own, with validation, cancellation and clear errors.
3. Watch real on-device analysis with honest stage progress.
4. See the Song Overview: duration, estimated tempo, key, sections, and an analysis-quality level explained by measured signals.
5. Open the **Learning Studio** in Neck or Tab mode, where the fretboard, tab strip, chord lane and audio are synchronized.
6. Use recommended fingering with finger numbers, power-chord and barre shapes, and alternative positions per note.
7. Play, pause, seek precisely, loop a section or a custom region, change speed (25–125%) with pitch preserved, use the metronome on the analyzed beat grid, use a count-in, and set bookmarks.
8. Have everything persist locally: library, analysis, Studio state and fingering overrides.
9. Use the app in pt-BR with VoiceOver, Dynamic Type and Reduce Motion support.
10. Rely on automated tests for critical behavior (see `03-architecture.md` §9).

## 2. Explicit exclusions (not in MVP)

| Excluded | Planned for |
|---|---|
| Practice mode with microphone listening and feedback | M5 |
| Flow mode (note highway) | M6 |
| Detection of bends, slides, hammer-ons, pull-offs, vibrato and palm mute (the renderer supports them; detection does not) | M7 |
| Editing transcriptions (beyond choosing alternative positions) | M8 |
| Guitar source separation (server-side, opt-in) | M9, needs legal review |
| Alternative tunings in the UI (the model supports them; the MVP exposes standard tuning only) | M8 |
| English localization (the architecture is ready; strings are not translated) | M8 |
| iPad-specific layout, Mac, watchOS | Later |
| Streaming integrations (Spotify, Apple Music) | Not planned. Licensing does not allow it. |
| Accounts, cloud sync, sharing or exporting tabs, social features, gamification, streaks | Later, with a rights review for sharing |
| Any accuracy or “mastery” percentage not backed by measurement | Never |

## 3. Milestones

Each milestone ends with a build on Xcode 27, a green test suite, and a short demo recording or notes. Accuracy claims come only from the evaluation harness.

### M0 · Foundation
- Repository layout, XcodeGen `project.yml`, the `RiffnexKit` package and its targets, swift-format config, `.gitignore`.
- GitHub Actions: build plus unit tests on a macOS runner with Xcode 27 (and the `MusicCore` tests on Linux if feasible).
- DesignSystem tokens (colors, type, spacing, motion, haptics) and a component gallery preview.
- `MusicCore` domain types, pitch, interval and tuning math, with tests.
- **Exit:** an empty app shell launches on the simulator and CI is green.

### M1 · Library, import & playback
- Onboarding (the full animated sequence plus a Reduce Motion variant).
- Import flow with validation, DRM detection, deduplication by content hash and cancellation.
- SwiftData library (`VersionedSchema`) and Home screen states (empty, list, continue practicing).
- `PlaybackEngine`: play, pause, precise seek, rate, gapless loop, clock with latency compensation, interruptions and route changes, Now Playing.
- Waveform overview and timeline scrubbing.
- **Exit:** import a real MP3, loop 8 seconds at 70% with no gap or drift. Clock math and import validation have tests. The UI test runs onboarding → import → playback.

### M2 · Analysis v1 (the engine)
- `tools/fixtures`: generator for synthesized, rights-free fixtures with ground truth. Python scripts produce golden vectors with the reference `basic-pitch`.
- Decode stage, Music Understanding stage, Basic Pitch inference and a **Swift port of note decoding**, validated against the golden vectors.
- Guitar-range gating, chord and power-chord estimator, section labeling, quality report.
- `AnalysisCoordinator`: progress stream, cancellation, checkpoints, background continuation.
- Analysis screen with real stage progress, and the Song Overview.
- Evaluation harness on GuitarSet, with the first measured baseline written to `docs/quality/`.
- **Exit:** fixtures pass their thresholds, the GuitarSet baseline is documented, a 3-minute song analyzes on a mid-range device in a measured, documented time, and cancellation leaves no partial state.

### M3 · Learning Studio (MVP vertical slice complete)
- Fingering optimizer (DP plus shape library) with invariant and canonical-riff tests.
- `FretboardView` (Canvas): geometry, follow and pan, markers, sustain, anticipation, chords and barres, power chords, low-confidence styling, left-handed and orientation options.
- Tab strip with measure layout from the bar grid, the chord lane, and the mini timeline with sections, loop handles and bookmarks.
- Note popover with provenance, confidence and alternatives; re-optimization with pins.
- Metronome and count-in. Studio state persistence.
- **Exit:** the full MVP journey works on device with the demo song and with user files. 120 Hz is held on a ProMotion device and 60 Hz on the oldest supported device, measured with Instruments.

### M4 · MVP hardening → TestFlight
- Accessibility pass (VoiceOver rotor, Dynamic Type at AX sizes, Increase Contrast, Differentiate Without Color).
- Complete the pt-BR copy review, privacy manifest, licenses screen, App Store metadata draft.
- Performance and memory pass, plus edge cases (very short or long files, silence, mono or stereo, odd sample rates, files without a clear beat).
- **Exit:** TestFlight build, with a known-limitations list published in the README.

### Post-MVP
- **M5 · Practice v1:** microphone permission flow, headphones-first, latency calibration, tuner, monophonic note-hit feedback (pYIN) with explicit “couldn't hear clearly” states, and a Practice Summary with real measurements only.
- **M6 · Flow mode:** the note highway, with a Metal renderer if profiling requires it.
- **M7 · Techniques:** bends and vibrato from the Basic Pitch contours, slides from pitch glides, hammer-ons and pull-offs from onset strength. Each ships only once measured.
- **M8 · Editing, tunings, English:** note editing, Drop D / E♭ / custom tunings and capo in the UI, English localization.
- **M9 · Separation (optional, server):** opt-in Demucs-based guitar stem with consent and retention policy, after legal review.
- **Research:** direct tab estimation (TabCNN/FretNet-style), measured against our optimizer.

## 4. Open decisions (blocking M0)

- **D1:** iOS 27 minimum (recommended) or iOS 18 plus a custom DSP fallback.
- **D2:** A Mac with Xcode 27 and/or GitHub Actions macOS CI. This container is Linux and cannot build iOS.
- **D3:** An original demo riff to bundle.
- **D4:** Bundle ID, team and display name.
