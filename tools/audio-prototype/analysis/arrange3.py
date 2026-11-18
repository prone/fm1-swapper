# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# The song with the v4 analysis: each section's own 16th grid, its drums (a2s), and its notes snapped to that grid.
import sys, os, json, numpy as np, librosa
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from a2s import Analysis
wavf, notesf, out = sys.argv[1], sys.argv[2], sys.argv[3]
starts = [float(x) for x in sys.argv[4].split(",")]
y, sr = librosa.load(wavf, sr=22050, mono=True); a = Analysis(y, sr)
notes = json.load(open(notesf))
def ghost(n):
    s, e, p, amp = n
    return any(m[0] <= s < m[1] and p - m[2] in (12, 19, 24) and amp < 0.6 * m[3] for m in notes if m is not n)
notes = [n for n in notes if not ghost(n)]
def mono(line):
    return [[st, max(1, min(ln, (line[i + 1][0] - st) if i + 1 < len(line) else ln)), p] for i, (st, ln, p) in enumerate(line)]
secs = []
for t0 in starts:
    steps, bpm = a.grid(t0); hits = a.drums(steps); o = a.bar_start(hits)
    if o: steps, bpm = a.grid(steps[o]); hits = a.drums(steps)
    q = (steps[-1] - steps[0]) / 63
    snap = lambda t: int(round((t - steps[0]) / q))
    by = {}
    for s, e, p, amp in notes:
        st = snap(s)
        if 0 <= st < 64: by.setdefault(st, []).append((p, max(1, min(64 - st, round((e - s) / q))), amp))
    bass, lead, keys = [], [], []
    for st in sorted(by):
        ns = by[st]; low = [n for n in ns if n[0] < 48]; high = [n for n in ns if n[0] >= 60]
        top = max(high, key=lambda n: n[0]) if high else None
        if low: p, ln, _ = min(low); bass.append((st, ln, p))
        if top: lead.append((st, top[1], top[0]))
        mid = sorted({n[0] for n in ns if 48 <= n[0] < 72 and (top is None or n[0] != top[0])})[:4]
        if mid: keys.append([st, max(n[1] for n in ns if n[0] in mid), mid])
    drums = {}
    for n, l in hits: drums.setdefault(n, []).append(l)
    secs.append({"start": float(steps[0]), "bpm": bpm, "bass": mono(bass), "lead": mono(lead), "keys": keys,
                 "drums": [[n, ls] for n, ls in sorted(drums.items())]})
    print(f"section at {steps[0]:.2f}s {bpm:.1f} BPM: bass {len(bass)} keys {len(keys)} lead {len(lead)} drum steps {len(drums)}")
json.dump({"bpm": round(a.bpm), "sections": secs}, open(out, "w"))
