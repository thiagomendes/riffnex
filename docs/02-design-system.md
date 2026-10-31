# RIFFNEX — Phase B: Product Design Specification

> Status: **Draft for approval** · Last updated: 2026-10-31

## 1. Design principles

1. **The music is the light source.** The interface is dark and quiet until music plays. Then light comes *from* the notes. Glow is reserved for things that are sounding right now.
2. **One instrument, not a dashboard.** The Studio is a single composed surface. Avoid cards stacked on cards. Use hierarchy through scale, light and depth.
3. **Truth is visible.** Confidence and provenance are visual properties (solidity, saturation, outline), not footnotes.
4. **Motion follows the music.** Anything tied to playback is driven by the audio clock, not by animation curves. Anything tied to the user's touch uses springs.
5. **Hands are busy.** Big targets, few controls, and everything reachable with one thumb while holding a guitar. Defaults are good enough that the user rarely needs settings.

## 2. Visual language

### 2.1 Color tokens (dark-first)

| Token | Value | Use |
|---|---|---|
| `bg.base` | `#07070A` | App background (near-black, slightly cool) |
| `bg.surface` | `#0E0F14` | Sheets, Studio panels |
| `bg.raised` | `#161721` | Controls, selected rows |
| `fretboard.wood` | `#121219` → `#0B0B10` vertical gradient | Fretboard body: graphite, not skeuomorphic wood |
| `fretboard.fret` | `#8E93A6` @ 55% | Fret wires (thin metallic gradient) |
| `fretboard.string` | `#C9CCD8` @ 35–70% (thicker strings are dimmer) | Strings |
| `line.hairline` | `#FFFFFF` @ 8% | Separators |
| `text.primary` | `#F4F4F7` | |
| `text.secondary` | `#F4F4F7` @ 64% | |
| `text.tertiary` | `#F4F4F7` @ 40% | |
| `accent.violet` *(“Riff”)* | `#7C5CFF` | Brand, primary actions, upcoming notes |
| `accent.blue` *(“Pulse”)* | `#3D7BFF` | Timeline, playhead, loop region |
| `accent.cyan` *(“Signal”)* | `#3FE0E8` | **Sounding now**: active notes, current chord |
| `state.success` | `#4ADE9B` | Practice hits (post-MVP) |
| `state.warning` | `#F5B946` | Low-confidence callouts, analysis warnings |
| `state.error` | `#FF5C6C` | Errors only |

- **Brand gradient:** violet → blue → cyan (`#7C5CFF → #3D7BFF → #3FE0E8`). Used sparingly: the app icon, the onboarding hero, the primary CTA highlight and the active-note glow core.
- **Glow rule:** at most one glowing element family on screen at a time (the sounding notes). Glow is a soft blur at about 30% opacity with a radius proportional to marker size. No neon outlines on chrome.
- **Light mode:** the color tokens are defined as an asset catalog with a light variant (the base is `#F6F6F9`) so a light theme is possible later. The MVP ships with dark appearance enforced in the Studio and system appearance elsewhere. **[decision: we may force dark app-wide for MVP]**
- **Contrast:** text tokens meet WCAG AA on `bg.base`. Increase Contrast raises secondary and tertiary text to 80% and 60%, and thickens strings and frets.

### 2.2 Typography

System fonts only: no licensing risk, full Dynamic Type, and native rendering.

| Style | Font | Notes |
|---|---|---|
| Display (song titles, onboarding words) | SF Pro, `.fontWidth(.expanded)`, Bold | Wide, confident display type that gives RIFFNEX its signature |
| Title / Headline / Body / Caption | SF Pro (text styles) | Standard Dynamic Type text styles |
| Numerics (BPM, time, fret numbers) | SF Pro with `.monospacedDigit()` | Prevents jitter while values change |
| Tablature digits | SF Mono, Medium | Tab grid alignment |
| Chord symbols | SF Pro Rounded, Semibold | Friendly and highly legible at a distance (phone on a music stand) |

Hierarchy: one display element per screen, at most. Chrome text sizes scale with Dynamic Type up to AX5. Fretboard labels scale up to a clamp (see §6).

### 2.3 Spacing, shape, depth

- **4-pt grid:** 4, 8, 12, 16, 24, 32, 48, 64. Screen margins: 20 (compact) and 24 (regular).
- **Corner radii (continuous):** 10 (chips), 16 (controls), 24 (panels), 32 (hero artwork).
- **Depth:** created by tone steps (`base → surface → raised`) and a single soft shadow for floating elements. No borders on cards. Use hairlines only for structure.
- **Platform materials:** with the iOS 26+ SDK, system bars and controls get the system glass material automatically. We keep system navigation chrome native and **don't imitate glass** on custom surfaces.

### 2.4 Iconography & artwork

