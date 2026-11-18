# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Where the song changes: per bar line, how unlike the bars before are to the bars after (a checkerboard over the
# bar-to-bar similarity, 4 bars each side); the strong peaks are section boundaries.
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import loops
def boundaries(d, k=4, z=1.0):
    F = d["F"]; nb = d["nb"]; X = np.concatenate([F[f] for f in ("drums", "bass", "chords")], 1) / np.sqrt(3); S = X @ X.T
    nov = np.zeros(nb)
    for b in range(2, nb - 1):
        a0, a1 = max(0, b - k), min(nb, b + k)
        nov[b] = S[a0:b, a0:b].mean() + S[b:a1, b:a1].mean() - 2 * S[a0:b, b:a1].mean()
    thr = nov.mean() + z * nov.std()
    peaks = [b for b in range(1, nb - 1) if nov[b] >= thr and nov[b] >= nov[b - 1] and nov[b] >= nov[b + 1]]
    return peaks, nov
if __name__ == "__main__":
    d, per, phase, starts, groups, lab = loops.song(sys.argv[2]); st = d["steps"]
    peaks, nov = boundaries(d)
    print("changes at " + ", ".join(f"bar {b} ({int(st[b * 16]) // 60}:{st[b * 16] % 60:04.1f})" for b in peaks))
