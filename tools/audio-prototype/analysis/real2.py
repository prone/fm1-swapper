# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
import sys, os, numpy as np, librosa
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from a2s import Analysis
y, sr = librosa.load(sys.argv[1], sr=22050, mono=True); a = Analysis(y, sr)
print("song tempo %.1f BPM" % a.bpm, {k: round(float(v), 2) for k, v in a.tempo_scores.items()})
lanes = {0: "kick", 2: "snare", 4: "hat", 5: "open hat"}
tot = back = 0
for start in [float(x) for x in sys.argv[2].split(",")]:
    steps, bpm = a.grid(start); hits = a.drums(steps); o = a.bar_start(hits)
    if o: steps, bpm = a.grid(steps[o]); hits = a.drums(steps)
    sn = [n for n, l in hits if l == 2]; tot += len(sn); back += sum(1 for n in sn if n % 16 in (4, 12))
    print(f"== section from {steps[0]:.2f}s ({bpm:.1f} BPM): " + ", ".join(f"{lanes[l]} {sum(1 for _, x in hits if x == l)}" for l in lanes))
    H = set(hits)
    for l in lanes:
        row = "".join("x" if (n, l) in H else "." for n in range(64))
        print(f"  {lanes[l]:8s} " + " ".join(row[i:i + 16] for i in range(0, 64, 16)))
print(f"snares on beats 2 and 4: {100 * back / max(1, tot):.0f}%")