- SF Symbols for all UI icons, with matching weights.
- **Song artwork:** use the embedded artwork if the file has it. Otherwise generate a deterministic visual from the song itself, such as a radial plot of the chroma profile tinted with the brand gradient, so every song gets a unique, *meaningful* cover. (This needs only analysis we already compute.)

### 2.5 Motion

| Kind | Spec | Examples |
|---|---|---|
| **Audio-clocked** | Driven per frame from the playback clock with `TimelineView(.animation)`. No implicit animations. | Playhead, tab scroll, note lighting, sustain rings, fretboard follow |
| **Touch response** | Spring `response 0.32, dampingFraction 0.86` | Buttons, chips, mode switch, sheet content |
| **Spatial transitions** | Spring `response 0.55, dampingFraction 0.9`, plus `matchedGeometryEffect` / zoom navigation transition | Library cover → Overview → Studio |
| **Celebration** | Spring `response 0.45, dampingFraction 0.62` (slight bounce) | Rare: analysis complete, section mastered (post-MVP) |
| **Reduce Motion** | Cross-fades replace spatial transitions. The fretboard jumps instead of panning. The tab view pages per measure instead of scrolling continuously. No particle effects. | |

The target device (iPhone 14 Plus) has a 60 Hz display, so the Studio target is a steady 60 fps with no hitches. The code also supports 120 Hz on ProMotion. Any frame work must be O(visible events).

### 2.6 Haptics (Core Haptics / `sensoryFeedback`)

| Moment | Haptic |
|---|---|
| Count-in beats | Light transient per beat (the downbeat is stronger) |
| Loop handle drag snapping to a beat or bar | Selection tick |
| Scrubbing across a chord change | Soft tick |
| Analysis finished | Success notification |
| Error | Error notification |

Off during normal playback (it is distracting while playing). The user can disable all haptics in Settings.

## 3. Navigation architecture

Minimal, a single stack. Tabs are deferred until there is more than one top-level destination worth a tab.

```
App
├── Onboarding (fullScreenCover, first launch only)
└── NavigationStack
    ├── Home / Biblioteca            (root)
    │   ├── ⊕ Import → document picker (sheet) → Analysis (pushed)
    │   ├── Song → Song Overview     (zoom transition from cover)
    │   │        └── “Aprender esta música” → Learning Studio (fullScreenCover, immersive)
    │   └── ⚙︎ Settings (sheet): tuning display, handedness, note naming, haptics, data & privacy, licenses
    └── Learning Studio → Practice Summary (post-MVP, sheet)
```

## 4. Screens & states

### 4.1 Onboarding: IMPORT · DISCOVER · PLAY

Three scenes that form **one continuous animation**, not three slides. Swipe or tap to advance. A Skip button is always visible.

1. **IMPORTE — “Traga a sua música.”** (Bring your music.) A song file icon dissolves into a flowing waveform in brand gradient.
2. **DESCUBRA — “Revele notas, riffs e acordes.”** (Reveal notes, riffs and chords.) The waveform's peaks lift off and condense into note markers. Chord symbols (`Em`, `G5`) resolve above.
3. **TOQUE — “Aprenda na sua guitarra de verdade.”** (Learn on your real guitar.) The markers fly onto a fretboard, which slides in from below. The strings shimmer as each note lands.

CTA: **“Começar”** (Start). It leads to Home with the demo song already analyzing *for real* in the library (D3). **No permission prompts during onboarding.** The microphone permission is requested only when the user first enters Practice mode (post-MVP), after an explanation screen.

Reduce Motion version: three static compositions with cross-fades.

### 4.2 Home / Biblioteca

- **Header:** “RIFFNEX” wordmark (small), settings button.
- **Continue practicing (hero):** the last-opened song with large artwork, the last section practiced, and the loop and speed state. One tap resumes the Studio exactly where the user left off.
- **Library:** a vertical list of songs with artwork, title, duration, key and tempo once known, and an analysis-status pill (*Analisando…* / *Pronta* / *Falhou*).
- **Prominent import:** a large primary button at the bottom (thumb zone), **“Importar música”**.
- **Learning progress:** MVP shows only **true facts**, such as time practiced per song (measured in the Studio) and sections looped. No invented mastery percentages.
- **Empty state:** illustration plus one sentence and the Import CTA.

### 4.3 Import

