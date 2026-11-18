# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import loops
d, per, phase, starts, groups, lab = loops.song(sys.argv[2]); st = d["steps"]; F = d["F"]; nb = d["nb"]
allF = np.concatenate([F[k] for k in F], 1) / np.sqrt(len(F))
S = allF @ allF.T
print("phase", phase, "bars", nb, "order", "".join(chr(65 + g) for g in lab))
for g in [ord(c) - 65 for c in sys.argv[3]]:
    occ = [starts[i] for i in groups[g]]
    print(f"\nloop {chr(65+g)}: phrase starts at bars {occ} (times " + ", ".join(f"{st[b*16]:.1f}" for b in occ) + ")")
    # how alike each bar of this loop is to the same bar in the other repeats, per shift of the start by -3..+3 bars
    for sh in range(-3, 4):
        o = [b + sh for b in occ if 0 <= b + sh and b + sh + 4 <= nb]
        if len(o) < 2: continue
        within = np.mean([S[a + q, b + q] for a in o for b in o if a < b for q in range(4)])
        # does the loop's end lead into its start? (bar after the end vs the first bar, bar before the start vs the last)
        seam = np.mean([S[b + 4, b] for b in o if b + 4 < nb] + [S[b - 1, b + 3] for b in o if b >= 1])
        print(f"   shift {sh:+d} bars: repeats alike {within:.3f}, seam {seam:.3f}")
    # each bar of the song against the loop's first bar
    print("   bar-by-bar similarity to the loop's bar 1 (first repeat):", " ".join(f"{S[occ[0], b]:.2f}" for b in range(max(0, occ[0]-2), min(nb, occ[0]+10))))
