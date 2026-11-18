# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# What the app takes from a loop, as plain synth (mono, in sequence): the original 4 bars, the lead alone, the bass
# and chords, then all of it with the original.
import sys, json, numpy as np, soundfile as sf
wav, dump, k, out = sys.argv[1], json.load(open(sys.argv[2])), int(sys.argv[3]), sys.argv[4]
y, sr = sf.read(wav, dtype="float32"); l = dump["loops"][k]; q = 15 / l["bpm"]; a = l["start"]; n = int(64 * q * sr)
orig = y[int(a * sr):int(a * sr) + n]
def tone(p, ln, bright, decay):
    f = 440 * 2 ** ((p - 69) / 12); m = int(ln * q * sr * 0.95); t = np.arange(m) / sr
    x = sum(np.sin(2 * np.pi * f * h * t) / h for h in range(1, bright)) * np.minimum(1, t / .005) * np.exp(-t * decay)
    x[-int(.01 * sr):] *= np.linspace(1, 0, int(.01 * sr)); return x
def line(notes, bright, decay, gain):
    r = np.zeros(n)
    for st, ln, p in notes:
        x = tone(p, ln, bright, decay) * gain; i = int(st * q * sr); r[i:i + len(x)] += x[:max(0, n - i)]
    return r
lead = line(l["lead"], 6, 1.5, .5); bass = line(l["bass"], 4, 1.0, .6)
keys = line([(st, ln, p) for st, ln, ps in l["keys"] for p in ps], 3, 0.8, .2)
norm = lambda x: x / (np.abs(x).max() + 1e-9) * .8; gap = np.zeros(int(.8 * sr))
mix = norm(.6 * norm(orig) + .5 * norm(lead + bass + keys))
sf.write(out, np.concatenate([norm(orig), gap, norm(lead), gap, norm(bass + keys), gap, mix]), sr)
print(f"loop {k + 1}: {len(l['lead'])} lead notes, {len(l['bass'])} bass, {len(l['keys'])} chords; from {a:.1f} s")
