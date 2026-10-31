"""Generates App/AppIcon.png (1024x1024, RGB, no alpha) for RIFFNEX.

Concept: a sound wave on the left resolves into six guitar strings on the right
("from listening to playing"), with one cyan note lit on a string.
Run: python3 tools/make_icon.py
"""
import numpy as np
from PIL import Image

S = 1024
SS = 3  # supersampling
N = S * SS
y, x = np.mgrid[0:N, 0:N].astype(np.float32) / N  # 0..1

# Background: near-black with a soft violet glow, slightly cooler at the bottom.
bg = np.zeros((N, N, 3), np.float32)
bg[...] = np.array([7, 7, 10], np.float32) / 255
glow = np.exp(-(((x - 0.38) ** 2) / 0.10 + ((y - 0.42) ** 2) / 0.07))
bg += glow[..., None] * (np.array([124, 92, 255], np.float32) / 255) * 0.22
img = bg

def gradient(t):
    """Brand gradient violet -> blue -> cyan for t in 0..1."""
    stops = np.array([[124, 92, 255], [61, 123, 255], [63, 224, 232]], np.float32) / 255
    t = np.clip(t, 0, 1) * 2
    i = np.minimum(t.astype(int), 1)
    f = (t - i)[..., None]
    return stops[i] * (1 - f) + stops[i + 1] * f

def stroke(dist, width):
    """Anti-aliased coverage for distance field (in normalized units)."""
    px = 1.0 / N
    return np.clip((width - dist) / (1.5 * px) + 0.5, 0, 1)

strings_y = 0.30 + np.arange(6) * 0.08          # six strings
x0, x1 = 0.12, 0.88                               # drawable span
blend = np.clip((x - 0.30) / 0.30, 0, 1)          # 0 = wave, 1 = straight string
blend = blend * blend * (3 - 2 * blend)
env = (1 - blend)
for k, sy in enumerate(strings_y):
    amp = 0.085 * np.exp(-((k - 2.5) ** 2) / 6.0)
    phase = k * 0.9
    curve = sy + env * amp * np.sin(2 * np.pi * (x * 3.2) + phase) * np.sin(np.pi * np.clip((x - x0) / 0.5, 0, 1))
    width = 0.0042 + k * 0.0011                   # thicker low strings
    cov = stroke(np.abs(y - curve), width) * ((x > x0) & (x < x1))
    fade = np.clip((x - x0) / 0.05, 0, 1) * np.clip((x1 - x) / 0.05, 0, 1)
    color = gradient((x - x0) / (x1 - x0))
    alpha = (cov * fade * (0.55 + 0.45 * env))[..., None]
    img = img * (1 - alpha) + color * alpha

# A fret line where the wave has become strings.
fx = 0.70
cov = stroke(np.abs(x - fx), 0.0035) * ((y > strings_y[0] - 0.03) & (y < strings_y[-1] + 0.03))
img = img * (1 - cov[..., None] * 0.35) + np.array([0.75, 0.77, 0.85]) * cov[..., None] * 0.35

# The lit note: cyan dot with glow on string 3, just behind the fret.
cx, cy = 0.64, strings_y[2]
d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
halo = np.exp(-(d ** 2) / 0.0035)[..., None] * 0.55
cyan = np.array([63, 224, 232], np.float32) / 255
img = img + halo * cyan * 0.6
core = stroke(d, 0.034)[..., None]
img = img * (1 - core) + (cyan * 0.85 + 0.15) * core

img = np.clip(img, 0, 1)
out = Image.fromarray((img * 255).astype(np.uint8), "RGB").resize((S, S), Image.LANCZOS)
out.save("App/AppIcon.png", optimize=True)
print("wrote App/AppIcon.png", out.size, out.mode)
