# M0: What the real device showed

> Device: iPhone 14 Plus, iOS 27.0.1 · Build: xtool (Windows + WSL), signed with a free Apple ID · Date: 2026-10-31

## Toolchain checks

| Check | Result |
|---|---|
| xtool build on WSL | ✅ Builds in about 10 s on a warm build. |
| Install over USB via usbipd | ❌ Hangs at “[Connecting] 100%” (known issue, [xtool#19](https://github.com/xtool-org/xtool/issues/19)). |
| Install via the Windows usbmuxd relay (Apple Devices app + `netsh portproxy`) | ✅ Works. This is the documented path in `docs/toolchain.md`. |
| Developer Mode | The option appears only after the first install attempt. |
| SwiftUI + `@Observable` | ✅ |
| `pt-BR.lproj/Localizable.strings` in `Bundle.module` | ✅ |
| SwiftPM resources (demo m4a in `Riffnex_RiffnexApp.bundle`) | ✅ |
| AVAudioEngine playback | ✅ |
| Audio decode | ✅ after the fix. `AVAudioFile.read` threw `kAudioFileEndOfFileError` (-39) when called at EOF; the decoder now checks `framePosition`, and simulator tests cover it. The demo (21.5 s, 44.1 kHz mono AAC) decodes to mono 22 050 Hz in **76 ms**. |
| Basic Pitch on-device compile and inference | ✅ Compiled on device and cached. Input `[1, 43844, 1]`; outputs notes `[1, 172, 88]`, onsets `[1, 172, 88]`, contour `[1, 172, 264]`. One window took **1 816 ms**, with a maximum note activation of 0.84 at MIDI 45 (A2, a note the demo riff plays in its first 2 s). |

## Music Understanding on the demo song (ground truth in `tools/fixtures/riffnex-demo.truth.json`)

| Quantity | Ground truth | Music Understanding |
|---|---|---|
| Tempo | 96 BPM | **96** (`rhythm.beatsPerMinute`) |
| Beats | every 0.625 s | Exact (35 beats, `CMTime` at timescale 44 100) |
| Bars | every 2.5 s, 4/4 | Exact (`rhythm.bars`) |
| Key | E minor | **E minor** (`key.ranges[].value = {tonic: "e", mode: "minor"}`) |
| Sections | 0–10 s riff, 10–20 s power chords | `structure.sections`: 0–10 s, 10–20 s, 20–21.5 s (tail) |
| Phrases | 2 bars each | `structure.phrases`: 5 s each ✅ |

**Facts learned about the API (iOS 27.0.1):**
- `instrumentActivity.activity` has exactly four classes: **`bass`, `drum`, `vocal`, `other`**. **There is no guitar class**, so guitar falls under `other`. Values come every 0.05 s (2 205 samples at 44.1 kHz). `instrumentActivity.ranges` gives the active spans per class.
- No confidence values are exposed for tempo, key or structure. This matches the documentation.
- The JSON also contains undocumented `structurePredictions` (raw tensors: `kinds` [1, 3, 430], `pace` [1, 41, 430], `phrases`/`sections`/`segments` [1, 430], `predictionResolution` 0.05, `detectionThreshold` 0.33). These are not part of the documented API, so **we do not depend on them**.
- **Performance:** a second run took **14.15 s** for 21.5 s of audio (0.66× real time), so the first run includes a one-time warm-up. The first run took 23.5 s to analyze 21.5 s of audio with `.rhythm`, `.key`, `.structure` and `.instrumentActivity` requested. That is slower than real time on the A15. **This must be measured on a full-length song** before deciding how analysis progress and background execution should work. It may be a first-run cost, or it may be `instrumentActivity`/`structure`.

## Open performance question: Basic Pitch speed

1.8 s for a 2 s window is close to real time. A 4-minute song (about 130 windows) would take about 4 minutes if that holds. That measurement was a **single, first** prediction with `.all` compute units, so it likely includes Core ML's one-time specialization for the device. M2 must benchmark many consecutive windows, compare `.all`, `.cpuAndNeuralEngine` and `.cpuAndGPU`, and try batching windows, before choosing the analysis UX.

## Consequences for the plan

1. **Adopt Music Understanding for tempo, beats, bars, key and sections.** Exact results on the fixture justify relying on it, while we keep validating on real songs.
2. **Instrument gating:** use `other` activity (and the absence of `vocal`/`bass` dominance) only as a *weak* signal. The architecture doc's “if guitar is supported” branch resolves to: guitar is not a class.
3. **Analysis UX:** if full songs also run slower than real time, the Analysis screen must show the Music Understanding stage as long-running and indeterminate. Basic Pitch can run in parallel. Background continuation becomes important.
4. Section labels (A/B/A′) still come from our own chord-sequence similarity, because the framework gives unlabeled ranges.
