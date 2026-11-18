// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The loops of a made-up song with known parts: a verse (a 1-bar drum beat, a 2-bar bassline) 8 times as 4-bar
// phrases' worth, a chorus (another beat and bassline), the verse again.
import { describe, expect, it } from "vitest";
import { SR } from "./dsp";
import { SongAudio } from "./analysis";
import { findLoops } from "./loops";

function song(bpm = 100) {
  const step = 60 / bpm / 4, lead = 0.5;
  const plan = [...Array(16).fill("verse"), ...Array(8).fill("chorus"), ...Array(12).fill("verse")] as ("verse" | "chorus")[];
  const n = Math.round((plan.length * 16 * step + lead + 1) * SR), y = new Float32Array(n);
  let seed = 1; const noise = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32) * 2 - 1;
  const add = (t: number, len: number, f: (x: number) => number) => { const i0 = Math.round(t * SR); for (let k = 0; k < len * SR && i0 + k < n; k++) y[i0 + k] += f(k / SR); };
  plan.forEach((part, bar) => {
    const t0 = lead + bar * 16 * step, at = (s: number) => t0 + s * step;
    const kicks = part === "verse" ? [0, 7, 10] : [0, 4, 8, 12];   // (a syncopated verse kick: 1 is clear)
    for (const s of kicks) { let ph = 0; add(at(s), 0.3, (x) => { ph += (2 * Math.PI * (50 + 100 * Math.exp(-x * 30))) / SR; return Math.sin(ph) * Math.exp(-x * 10); }); }
    for (const s of [4, 12]) add(at(s), 0.2, (x) => 0.5 * noise() * Math.exp(-x * 20));
    for (let s = 0; s < 16; s += 2) add(at(s), 0.05, (x) => 0.2 * noise() * Math.exp(-x * 70));
    const bass = part === "verse" ? (bar % 2 ? [40, 43] : [36, 38]) : [45, 45];
    bass.forEach((p, i) => { const f = 440 * 2 ** ((p - 69) / 12); add(at(i * 8), 7 * step, (x) => 0.3 * (Math.sin(2 * Math.PI * f * x) + 0.4 * Math.sin(4 * Math.PI * f * x)) * Math.exp(-x * 1.5)); });
    const chord = part === "verse" ? [60, 64, 67] : [62, 65, 69];
    for (const p of chord) { const f = 440 * 2 ** ((p - 69) / 12); add(at(0), 16 * step, (x) => 0.06 * Math.sin(2 * Math.PI * f * x)); }
  });
  const peak = y.reduce((m, v) => Math.max(m, Math.abs(v)), 0);
  for (let i = 0; i < n; i++) y[i] /= peak * 1.05;
  return { y, step, lead, plan };
}

describe("loops", () => {
  it("finds the verse and the chorus, their pattern lengths, and their drums from all repeats", async () => {
    const { y, step, lead } = song();
    const loops = await findLoops(new SongAudio(y), [], 4);
    expect(loops.length).toBeGreaterThanOrEqual(2);
    const verse = loops.reduce((a, b) => ((b.repeats ?? 0) > (a.repeats ?? 0) ? b : a));
    expect(verse.repeats).toBeGreaterThanOrEqual(5);                         // 28 verse bars: 7 phrases (some cut)
    expect(verse.lengths?.drums).toBe(16);                                    // a 1-bar beat
    expect(verse.lengths?.bass).toBe(32);                                     // a 2-bar bassline
    // it starts on a bar line of the song
    const bar = (verse.start - lead) / (16 * step);
    expect(Math.abs(bar - Math.round(bar))).toBeLessThan(0.05);
    // kicks on 1 and syncopated (steps 0, 7, 10), snares on 2 and 4, in every bar
    const at = new Map(verse.drums);
    for (const b of [0, 16, 32, 48]) {
      for (const s of [0, 7, 10]) expect(at.get(b + s)).toContain(0);
      for (const s of [4, 12]) expect(at.get(b + s)).toContain(2);
    }
  }, 120_000);

  it("finds none in audio too short to repeat", async () => {
    const { y } = song();
    expect(await findLoops(new SongAudio(y.subarray(0, 6 * SR)), [], 4)).toEqual([]);
  }, 60_000);
});
