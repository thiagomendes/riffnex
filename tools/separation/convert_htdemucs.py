#!/usr/bin/env python3
"""Converts Demucs v4 `htdemucs_6s` (Meta, MIT) to Core ML for on-device stem separation.

HTDemucs runs a time branch and a frequency branch; the frequency branch needs an STFT and an
inverse STFT, which Core ML has no good ops for. So we convert only the network core:

    inputs : mix  [1, 2, L]           stereo waveform segment (L = model.segment · 44 100)
             mag  [1, 4, 2048, T]     complex-as-channels spectrogram of `mix` (Demucs `_spec`
                                      + `_magnitude`), T = ceil(L / 1024)
    outputs: time [1, S, 2, L]        time-branch estimate per source
             spec [1, S, 4, 2048, T]  frequency-branch estimate per source (complex as channels)

The app computes the STFT and iSTFT itself (Accelerate) and adds the two branches, exactly as
`HTDemucs.forward` does. This script also writes the fixtures the Swift side is tested against,
and validates the Core ML model against PyTorch on a real segment of the demo song.

Runs on macOS (Core ML prediction needs it). CI: `.github/workflows/separation-model.yml`.
"""

import json
import math
import pathlib
import subprocess
import sys
import tempfile
import time
import wave

import numpy as np
import torch
import coremltools as ct
from demucs.apply import apply_model
from demucs.pretrained import get_model

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT_MODEL = ROOT / "Sources/AnalysisEngine/Resources/Separation/htdemucs6s.mlpackage"
OUT_CONFIG = ROOT / "Sources/AnalysisEngine/Resources/Separation/htdemucs6s.json"
FIXTURES = ROOT / "Tests/Fixtures"
DEMO = ROOT / "Sources/RiffnexApp/Resources/Demo/riffnex-demo.m4a"


def load_demo_stereo_44k():
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = pathlib.Path(tmp) / "demo.wav"
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", "-c", "2", str(DEMO), str(wav_path)], check=True)
        with wave.open(str(wav_path)) as w:
            frames = w.readframes(w.getnframes())
            channels = w.getnchannels()
    data = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    return data.reshape(-1, channels).T.copy()  # [2, N]


