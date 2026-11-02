# RIFFNEX

**Da escuta ao toque. (From listening to playing.)** RIFFNEX is an iPhone app that helps you learn guitar parts **by ear** from songs you own. It separates the guitar from the rest of the band on the device, then lets you hear the guitar alone, the band without it, or both, at any speed, and catch a riff in a ring that repeats it until you can play it.

> **Status: one-screen rewrite (Nov 2026).** After testing the note-transcription version on the owner's iPhone, we cut every feature built on automatic note detection (tab, fingering, highway, chords, metronome, quality report). Their accuracy on full-band songs was not good enough to teach from. What stayed is what the device measures reliably:
> - guitar separation (Demucs `htdemucs_6s`, Core ML);
> - tempo, beats and sections (Apple Music Understanding);
> - loudness envelopes and guitar attacks measured on the separated audio.
>
> Every number on screen is something the app really knows: laps, speed, time practised. Test script for the owner's iPhone: [`docs/teste-arena.md`](docs/teste-arena.md) (Portuguese). The design documents below describe the original plan and are kept for history.

## Documents

| Doc | Contents |
|---|---|
| [`docs/01-product-discovery.md`](docs/01-product-discovery.md) | Vision, persona, journey, differentiators, technology research, risks, on-device feasibility |
| [`docs/02-design-system.md`](docs/02-design-system.md) | Design principles, tokens, typography, motion, haptics, navigation, screens and states, fretboard interaction model, accessibility |
| [`docs/03-architecture.md`](docs/03-architecture.md) | Modules, domain model, analysis pipeline, fingering optimizer, playback, persistence, dependencies, testing, privacy, decision log |
| [`docs/04-roadmap.md`](docs/04-roadmap.md) | MVP scope, explicit exclusions, milestones, open decisions |

## Stack

Swift 6 · SwiftUI (Canvas) · AVAudioEngine · Core ML (Demucs v4 `htdemucs_6s`, MIT) · Apple Music Understanding (iOS 27) · Accelerate. No backend; everything runs on-device.

## Build instructions

**Easiest:** every push to the app branch is uploaded to TestFlight (`.github/workflows/testflight.yml`; setup in [`docs/testflight.md`](docs/testflight.md), Portuguese). CI also builds an unsigned `.ipa` on every push (`.github/workflows/ipa.yml`); install it with Sideloadly — see **[`docs/instalar-no-windows.md`](docs/instalar-no-windows.md)** (Portuguese). Alternatively see **[`docs/toolchain.md`](docs/toolchain.md)** for step-by-step instructions (in Portuguese). No Mac is required. Builds use [xtool](https://github.com/xtool-org/xtool) on Linux or Windows (WSL) with Swift 6.4 and an iOS SDK extracted from Xcode 27.1, and the app is installed on the iPhone over USB. CI builds and tests on GitHub Actions macOS runners.

### Tests

- `swift test`: MusicCore and Persistence tests. On Linux, run `RIFFNEX_CORE_ONLY=1 swift test`, which drops the iOS-only targets.
- CI (`.github/workflows/ci.yml`) runs a Linux job for MusicCore and an `xcode-27` macOS job that builds the app for iOS and runs the package tests on the iOS simulator.

### Regenerating assets

- `python3 tools/make_icon.py` regenerates `App/AppIcon.png` (needs numpy and Pillow).
- `python3 tools/fixtures/make_demo.py` regenerates the demo song and its ground truth (needs numpy and ffmpeg).
- `python tools/separation/convert_htdemucs.py` converts Demucs to Core ML (run in CI by `.github/workflows/separation-model.yml`).

## Licenses

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
