"""Synthesizes RIFFNEX's bundled demo song and its ground-truth annotation.

The riff is an ORIGINAL composition written for RIFFNEX (no third-party material), so it can be
bundled and redistributed. Because we generate it from a score, we know the exact notes, chords,
tempo and key, which makes it a test fixture too.

Sound: Karplus-Strong plucked strings with mild overdrive, plus a quiet synthesized kick/snare/
hi-hat so beat tracking has something to lock onto.

Outputs (deterministic):
  Sources/RiffnexApp/Resources/Demo/riffnex-demo.m4a   (AAC, via ffmpeg)
  tools/fixtures/out/riffnex-demo.wav                   (lossless reference, not committed)
  tools/fixtures/riffnex-demo.truth.json                (ground truth)

Run from the repo root: python3 tools/fixtures/make_demo.py
"""
import json
import subprocess
import wave
from pathlib import Path

import numpy as np

SR = 44100
BPM = 96.0
BEAT = 60.0 / BPM
RNG = np.random.default_rng(20261031)
ROOT = Path(__file__).resolve().parents[2]

# Standard tuning, string 0 = low E. (string, fret) -> MIDI.
OPEN = [40, 45, 50, 55, 59, 64]


def midi(string, fret):
    return OPEN[string] + fret


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def pluck(freq, dur, amp=0.5, brightness=0.6, decay=0.996):
    """Karplus-Strong with a fractional-delay-free simple averaging filter."""
    n = int(dur * SR)
    period = max(2, int(round(SR / freq)))
    buf = RNG.uniform(-1, 1, period)
    # Low-pass the excitation for a softer pick attack.
    for _ in range(int((1 - brightness) * 4)):
        buf = 0.5 * (buf + np.roll(buf, 1))
    out = np.empty(n)
    idx = 0
    for i in range(n):
        out[i] = buf[idx]
        nxt = (idx + 1) % period
        buf[idx] = decay * 0.5 * (buf[idx] + buf[nxt])
        idx = nxt
    # Short release to avoid clicks at the note end.
    rel = min(n, int(0.015 * SR))
    out[-rel:] *= np.linspace(1, 0, rel)
    return amp * out


def kick(dur=0.25):
    t = np.arange(int(dur * SR)) / SR
    f = 50 + 70 * np.exp(-t * 30)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 14)


def snare(dur=0.18):
    t = np.arange(int(dur * SR)) / SR
    noise = RNG.uniform(-1, 1, t.size)
    return (0.6 * noise + 0.4 * np.sin(2 * np.pi * 190 * t)) * np.exp(-t * 22)


def hat(dur=0.05):
    t = np.arange(int(dur * SR)) / SR
    noise = RNG.uniform(-1, 1, t.size)
    noise = noise - np.concatenate([[0], noise[:-1]])  # crude high-pass
    return noise * np.exp(-t * 70)


# ---- The score -------------------------------------------------------------------------------
# Each event: (beat_start, beats_duration, [(string, fret), ...])
# Bars 1-4: single-note riff in E minor. Bars 5-8: power-chord progression E5 G5 A5 C5 / E5 G5 D5 D5.
riff_bar_a = [  # one bar = 8 eighth notes
    (0.0, 0.5, [(0, 0)]), (0.5, 0.5, [(0, 0)]), (1.0, 0.5, [(0, 3)]), (1.5, 0.5, [(0, 0)]),
    (2.0, 0.5, [(1, 0)]), (2.5, 0.5, [(0, 3)]), (3.0, 0.5, [(1, 2)]), (3.5, 0.5, [(1, 0)]),
]
riff_bar_b = [
    (0.0, 0.5, [(0, 0)]), (0.5, 0.5, [(0, 0)]), (1.0, 0.5, [(0, 3)]), (1.5, 0.5, [(0, 5)]),
    (2.0, 1.0, [(1, 2)]), (3.0, 0.5, [(2, 0)]), (3.5, 0.5, [(1, 2)]),
]

def power(root_string, fret):
    """Root, fifth and octave. Strings above the G string sit a major third (not a fourth)
    higher, so a shape that reaches the B string needs one extra fret there."""
    def shift(string):
        return 3 if string == 4 else 2
    return [(root_string, fret), (root_string + 1, fret + shift(root_string + 1)),
            (root_string + 2, fret + shift(root_string + 2))]

