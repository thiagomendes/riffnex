# RIFFNEX — Phase A: Product & Technical Discovery

> Status: **Draft for approval** · Last updated: 2026-10-31
> Facts marked **[verified]** were checked during discovery against primary sources: Apple developer documentation or the published Basic Pitch package. Facts marked **[to verify]** must be confirmed on a Mac with the current Xcode SDK before we depend on them.

---

## 1. Product vision

**“Da escuta ao toque.” / “From listening to playing.”**

RIFFNEX turns a song you own into something you can play. Import an audio file, and RIFFNEX listens to it on-device. It finds the beat, the key, the sections, the chords and the notes. Then it lays them out on a living guitar fretboard, synced to the real recording, with fingering you can actually play.

RIFFNEX is not a tab viewer. It is **an honest instrument teacher that shows its work**: what it heard, what it inferred and what it recommends. It also shows how sure it is about each of those.

## 2. Primary persona

**Rafa, 24, São Paulo: the self-taught “almost-there” guitarist**

| | |
|---|---|
| Experience | 1–3 years, self-taught. Knows open chords, power chords, the minor pentatonic box and some riffs. |
| Gear | Electric guitar with a small amp or plug-in, plus an acoustic at home. Practices with headphones or the phone on a music stand. |
| Habits | Learns from YouTube, chord sites (cifras) and tabs. Practices 20–40 min in the evenings. |
| Frustrations | Tabs for the songs Rafa loves are missing, wrong, or in the wrong position on the neck. Tabs are never synced to the record. Slowing a song down is clumsy. Rafa cannot tell whether what they are playing is right. |
| Motivation | “I want to play *this* song, the way it sounds on the record, and know I'm getting closer.” |
| Language | Brazilian Portuguese first. Reads chord names in letter notation (C, Am, G5). |

**Secondary personas, which shape decisions but are not the first target:**
- **The band member** who wants to learn parts from their own band's demos and rehearsal recordings. They own the rights, and the recordings are often guitar-heavy, which is ideal input.
- **The returning player** who stopped years ago and needs gentle, progressive steps.

**Explicitly not the first target:** absolute beginners who cannot yet fret a note (they need a curriculum, not transcription), and professional transcribers (they need notation-grade editing).

## 3. Refined core journey

```
 Onboarding (once)      Home / Library          Import                 Analysis
 IMPORT·DISCOVER·PLAY → recent · continue  →  document picker   →  live pipeline stages
                        big “Importar”         validation             (real, not faked)
                                                                         │
     Practice Summary  ←  Learning Studio   ←   Song Overview   ←────────┘
     (real measures,      fretboard · tab ·     tempo · key · sections
      post-MVP)           timeline · loop ·     analysis quality
                          speed · count-in      “Aprender esta música”
```

Journey refinements from discovery:
1. **The first song must succeed.** A bad first transcription kills trust. We ship an **original demo recording**, created by us and licensed for the app, and run it **through the real pipeline** at first launch. It is not precomputed. That way the first experience shows real, high-quality output.
2. **Set expectations at import time, not after failure.** The import sheet says in one line that results are best on guitar-forward recordings, and that dense full-band mixes get chords and rhythm reliably but individual notes less reliably.
3. **Uncertainty is part of the UI, not a disclaimer.** Low-confidence notes look different (dashed, desaturated). The Overview shows an analysis-quality summary that comes from measured signals.
4. **The Studio is the product.** Everything else is a funnel into it. The design and engineering budget is weighted accordingly.

## 4. Differentiators

1. **Your recording, in sync.** Notes and chords are locked to the actual audio timeline, so loop, slow down and follow along always line up with what you hear. Generic tabs cannot do this.
2. **Playable fingering, not just pitches.** Positions come from an optimizer that minimizes hand movement and respects human reach. Every note carries alternative positions you can switch to.
3. **Honest AI.** Each event carries provenance (*detected / inferred / recommended / edited by you*) and confidence. When RIFFNEX is unsure, it says so.
4. **Private by design.** The MVP does all analysis on-device. Audio never leaves the phone.
5. **The fretboard as the hero.** It is a beautiful, fluid instrument, not a diagram.

## 5. Technology research summary

