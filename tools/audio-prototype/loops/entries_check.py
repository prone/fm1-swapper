# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import loops, timbre
for p in sys.argv[2:]:
    d = loops.analyse(p); inside, at, times = timbre.entries(d)
    print(os.path.basename(p), "entries:", ", ".join(f"{t}s ({b})" for t, b in times))
