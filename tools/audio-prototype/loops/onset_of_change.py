# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Where a change starts, to the beat: the tone colour per beat (MFCCs of the tonal layer) against the average of the
# 8 beats before; printed per beat around given times.
import sys, numpy as np, librosa
y, sr = librosa.load(sys.argv[1], sr=22050, mono=True)
harm, perc = librosa.effects.hpss(y)
tempo, beats = librosa.beat.beat_track(y=perc, sr=sr, units="time")
M = librosa.feature.mfcc(y=harm, sr=sr, n_mfcc=20, hop_length=512)[1:]; M = (M - M.mean(1, keepdims=True)) / (M.std(1, keepdims=True) + 1e-9)
# the energy of 1-3 kHz in the tonal layer (where a flute's notes sit)
Hs = np.abs(librosa.stft(harm, n_fft=2048, hop_length=512)); f = librosa.fft_frequencies(sr=sr, n_fft=2048)
fl = Hs[(f >= 700) & (f < 3000)].sum(0); fl = fl / fl.max()
fr = lambda t: int(round(t * sr / 512))
B = np.array([M[:, fr(a):fr(b)].mean(1) for a, b in zip(beats[:-1], beats[1:])]); E = np.array([fl[fr(a):fr(b)].mean() for a, b in zip(beats[:-1], beats[1:])])
for c in [float(x) for x in sys.argv[2].split(",")]:
    print(f"around {c}s:")
    for i, t in enumerate(beats[:-1]):
        if abs(t - c) > 6 or i < 8: continue
        d = float(np.linalg.norm(B[i] - B[i - 8:i].mean(0)))
        print(f"   beat at {t:6.2f} s: tone change {d:5.2f}  {'#' * int(d * 4)}   tonal 0.7-3 kHz {E[i]:.2f} {'=' * int(E[i] * 40)}")
