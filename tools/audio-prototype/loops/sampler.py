# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# A loop-sampler page: each song's loops (the most typical repeat of each, exactly 4 bars: from its first 16th to
# the next phrase's) as pads; the audio is embedded (mono 16-bit WAV, base64) so the page works from a file.
import sys, os, io, json, base64, html, numpy as np, soundfile as sf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import loops, timbre
SR = loops.SR; out = sys.argv[2]; songs = []
for path, label in zip(sys.argv[3::2], sys.argv[4::2]):
    d, per, phase, starts, groups, lab = loops.song(path); st = d["steps"]; y = d["y"]
    inside, at, times = timbre.entries(d)
    ref = loops.refine(d, starts, groups, (set(timbre.bounds.boundaries(d)[0]) | at, inside)); pads = []
    print(f"  {label}: new sounds at " + ", ".join(f"{t}s" for t, _ in times))
    for g, occ in sorted(enumerate(groups), key=lambda x: groups[x[0]][0]):
        if len(occ) < 2: continue
        r = ref[g]; s0 = r["rep"] * 16
        print(f"  {label} loop {chr(65 + g)}: {len(occ)}x, start moved {r['shift']:+d} bars, from {st[s0]:.1f} s" + (" (crosses a change)" if r["crosses"] else ""))
        a = st[s0]; b = st[s0 + 64] if s0 + 64 < len(st) else st[s0 + 63] + (st[s0 + 63] - st[s0 + 62])
        clip = y[int(round(a * SR)):int(round(b * SR))]; clip = clip / (np.abs(clip).max() + 1e-9) * 0.9
        buf = io.BytesIO(); sf.write(buf, clip, SR, format="WAV", subtype="PCM_16")
        t = st[r["bars"][0] * 16]
        pads.append({"name": chr(65 + g) if g < 26 else "?", "repeats": len(occ), "first": f"{int(t) // 60}:{int(t % 60):02d}",
                     "secs": round(b - a, 3), "from": round(a, 3), "to": round(b, 3), "wav": base64.b64encode(buf.getvalue()).decode()})
    songs.append({"song": label, "bpm": round(d["a"].bpm, 1), "lengths": {k: p for k, (p, _) in per.items()},
                  "order": "".join(chr(65 + g) if g < 26 else "?" for g in lab), "pads": pads})
    print(label, len(pads), "loops", flush=True)
data = json.dumps(songs)
page = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sampler.html")).read().replace("__DATA__", data)
open(out, "w").write(page)
