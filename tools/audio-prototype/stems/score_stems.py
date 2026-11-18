# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Drums found on the full mix vs on the Demucs drum stem (the grid from the mix in both), scored against the truth.
import sys, os, json, numpy as np, librosa
sys.path.insert(0, sys.argv[1])
from a2s import Analysis
from score import score
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stemdrums
for mixf, stemf, jf in zip(sys.argv[2::3], sys.argv[3::3], sys.argv[4::3]):
    d = json.load(open(jf)); mix, sr = librosa.load(mixf, sr=22050, mono=True); stem, _ = librosa.load(stemf, sr=22050, mono=True)
    n = min(len(mix), len(stem)); a = Analysis(mix[:n], sr)
    # the drum stem has no bass to tell a kick from: no harmonic split (all of it is drums), so no "bass tone" either
    real = librosa.effects.hpss; librosa.effects.hpss = lambda y, **k: (np.zeros_like(y), y)
    b = Analysis(stem[:n], sr); librosa.effects.hpss = real
    new = lambda steps: stemdrums.drums2(stem[:n], sr, steps)
    for label, det in (("mix ", a.drums), ("stem", b.drums), ("stem, new", new)):
        steps, bpm = a.grid(d["lead_in"] + 0.05); hits = det(steps); o = a.bar_start(hits)
        if o: steps, bpm = a.grid(steps[o]); hits = det(steps)
        n0 = round((steps[0] - d["lead_in"]) / (60 / d["bpm"] / 4))
        truth = [(s - n0, l) for s, l in d["truth"] if 0 <= s - n0 < 64]
        per, f1 = score(truth, hits)
        print(f"{d['bpm']:>3} BPM {label}: F1 {f1:.2f}  " + "  ".join(f"{k} {h}/{t} (+{g - h})" for k, (h, t, g) in per.items()))
