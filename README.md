# RIFFNEX

**Da escuta ao toque. (From listening to playing.)** RIFFNEX is an iPhone app that turns songs you own into an interactive guitar lesson. It analyzes the audio on-device, then shows notes, chords and recommended fingering on a fretboard, all synced to the recording.

> **Status: M0 (foundation).** The project scaffold, the MusicCore domain with tests, the design tokens, and an on-device **Diagnostics** screen that exercises every risky capability (Core ML, Music Understanding, audio decode and playback, localization, logs). Song import starts in M1.

## Documents

| Doc | Contents |
|---|---|
| [`docs/01-product-discovery.md`](docs/01-product-discovery.md) | Vision, persona, journey, differentiators, technology research, risks, on-device feasibility |
| [`docs/02-design-system.md`](docs/02-design-system.md) | Design principles, tokens, typography, motion, haptics, navigation, screens and states, fretboard interaction model, accessibility |
| [`docs/03-architecture.md`](docs/03-architecture.md) | Modules, domain model, analysis pipeline, fingering optimizer, playback, persistence, dependencies, testing, privacy, decision log |
| [`docs/04-roadmap.md`](docs/04-roadmap.md) | MVP scope, explicit exclusions, milestones, open decisions |

## Planned stack

Swift 6 · SwiftUI · AVAudioEngine · Core ML (Spotify Basic Pitch, Apache-2.0) · Apple Music Understanding (iOS 27) · Accelerate. No backend in the MVP; all analysis runs on-device.

## Build instructions

See **[`docs/toolchain.md`](docs/toolchain.md)** for step-by-step instructions (in Portuguese). No Mac is required. Builds use [xtool](https://github.com/xtool-org/xtool) on Linux or Windows (WSL) with Swift 6.4 and an iOS SDK extracted from Xcode 27.1, and the app is installed on the iPhone over USB. CI builds and tests on GitHub Actions macOS runners.

### Tests

- `swift test`: MusicCore tests. Runs on macOS, and on Linux with Swift 6.x.
- CI (`.github/workflows/ci.yml`) runs a Linux job for MusicCore and an `xcode-27` macOS job that builds the app for iOS and runs the package tests on the iOS simulator.

### Regenerating assets

- `python3 tools/make_icon.py` regenerates `App/AppIcon.png` (needs numpy and Pillow).
- `python3 tools/fixtures/make_demo.py` regenerates the demo song and its ground truth (needs numpy and ffmpeg).

## Licenses

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
