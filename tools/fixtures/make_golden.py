#!/usr/bin/env python3
"""Golden vectors for RIFFNEX's Swift port of Basic Pitch note decoding.

Runs the *reference* basic-pitch 0.4.0 (Spotify, Apache-2.0) on the bundled demo song:

1. Decodes the demo m4a to mono float32 at 22 050 Hz with ffmpeg.
2. Windows the audio exactly like `basic_pitch.inference.run_inference` (30-frame overlap,
   half-overlap zero padding) and runs the reference ONNX model.
3. Unwraps the windows exactly like `unwrap_output`.
4. Quantizes the note/onset activations to uint16 and writes them to
   `Tests/Fixtures/demo-activations.bin`.
5. Runs the reference `output_to_notes_polyphonic` on the *dequantized* matrices (so the Swift
   port sees bit-identical input) for several parameter sets and writes the resulting note
   events (in frames) to `Tests/Fixtures/demo-notes.golden.json`.

Setup (no TensorFlow needed):
    python3 -m venv .venv && . .venv/bin/activate
    pip install --no-deps basic-pitch==0.4.0
    pip install numpy scipy librosa pretty_midi mir_eval resampy onnxruntime
    python tools/fixtures/make_golden.py

Binary layout of demo-activations.bin (little endian):
    char[4]  magic "RXA1"
    uint32   frames
    uint32   bins (88)
    uint16   note[frames * bins]   value = round(activation * 65535), row-major (frame, bin)
    uint16   onset[frames * bins]
"""

import json
import pathlib
import struct
import subprocess

import numpy as np
import onnxruntime as ort
from basic_pitch import ICASSP_2022_MODEL_PATH
from basic_pitch.constants import AUDIO_N_SAMPLES, AUDIO_SAMPLE_RATE, FFT_HOP, ANNOTATIONS_FPS
from basic_pitch.note_creation import output_to_notes_polyphonic

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEMO = ROOT / "Sources/RiffnexApp/Resources/Demo/riffnex-demo.m4a"
OUT = ROOT / "Tests/Fixtures"


def decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(path), "-ac", "1", "-ar", str(AUDIO_SAMPLE_RATE),
         "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def run_reference(audio):
    model_path = pathlib.Path(str(ICASSP_2022_MODEL_PATH)).parent / "nmp.onnx"
    session = ort.InferenceSession(str(model_path))
    names = {"note": "StatefulPartitionedCall:1", "onset": "StatefulPartitionedCall:2",
             "contour": "StatefulPartitionedCall:0"}
    n_overlap = 30
    overlap_len = n_overlap * FFT_HOP
    hop = AUDIO_N_SAMPLES - overlap_len
    padded = np.concatenate([np.zeros(overlap_len // 2, dtype=np.float32), audio])
    out = {k: [] for k in names}
    for i in range(0, padded.shape[0], hop):
        window = padded[i:i + AUDIO_N_SAMPLES]
        if len(window) < AUDIO_N_SAMPLES:
            window = np.pad(window, (0, AUDIO_N_SAMPLES - len(window)))
        result = session.run(list(names.values()), {"serving_default_input_2:0": window[None, :, None]})
        for k, v in zip(names, result):
            out[k].append(v)
    n_frames = int(np.floor(len(audio) * (ANNOTATIONS_FPS / AUDIO_SAMPLE_RATE)))
    half = n_overlap // 2
    unwrapped = {}
    for k, v in out.items():
        v = np.concatenate(v)[:, half:-half, :]
        unwrapped[k] = v.reshape(-1, v.shape[2])[:n_frames]
    return unwrapped, len(out["note"])


def quantize(m):
    return np.round(np.clip(m, 0, 1) * 65535).astype("<u2")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    audio = decode(DEMO)
    output, n_windows = run_reference(audio)
    note_q, onset_q = quantize(output["note"]), quantize(output["onset"])
    frames, bins = note_q.shape
    with open(OUT / "demo-activations.bin", "wb") as f:
        f.write(b"RXA1")
        f.write(struct.pack("<II", frames, bins))
        f.write(note_q.tobytes())
        f.write(onset_q.tobytes())

    note = note_q.astype(np.float64) / 65535
    onset = onset_q.astype(np.float64) / 65535

    def hz(m):
        return 440.0 * 2 ** ((m - 69) / 12)

    configs = [
        {"name": "default", "onsetThreshold": 0.5, "frameThreshold": 0.3, "minNoteFrames": 11,
         "inferOnsets": True, "melodia": True, "minMIDI": None, "maxMIDI": None},
        {"name": "guitar", "onsetThreshold": 0.5, "frameThreshold": 0.3, "minNoteFrames": 11,
         "inferOnsets": True, "melodia": True, "minMIDI": 40, "maxMIDI": 88},
        {"name": "sensitive-no-melodia", "onsetThreshold": 0.3, "frameThreshold": 0.2, "minNoteFrames": 6,
         "inferOnsets": False, "melodia": False, "minMIDI": None, "maxMIDI": None},
    ]
    golden = {
        "reference": "basic-pitch 0.4.0 output_to_notes_polyphonic (ONNX icassp_2022 model)",
        "audio": "Sources/RiffnexApp/Resources/Demo/riffnex-demo.m4a decoded by ffmpeg to 22050 Hz mono",
        "samples": int(len(audio)),
        "windows": n_windows,
        "frames": int(frames),
        "configs": [],
    }
    for c in configs:
        events = output_to_notes_polyphonic(
            note.copy(), onset.copy(), onset_thresh=c["onsetThreshold"], frame_thresh=c["frameThreshold"],
            min_note_len=c["minNoteFrames"], infer_onsets=c["inferOnsets"],
            # The reference takes Hz; the bin it keeps is round(hz_to_midi(f) - 21), exclusive at the top.
            min_freq=hz(c["minMIDI"]) if c["minMIDI"] is not None else None,
            max_freq=hz(c["maxMIDI"] + 1) if c["maxMIDI"] is not None else None,
            melodia_trick=c["melodia"])
        golden["configs"].append({
            **c,
            "notes": [[int(s), int(e), int(p), round(float(a), 6)] for s, e, p, a in events],
        })
        print(f"{c['name']}: {len(events)} notes")
    with open(OUT / "demo-notes.golden.json", "w") as f:
        json.dump(golden, f, indent=1)
    print(f"{frames} frames from {n_windows} windows → {OUT}")


if __name__ == "__main__":
    main()
