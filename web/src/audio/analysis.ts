// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Audio -> SLOOP sections (the TypeScript version of the Python prototype, kept to the same steps and numbers):
// the song's beats, a 16th grid per 4-bar section lined up with the drum attacks, the drums on that grid, the bar's
// first beat, and the notes (from Basic Pitch) split into a bassline, chords and a lead.
import { SR, Spec, band, beatTrack, hpss, linefit, onsetStrength, stft } from "./dsp";

/** A note from the transcription: seconds, MIDI pitch, how loud (0..1). */
export interface AudioNote { start: number; end: number; pitch: number; amp: number }
/** One SLOOP section's worth: 64 16ths. Steps 0..63; drum lanes as SLOOP's (0 kick, 2 snare, 4 hat, 5 open hat). */
export interface Section {
  start: number; bpm: number;
  /** A loop of the song (loops.ts): how often it plays, each part's own length in steps (16, 32 or 64), and whether
   *  it's a weak find (few repeats, loosely alike, or it crosses a change). */
  repeats?: number; lengths?: { bass: number; keys: number; lead: number; drums: number }; unsure?: boolean;
  bass: [number, number, number][];        // [step, length, pitch]
  keys: [number, number, number[]][];      // [step, length, pitches (up to 4)]
  lead: [number, number, number][];
  drums: [number, number[]][];             // [step, lanes]
}

const HOP = 128;                           // the drum analysis (5.8 ms)
const fr = (t: number) => Math.round((t * SR) / HOP);

/** The song: its beats (whole song) and a way to analyse any 4-bar section of it. */
export class SongAudio {
  readonly beats: number[];
  readonly bpm: number;
  constructor(readonly y: Float32Array) {
    // the beat tracker works on the whole mix (coarse frames, cheap); the tempo is then checked against half and
    // double, which a song with hats on 8ths fits alike, weighing how common each tempo is (most music: 80-160)
    const s = stft(y, 2048, 512);
    const env = onsetStrength(s);
    const t = beatTrack(env, 512).beats;
    const at = (ts: number[]) => ts.map((x) => env[Math.min(env.length - 1, Math.max(0, Math.round((x * SR) / 512)))]);
    const contrast = (b: number[]) => {
      if (b.length < 8) return -1;
      const on: number[] = [], off: number[] = [];
      for (let i = 0; i + 1 < b.length; i++) for (let k = 0; k < 4; k++) {
        const q = (b[i + 1] - b[i]) / 4;
        on.push(b[i] + k * q); off.push(b[i] + k * q + q / 2);
      }
      const m = (a: number[]) => a.reduce((x, v) => x + v, 0) / a.length;
      const bpm = 60 / median(diff(b));
      if (bpm < 55 || bpm > 200) return -1;
      return (m(at(on)) / (m(at(off)) + 1e-9)) * Math.exp(-0.5 * (Math.log2(bpm / 110) / 0.8) ** 2);
    };
    const half = t.filter((_, i) => i % 2 === 0);
    const double = t.flatMap((x, i) => (i + 1 < t.length ? [x, (x + t[i + 1]) / 2] : [x]));
    const cands = [t, half, double];
    this.beats = cands.reduce((a, b) => (contrast(b) > contrast(a) ? b : a), t);
    this.bpm = this.beats.length > 1 ? 60 / median(diff(this.beats)) : 120;
  }

  get duration() { return this.y.length / SR; }

  /** Drum hits and the grid of the 4 bars from about `start` (seconds), bar 1 on the downbeat. The audio around it
   *  is separated once (the slow part) and used for the grid, the drums and, if bar 1 is later, both again. */
  section(start: number): { steps: number[]; bpm: number; hits: [number, number][] } {
    const w = new SectionAudio(this.y, start - 0.6, start + 64 * (15 / this.bpm) + 3.5);
    let g = this.grid(start, w), hits = w.drums(g.steps);
    const o = barStart(hits);
    if (o) { g = this.grid(g.steps[o], w); hits = w.drums(g.steps); }
    return { ...g, hits };
  }

