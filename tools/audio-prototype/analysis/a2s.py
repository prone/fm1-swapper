# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Audio -> SLOOP, reference version (to port to TypeScript): a section's 16th grid, its drums, and its notes.
import numpy as np, librosa
HOP = 128

class Analysis:
    def __init__(self, y, sr=22050):
        self.y, self.sr = y, sr
        harm, perc = librosa.effects.hpss(y, margin=(1.0, 3.0))
        f = librosa.fft_frequencies(sr=sr, n_fft=1024)
        S = np.abs(librosa.stft(perc, n_fft=1024, hop_length=HOP))
        H = np.abs(librosa.stft(harm, n_fft=1024, hop_length=HOP))
        self.B = {"low": S[(f >= 30) & (f < 120)].sum(0), "mid": S[(f >= 180) & (f < 3500)].sum(0), "high": S[(f >= 6000) & (f < 11000)].sum(0)}
        self.low_tone = H[(f >= 30) & (f < 120)].sum(0)
        self.env = librosa.onset.onset_strength(y=perc, sr=sr, hop_length=64)          # (fine: for timing)
        tempo, beats = librosa.beat.beat_track(onset_envelope=librosa.onset.onset_strength(y=perc, sr=sr), sr=sr)
        bt = librosa.frames_to_time(beats, sr=sr)
        # half or double the tracker's tempo when that puts the onsets on 16ths better (it often locks onto half)
        def contrast(b):
            q = float(np.median(np.diff(b))) / 4; on = np.concatenate([np.linspace(a, c, 4, endpoint=False) for a, c in zip(b[:-1], b[1:])])
            return self.at(on).mean() / (self.at(on + q / 2).mean() + 1e-9)
        half = bt[::2]; double = np.sort(np.concatenate([bt, (bt[:-1] + bt[1:]) / 2]))
        # a song with hats on 8ths fits 128 and 64 BPM alike: weigh by how common the tempo is (most music is
        # 80-160 BPM: a bell around 110 BPM, 0.8 octave wide), so the fit decides only when it clearly differs
        common = lambda b: np.exp(-0.5 * (np.log2(60 / np.median(np.diff(b)) / 110) / 0.8) ** 2)
        c = {k: contrast(b) * common(b) if 55 <= 60 / np.median(np.diff(b)) <= 200 else -1
             for k, b in (("half", half), ("same", bt), ("double", double))}
        self.beats = {"half": half, "same": bt, "double": double}[max(c, key=c.get)]
        self.tempo_scores = c
        self.bpm = 60 / float(np.median(np.diff(self.beats)))

    fr = lambda self, t: int(round(t * self.sr / HOP))
    def at(self, ts): return self.env[np.clip(np.round(np.asarray(ts) * self.sr / 64).astype(int), 0, len(self.env) - 1)]

    def grid(self, start):
        """64 16ths from the beat nearest `start`: the beats around it fitted to a straight line (a steady tempo for
        these 4 bars), then slid (+-60 ms, 1 ms steps) to where the attacks fall."""
        b = self.beats; i0 = int(np.argmin(np.abs(b - start)))
        near = [(i, t) for i, t in enumerate(b) if i0 - 4 <= i <= i0 + 20]
        k, c = np.polyfit([i for i, _ in near], [t for _, t in near], 1)        # seconds per beat, offset
        first = round((start - c) / k)                                       # (may be before the first tracked beat)
        steps = c + k * (first + np.arange(64) / 4)
        shift = max(np.arange(-0.06, 0.061, 0.001), key=lambda d: self.at(steps + d).sum())
        return steps + shift, 60 / k

    def rises(self, steps):
        """How much each band rises at each step (best attack within -45..+35 ms, against the 45 ms before), and how
        much of the lows is tone (a bass note) rather than a thump."""
        w0, w1, pre = self.fr(0.045), self.fr(0.035), self.fr(0.045)
        R = {k: np.zeros(len(steps)) for k in self.B}; tone = np.zeros(len(steps)); ring = np.zeros(len(steps))
        for n, t in enumerate(steps):
            x = self.fr(t)
            for k, e in self.B.items():
                if x - w0 - pre < 1 or x + w1 + self.fr(0.4) >= len(e): continue
                j = max(range(x - w0, x + w1), key=lambda j: e[j] - e[j - 1])
                R[k][n] = 10 * np.log10(e[j:j + self.fr(0.02) + 1].max() / (e[j - pre:j - 1].mean() + 1e-9))
            tone[n] = self.low_tone[x:x + self.fr(0.1)].mean() / (self.B["low"][x:x + self.fr(0.1)].mean() + 1e-9)
            e = self.B["high"]; peak = e[x:x + w1].max() + 1e-9; r = x + w1
            while r < len(e) and e[r] > 0.25 * peak and r - x < self.fr(0.4): r += 1
            ring[n] = (r - x) * HOP / self.sr
        return R, tone, ring

    def drums(self, steps):
        """Hits on the grid: kick (lows rise most, not a bass tone), snare (mids rise well above the lows), hat (highs;
        on a snare only when well above the mids; open when it rings past 150 ms). A hit counts when strong, or when
        moderate at a position of the bar the section's other bars also hit (drum parts repeat)."""
        R, tone, ring = self.rises(steps)
        cand = {0: np.where((R["low"] >= R["mid"] - 2) & (tone < 12), R["low"], 0),     # how strong a kick, a snare,
                2: np.where(R["mid"] - R["low"] >= 2.5, R["mid"], 0),                  # a hat each step looks
                4: R["high"]}
        out = []
        for lane, v in cand.items():
            strong, weak = {0: (9, 6), 2: (11, 7.5), 4: (9, 6)}[lane]
            # adapt to the song: never accept more than the loudest 35% of steps for a lane
            cut = max(weak, float(np.quantile(v, 0.65)))
            groove = np.array([v[p::16].mean() for p in range(16)])             # each position of the bar, all bars
            for n in range(len(steps)):
                if lane == 4 and n in [m for m, l in out if l == 2] and R["high"][n] - R["mid"][n] < 3.5: continue
                if v[n] >= strong or (v[n] >= cut and groove[n % 16] >= cut):
                    out.append((n, 5 if lane == 4 and ring[n] > 0.15 else lane))
        return sorted(set(out))

    def bar_start(self, hits):
        """Which of the 4 beats is bar 1: kicks on 1 (and 3), snares on 2 and 4."""
        def fit(o):
            return sum((2 if (n - o) % 16 == 0 else 1 if (n - o) % 16 == 8 else 0) for n, l in hits if l == 0) + \
                   sum(2 for n, l in hits if l == 2 and (n - o) % 16 in (4, 12)) - sum(1 for n, l in hits if l == 2 and (n - o) % 16 in (0, 8))
        return max((0, 4, 8, 12), key=fit)
