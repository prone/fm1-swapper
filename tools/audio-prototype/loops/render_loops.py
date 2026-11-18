# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Listening files for each song's main loops (mono): the loop's original audio twice in a row (does the seam hold?),
# then its drums from all the repeats as plain synth, twice, then both together.
import sys, os, json, numpy as np, soundfile as sf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import loops
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "stems")); import ab_sounds
out = sys.argv[2]; SR = loops.SR; made = []
for path, label in zip(sys.argv[3::2], sys.argv[4::2]):
    d, per, phase, starts, groups, lab = loops.song(path); st = d["steps"]; y = d["y"]
    W = {i: np.concatenate([d["F"][k][starts[i]:starts[i] + 4].ravel() for k in d["F"]]) for i in range(len(starts))}
    for rank, (g, occ) in enumerate(sorted(enumerate(groups), key=lambda x: -len(x[1]))[:2]):
        med = max(occ, key=lambda i: sum(float(W[i] @ W[j]) for j in occ))        # the most typical repeat
        s0 = starts[med] * 16; a = st[s0]; b = st[s0 + 63] + (st[s0 + 63] - st[s0 + 62])
        orig = y[int(a * SR):int(b * SR)]; hits = loops.consensus(d, [starts[i] for i in occ], per["drums"][0])
        r = np.zeros(len(orig))
        for n, l in hits:
            snd = ab_sounds.SOUND[l](); i = int((st[s0 + n] - a) * SR); r[i:i + len(snd)] += snd[:max(0, len(r) - i)]
        o2, r2 = np.tile(orig, 2), np.tile(r, 2)
        o2 = o2 / (np.abs(o2).max() + 1e-9) * .8; r2 = r2 / (np.abs(r2).max() + 1e-9) * .8; gap = np.zeros(int(.8 * SR))
        both = .6 * o2 + .6 * r2; both /= max(1, np.abs(both).max() / .9)
        name = f"{label} - loop {rank + 1} ({len(occ)}x).wav"
        sf.write(os.path.join(out, name), np.concatenate([o2, gap, r2, gap, both]), SR); made.append(name)
        print(f"{label}: loop {rank + 1} = group {chr(65 + g)}, {len(occ)} repeats, from {int(a) // 60}:{a % 60:04.1f} ({b - a:.2f} s)")
json.dump(made, open(os.path.join(out, "loops.json"), "w"))
