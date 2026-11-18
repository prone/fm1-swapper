# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# How long the music takes to repeat, in seconds, independent of the beat tracker: frame features (chroma and the
# percussive onset spectrum, ~23 ms frames) compared with themselves at each lag (a "beat spectrum", as REPET).
import sys, numpy as np, librosa
y, sr = librosa.load(sys.argv[1], sr=22050, mono=True)
t0, t1 = float(sys.argv[2]), float(sys.argv[3]); y = y[int(t0 * sr):int(t1 * sr)]
harm, perc = librosa.effects.hpss(y); hop = 512
C = librosa.feature.chroma_stft(y=harm, sr=sr, hop_length=hop)
P = np.log1p(np.abs(librosa.stft(perc, n_fft=1024, hop_length=hop))[:200]); P = np.maximum(0, np.diff(P, axis=1, prepend=P[:, :1]))
def lagsim(X):
    X = X / (np.linalg.norm(X, axis=0, keepdims=True) + 1e-9); n = X.shape[1]
    return np.array([float((X[:, :n - L] * X[:, L:]).sum(0).mean()) if L else 1 for L in range(int(16 * sr / hop))])
for name, X in (("tonal (chroma)", C), ("drums (onsets)", P)):
    s = lagsim(X); fps = sr / hop
    lo = int(1.0 * fps); pk = [L for L in range(lo, len(s) - 1) if s[L] >= s[L - 1] and s[L] >= s[L + 1]]
    top = sorted(pk, key=lambda L: -s[L])[:6]
    print(name + ": strongest repeat lags " + ", ".join(f"{L / fps:.2f} s ({s[L]:.2f})" for L in sorted(top)))
import os, sys as _s; _s.path.insert(0, sys.argv[4]); from a2s import Analysis
a = Analysis(y, sr); print(f"beat tracker: {a.bpm:.1f} BPM -> 1 bar {240 / a.bpm:.2f} s, 2 bars {480 / a.bpm:.2f} s, 4 bars {960 / a.bpm:.2f} s")
