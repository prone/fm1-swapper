# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
import sys, os, json, numpy as np, librosa
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import stemdrums
L = {0: "kick", 2: "snare", 4: "hat", 5: "open hat"}
def stats(h):
    H = set((n, 4 if l == 5 else l) for n, l in h)
    rep = [sum((p % 16 + 16 * b, l) in H for b in range(4) if b != p // 16) >= 2 for p, l in H]
    sn = [n for n, l in H if l == 2]
    return len(H), np.mean(rep) if rep else 0, (np.mean([n % 16 in (4, 12) for n in sn]) if sn else float("nan"))
def grid(h):
    H = set(h); return "\n".join(f"    {L[l]:8s} " + " ".join("".join("x" if (b * 16 + s, l) in H else "." for s in range(16)) for b in range(4)) for l in L)
tot = {"mix": [], "stem": []}
for name, d in ((n, json.load(open(f"{sys.argv[1]}/{n}.json"))) for n in sys.argv[2:]):
    for k, p in enumerate(d["pieces"]):
        a0 = max(0, p["steps"][0] - 1)
        y, sr = librosa.load(f"{sys.argv[1]}/{name}/{k}_drums.wav", sr=22050)
        st = [tuple(x) for x in stemdrums.drums2(y, sr, np.array(p["steps"]) - a0)]; mx = [tuple(x) for x in p["mix"]]
        for lab, h in (("mix", mx), ("stem", st)): tot[lab].append(stats(h))
        (a, ra, sa), (b, rb, sb) = stats(mx), stats(st)
        print(f"{name} piece {k}: mix {a} hits, {ra:.0%} repeat, snares on 2/4 {sa:.0%}  |  stem {b} hits, {rb:.0%} repeat, snares on 2/4 {sb:.0%}")
        if "-v" in os.environ.get("SHOW", ""): print("  mix\n" + grid(mx) + "\n  stem\n" + grid(st))
for lab, v in tot.items():
    v = np.array(v); print(f"{lab:4s}: {v[:,0].mean():.0f} hits a piece, {v[:,1].mean():.0%} repeat bar to bar, snares on 2/4 {np.nanmean(v[:,2]):.0%}")