  /** 64 16ths from the beat nearest `start`: the beats around it fitted to a straight line (a steady tempo for these 4
   *  bars; it may start before the first tracked beat), then slid +-60 ms to where the percussive attacks fall. */
  grid(start: number, w?: SectionAudio): { steps: number[]; bpm: number } {
    const b = this.beats;
    if (b.length < 4) {                                                  // (too short to track: 120 BPM from `start`)
      const q = 60 / 120 / 4;
      return { steps: Array.from({ length: 64 }, (_, i) => start + i * q), bpm: 120 };
    }
    let i0 = 0;
    b.forEach((t, i) => { if (Math.abs(t - start) < Math.abs(b[i0] - start)) i0 = i; });
    const near = b.map((t, i) => [i, t]).filter(([i]) => i >= i0 - 4 && i <= i0 + 20);
    const [k, c] = linefit(near.map(([i]) => i), near.map(([, t]) => t));
    const first = Math.round((start - c) / k);
    const steps = Array.from({ length: 64 }, (_, n) => c + k * (first + n / 4));
    const audio = w ?? new SectionAudio(this.y, steps[0] - 0.6, steps[63] + 1);
    let best = 0, bestScore = -Infinity;
    for (let d = -0.06; d <= 0.0605; d += 0.001) {
      const s = audio.attackScore(steps.map((t) => t + d));
      if (s > bestScore) { bestScore = s; best = d; }
    }
    return { steps: steps.map((t) => t + best), bpm: 60 / k };
  }
}

/** The audio from `from` to `to` seconds (around one section), separated into drums and tone. */
export class SectionAudio {
  readonly t0: number;
  readonly perc: Spec;
  readonly bands: { low: Float32Array; mid: Float32Array; high: Float32Array };
  readonly lowTone: Float32Array;
  readonly env: Float32Array;
  constructor(y: Float32Array, from: number, to: number) {
    this.t0 = Math.max(0, from);
    const seg = y.subarray(Math.round(this.t0 * SR), Math.min(y.length, Math.round(to * SR)));
    const { harm, perc } = hpss(stft(seg, 2048, 512), stft(seg, 1024, HOP));
    this.perc = perc;
    this.bands = { low: band(perc, 30, 120), mid: band(perc, 180, 3500), high: band(perc, 6000, 11000) };
    this.lowTone = band(harm, 30, 120);
    this.env = onsetStrength(perc);
  }
  x(t: number) { return fr(t - this.t0); }

  /** How well a grid lines up with the attacks (the onset strength at its steps). */
  attackScore(ts: number[]) {
    let s = 0;
    for (const t of ts) { const i = this.x(t); if (i >= 0 && i < this.env.length) s += this.env[i]; }
    return s;
  }

  /** Per step: how much each band rises (best attack within -45..+35 ms, against the 45 ms before), how much of the
   *  lows is tone (a bass note) rather than a thump, and how long the highs ring. */
  rises(steps: number[]) {
    const w0 = fr(0.045), w1 = fr(0.035), pre = fr(0.045), n = steps.length;
    const R = { low: new Float64Array(n), mid: new Float64Array(n), high: new Float64Array(n) };
    const tone = new Float64Array(n), ring = new Float64Array(n);
    steps.forEach((t, s) => {
      const x = this.x(t);
      for (const k of ["low", "mid", "high"] as const) {
        const e = this.bands[k];
        if (x - w0 - pre < 1 || x + w1 + fr(0.4) >= e.length) continue;
        let j = x - w0;
        for (let i = x - w0; i < x + w1; i++) if (e[i] - e[i - 1] > e[j] - e[j - 1]) j = i;
        let peak = 0, before = 0;
        for (let i = j; i <= j + fr(0.02); i++) peak = Math.max(peak, e[i]);
        for (let i = j - pre; i < j - 1; i++) before += e[i];
        R[k][s] = 10 * Math.log10(peak / (before / (pre - 1) + 1e-9) + 1e-12);
      }
      let lt = 0, lp = 0;
      for (let i = x; i < x + fr(0.1) && i < this.lowTone.length; i++) { lt += this.lowTone[i]; lp += this.bands.low[i]; }
      tone[s] = lt / (lp + 1e-9);
      const e = this.bands.high;
      let peak = 1e-9; for (let i = x; i < x + w1 && i < e.length; i++) peak = Math.max(peak, e[i]);
      let r = x + w1;
      while (r < e.length && e[r] > 0.25 * peak && r - x < fr(0.4)) r++;
      ring[s] = ((r - x) * HOP) / SR;
    });
    return { R, tone, ring };
  }

