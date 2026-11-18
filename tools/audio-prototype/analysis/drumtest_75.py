# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# A drum test with known hits: kick, snare, closed hat, open hat over a bassline and lead, 92 BPM, 8 bars.
# Writes the audio and the truth (step, lane) so detectors can be scored.
import sys, json, numpy as np, scipy.io.wavfile as wav, scipy.signal as sg
out = sys.argv[1]; SR = 22050; BPM = 75; STEP = 60 / BPM / 4; rng = np.random.default_rng(75)
bars = 8; n = int((bars * 16 + 8) * STEP * SR); mix = np.zeros(n)
def at(st): return int((st * STEP + 0.4) * SR)                    # 0.4 s of lead-in, as a song has
def kick(g=1.0):
    t = np.arange(int(0.35 * SR)) / SR; f = 50 + 110 * np.exp(-t * 30)
    return g * np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9)
def snare(g=0.8):
    t = np.arange(int(0.25 * SR)) / SR
    noise = sg.lfilter(*sg.butter(2, [800 / (SR / 2), 9000 / (SR / 2)], "band"), rng.standard_normal(len(t)))
    return g * (0.6 * noise * np.exp(-t * 18) + 0.5 * np.sin(2 * np.pi * 190 * t) * np.exp(-t * 25))
def hat(open_=False, g=0.35):
    t = np.arange(int((0.35 if open_ else 0.06) * SR)) / SR
    noise = sg.lfilter(*sg.butter(4, 7000 / (SR / 2), "high"), rng.standard_normal(len(t)))
    return g * noise * np.exp(-t * (7 if open_ else 60))
def add(x, i): mix[i:i + len(x)] += x[: max(0, n - i)]
truth = []
for b in range(bars):
    o = b * 16
    kicks = [0, 7, 10] if b % 2 == 0 else [0, 3, 10, 14]          # syncopated kicks
    for s in kicks: add(kick(), at(o + s)); truth.append((o + s, 0))
    for s in (4, 12): add(snare(), at(o + s)); truth.append((o + s, 2))
    if b % 4 == 3: add(snare(0.5), at(o + 15)); truth.append((o + 15, 2))   # a fill
    for s in range(0, 16, 2):
        op = s == 6
        add(hat(op), at(o + s)); truth.append((o + s, 5 if op else 4))
    if b % 2 == 1:
        for s in (11, 13): add(hat(g=0.25), at(o + s)); truth.append((o + s, 4))   # off-beat 16ths
# a bassline and a lead (pitched sound the drums must not be confused with)
def saw(f, ln, g):
    t = np.arange(int(ln * STEP * SR * 0.9)) / SR
    return g * sum(np.sin(2 * np.pi * f * k * t) / k for k in range(1, 8)) * np.exp(-t * 3)
for b in range(bars):
    for s, ln, p in [(0, 3, 39), (3, 3, 39), (8, 4, 42), (12, 4, 44)]: add(saw(440 * 2 ** ((p - 69) / 12), ln, 0.35), at(b * 16 + s))
    for s, ln, p in [(0, 2, 70), (2, 2, 72), (4, 4, 75), (10, 2, 73), (12, 4, 70)]: add(saw(440 * 2 ** ((p - 69) / 12), ln, 0.15), at(b * 16 + s))
mix += 0.01 * rng.standard_normal(n)
mix /= np.abs(mix).max() * 1.05
wav.write(out + "/drumtest75.wav", SR, (mix * 32767).astype(np.int16))
json.dump({"bpm": BPM, "lead_in": 0.4, "truth": truth}, open(out + "/drumtest75.json", "w"))
print(len(truth), "hits:", {l: sum(1 for _, x in truth if x == l) for l in (0, 2, 4, 5)})
