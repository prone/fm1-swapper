# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# For a song: the beat (from the whole mix, as the app does), and three 4-bar pieces at 25/50/75% with their grids
# and the drums the mix detector finds. Writes JSON for the separation and the comparison.
import sys, os, json, numpy as np, librosa
sys.path.insert(0, sys.argv[1]); from a2s import Analysis
y, sr = librosa.load(sys.argv[2], sr=22050, mono=True); a = Analysis(y, sr); dur = len(y) / sr
pieces = []
for f in (0.25, 0.5, 0.75):
    steps, bpm = a.grid(f * dur); hits = a.drums(steps); o = a.bar_start(hits)
    if o: steps, bpm = a.grid(steps[o]); hits = a.drums(steps)
    pieces.append({"steps": [float(t) for t in steps], "bpm": bpm, "mix": hits})
json.dump({"bpm": a.bpm, "pieces": pieces}, open(sys.argv[3], "w"))
print(f"{os.path.basename(sys.argv[2])}: {a.bpm:.1f} BPM; pieces " + ",".join(f"{p['steps'][0]:.1f}" for p in pieces))
