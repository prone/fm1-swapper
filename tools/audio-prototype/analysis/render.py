# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# The arranged sections as audio (a sawtooth lead, a softer bass), to compare with the song by ear.
import sys, json, numpy as np, scipy.io.wavfile as wav
arr = json.load(open(sys.argv[1])); out = sys.argv[2]
SR = 44100; step = 60 / arr["tempo"] / 4
def tone(f, n, bright):
    t = np.arange(n) / SR
    s = sum(np.sin(2 * np.pi * f * k * t) / k for k in range(1, bright))
    env = np.minimum(1, np.arange(n) / (0.004 * SR)) * np.exp(-t * 2.5)
    r = min(n, int(0.02 * SR)); env[-r:] *= np.linspace(1, 0, r)
    return s * env
song = []
for sec in arr["sections"]:
    a = np.zeros(int(64 * step * SR) + SR // 4)
    for line, gain, bright in ((sec["lead"], 0.3, 10), (sec["bass"], 0.5, 5)):
        for st, ln, p in line:
            f = 440 * 2 ** ((p - 69) / 12); i = int(st * step * SR); n = int(ln * step * SR * 0.95)
            a[i:i + n] += tone(f, n, bright) * gain
    song.append(a[: int(64 * step * SR)])
x = np.concatenate(song); x /= np.abs(x).max() * 1.1
wav.write(out, SR, (x * 32767).astype(np.int16))
print(f"{len(x) / SR:.1f} s")
