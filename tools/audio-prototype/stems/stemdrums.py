# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Drums from a drums-only stem: each band's onset flux near each 16th, kept when it stands out against the
# section's own hits (a clean stem has no bass or chords to be confused with, so no tone checks are needed).
import numpy as np, librosa
HOP = 128
BANDS = {0: (30, 150), 2: (180, 3500), 4: (6000, 11000)}
def drums(y, sr, steps, rel=(0.25, 0.3, 0.2), w=(0.035, 0.035)):
    S = np.abs(librosa.stft(y, n_fft=1024, hop_length=HOP)); f = librosa.fft_frequencies(sr=sr, n_fft=1024)
    fr = lambda t: int(round(t * sr / HOP))
    flux = {}
    for lane, (lo, hi) in BANDS.items():
        e = np.log1p(100 * S[(f >= lo) & (f < hi)].sum(0))
        flux[lane] = np.maximum(0, np.diff(e, prepend=e[0]))
    val = {lane: np.array([flux[lane][max(0, fr(t - w[0])):fr(t + w[1]) + 1].max(initial=0) for t in steps]) for lane in BANDS}
    out = []
    for k, lane in enumerate(BANDS):
        v = val[lane]; top = np.quantile(v, 0.97) + 1e-9
        for n in range(len(steps)):
            if v[n] < rel[k] * top: continue
            if lane == 2 and val[0][n] > v[n] * 1.3: continue          # (a kick's click in the mids is not a snare)
            if lane == 4:
                e = S[(f >= 6000) & (f < 11000)].sum(0); x = fr(steps[n]); pk = e[x:x + fr(0.035)].max(initial=0) + 1e-9; r = x
                while r < len(e) and e[r] > 0.25 * pk and r - x < fr(0.4): r += 1
                out.append((n, 5 if (r - x) * HOP / sr > 0.15 else 4)); continue
            out.append((n, lane))
    return sorted(set(out))

def drums2(y, sr, steps, z=0.5, floor=6.0):
    """Each step's rise per band (dB, the best attack near the step against the 45 ms before), scaled by the band's
    own loud steps (its 95th percentile); a hit is given to the bands that dominate it: kick when the lows rise more
    than the mids, snare when the mids rise more than the lows, hat when the highs rise well above the mids."""
    import librosa as lr
    S = np.abs(lr.stft(y, n_fft=1024, hop_length=HOP)); f = lr.fft_frequencies(sr=sr, n_fft=1024)
    fr = lambda t: int(round(t * sr / HOP)); w0, w1, pre = fr(0.045), fr(0.035), fr(0.045)
    E = {"low": S[(f >= 30) & (f < 150)].sum(0), "mid": S[(f >= 180) & (f < 3500)].sum(0), "high": S[(f >= 6000) & (f < 11000)].sum(0)}
    R = {k: np.zeros(len(steps)) for k in E}
    for n, t in enumerate(steps):
        x = fr(t)
        for k, e in E.items():
            if x - w0 - pre < 1 or x + w1 + 2 >= len(e): continue
            j = max(range(x - w0, x + w1), key=lambda j: e[j] - e[j - 1])
            R[k][n] = 10 * np.log10(e[j:j + fr(0.02) + 1].max() / (e[j - pre:j - 1].mean() + 1e-9))
    Z = {k: R[k] / (np.quantile(R[k], 0.95) + 1e-9) for k in R}
    out = []
    for n in range(len(steps)):
        lo, mi, hi = R["low"][n], R["mid"][n], R["high"][n]
        kick = Z["low"][n] >= z and lo >= floor and lo >= mi
        snare = Z["mid"][n] >= z and mi >= floor and mi > lo + 1
        hat = Z["high"][n] >= z and hi >= floor and (hi >= mi + 2 or not snare)
        if kick: out.append((n, 0))
        if snare: out.append((n, 2))
        if hat:
            e = E["high"]; x = fr(steps[n]); pk = e[x:x + w1].max(initial=0) + 1e-9; r = x
            while r < len(e) and e[r] > 0.25 * pk and r - x < fr(0.4): r += 1
            out.append((n, 5 if (r - x) * HOP / sr > 0.15 else 4))
    return sorted(set(out))
