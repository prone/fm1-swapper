# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# The TS features against the prototype's, bar by bar (matched by time): how alike each pair of bars is, per part.
import sys, os, json, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import loops
ts = json.load(open(sys.argv[3])); d = loops.analyse(sys.argv[2])
pst = d["steps"]; tst = np.array(ts["steps"])
pb = [pst[i * 16] for i in range(d["nb"])]; tb = [tst[i * 16] for i in range(len(ts["F"]["drums"]))]
pairs = [(i, int(np.argmin(np.abs(np.array(tb) - t)))) for i, t in enumerate(pb) if np.min(np.abs(np.array(tb) - t)) < 0.15]
print(f"{len(pairs)} bars matched of {len(pb)} (prototype) / {len(tb)} (app)")
for k, tk in (("drums", "drums"), ("bass", "bass"), ("chords", "chords")):
    P = d["F"][k]; T = np.array(ts["F"][tk])
    ip = [a for a, _ in pairs]; it = [b for _, b in pairs]
    SP = P[ip] @ P[ip].T; ST = T[it] @ T[it].T; m = ~np.eye(len(ip), dtype=bool)
    print(f"{k:7s}: prototype bar-pair similarity mean {SP[m].mean():.2f} (sd {SP[m].std():.2f}) | app {ST[m].mean():.2f} (sd {ST[m].std():.2f}) | agreement (correlation) {np.corrcoef(SP[m], ST[m])[0,1]:.2f}")