class Core(torch.nn.Module):
    """HTDemucs.forward with the STFT, masking and iSTFT steps cut out (see module docstring)."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, mix, mag):
        m = self.model
        stash = {}
        original = (m._spec, m._magnitude, m._mask, m._ispec)
        m._spec = lambda x: None
        m._magnitude = lambda z: mag
        m._mask = lambda z, x: x                     # x: [B, S, 4, F, T] spectrogram estimate

        def ispec(zout, length=None, scale=0):
            stash["spec"] = zout
            return torch.zeros((), dtype=mix.dtype)  # forward adds this to the time branch
        m._ispec = ispec
        try:
            time_branch = m.forward(mix)
        finally:
            m._spec, m._magnitude, m._mask, m._ispec = original
        return time_branch, stash["spec"]


def main():
    torch.backends.mha.set_fastpath_enabled(False)  # the fused attention op has no Core ML equivalent
    bag = get_model("htdemucs_6s")
    model = bag.models[0] if hasattr(bag, "models") else bag
    model.eval()
    sources = list(model.sources)
    sr = model.samplerate
    seg = int(model.segment * sr)
    hop = model.hop_length
    nfft = model.nfft
    frames = int(math.ceil(seg / hop))
    print(f"sources={sources} samplerate={sr} segment={seg} nfft={nfft} hop={hop} frames={frames}")

    # A real segment of the demo, normalized the way `demucs.separate` does.
    demo = load_demo_stereo_44k()
    ref = demo.mean(0)
    mean, std = float(ref.mean()), float(ref.std())
    demo_n = (demo - mean) / std
    segment = np.zeros((2, seg), dtype=np.float32)
    segment[:, :min(seg, demo_n.shape[1])] = demo_n[:, :seg]
    mix = torch.from_numpy(segment)[None]

    with torch.no_grad():
        z = model._spec(mix)
        mag = model._magnitude(z)
        print("mag shape", tuple(mag.shape))
        reference = model(mix)                       # [1, S, 2, L]
        core = Core(model).eval()
        traced = torch.jit.trace(core, (mix, mag), check_trace=False)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=tuple(mix.shape)), ct.TensorType(name="mag", shape=tuple(mag.shape))],
        outputs=[ct.TensorType(name="time"), ct.TensorType(name="spec")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.author = "Meta AI (Demucs v4 htdemucs_6s, MIT); converted for RIFFNEX"
    mlmodel.short_description = "HTDemucs 6-source core (STFT/iSTFT done by the app)"
    OUT_MODEL.parent.mkdir(parents=True, exist_ok=True)
    if OUT_MODEL.exists():
        subprocess.run(["rm", "-rf", str(OUT_MODEL)], check=True)
    mlmodel.save(str(OUT_MODEL))

    # Validate: Core ML core + PyTorch iSTFT vs the full PyTorch model.
    for units in (ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.ALL):
        loaded = ct.models.MLModel(str(OUT_MODEL), compute_units=units)
        start = time.time()
        out = loaded.predict({"mix": mix.numpy(), "mag": mag.numpy()})
        elapsed = time.time() - start
        spec = torch.from_numpy(np.asarray(out["spec"], dtype=np.float32))
        tb = torch.from_numpy(np.asarray(out["time"], dtype=np.float32))
        B, S, C, Fr, T = spec.shape
        zout = torch.view_as_complex(spec.view(B, S, -1, 2, Fr, T).permute(0, 1, 2, 4, 5, 3).contiguous())
        estimate = tb + model._ispec(zout, seg)
        errors = {}
        for i, name in enumerate(sources):
            num = torch.linalg.norm(estimate[0, i] - reference[0, i]).item()
            den = torch.linalg.norm(reference[0, i]).item() + 1e-9
            errors[name] = round(num / den, 4)
        print(f"[{units}] predict {elapsed:.2f}s; relative error per source: {errors}")

    config = {
        "model": "htdemucs_6s",
        "license": "MIT (Demucs, Meta AI)",
        "sources": sources,
        "sampleRate": sr,
        "channels": 2,
        "segmentSamples": seg,
        "nfft": nfft,
        "hop": hop,
        "frames": frames,
        "overlap": 0.25,
    }
    OUT_CONFIG.write_text(json.dumps(config, indent=1))

    # Fixture 1: STFT parity (Demucs `_spec`) on a short deterministic signal, a few frames.
    n = 3 * hop + 517
    t = np.arange(n) / sr
    signal = (0.5 * np.sin(2 * np.pi * 220 * t) + 0.25 * np.sin(2 * np.pi * 1375.3 * t + 0.3)
              + 0.1 * np.sin(2 * np.pi * 97 * t) * np.cos(2 * np.pi * 3 * t)).astype(np.float32)
    zt = model._spec(torch.from_numpy(signal)[None, None])[0, 0]  # [2048, frames]
    pick_bins = [0, 1, 10, 20, 64, 128, 512, 1024, 2047]
    stft_fixture = {
        "signal": [float(v) for v in signal],
        "frames": int(zt.shape[1]),
        "bins": pick_bins,
        "real": [[float(zt[b, f].real) for f in range(zt.shape[1])] for b in pick_bins],
        "imag": [[float(zt[b, f].imag) for f in range(zt.shape[1])] for b in pick_bins],
        "roundTrip": [float(v) for v in model._ispec(zt[None, None], n)[0, 0][:: max(1, n // 400)]],
        "roundTripStride": max(1, n // 400),
    }
    (FIXTURES / "demucs-stft.json").write_text(json.dumps(stft_fixture))

    # Fixture 2: per-source RMS envelopes of the full demo separation (reference apply_model, no shifts).
    with torch.no_grad():
        full = apply_model(model, torch.from_numpy(demo_n)[None], shifts=0, split=True, overlap=0.25)[0]
    full = full * std + mean
    hop_env = int(0.25 * sr)
    envelopes = {}
    for i, name in enumerate(sources):
        mono = full[i].mean(0).numpy()
        count = len(mono) // hop_env
        envelopes[name] = [round(float(np.sqrt(np.mean(mono[k * hop_env:(k + 1) * hop_env] ** 2))), 5) for k in range(count)]
    (FIXTURES / "demucs-demo-envelopes.json").write_text(json.dumps({"hopSeconds": 0.25, "sources": envelopes}))
    print("wrote", OUT_MODEL, OUT_CONFIG, "and fixtures")


if __name__ == "__main__":
    sys.exit(main())
