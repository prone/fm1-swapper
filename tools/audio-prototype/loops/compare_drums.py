# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
import sys, os, json, numpy as np, librosa
sys.path.insert(0, sys.argv[1]); from a2s import Analysis
ts = json.load(open(sys.argv[3])); y, sr = librosa.load(sys.argv[2], sr=22050, mono=True); a = Analysis(y, sr)
tst = np.array(ts["steps"]); nb = len(ts["F"]["drums"]); T = np.array(ts["F"]["drums"])
R, _, _ = a.rises(tst[:nb * 16])
P = np.array([np.concatenate([np.clip(R[k][i * 16:(i + 1) * 16], 0, None) for k in ("low", "mid", "high")]) for i in range(nb)])
P = P / (np.linalg.norm(P, axis=1, keepdims=True) + 1e-9)
m = ~np.eye(nb, dtype=bool); SP = P @ P.T; ST = T @ T.T
print(f"same grid: prototype drums {SP[m].mean():.2f} (sd {SP[m].std():.2f}) | app {ST[m].mean():.2f} (sd {ST[m].std():.2f}) | correlation {np.corrcoef(SP[m], ST[m])[0,1]:.2f}")
# per step: how the attack values themselves agree
print("per-bar vector agreement (cosine of prototype vs app, same bar):", f"{np.mean((P * T).sum(1)):.2f}")
pb = np.array([a.beats[0]]); bt = a.beats; tb = tst[::4]
d = [float(np.min(np.abs(bt - t))) for t in tb[:200]]
print(f"beat times: app beats vs prototype beats, median gap {np.median(d) * 1000:.0f} ms, 90th percentile {np.quantile(d, .9) * 1000:.0f} ms")
