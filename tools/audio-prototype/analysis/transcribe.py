# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Whole song -> notes (start, end, pitch, amp), saved as JSON; then a summary of what came out.
import sys, json, numpy as np
from basic_pitch import FilenameSuffix, build_icassp_2022_model_path
from basic_pitch.inference import predict
src, out = sys.argv[1], sys.argv[2]
_, _, notes = predict(src, build_icassp_2022_model_path(FilenameSuffix.onnx), onset_threshold=0.5, frame_threshold=0.3, minimum_note_length=80)
rows = sorted([(float(s), float(e), int(p), float(a)) for s, e, p, a, _ in notes])
json.dump(rows, open(out, "w"))
p = np.array([r[2] for r in rows]); a = np.array([r[3] for r in rows])
print(len(rows), "notes; pitch range", p.min(), "-", p.max(), "; median amp", round(float(np.median(a)), 2))
names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
hist = np.bincount(p % 12, weights=a, minlength=12)
print("pitch classes (weighted):", " ".join(f"{names[i]}:{hist[i]:.0f}" for i in np.argsort(-hist)))
for lo, hi, name in [(0, 48, "below C3 (bass)"), (48, 60, "C3-B3"), (60, 72, "C4-B4"), (72, 128, "C5 up")]:
    print(f"  {name}: {((p >= lo) & (p < hi)).sum()}")