  /** Hits on the grid: kick (the lows rise most, and aren't a bass tone), snare (the mids rise well above the lows),
   *  hat (the highs; on a snare only when well above the mids; open when it rings past 150 ms). A hit counts when
   *  strong, or when moderate at a position of the bar the section's other bars also hit (drum parts repeat). */
  drums(steps: number[]): [number, number][] { return drumHits(this.rises(steps)); }
}

/** Rises (SectionAudio.rises) as hits: see SectionAudio.drums. */
export function drumHits({ R, tone, ring }: Rises): [number, number][] {
  {
    const n = tone.length;
    const cand: Record<number, Float64Array> = {
      0: R.low.map((v, s) => (v >= R.mid[s] - 2 && tone[s] < 12 ? v : 0)),
      2: R.mid.map((v, s) => (v - R.low[s] >= 2.5 ? v : 0)),
      4: R.high,
    };
    const limits: Record<number, [number, number]> = { 0: [9, 6], 2: [11, 7.5], 4: [9, 6] };
    const out = new Set<string>();
    for (const lane of [0, 2, 4]) {
      const v = cand[lane], [strong, weak] = limits[lane];
      const cut = Math.max(weak, quantile(Array.from(v), 0.65));        // never more than the loudest 35%
      const groove = Array.from({ length: 16 }, (_, p) => { let s = 0, c = 0; for (let i = p; i < n; i += 16) { s += v[i]; c++; } return s / c; });
      for (let s = 0; s < n; s++) {
        if (lane === 4 && out.has(`${s},2`) && R.high[s] - R.mid[s] < 3.5) continue;
        if (v[s] >= strong || (v[s] >= cut && groove[s % 16] >= cut)) out.add(`${s},${lane === 4 && ring[s] > 0.15 ? 5 : lane}`);
      }
    }
    return [...out].map((k) => k.split(",").map(Number) as [number, number]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  }
}
export type Rises = ReturnType<SectionAudio["rises"]>;

/** Which beat of the first bar is the downbeat (step 0, 4, 8 or 12): kicks on 1 (and 3), snares on 2 and 4. */
export function barStart(hits: [number, number][]): number {
  const fit = (o: number) => hits.reduce((s, [n, l]) => {
    const p = (((n - o) % 16) + 16) % 16;
    if (l === 0) return s + (p === 0 ? 2 : p === 8 ? 1 : 0);
    if (l === 2) return s + (p === 4 || p === 12 ? 2 : p === 0 || p === 8 ? -1 : 0);
    return s;
  }, 0);
  return [0, 4, 8, 12].reduce((a, b) => (fit(b) > fit(a) ? b : a), 0);
}

/** An overtone the transcription heard as a note: an octave (or octave + fifth, two octaves) above a note sounding
 *  then, and much quieter than it. */
export function dropGhosts(notes: AudioNote[]): AudioNote[] {
  return notes.filter((n) => !notes.some((m) => m !== n && m.start <= n.start && n.start < m.end && [12, 19, 24].includes(n.pitch - m.pitch) && n.amp < 0.6 * m.amp));
}

/** The notes of a section on its grid: a bassline (lowest note per step, below C3), a lead (highest per step, C4 and
 *  up), each playing one note at a time, and chords from the notes between (up to 4 a step, not the lead's). */
export function arrangeNotes(notes: AudioNote[], steps: number[]): Pick<Section, "bass" | "keys" | "lead"> {
  const q = (steps[steps.length - 1] - steps[0]) / (steps.length - 1);
  const by = new Map<number, { p: number; ln: number }[]>();
  for (const n of notes) {
    const st = Math.round((n.start - steps[0]) / q);
    if (st < 0 || st >= 64) continue;
    const ln = Math.max(1, Math.min(64 - st, Math.round((n.end - n.start) / q)));
    by.set(st, [...(by.get(st) ?? []), { p: n.pitch, ln }]);
  }
  const bass: [number, number, number][] = [], lead: [number, number, number][] = [], keys: [number, number, number[]][] = [];
  for (const st of [...by.keys()].sort((a, b) => a - b)) {
    const ns = by.get(st)!;
    const low = ns.filter((n) => n.p < 48).sort((a, b) => a.p - b.p)[0];
    const top = ns.filter((n) => n.p >= 60).sort((a, b) => b.p - a.p)[0];
    if (low) bass.push([st, low.ln, low.p]);
    if (top) lead.push([st, top.ln, top.p]);
    const mid = [...new Set(ns.filter((n) => n.p >= 48 && n.p < 72 && n.p !== top?.p).map((n) => n.p))].sort((a, b) => a - b).slice(0, 4);
    if (mid.length) keys.push([st, Math.max(...ns.filter((n) => mid.includes(n.p)).map((n) => n.ln)), mid]);
  }
  const mono = (line: [number, number, number][]) =>
    line.map(([st, ln, p], i): [number, number, number] => [st, Math.max(1, Math.min(ln, i + 1 < line.length ? line[i + 1][0] - st : ln)), p]);
  return { bass: mono(bass), keys, lead: mono(lead) };
}

/** Up to `count` 4-bar windows worth importing: where the drums and the notes are busiest, at least 4 bars apart,
 *  in song order (start times, each on a beat). */
export function suggestSections(song: SongAudio, notes: AudioNote[], count = 4): number[] {
  const b = song.beats;
  if (b.length < 16) return [b[0] ?? 0];
  const env = onsetStrength(stft(song.y, 2048, 512));
  const act = (t0: number, t1: number) => { let s = 0; for (let i = Math.round((t0 * SR) / 512); i < Math.min(env.length, Math.round((t1 * SR) / 512)); i++) s += env[i]; return s; };
  const wins: { t: number; score: number }[] = [];
  for (let i = 0; i + 16 < b.length; i += 4) {
    const t0 = b[i], t1 = b[i + 16];
    const n = notes.filter((x) => x.start >= t0 && x.start < t1).length;
    wins.push({ t: t0, score: act(t0, t1) / (t1 - t0) + 0.15 * n });
  }
  const top = Math.max(...wins.map((w) => w.score)) || 1;
  const picked: number[] = [];
  for (const w of [...wins].sort((a, b) => b.score - a.score)) {
    if (picked.length >= count || w.score < 0.3 * top) break;
    if (picked.every((t) => Math.abs(t - w.t) >= 16 * (60 / song.bpm) - 0.01)) picked.push(w.t);
  }
  return picked.sort((a, b) => a - b);
}

export function analyseSection(song: SongAudio, notes: AudioNote[], start: number): Section {
  const { steps, bpm, hits } = song.section(start);
  const drums = new Map<number, number[]>();
  for (const [n, l] of hits) drums.set(n, [...(drums.get(n) ?? []), l]);
  return { start: steps[0], bpm, ...arrangeNotes(notes, steps), drums: [...drums.entries()].sort((a, b) => a[0] - b[0]) };
}

const diff = (a: number[]) => a.slice(1).map((v, i) => v - a[i]);
function median(a: number[]) { const s = [...a].sort((x, y) => x - y); return s[s.length >> 1] ?? 0; }
function quantile(a: number[], q: number) { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(q * (s.length - 1)))] ?? 0; }
