# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# A/B files for listening: the piece's original 4 bars (left) with the detected drums as plain synth hits (right);
# one file per method, and the Demucs drum stem alone.
import sys, os, json, numpy as np, librosa, soundfile as sf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import stemdrums, abmono
song, d, stems, out, label = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4], sys.argv[5]
SR = 22050; rng = np.random.default_rng(0)
def kick(): t = np.arange(int(.3 * SR)) / SR; return np.sin(2 * np.pi * np.cumsum(50 + 100 * np.exp(-t * 30)) / SR) * np.exp(-t * 10)
def snare(): t = np.arange(int(.2 * SR)) / SR; return .5 * rng.standard_normal(len(t)) * np.exp(-t * 20) + .4 * np.sin(2 * np.pi * 190 * t) * np.exp(-t * 25)
def hat(o): t = np.arange(int((.3 if o else .05) * SR)) / SR; n = rng.standard_normal(len(t)); n = np.diff(n, prepend=0); return .25 * n * np.exp(-t * (8 if o else 70))
SOUND = {0: kick, 2: snare, 4: lambda: hat(False), 5: lambda: hat(True)}
y, _ = librosa.load(song, sr=SR, mono=True)
for k, p in enumerate(d["pieces"][:1]):
    st = np.array(p["steps"]); a, b = st[0], st[-1] + 60 / p["bpm"] / 4 + .3
    orig = y[int(a * SR):int(b * SR)]; a0 = max(0, a - 1)
    sy, _ = librosa.load(f"{stems}/{k}_drums.wav", sr=SR)
    sf.write(f"{out}/{label} - drum stem.wav", sy[int((a - a0) * SR):int((b - a0) * SR)], SR)
    for name, hits in (("1 now (from the mix)", [tuple(x) for x in p["mix"]]), ("2 from the drum stem", stemdrums.drums2(sy, SR, st - a0))):
        r = np.zeros(len(orig))
        for n, l in hits:
            s = SOUND[l](); i = int((st[n] - a) * SR); r[i:i + len(s)] += s[:max(0, len(r) - i)]
        st2 = abmono.sequence(orig, r)
        sf.write(f"{out}/{label} - {name}.wav", st2, SR)
print("ok", label)
