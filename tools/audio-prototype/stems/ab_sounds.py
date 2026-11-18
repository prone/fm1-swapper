# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
import numpy as np
SR = 22050; rng = np.random.default_rng(0)
def kick(): t = np.arange(int(.3 * SR)) / SR; return np.sin(2 * np.pi * np.cumsum(50 + 100 * np.exp(-t * 30)) / SR) * np.exp(-t * 10)
def snare(): t = np.arange(int(.2 * SR)) / SR; return .5 * rng.standard_normal(len(t)) * np.exp(-t * 20) + .4 * np.sin(2 * np.pi * 190 * t) * np.exp(-t * 25)
def hat(o): t = np.arange(int((.3 if o else .05) * SR)) / SR; n = rng.standard_normal(len(t)); n = np.diff(n, prepend=0); return .25 * n * np.exp(-t * (8 if o else 70))
SOUND = {0: kick, 2: snare, 4: lambda: hat(False), 5: lambda: hat(True)}