- `UIDocumentPickerViewController` (via `.fileImporter`) restricted to `UTType.audio` subtypes: `.mp3`, `.wav`, `.mpeg4Audio` (m4a/aac), plus AIFF and CAF because they are free to support.
- **Validation:** readable via `AVURLAsset`, has an audio track, duration between 5 s and 15 min, and the file is not DRM-protected (`hasProtectedContent`). The file is copied into the app's private storage.
- **States:** copying (cancellable) → validating → error with a specific message (“Este arquivo está protegido por DRM e não pode ser analisado.” / “This file is DRM-protected and cannot be analyzed.”, “Formato não suportado.” / “Unsupported format.”, “Arquivo muito longo (máx. 15 min).” / “File too long (max 15 min).”) → success, which navigates to Analysis.
- A one-line rights reminder in the sheet: *“Importe apenas músicas que você tem o direito de usar.”* (“Import only music you have the right to use.”)
- Duplicate detection by content hash offers to open the existing song.

### 4.4 Analysis

A vertical list of **real pipeline stages**. Each stage has a state: *aguardando* (waiting), *em andamento* (in progress), *concluído* (done), *falhou* (failed) or *indisponível* (unavailable).

| Stage (pt-BR) | Progress shown |
|---|---|
| Lendo o áudio (reading the audio) | **Determinate:** frames decoded / total frames (real) |
| Ritmo e compasso (rhythm and meter) | Indeterminate (Music Understanding exposes no progress) |
| Tonalidade e estrutura (key and structure) | Indeterminate |
| Notas (notes) | **Determinate:** model windows processed / total windows (real) |
| Acordes (chords) | Indeterminate (fast) |
| Digitação no braço (fretboard fingering) | Indeterminate (fast) |

- Hero visual: the waveform renders as decoding happens. Detected notes then “rain” onto it as the transcription windows complete. This is real streaming output, not decoration.
- **Cancel** is always available. Leaving the screen keeps analysis running, and the library shows its status. If the app is backgrounded, analysis continues as a user-initiated continued-processing task where supported **[to verify]**. Otherwise it resumes from the last completed stage.
- Failure of an optional stage (for example, instrument activity) shows *indisponível* and does not fail the analysis.

### 4.5 Song Overview

- Large artwork, title (Display style), artist (from metadata, if present), duration.
- **Facts row:** `♩ 128 BPM` *estimado* · `Mi menor` *estimado* · `4/4` (if bars are consistent).
- **Sections:** a horizontal strip proportional to time, labeled A, B, A′… by chord-sequence similarity. Tap to preview-play a section.
- **Qualidade da análise** (analysis quality): one of three levels (*Alta / Média / Baixa*, high / medium / low) with a plain-language explanation built from **measured signals**. Those signals are the share of notes above the confidence threshold, the share of note-dense frames outside the guitar range, and agreement between the estimated key and the chord statistics. For example: *“Muitas notas detectadas fora da região típica da guitarra — a mixagem pode ter outros instrumentos. Acordes tendem a ser mais confiáveis que notas individuais.”* (“Many notes were detected outside the typical guitar range; the mix may contain other instruments. Chords tend to be more reliable than individual notes.”)
- Primary CTA: **“Aprender esta música”** (Learn this song).

### 4.6 Learning Studio (the signature screen)

Portrait layout, top to bottom:

```
┌───────────────────────────────────────┐
│ ✕   Song Title            Seção B ▾   │  compact header
│                                       │
│      Em        G5          D          │  chord lane (current chord glows cyan)
│ ═══════════ FRETBOARD (hero) ════════ │  window of ~5–7 frets that follows the hand
│ ─────────────────────────────────────│
│ e|-------0---------|                  │  tab strip; playhead fixed at ~30% from left
│ B|-----0---0-------|                  │
│ ...                                   │
│ ▁▃▅▇▅▃▁▂▅▇▇▅▃ [==loop==]  │ playhead   │  mini timeline: waveform + sections + loop
│   ⟲  ◀◀   ▶︎/❚❚   ▶▶   70%  ♩  1-2-3-4  │  transport: loop · seek · play · speed · metronome · count-in
└───────────────────────────────────────┘
```

- **Landscape:** the fretboard spans the full width showing about 12 frets, with the tab strip below and a slimmer transport. Landscape is the recommended orientation on a music stand.
- **Mode switcher:** `Braço · Tab` (Neck · Tab) in the MVP, which changes which surface is the hero. *Fluxo* (Flow) and *Prática* (Practice) appear only when they ship. **Unavailable features are never shown as disabled teasers.**
- **Speed:** 25%–125% in 5% steps (pitch preserved). A long press gives presets: 50 / 70 / 85 / 100.
- **Loop:** tap a section to loop it, or drag the handles on the timeline (they snap to beats or bars, with a haptic tick). “Loop this phrase” is a one-tap action from the tab.
- **Count-in:** 1 or 2 bars at the current tempo × speed, with audible clicks and visual numbers before play, and on every loop restart if enabled.
- **Metronome:** sample-accurate clicks on the analyzed beat grid, so they follow tempo changes in the recording.
- **Bookmarks:** long-press the timeline → “Marcar aqui” (mark here).
- **Persistence of state:** position, loop, speed and mode are restored per song.

