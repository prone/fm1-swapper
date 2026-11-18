# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
import sys, os, json, numpy as np, librosa
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from a2s import Analysis
from score import score
for wavf, jf in zip(sys.argv[1::2], sys.argv[2::2]):
    y, sr = librosa.load(wavf, sr=22050, mono=True); d = json.load(open(jf))
    a = Analysis(y, sr)
    steps, bpm = a.grid(d["lead_in"] + 0.05)              # "start here": near bar 1, as the user would pick
    hits = a.drums(steps)
    o = a.bar_start(hits)
    if o:                                                 # bar 1 is later: take the grid from there
        steps, bpm = a.grid(steps[o]); hits = a.drums(steps)
    n0 = round((steps[0] - d["lead_in"]) / (60 / d["bpm"] / 4))            # where the grid starts in the truth's steps
    truth = [(s - n0, l) for s, l in d["truth"] if 0 <= s - n0 < 64]
    print("  tempo scores", {k: round(float(v), 2) for k, v in a.tempo_scores.items()}, "grid starts at truth step", n0)
    per, f1 = score(truth, hits)
    print(f"{d['bpm']} BPM -> {bpm:.1f}, bar offset {o}: F1 {f1:.2f}  " + "  ".join(f"{k} {h}/{t} (+{g - h})" for k, (h, t, g) in per.items()))
