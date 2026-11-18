// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Previews of a piece for the import's review, as loops: the original audio of its 4 bars, and what SLOOP will play
// from it (the notes and drums found, each part looping at its own track length, in plain sounds: SLOOP plays them
// with the tracks' own sounds). Mono; the same 4 bars each, so they loop without a seam. The iOS app has the same
// renderer in Swift (SLOOPPreview).
import { SR } from "./dsp";
import { Section } from "./analysis";

export type PreviewPart = "bass" | "keys" | "lead" | "drums";

/** The original audio of a piece's 4 bars. */
export function originalLoop(y: Float32Array, sec: Section): Float32Array {
  const a = Math.round(sec.start * SR), n = Math.round(64 * (15 / sec.bpm) * SR);
  const out = new Float32Array(n);
  out.set(y.subarray(a, Math.min(y.length, a + n)));
  return normalise(out);
}

/** What SLOOP will play from a piece: the `parts` imported, each repeating every `lengths[part]` steps. A note still
 *  sounding at the end wraps round to the start (as it would, looping). */
export function sloopLoop(sec: Section, parts: Set<PreviewPart>): Float32Array {
  const q = 15 / sec.bpm, n = Math.round(64 * q * SR), out = new Float32Array(n);
  const len = (p: PreviewPart) => Math.max(1, Math.min(64, sec.lengths?.[p] ?? 64));
  const add = (st: number, x: Float32Array) => { const i0 = Math.round(st * q * SR); for (let k = 0; k < x.length; k++) out[(i0 + k) % n] += x[k]; };
  const every = (p: PreviewPart, st: number, f: (st: number) => void) => { if (st < len(p)) for (let s = st; s < 64; s += len(p)) f(s); };
  let seed = 7; const noise = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32) * 2 - 1;
  if (parts.has("drums")) for (const [st, lanes] of sec.drums) every("drums", st, (s) => { for (const l of lanes) add(s, drum(l, noise)); });
  if (parts.has("bass")) for (const [st, ln, p] of sec.bass) every("bass", st, (s) => add(s, tone(p, ln * q, 5, 1.2, 0.55)));
  if (parts.has("keys")) for (const [st, ln, ps] of sec.keys) every("keys", st, (s) => { for (const p of ps) add(s, tone(p, ln * q, 3, 0.8, 0.14)); });
  if (parts.has("lead")) for (const [st, ln, p] of sec.lead) every("lead", st, (s) => add(s, tone(p, ln * q, 7, 1.5, 0.3, true)));
  return normalise(out);
}

/** Both: the original under what SLOOP will play. */
export function bothLoop(orig: Float32Array, sloop: Float32Array): Float32Array {
  const out = new Float32Array(orig.length);
  for (let i = 0; i < out.length; i++) out[i] = 0.55 * orig[i] + 0.55 * (sloop[i] ?? 0);
  return normalise(out);
}

/** A note: `harmonics` partials (odd only: `hollow`, a reedier lead), a 5 ms attack, a decay, a 10 ms release. */
function tone(pitch: number, secs: number, harmonics: number, decay: number, gain: number, hollow = false): Float32Array {
  const f = 440 * 2 ** ((pitch - 69) / 12), n = Math.max(1, Math.round(secs * 0.95 * SR)), x = new Float32Array(n), r = Math.min(n, Math.round(0.01 * SR));
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    let v = 0;
    for (let h = 1; h <= harmonics; h += hollow ? 2 : 1) if (f * h < SR / 2) v += Math.sin(2 * Math.PI * f * h * t) / h;
    x[i] = gain * v * Math.min(1, t / 0.005) * Math.exp(-t * decay) * (i >= n - r ? (n - i) / r : 1);
  }
  return x;
}

/** SLOOP's drum lanes as plain sounds: 0 kick, 2 snare, 4 closed hat, 5 open hat (others: a click). */
function drum(lane: number, noise: () => number): Float32Array {
  const len = { 0: 0.3, 2: 0.2, 4: 0.05, 5: 0.3 }[lane] ?? 0.03, n = Math.round(len * SR), x = new Float32Array(n);
  let ph = 0, prev = 0;
  for (let i = 0; i < n; i++) {
    const t = i / SR, w = noise();
    if (lane === 0) { ph += (2 * Math.PI * (50 + 100 * Math.exp(-t * 30))) / SR; x[i] = Math.sin(ph) * Math.exp(-t * 10); }
    else if (lane === 2) x[i] = (0.5 * w * Math.exp(-t * 20) + 0.4 * Math.sin(2 * Math.PI * 190 * t) * Math.exp(-t * 25)) * 0.8;
    else { x[i] = 0.3 * (w - prev) * Math.exp(-t * (lane === 5 ? 8 : 70)); prev = w; }        // (a difference: bright noise)
  }
  return x;
}

function normalise(x: Float32Array): Float32Array {
  let m = 0;
  for (const v of x) m = Math.max(m, Math.abs(v));
  if (m > 0) for (let i = 0; i < x.length; i++) x[i] *= 0.85 / m;
  return x;
}
