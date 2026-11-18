# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# The loop-sampler page from the app's own loops (loops.songs.test.ts with LOOP_DUMP): each loop's audio exactly.
import sys, os, io, json, base64, numpy as np, soundfile as sf
wavdir, dump, out = sys.argv[1], sys.argv[2], sys.argv[3]; songs = []
for sid, label in zip(sys.argv[4::2], sys.argv[5::2]):
    y, sr = sf.read(os.path.join(wavdir, sid + ".wav"), dtype="float32"); L = json.load(open(os.path.join(dump, sid + ".loops.json")))
    pads = []
    for i, l in enumerate(L["loops"]):
        a, b = l["start"], l["end"]; clip = y[int(round(a * sr)):int(round(b * sr))]; clip = clip / (np.abs(clip).max() + 1e-9) * 0.9
        buf = io.BytesIO(); sf.write(buf, clip, sr, format="WAV", subtype="PCM_16")
        pads.append({"name": str(i + 1) + (" ?" if l["unsure"] else ""), "repeats": l["repeats"], "first": f"{int(a) // 60}:{int(a % 60):02d}",
                     "secs": round(b - a, 3), "from": round(a, 3), "to": round(b, 3), "wav": base64.b64encode(buf.getvalue()).decode()})
    ln = L["loops"][0]["lengths"] if L["loops"] else {"drums": 64, "bass": 64, "keys": 64}
    songs.append({"song": label, "bpm": round(L["bpm"], 1), "lengths": {"drums": ln["drums"] // 16, "bass": ln["bass"] // 16, "chords": ln["keys"] // 16}, "order": "(from the app's analysis)", "pads": pads})
page = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sampler.html")).read().replace("__DATA__", json.dumps(songs))
page = page.replace("<h1>Loop sampler</h1>", "<h1>Loop sampler: the app's version</h1><p><b>These are the loops the app itself now finds</b> (its own code, not the prototype). A ? marks a loop the app is unsure of.</p>")
open(out, "w").write(page)