chord_bars = [
    [(0.0, 2.0, power(0, 0), "E5"), (2.0, 2.0, power(0, 3), "G5")],
    [(0.0, 2.0, power(1, 0), "A5"), (2.0, 2.0, power(1, 3), "C5")],
    [(0.0, 2.0, power(0, 0), "E5"), (2.0, 2.0, power(0, 3), "G5")],
    [(0.0, 4.0, power(2, 0), "D5")],
]

events = []   # (start_s, dur_s, [(string, fret)])
chords = []   # (start_s, end_s, symbol)
bar_beats = 4
for bar, pattern in enumerate([riff_bar_a, riff_bar_b, riff_bar_a, riff_bar_b]):
    for b, d, notes in pattern:
        events.append(((bar * bar_beats + b) * BEAT, d * BEAT, notes))
for i, bar_events in enumerate(chord_bars):
    bar = 4 + i
    for b, d, notes, sym in bar_events:
        start = (bar * bar_beats + b) * BEAT
        events.append((start, d * BEAT, notes))
        chords.append((start, start + d * BEAT, sym))

total_bars = 8
tail = 1.5
duration = total_bars * bar_beats * BEAT + tail
mix = np.zeros(int(duration * SR) + SR)

# Guitar
guitar = np.zeros_like(mix)
truth_notes = []
for start, dur, notes in events:
    for string, fret in notes:
        m = midi(string, fret)
        sound_dur = dur * 0.95
        sig = pluck(hz(m), sound_dur + 0.08, amp=0.42 if len(notes) > 1 else 0.6,
                    decay=0.997 if len(notes) > 1 else 0.995)
        i0 = int(start * SR)
        guitar[i0:i0 + sig.size] += sig
        truth_notes.append({"onset": round(start, 6), "offset": round(start + sound_dur, 6),
                            "midi": m, "string": string, "fret": fret})
guitar = np.tanh(2.2 * guitar) / np.tanh(2.2)  # mild overdrive

# Drums (quiet)
drums = np.zeros_like(mix)
for beat in range(total_bars * bar_beats):
    t0 = int(beat * BEAT * SR)
    k = kick() if beat % 2 == 0 else snare()
    drums[t0:t0 + k.size] += (0.35 if beat % 2 == 0 else 0.18) * k
    for half in (0, 0.5):
        h = hat()
        th = int((beat + half) * BEAT * SR)
        drums[th:th + h.size] += 0.05 * h

mix = 0.85 * guitar + drums
mix = mix[: int(duration * SR)]
mix /= np.max(np.abs(mix)) * 1.12  # peak at about -1 dBFS

out_dir = ROOT / "tools/fixtures/out"
out_dir.mkdir(parents=True, exist_ok=True)
wav_path = out_dir / "riffnex-demo.wav"
with wave.open(str(wav_path), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((mix * 32767).astype("<i2").tobytes())

m4a_dir = ROOT / "Sources/RiffnexApp/Resources/Demo"
m4a_dir.mkdir(parents=True, exist_ok=True)
m4a_path = m4a_dir / "riffnex-demo.m4a"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav_path), "-c:a", "aac", "-b:a", "160k",
                "-map_metadata", "-1", "-metadata", "title=RIFFNEX Demo Riff", "-metadata", "artist=RIFFNEX",
                str(m4a_path)], check=True)

truth = {
    "title": "RIFFNEX Demo Riff",
    "license": "Original composition for RIFFNEX; generated by tools/fixtures/make_demo.py",
    "sampleRate": SR,
    "duration": round(duration, 6),
    "tempoBPM": BPM,
    "timeSignature": [4, 4],
    "key": {"tonic": "E", "mode": "minor"},
    "sections": [
        {"label": "Riff", "start": 0.0, "end": round(4 * bar_beats * BEAT, 6)},
        {"label": "Power chords", "start": round(4 * bar_beats * BEAT, 6), "end": round(8 * bar_beats * BEAT, 6)},
    ],
    "beats": [round(b * BEAT, 6) for b in range(total_bars * bar_beats)],
    "chords": [{"start": round(s, 6), "end": round(e, 6), "symbol": c} for s, e, c in chords],
    "notes": sorted(truth_notes, key=lambda n: (n["onset"], n["midi"])),
    "notesAudioCaveat": "Fret positions are as composed; any playable equivalent is acceptable.",
}
(ROOT / "tools/fixtures/riffnex-demo.truth.json").write_text(json.dumps(truth, indent=2, ensure_ascii=False) + "\n")
print(f"wrote {m4a_path.relative_to(ROOT)} ({m4a_path.stat().st_size // 1024} KB), "
      f"{len(truth_notes)} notes, {len(chords)} chords, {duration:.2f}s")
