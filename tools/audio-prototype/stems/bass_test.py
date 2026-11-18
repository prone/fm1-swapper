# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# The bassline as the app finds it (Basic Pitch on the mix, the lowest note per step below C3) vs Basic Pitch on the
# Demucs bass stem (the lowest note per step below C4). Synthetic: scored against the truth. Real: compared, and A/B
# files (the original left, the bassline as a plain synth right).
import sys, os, json, tempfile, numpy as np, librosa, soundfile as sf
sys.path.insert(0, sys.argv[1]); from a2s import Analysis
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import abmono
from basic_pitch import FilenameSuffix, build_icassp_2022_model_path
from basic_pitch.inference import predict
MODEL = build_icassp_2022_model_path(FilenameSuffix.onnx); SR = 22050
def notes(y):
    with tempfile.NamedTemporaryFile(suffix=".wav") as f:
        sf.write(f.name, y, SR); _, _, ns = predict(f.name, MODEL, onset_threshold=0.5, frame_threshold=0.3, minimum_note_length=80)
    return [(float(s), float(e), int(p), float(a)) for s, e, p, a, _ in ns]
def line(ns, steps, top, t0=0.0):
    q = (steps[-1] - steps[0]) / 63; by = {}
    for s, e, p, a in ns:
        st = int(round((s + t0 - steps[0]) / q))
        if 0 <= st < 64 and p < top: by.setdefault(st, []).append((p, max(1, min(64 - st, round((e - s) / q)))))
    out = [(st, *min(by[st])[::-1]) for st in sorted(by)]                # (step, len, pitch)
    return [(st, max(1, min(ln, (out[i + 1][0] - st) if i + 1 < len(out) else ln)), p) for i, (st, ln, p) in enumerate(out)]
def f1(truth, got, octave=False):
    k = (lambda st, p: (st, p % 12)) if octave else (lambda st, p: (st, p))
    T = {k(s, p) for s, _, p in truth}; G = {k(s, p) for s, _, p in got}; tp = len(T & G)
    return 2 * tp / max(1, len(T) + len(G))
mode = sys.argv[2]
if mode == "synth":
    for mixf, stemf, jf in zip(sys.argv[3::3], sys.argv[4::3], sys.argv[5::3]):
        d = json.load(open(jf)); mix, _ = librosa.load(mixf, sr=SR); stem, _ = librosa.load(stemf, sr=SR)
        a = Analysis(mix, SR); steps, bpm = a.grid(d["lead_in"] + 0.05)
        n0 = round((steps[0] - d["lead_in"]) / (60 / d["bpm"] / 4))
        truth = [(b * 16 + s - n0, ln, p) for b in range(8) for s, ln, p in [(0, 3, 39), (3, 3, 39), (8, 4, 42), (12, 4, 44)] if 0 <= b * 16 + s - n0 < 64]
        m, s = line(notes(mix), steps, 48), line(notes(stem[:len(mix)]), steps, 60)
        print(f"{d['bpm']:>3} BPM: truth {len(truth)} notes | mix {len(m)} notes, F1 {f1(truth, m):.2f} (any octave {f1(truth, m, True):.2f}) | stem {len(s)} notes, F1 {f1(truth, s):.2f} (any octave {f1(truth, s, True):.2f})")
else:
    song, d, stems, out, label = sys.argv[3], json.load(open(sys.argv[4])), sys.argv[5], sys.argv[6], sys.argv[7]
    y, _ = librosa.load(song, sr=SR)
    for k, p in enumerate(d["pieces"]):
        st = np.array(p["steps"]); a, b = st[0], st[-1] + 60 / p["bpm"] / 4 + .3; a0 = max(0, a - 1); b0 = b + 1
        m = line(notes(y[int(a0 * SR):int(b0 * SR)]), st, 48, a0)
        sb, _ = librosa.load(f"{stems}/{k}_bass.wav", sr=SR); s = line(notes(sb), st, 60, a0)
        agree = f1(m, s); agree8 = f1(m, s, True)
        rng = lambda l: f"{min(x[2] for x in l)}-{max(x[2] for x in l)}" if l else "-"
        print(f"{label} piece {k}: mix {len(m)} notes ({rng(m)}) | stem {len(s)} notes ({rng(s)}) | agree {agree:.0%} (any octave {agree8:.0%})")
        if k == 0:
            orig = y[int(a * SR):int(b * SR)]
            for name, l in (("1 now (from the mix)", m), ("2 from the bass stem", s)):
                r = np.zeros(len(orig)); q = (st[-1] - st[0]) / 63
                for s0, ln, pi in l:
                    f = 440 * 2 ** ((pi - 69) / 12); n = int(ln * q * SR * .95); t = np.arange(n) / SR
                    x = sum(np.sin(2 * np.pi * f * h * t) / h for h in range(1, 6)) * np.minimum(1, t / .005) * np.exp(-t * 2)
                    x[-int(.01 * SR):] *= np.linspace(1, 0, int(.01 * SR)); i = int((st[s0] - a) * SR); r[i:i + n] += x[:max(0, len(r) - i)]
                sf.write(f"{out}/{label} - bass {name}.wav", abmono.sequence(orig, r), SR)
            sf.write(f"{out}/{label} - bass stem.wav", sb[int((a - a0) * SR):int((b - a0) * SR)], SR)
