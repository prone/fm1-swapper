# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Scores detected drum hits (step, lane) against the truth: per lane precision and recall, and the overall F1.
import json
def score(truth, got, lanes={0: "kick", 2: "snare", 4: "hat", 5: "open hat"}, merge_hats=True):
    norm = lambda l: 4 if merge_hats and l == 5 else l
    T = {(s, norm(l)) for s, l in truth}; G = {(s, norm(l)) for s, l in got}
    out = {}
    for l in sorted({norm(x) for x in lanes}):
        t = {x for x in T if x[1] == l}; g = {x for x in G if x[1] == l}; hit = len(t & g)
        out[lanes[l]] = (hit, len(t), len(g))
    tp = len(T & G); p = tp / max(1, len(G)); r = tp / max(1, len(T))
    return out, 2 * p * r / max(1e-9, p + r)
