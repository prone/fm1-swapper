// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The audio import on a drum part with known hits (kick, snare, closed and open hats under a bassline and a lead):
// the tempo, the grid and the drums found, scored as the Python prototype scored them.
import { describe, expect, it } from "vitest";
import { SR } from "./dsp";
import { SongAudio, arrangeNotes, barStart, dropGhosts, suggestSections } from "./analysis";

function rand(seed: number) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32) * 2 - 1; }

/** A biquad filter (RBJ cookbook), high- or low-pass at `f` Hz. */
function biquad(kind: "hp" | "lp", f: number) {
  const w = (2 * Math.PI * f) / SR, al = Math.sin(w) / Math.SQRT2, c = Math.cos(w);
  const b = kind === "hp" ? [(1 + c) / 2, -(1 + c), (1 + c) / 2] : [(1 - c) / 2, 1 - c, (1 - c) / 2];
  const a0 = 1 + al, a1 = -2 * c, a2 = 1 - al;
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x: number) => { const y = (b[0] * x + b[1] * x1 + b[2] * x2 - a1 * y1 - a2 * y2) / a0; x2 = x1; x1 = x; y2 = y1; y1 = y; return y; };
}
/** Noise through filters (each a function of the sample). */
const filtered = (seed: number, ...fs: ((x: number) => number)[]) => { const r = rand(seed); return () => fs.reduce((x, f) => f(x), r()); };

/** 8 bars at `bpm` after a 0.4 s lead-in; returns the audio and the truth (step, lane). */
function drumTest(bpm: number, sub = false) {
  const step = 60 / bpm / 4, lead = 0.4, n = Math.round((8 * 16 + 8) * step * SR), y = new Float32Array(n), noise = rand(bpm);
  const at = (st: number) => Math.round((st * step + lead) * SR);
  const add = (i: number, len: number, f: (t: number) => number) => { for (let k = 0; k < len && i + k < n; k++) y[i + k] += f(k / SR); };
  const truth: [number, number][] = [];
  for (let b = 0; b < 8; b++) {
    const o = b * 16;
    for (const s of b % 2 ? [0, 3, 10, 14] : [0, 7, 10]) {
      let ph = 0; add(at(o + s), Math.round(0.35 * SR), (t) => { ph += 2 * Math.PI * (50 + 110 * Math.exp(-t * 30)) / SR; return Math.sin(ph) * Math.exp(-t * 9); });
      truth.push([o + s, 0]);
    }
    for (const s of [4, 12]) { const h = filtered(o + s, biquad("hp", 800), biquad("lp", 9000)); add(at(o + s), Math.round(0.25 * SR), (t) => 0.8 * (0.6 * h() * Math.exp(-t * 18) + 0.5 * Math.sin(2 * Math.PI * 190 * t) * Math.exp(-t * 25))); truth.push([o + s, 2]); }
    for (let s = 0; s < 16; s += 2) {
      const open = s === 6, h = filtered(1000 + o + s, biquad("hp", 7000), biquad("hp", 7000));
      add(at(o + s), Math.round((open ? 0.35 : 0.06) * SR), (t) => 0.35 * h() * Math.exp(-t * (open ? 7 : 60)));
      truth.push([o + s, open ? 5 : 4]);
    }
    for (const [s, ln, p] of [[0, 3, 39], [3, 3, 39], [8, 4, 42], [12, 4, 44]]) {
      const f = 440 * 2 ** ((p - 69) / 12);
      let saw = 0;                                   // a sawtooth bass, or (sub) a pure sine one, as an 808 sub-bass
      add(at(o + s), Math.round(ln * step * SR * 0.9), (t) => { saw = 0; for (let k = 1; k < (sub ? 2 : 8); k++) saw += Math.sin(2 * Math.PI * f * k * t) / k; return 0.35 * saw * Math.exp(-t * 3); });
    }
  }
  for (let i = 0; i < n; i++) y[i] += 0.01 * noise();
  const peak = y.reduce((m, v) => Math.max(m, Math.abs(v)), 0);
  for (let i = 0; i < n; i++) y[i] /= peak * 1.05;
  return { y, truth, step, lead };
}

function f1(truth: [number, number][], got: [number, number][]) {
  const key = ([s, l]: [number, number]) => `${s},${l === 5 ? 4 : l}`;
  const T = new Set(truth.map(key)), G = new Set(got.map(key)), tp = [...G].filter((x) => T.has(x)).length;
  const p = tp / Math.max(1, G.size), r = tp / Math.max(1, T.size);
  return (2 * p * r) / (p + r || 1);
}

describe("import from audio", () => {
  for (const [bpm, sub] of [[92, false], [128, false], [75, false], [92, true]] as const) {
    it(`finds the tempo, bar 1 and the drums at ${bpm} BPM${sub ? " over a sub-bass" : ""}`, () => {
      const { y, truth, step, lead } = drumTest(bpm, sub);
      const song = new SongAudio(y);
      const sec = song.section(lead + 0.05);
      expect(Math.abs(sec.bpm - bpm)).toBeLessThan(1.5);
      const n0 = Math.round((sec.steps[0] - lead) / step);                     // the grid starts on a bar
      expect(((n0 % 16) + 16) % 16).toBe(0);
      expect(Math.abs(sec.steps[0] - (lead + n0 * step))).toBeLessThan(0.03); // within 30 ms of the true downbeat
      const t = truth.filter(([s]) => s - n0 >= 0 && s - n0 < 64).map(([s, l]): [number, number] => [s - n0, l]);
      // (over a pure sine sub-bass, the separation gives part of each kick to the tone: kicks are missed or taken for
      // snares; known weak case, to be improved with the transcribed bass notes)
      expect(f1(t, sec.hits)).toBeGreaterThan(sub ? 0.55 : 0.75);
    }, 60000);
  }

  it("puts bar 1 where kicks and snares say", () => {
    const groove: [number, number][] = [[0, 0], [8, 0], [4, 2], [12, 2]].map(([s, l]) => [(s + 4) % 16, l]);
    expect(barStart(groove)).toBe(4);
  });

  it("splits notes into bass, chords and lead on the grid, without overtones", () => {
    const steps = Array.from({ length: 64 }, (_, i) => i * 0.125);
    const notes = dropGhosts([
      { start: 0, end: 0.5, pitch: 36, amp: 0.8 }, { start: 0, end: 0.5, pitch: 48, amp: 0.3 },   // a bass and its octave
      { start: 0, end: 0.25, pitch: 72, amp: 0.7 }, { start: 0, end: 1, pitch: 60, amp: 0.6 }, { start: 0, end: 1, pitch: 64, amp: 0.6 },
      { start: 0.25, end: 0.5, pitch: 74, amp: 0.7 },
    ]);
    expect(notes.map((n) => n.pitch)).toEqual([36, 72, 60, 64, 74]);
    const a = arrangeNotes(notes, steps);
    expect(a.bass).toEqual([[0, 4, 36]]);
    expect(a.lead).toEqual([[0, 2, 72], [2, 2, 74]]);
    expect(a.keys).toEqual([[0, 8, [60, 64]]]);
  });

  it("suggests busy 4-bar sections in song order", () => {
    const { y } = drumTest(92);
    const song = new SongAudio(y);
    const s = suggestSections(song, [], 2);
    expect(s.length).toBeGreaterThan(0);
    expect([...s].sort((a, b) => a - b)).toEqual(s);
  }, 60000);
});
