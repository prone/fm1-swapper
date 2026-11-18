# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Separates audio (or pieces of it) into drums / bass / other / vocals with Demucs; writes 22050 Hz mono stems.
# usage: sep.py audio outdir [model] [start:end,start:end...]   (seconds; a second's margin either side is added)
import sys, time, numpy as np, soundfile as sf, torch, scipy.signal as sg
from demucs.pretrained import get_model
from demucs.apply import apply_model
src, out = sys.argv[1], sys.argv[2]; name = sys.argv[3] if len(sys.argv) > 3 else "htdemucs"
y, sr = sf.read(src, always_2d=True, dtype="float32")
if y.shape[1] == 1: y = np.repeat(y, 2, 1)
model = get_model(name); model.eval()
dev = "mps" if torch.backends.mps.is_available() else "cpu"
segs = [tuple(map(float, s.split(":"))) for s in sys.argv[4].split(",")] if len(sys.argv) > 4 else [(0, len(y) / sr)]
total = 0
for k, (a, b) in enumerate(segs):
    a0, b0 = max(0, a - 1), min(len(y) / sr, b + 1)
    x = y[int(a0 * sr):int(b0 * sr)].T
    if sr != model.samplerate: x = sg.resample_poly(x, model.samplerate, sr, axis=1)
    wav = torch.tensor(x.copy())[None]
    ref = wav.mean(0); wav = (wav - ref.mean()) / (ref.std() + 1e-8)
    t0 = time.time()
    with torch.no_grad(): s = apply_model(model, wav.to(dev), device=dev, progress=False, split=True, overlap=0.25)[0].cpu()
    s = s * (ref.std() + 1e-8) + ref.mean()
    dt = time.time() - t0; total += dt
    for i, stem in enumerate(model.sources):
        m = sg.resample_poly(s[i].mean(0).numpy(), 22050, model.samplerate)
        sf.write(f"{out}/{k}_{stem}.wav", m, 22050)
    print(f"piece {k}: {a0:.1f}-{b0:.1f} s ({b0 - a0:.1f} s of audio) in {dt:.1f} s", flush=True)
print(f"{name} on {dev}: {total:.1f} s in all; stems {model.sources}")