### 4.7 Practice Summary (post-MVP)

Shown only after a Practice-mode session. It reports **actual measurements**: time practiced, loops completed, and, once listening ships, notes heard at the right pitch and timing offset distribution. Each metric includes the conditions it was measured under. If listening confidence was low, it says so instead of scoring.

## 5. Fretboard interaction model

### 5.1 Geometry

- Fret spacing follows the real rule (`d(n) = L·(1 − 2^(−n/12))`) and is compressed slightly for readability. A *proportional ↔ uniform* blend factor is set to 0.6 by default.
- String spacing is uniform. Stroke weight increases from the high e to the low E.
- Inlays sit at frets 3, 5, 7, 9, 12 (double), 15, 17, 19, 21 and 24, subtle at 6% white.
- **Orientation:** high e on top by default (it matches tab). The setting *“Visão do guitarrista”* (player's view) puts low E on top.
- **Left-handed:** mirrors the fret axis (nut on the right). It applies to the fretboard and Flow mode, but tab stays standard.
- **Visible window:** auto-follows the optimizer's hand position with a spring pan. Dragging pans manually and pauses following for 4 s, with a “recentralizar” (recenter) pill. Pinch zooms between about 5 frets and the full neck.

### 5.2 Event rendering

| Element | Visual |
|---|---|
| Sounding note | Filled circle in cyan with a glow core. Shows the finger number (1–4) or `0` for an open string; the user can toggle to note names. |
| Upcoming note (within 1 beat) | Violet ring that fills as its onset approaches (anticipation) |
| Sustain | Marker stays lit. A thin ring drains clockwise over the note's remaining duration. |
| Chord shape | All notes light together. A **barre** is a capsule across the strings at the index-finger fret. Muted strings show `×` and open strings show `○` at the nut. |
| Power chord | Root plus fifth (plus octave) joined by a short connecting bar, labeled `5`. |
| Low confidence | Dashed outline, desaturated fill, with no glow. It never relies on color alone. |
| Bend / slide / hammer-on / pull-off | Renderer support is built in from the start: bends get an arrow with a semitone label, slides a connecting line between frets, and hammer-ons and pull-offs an `h`/`p` arc. **Detection is post-MVP.** These are drawn only for events carrying a technique annotation. |

### 5.3 Interactions

- **Tap a note** → a popover with the note name and octave (`Sol 3 · G3`), time, **provenance** (*Detectada / Inferida / Recomendada / Editada*), confidence level, and **alternative positions**. Tapping an alternative re-optimizes the surrounding phrase with that constraint and remembers it.
- **Tap a chord** in the chord lane → shows the recommended shape plus up to two alternative voicings.
- **Scrub** the tab or timeline → the fretboard updates live, and the audio plays a short scrub preview.
- **Double-tap the fretboard** → recenters.

### 5.4 Rendering technology

**SwiftUI `Canvas` inside `TimelineView(.animation)`.** At any moment the scene has at most ~6 strings, ~25 frets and dozens of markers. That is well within Canvas's immediate-mode budget, and Canvas keeps text, accessibility and Dynamic Type simple. Static layers (wood, frets, inlays) are drawn into a cached layer and redrawn only on size or orientation change. **Escalation path:** if the in-app frame-time monitor shows hitches at 60 Hz on the iPhone 14 Plus (most likely in Flow mode), move the moving layers to Metal (`MTKView`). The domain and layout code stays unchanged.

## 6. Accessibility & adaptive layout

- **VoiceOver:**
  - The fretboard is an accessibility container exposing the *current* events, for example “Corda 5, casa 3, Dó 3, dedo 3, recomendada” (string 5, fret 3, C3, finger 3, recommended).
  - A custom rotor steps through notes, chords and sections.
  - The playhead is an adjustable element: swipe up/down to step by beat.
  - All transport controls have labels and values (“Velocidade, 70 por cento” / “Speed, 70 percent”).
- **Dynamic Type:** all chrome scales to AX5. In the Studio at accessibility sizes, the layout switches to fretboard-or-tab (one hero at a time). Fretboard labels scale with a clamp so markers never overlap.
- **Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate Without Color:** each has a defined behavior (see §2). Confidence and state always have a shape cue as well as color.
- **Hit targets** are ≥ 44 pt, and transport buttons are 56 pt.
- **Size classes:** iPhone portrait and landscape are first-class. iPad runs the same layout scaled; a dedicated layout is post-MVP.
- **Localization:** all strings live in a String Catalog (`Localizable.xcstrings`) with pt-BR as the development language and English added in a later milestone. Note naming is selectable: **letter names (C D E)**, the default and common in Brazilian cifras, or **solfège (Dó Ré Mi)**.