| Capability | Candidate | Findings | Decision |
|---|---|---|---|
| Beats, bars, tempo, key, structure, instrument activity | **Apple Music Understanding** (`MusicUnderstandingSession`, WWDC26) | **[verified]** iOS 27+. Runs on-device and offline. `analyze(for: Set<AnalysisType>)` with `.rhythm`, `.key`, `.structure`, `.instrumentActivity`, `.loudness` and `.pace`. Results are `Codable`, `Sendable` and `CMTime`-based. Accepts an `AVAsset` or a streaming provider. **No chords, notes, pitch or source separation. No confidence values exposed.** Sections are unlabeled `CMTimeRange`s. **[to verify]** Whether `Instrument` includes guitar; Apple's examples name only drums, bass and vocals. | **Adopt** for rhythm, key and structure. Treat instrument activity as optional. |
| Polyphonic note transcription | **Spotify Basic Pitch** (ICASSP 2022) | **[verified]** Apache-2.0 code and weights. Spotify ships an official Core ML package `nmp.mlpackage` (~270 KB) in `basic-pitch` 0.4.0. The input is raw mono audio at 22,050 Hz in windows of 43,844 samples (2 s − 1 hop), and the **CQT is computed inside the model**. Outputs are 88-pitch note and onset activations and 264-bin (3 per semitone) pitch contours at ~86 frames/s (hop 256). Note decoding (onset peak-picking, thresholds, minimum length of 11 frames, energy tolerance) is NumPy post-processing that we must **port to Swift**. The model is instrument-agnostic and was trained on data that includes guitar. | **Adopt** as the note engine. |
| Chords and power chords | Custom: pitch-class profile + templates + HMM/Viterbi | No Apple API. A classic, well-understood approach that is cheap with Accelerate. It can consume Basic Pitch activations, which are already harmonic-aware, aligned to the Music Understanding beat grid. | **Build** (small, testable). |
| Guitar source separation | Demucs / HTDemucs (MIT), `htdemucs_6s` has a guitar stem | Heavy: tens of MB of weights and minutes of compute per song. Transformer and LSTM blocks are hard to run efficiently on the Neural Engine. The guitar stem is known to be the weakest of the six. | **Defer.** Revisit as optional server-side processing with explicit upload consent (post-MVP). |
| Direct tablature estimation | TabCNN, FretNet (research; trained on GuitarSet) | Promising but trained on small datasets and not production-hardened. Licenses vary by repo. | **Research track** after MVP. Our optimizer is the baseline to beat. |
| Large seq2seq transcription | MT3 (Apache-2.0) | Large transformer, impractical on-device. | Reject for MVP. |
| General LLM | — | Cannot transcribe audio reliably. Could later help *explain* theory in text. | Not used for analysis. |
| Live pitch for practice | YIN / pYIN on `AVAudioEngine` input tap, Accelerate | Reliable for **single clean notes**. Chords can be checked only loosely, with a pitch-class match against the expected chord. | Post-MVP Practice v1. |
| Evaluation data | **GuitarSet** (CC BY 4.0, hexaphonic annotations) plus synthesized fixtures | Gives us *measured* note F1 and chord accuracy for each pipeline version. | **Adopt** for the offline evaluation harness. |

## 6. Feasibility & major risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | **Note transcription on full-band mixes is noisy.** Bass, vocals and keys produce notes in the guitar range. | **High** | Position the MVP around guitar-forward audio. Gate notes to the guitar range. Show confidence visually. Lead with chords and rhythm, which are robust on mixes. Use instrument activity for gating if guitar is supported. Measure on GuitarSet. Add separation later. |
| R2 | Music Understanding requires **iOS 27** and exposes no confidence. | Medium | Decision D1 (below). Present tempo and key as *“estimado”* (estimated) with no fake percentages. Cross-check key against chord statistics and flag disagreement. |
| R3 | Guitar may not be among the detected instruments. | Medium | Treat as a bonus signal. The pipeline must work without it. |
| R4 | Fingering “correctness” is subjective. | Medium | Optimize for playability, label positions as *recommended*, and let the user pick alternatives. |
| R5 | Analysis time and battery on older iPhones. | Medium | Basic Pitch is tiny (~270 KB model). Process in windows off the main thread, use `BGContinuedProcessingTask` **[to verify, iOS 26+]** for user-initiated background continuation, and cache stage outputs by content hash. Measure on the oldest supported device. |
| R6 | Real-time practice feedback: latency, room noise, playback bleed into the mic, distortion. | High (post-MVP) | Headphones-first practice mode, round-trip latency calibration, monophonic feedback only at first, and explicit *“não consegui ouvir com clareza”* (“I couldn't hear clearly”) states. |
| R7 | Copyright and App Store guideline 5.2 (intellectual property). | Medium | Local, user-supplied files only. Rights reminder at import. No sharing or export of transcriptions in the MVP. No streaming-service extraction. |
| R8 | **Development environment:** this cloud container is Linux with no Xcode and cannot build or run iOS. | **High (process)** | Pure-Swift core modules (domain, theory, fingering) are designed to be platform-independent. iOS builds, UI tests and on-device measurement need **a Mac with the Xcode 27 SDK or macOS CI** (GitHub Actions). Nothing will be declared “working” until it has built and passed tests there. |

## 7. What runs on-device (MVP: everything)

| Stage | Where | Notes |
|---|---|---|
| Decode and resample | On-device (AVFoundation, Accelerate) | Mono, 22,050 Hz float32. |
| Rhythm, key, structure | On-device (Music Understanding) | iOS 27+. |
| Note transcription | On-device (Basic Pitch, Core ML) | ~270 KB model. CPU/GPU/ANE compute units chosen after measurement. |
| Chords and power chords | On-device (Swift + Accelerate) | Beat-synchronous. |
| Fingering and tab layout | On-device (pure Swift) | Viterbi/DP optimizer. |
| Source separation | **Not in MVP** | Future server-side option, requiring explicit consent. |

**No backend in the MVP.** Nothing in the chosen capabilities requires one.

## 8. Minimum viable vertical slice

> **Import a song → watch real on-device analysis → see an honest overview → learn it in a Studio where the fretboard, tab, chord lane and audio move as one, with loop, slow-down and count-in.**

The scope, exclusions and milestones are in [`04-roadmap.md`](04-roadmap.md).

## 9. Decisions requested

- **D1: Minimum iOS version. Recommendation: iOS 27.** Music Understanding gives us production-grade rhythm, key and structure analysis on-device. Supporting iOS 18–26 would mean building and maintaining our own beat tracker, key estimator and segmenter. That roughly doubles the analysis surface for a product that would launch in 2027 anyway. Alternative: iOS 18 minimum plus a custom DSP fallback, which costs about one extra milestone.
- **D2: Build environment.** Do you have a Mac with Xcode 27? Should we set up GitHub Actions macOS CI so every increment is built and tested?
- **D3: Demo content.** Approve an **original** demo riff that we produce for bundling (synthesized or recorded by you), run through the real pipeline.
- **D4: Identity.** Bundle identifier, Apple Developer team, and confirmation of “RIFFNEX” as the display name.
