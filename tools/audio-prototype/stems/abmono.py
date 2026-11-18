# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Listening files in mono, one after the other: the original, a pause, what was found alone, a pause, both together.
import numpy as np
def sequence(orig, found, sr=22050):
    o = orig / (np.abs(orig).max() + 1e-9) * .8; f = found / (np.abs(found).max() + 1e-9) * .8; gap = np.zeros(int(.8 * sr))
    both = .6 * o + .6 * f; both /= max(1, np.abs(both).max() / .9)
    return np.concatenate([o, gap, f, gap, both])
