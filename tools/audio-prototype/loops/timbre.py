# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Per bar: the tone colour of the tonal part (MFCCs 1-19, mean and spread, from the harmonic layer), and how much it
# changes at each bar line (4 bars before vs after, as boundaries() does).
import sys, os, numpy as np, librosa
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import loops, bounds
def timbre(d):
    y = d["y"]; st = d["steps"]; nb = d["nb"]; sr = loops.SR
    harm, _ = librosa.effects.hpss(y); M = librosa.feature.mfcc(y=harm, sr=sr, n_mfcc=20, hop_length=512)[1:]
    M = (M - M.mean(1, keepdims=True)) / (M.std(1, keepdims=True) + 1e-9)
    fr = lambda t: int(round(t * sr / 512))
    T = np.array([np.concatenate([M[:, fr(st[b * 16]):fr(st[min(len(st) - 1, b * 16 + 15)])].mean(1), M[:, fr(st[b * 16]):fr(st[min(len(st) - 1, b * 16 + 15)])].std(1)]) for b in range(nb)])
    T = T - T.mean(0); return T / (np.linalg.norm(T, axis=1, keepdims=True) + 1e-9)
if __name__ == "__main__":
    d, per, phase, starts, groups, lab = loops.song(sys.argv[2]); st = d["steps"]; nb = d["nb"]
    T = timbre(d); S = T @ T.T; k = 4; nov = np.zeros(nb)
    for b in range(2, nb - 1):
        a0, a1 = max(0, b - k), min(nb, b + k); nov[b] = S[a0:b, a0:b].mean() + S[b:a1, b:a1].mean() - 2 * S[a0:b, b:a1].mean()
    thr = nov.mean() + nov.std()
    pk = [b for b in range(1, nb - 1) if nov[b] >= thr and nov[b] >= nov[b - 1] and nov[b] >= nov[b + 1]]
    print("tone-colour changes at " + ", ".join(f"bar {b} ({int(st[b*16])//60}:{st[b*16]%60:04.1f}, {nov[b]:.2f})" for b in pk))
    lo, hi = [int(x) for x in sys.argv[3].split("-")] if len(sys.argv) > 3 else (0, 0)
    for b in range(lo, hi): print(f"   bar {b} {int(st[b*16])//60}:{st[b*16]%60:04.1f} change {nov[b]:.2f}")

def changes(d):
    """The song's change points (bar numbers): where drums, bass and chords change, or the tone colour does."""
    T = timbre(d); S = T @ T.T; nb = d["nb"]; nov = np.zeros(nb)
    for b in range(2, nb - 1):
        a0, a1 = max(0, b - 4), min(nb, b + 4); nov[b] = S[a0:b, a0:b].mean() + S[b:a1, b:a1].mean() - 2 * S[a0:b, b:a1].mean()
    thr = nov.mean() + nov.std()
    tone = [b for b in range(1, nb - 1) if nov[b] >= thr and nov[b] >= nov[b - 1] and nov[b] >= nov[b + 1]]
    return sorted(set(tone) | set(bounds.boundaries(d)[0]))

def beat_changes(d, z=1.5):
    """Where something new starts, to the beat (the song's grid: 4 16ths a beat): the tone colour of each beat against
    the average of the 8 before, where it jumps (well above its usual level, and well above the beats just before).
    Returns the bars that contain one (part way in: a lead-in) and the bars that start with one."""
    y = d["y"]; st = d["steps"]; sr = loops.SR
    harm, _ = librosa.effects.hpss(y); M = librosa.feature.mfcc(y=harm, sr=sr, n_mfcc=20, hop_length=512)[1:]
    M = (M - M.mean(1, keepdims=True)) / (M.std(1, keepdims=True) + 1e-9)
    fr = lambda t: int(round(t * sr / 512)); bt = st[::4]
    B = np.array([M[:, fr(a):max(fr(a) + 1, fr(b))].mean(1) for a, b in zip(bt[:-1], bt[1:])])
    dv = np.array([np.linalg.norm(B[i] - B[i - 8:i].mean(0)) if i >= 8 else 0 for i in range(len(B))])
    thr = dv[8:].mean() + z * dv[8:].std()
    inside, at = set(), set()
    for i in range(9, len(B)):
        if dv[i] >= thr and dv[i] >= 1.6 * np.median(dv[i - 8:i]) and dv[i - 1] < thr:
            (at if i % 4 == 0 else inside).add(i // 4)
    return inside, at

BANDS = ((80, 250), (250, 700), (700, 3000), (3000, 8000))
def entries(d, ratio=2.0, floor=0.25):
    """Where a new sound comes in, to the beat: the tonal layer's energy per beat in four bands; an entry is a beat
    where a band jumps to at least `ratio` times its median over the 8 beats before (and is a real part of the mix:
    `floor` of that band's loudest). Returns the bars an entry falls part way into, and the bars that start with one,
    and the entries' times."""
    y = d["y"]; st = d["steps"]; sr = loops.SR
    harm, _ = librosa.effects.hpss(y); H = np.abs(librosa.stft(harm, n_fft=2048, hop_length=512)); f = librosa.fft_frequencies(sr=sr, n_fft=2048)
    fr = lambda t: int(round(t * sr / 512)); bt = st[::4]
    inside, at, times, hits = set(), set(), [], {}
    for lo, hi in BANDS:
        e = H[(f >= lo) & (f < hi)].sum(0)
        E = np.array([e[fr(a):max(fr(a) + 1, fr(b))].mean() for a, b in zip(bt[:-1], bt[1:])]); top = np.quantile(E, 0.98)
        for i in range(9, len(E)):
            m = np.median(E[i - 8:i]) + 1e-9
            if E[i] >= ratio * m and E[i] >= floor * top and E[i - 1] < ratio * m: hits.setdefault(i, []).append(f"{lo}-{hi}")
    for i, bands in hits.items():                       # (a new instrument lifts more than one band: two or more)
        if len(bands) >= 2: (at if i % 4 == 0 else inside).add(i // 4); times.append((round(float(bt[i]), 2), "+".join(bands)))
    return inside, at, sorted(times)
if __name__ == "__main__" and len(sys.argv) > 3 and sys.argv[3] == "entries":
    pass
