// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { describe, expect, it } from "vitest";
import { SR } from "./dsp";
import { originalLoop, sloopLoop } from "./preview";

const sec = { start: 1, bpm: 120, bass: [[0, 4, 36]], keys: [], lead: [[8, 2, 72]], drums: [[0, [0]], [4, [2]]], lengths: { bass: 16, keys: 64, lead: 64, drums: 16 } } as never;
const rms = (x: Float32Array, a: number, b: number) => { let s = 0; for (let i = a; i < b; i++) s += x[i] * x[i]; return Math.sqrt(s / (b - a)); };

describe("previews", () => {
  it("are exactly 4 bars, so they loop without a seam", () => {
    const n = Math.round(64 * (15 / 120) * SR);
    expect(sloopLoop(sec, new Set(["bass", "lead", "drums"])).length).toBe(n);
    expect(originalLoop(new Float32Array(10 * SR).fill(0.1), sec).length).toBe(n);
  });
  it("play each part at its track's length and leave out the parts not imported", () => {
    const bar = Math.round(16 * (15 / 120) * SR);
    const drums = sloopLoop(sec, new Set(["drums"]));
    // a 1-bar drum part: every bar the same
    for (let b = 1; b < 4; b++) expect(rms(drums, b * bar, b * bar + bar)).toBeCloseTo(rms(drums, 0, bar), 2);
    // the lead (4 bars long) plays once, in the first bar; without it, the first bar's second half is the drums' alone
    const withLead = sloopLoop(sec, new Set(["drums", "lead"])), without = sloopLoop(sec, new Set(["drums"]));
    const half = (x: Float32Array, b: number) => rms(x, b * bar + bar / 2, b * bar + bar * 0.75);
    expect(half(withLead, 0)).toBeGreaterThan(half(without, 0) * 1.2);
    expect(rms(sloopLoop(sec, new Set()), 0, 4 * bar)).toBe(0);
  });
});
