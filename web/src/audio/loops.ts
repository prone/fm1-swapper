// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The song's loops (the TypeScript version of the Python prototype, checked by ear on six songs): every bar described
// by its drums (each 16th's attack per band), bass and chords (pitch classes per beat), the bars compared with each
// other; each part's pattern length (1, 2 or 4 bars); the 4-bar phrases; the phrases grouped into the song's distinct
// loops; each loop's start (its own, off the points where a new sound comes in) and the repeat to take it from; and
// its drums and notes from all its repeats (a hit or a note most repeats have is real; one that turns up once isn't).
import { SR, fft } from "./dsp";
import { AudioNote, Rises, Section, SectionAudio, SongAudio, arrangeNotes, barStart, drumHits } from "./analysis";

type Part = "bass" | "keys" | "lead" | "drums";
/** (for checks: the last song's per-bar features) */
export const debug: { last?: { F: Record<string, number[][]>; steps: number[]; nb: number } } = {};
const CHUNK = 30;                                      // seconds of audio analysed at a time (memory: an iPad's web view)

/** Up to `max` loops of the song, in song order, as sections (start: the repeat used; repeats, lengths, unsure set).
 *  None when the audio is too short to repeat (under 8 bars). */
export async function findLoops(song: SongAudio, notes: AudioNote[], max = 4, progress: (f: number) => Promise<void> | void = () => {}): Promise<Section[]> {
  const b = song.beats;
  if (b.length < 40) return [];
  // the song's 16ths: each beat in four
  let steps: number[] = [];
  for (let i = 0; i + 1 < b.length; i++) for (let k = 0; k < 4; k++) steps.push(b[i] + (k * (b[i + 1] - b[i])) / 4);
  // each 16th's attacks (the drum analysis, a chunk of audio at a time), then bar 1 from the kicks and snares
  const n = steps.length, R = { low: new Float64Array(n), mid: new Float64Array(n), high: new Float64Array(n) };
  const tone = new Float64Array(n), ring = new Float64Array(n);
  for (let t0 = 0, i = 0; t0 < song.duration && i < n; t0 += CHUNK) {
    const idx: number[] = [];
    while (i < n && steps[i] < t0 + CHUNK) idx.push(i++);
    if (!idx.length) continue;
    // (the grid slid, +-60 ms, to where this chunk's attacks fall: the beat tracker runs a little early or late)
    const w = new SectionAudio(song.y, t0 - 0.6, t0 + CHUNK + 1);
    let shift = 0, best = -Infinity;
    for (let d = -0.06; d <= 0.0605; d += 0.002) { const sc = w.attackScore(idx.map((j) => steps[j] + d)); if (sc > best) { best = sc; shift = d; } }
    for (const j of idx) steps[j] += shift;
    const r = w.rises(idx.map((j) => steps[j]));
    idx.forEach((j, k) => { R.low[j] = r.R.low[k]; R.mid[j] = r.R.mid[k]; R.high[j] = r.R.high[k]; tone[j] = r.tone[k]; ring[j] = r.ring[k]; });
    await progress((0.7 * t0) / song.duration);
  }
  const o = barStart(drumHits({ R, tone, ring }));
  steps = steps.slice(o);
  const rises: Rises = { R: { low: R.low.slice(o), mid: R.mid.slice(o), high: R.high.slice(o) }, tone: tone.slice(o), ring: ring.slice(o) };
  const nb = Math.floor(steps.length / 16);
  if (nb < 8) return [];
  const tonal = await tonalFeatures(song.y, steps, nb, (f) => progress(0.7 + 0.25 * f));

  // per bar: drums (48: 16 steps x 3 bands), bass and chords (48: 4 beats x 12), each a unit vector; loudness
  const F = {
    drums: unit(Array.from({ length: nb }, (_, i) => [...rises.R.low.slice(i * 16, i * 16 + 16), ...rises.R.mid.slice(i * 16, i * 16 + 16), ...rises.R.high.slice(i * 16, i * 16 + 16)].map((v) => Math.max(0, v)))),
    bass: tonal.bass, chords: tonal.chords,
  };
  const loud = tonal.loud, live = loud.map((l) => l > 0.15);
  debug.last = { F, steps, nb };
  const per = { drums: period(F.drums, live), bass: period(F.bass, live), chords: period(F.chords, live) };
  const all = F.drums.map((d, i) => [...d, ...F.bass[i], ...F.chords[i]].map((v) => v / Math.sqrt(3)));
  const S = (a: number, c: number) => dot(all[a], all[c]);

  // 4-bar phrases from the bar phase whose bar lines are the most novel; grouped (each joins the first group it matches)
  const nov = all.map((_, i) => (i ? 1 - S(i - 1, i) : 0));
  const top = Math.max(1, Math.floor(nb / 16));
  const phase = [0, 1, 2, 3].reduce((best, p) => (meanTop(nov.filter((_, i) => i % 4 === p), top) > meanTop(nov.filter((_, i) => i % 4 === best), top) ? p : best), 0);
  const starts: number[] = [];
  for (let s = phase; s + 4 <= nb; s += 4) starts.push(s);
  const win = (s: number) => [0, 1, 2, 3].flatMap((q) => all[s + q]).map((v) => v / 2);
  const W = starts.map(win), groups: number[][] = [];
  W.forEach((w, i) => {
    const g = groups.find((m) => dot(w, W[m[0]]) >= 0.85);
    if (g) g.push(i); else groups.push([i]);
  });

  // where the song changes: bar lines where everything before differs from after, and new sounds coming in
  const changes = new Set(boundaries(all, nb)), inside = new Set<number>();
  for (const e of tonal.entries) (e % 4 === 0 ? changes : inside).add(Math.floor(e / 4));
  const crosses = (s: number) => [...changes].some((c) => s < c && c < s + 4) || [...inside].some((c) => s <= c && c < s + 4);
  const seam = (o: number[]) => { const v = [...o.filter((s) => s + 4 < nb).map((s) => S(s + 4, s)), ...o.filter((s) => s >= 1).map((s) => S(s - 1, s + 3))]; return v.length ? mean(v) : 0; };
  const fullVolume = (o: number[]) => { const l = o.map((s) => mean(loud.slice(s, s + 4))), m = Math.max(...l); return o.filter((_, i) => l[i] >= 0.85 * m); };

  const found = groups.filter((g) => g.length >= 2).map((g) => {
    let bars = g.map((i) => starts[i]);
    // its own start: off a change (when no full-volume repeat is clear of one), or half a phrase on for a better join
    const ok = new Map<number, number[]>();
    for (const sh of [0, -2, 2, -1, 1, -3, 3]) if (bars.every((s) => s + sh >= 0 && s + sh + 4 <= nb)) ok.set(sh, bars.map((s) => s + sh));
    const clean = (o: number[]) => fullVolume(o).some((s) => !crosses(s));
    const least = Math.min(...[...ok.values()].map((o) => (clean(o) ? 0 : 1)));
    const cands = [...ok.keys()].filter((sh) => (clean(ok.get(sh)!) ? 0 : 1) === least);
    let best = 0;
    if (cands.includes(0)) {
      for (const sh of [-2, 2]) if (cands.includes(sh) && seam(ok.get(sh)!) >= seam(ok.get(0)!) + 0.04 && seam(ok.get(sh)!) > seam(ok.get(best)!)) best = sh;
    } else best = cands.reduce((a, c) => (seam(ok.get(c)!) > seam(ok.get(a)!) || (seam(ok.get(c)!) === seam(ok.get(a)!) && Math.abs(c) < Math.abs(a)) ? c : a), cands[0]);
    bars = ok.get(best)!;
    // the repeat to use: the most typical of those at full volume (clear of changes, if any is)
    const loudOnes = fullVolume(bars), pool = loudOnes.filter((s) => !crosses(s)).length ? loudOnes.filter((s) => !crosses(s)) : loudOnes;
    const ws = new Map(bars.map((s) => [s, win(s)]));
    const rep = pool.reduce((a, c) => (sum(bars.map((x) => dot(ws.get(c)!, ws.get(x)!))) > sum(bars.map((x) => dot(ws.get(a)!, ws.get(x)!))) ? c : a), pool[0]);
    const alike = bars.length > 1 ? mean(bars.flatMap((x, i) => bars.slice(i + 1).map((y) => dot(ws.get(x)!, ws.get(y)!)))) : 1;
    return { bars, rep, first: bars[0], alike, crosses: crosses(rep) };
  });
  const chosen = found.sort((a, c) => c.bars.length - a.bars.length).slice(0, max).sort((a, c) => a.first - c.first);
  await progress(1);

  const bars4 = (n: number) => Math.min(4, n) * 16;     // (an 8-bar pattern doesn't fit SLOOP's 64 steps: 4 bars)
  const lengths = { drums: bars4(per.drums), bass: bars4(per.bass), keys: bars4(per.chords), lead: 64 };
  return chosen.map((l) => {
    const grid = steps.slice(l.rep * 16, l.rep * 16 + 64);
    const q = (grid[63] - grid[0]) / 63;
    return {
      start: grid[0], bpm: 60 / (4 * q),
      ...consensusNotes(notes, l.bars.map((s) => steps.slice(s * 16, s * 16 + 64)), lengths),
      drums: consensusDrums(rises, l.bars, lengths.drums),
      repeats: l.bars.length, lengths,
      unsure: l.crosses || (l.bars.length < 3 && l.alike < 0.9),
    };
  });
}

/** The smallest of 1, 2, 4 bars at which a part repeats about as well as at its best (of 1, 2, 4, 8). */
function period(F: number[][], live: boolean[]): number {
  const sc = new Map<number, number>();
  for (const lag of [1, 2, 4, 8]) {
    const v: number[] = [];
    for (let i = 0; i + lag < F.length; i++) if (live[i] && live[i + lag]) v.push(dot(F[i], F[i + lag]));
    sc.set(lag, v.length ? mean(v) : 0);
  }
  const best = Math.max(...sc.values());
  return [1, 2, 4, 8].find((l) => sc.get(l)! >= best - 0.03) ?? 4;
}

/** Bar lines where the 4 bars before are unlike the 4 after (a checkerboard over the bars' similarity): the peaks
 *  more than a standard deviation above the average. */
function boundaries(all: number[][], nb: number): number[] {
  const S = (a: number, c: number) => dot(all[a], all[c]);
  const block = (a0: number, a1: number, b0: number, b1: number) => { let s = 0, c = 0; for (let i = a0; i < a1; i++) for (let j = b0; j < b1; j++) { s += S(i, j); c++; } return c ? s / c : 0; };
  const nov = new Array(nb).fill(0);
  for (let b = 2; b < nb - 1; b++) {
    const a0 = Math.max(0, b - 4), a1 = Math.min(nb, b + 4);
    nov[b] = block(a0, b, a0, b) + block(b, a1, b, a1) - 2 * block(a0, b, b, a1);
  }
  const m = mean(nov), sd = Math.sqrt(mean(nov.map((v) => (v - m) ** 2))), thr = m + sd;
  return nov.map((v, b) => (b > 0 && b < nb - 1 && v >= thr && v >= nov[b - 1] && v >= nov[b + 1] ? b : -1)).filter((b) => b >= 0);
}

/** From the tonal part of the audio (an FFT of 4096 at a hop of 1024, the drums' quick attacks taken out by a running
 *  median over 9 frames): per bar the bass (32-250 Hz) and chords (32 Hz-4.2 kHz) as pitch classes per beat, the
 *  bar's loudness (0..1), and the beats where a new sound comes in (two or more of four bands jumping at once to
 *  twice their median over the 8 beats before, and a real part of the mix there). */
async function tonalFeatures(y: Float32Array, steps: number[], nb: number, progress: (f: number) => Promise<void> | void) {
  const N = 4096, H = 1024, K = Math.ceil((8000 * N) / SR), frames = Math.floor((y.length - N) / H) + 1;
  const win = new Float64Array(N).map((_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / N));
  const midi = (k: number) => Math.round(69 + 12 * Math.log2((k * SR) / N / 440));
  const pc = new Int8Array(K).map((_, k) => ((k * SR) / N < 30 ? -1 : ((midi(k) % 12) + 12) % 12));
  // each semitone counts once, as in a constant-Q transform: a bin's share is 1 / the bins in its semitone (high up
  // there are many: summed, the cymbals and the overtones would outweigh the chords)
  const perSemi = new Map<number, number>();
  for (let k = 1; k < K; k++) if (pc[k] >= 0) perSemi.set(midi(k), (perSemi.get(midi(k)) ?? 0) + 1);
  const share = new Float32Array(K).map((_, k) => (k && pc[k] >= 0 ? 1 / perSemi.get(midi(k))! : 0));
  const hz = (k: number) => (k * SR) / N;
  const BANDS = [[80, 250], [250, 700], [700, 3000], [3000, 8000]];
  const bassC = new Float32Array(frames * 12), chordC = new Float32Array(frames * 12), bandE = new Float32Array(frames * 4), rms = new Float32Array(frames);
  // a chunk of frames at a time: magnitudes, then the median over time per bin (the tonal part), then the features
  const CH = 256, PAD = 4, re = new Float64Array(N), im = new Float64Array(N);
  for (let c0 = 0; c0 < frames; c0 += CH) {
    const a = Math.max(0, c0 - PAD), z = Math.min(frames, c0 + CH + PAD), M = new Float32Array((z - a) * K);
    for (let t = a; t < z; t++) {
      for (let i = 0; i < N; i++) { re[i] = (y[t * H + i] ?? 0) * win[i]; im[i] = 0; }
      fft(re, im);
      for (let k = 0; k < K; k++) M[(t - a) * K + k] = Math.hypot(re[k], im[k]);
    }
    const buf = new Float32Array(9);
    for (let t = c0; t < Math.min(frames, c0 + CH); t++) {
      let e = 0;
      for (let i = t * H; i < t * H + H && i < y.length; i++) e += Math.abs(y[i]);
      rms[t] = e / H;
      for (let k = 1; k < K; k++) {
        let m = 0;
        for (let j = Math.max(a, t - PAD); j <= Math.min(z - 1, t + PAD); j++) buf[m++] = M[(j - a) * K + k];
        const v = buf.subarray(0, m).sort()[m >> 1], f = hz(k);   // (raised to 1.3 per beat below: as sharp as the prototype's constant-Q chroma)
        if (pc[k] >= 0 && f < 4200) { chordC[t * 12 + pc[k]] += v * share[k]; if (f < 250) bassC[t * 12 + pc[k]] += v * share[k]; }
        BANDS.forEach(([lo, hi], bi) => { if (f >= lo && f < hi) bandE[t * 4 + bi] += v; });
      }
    }
    await progress(c0 / frames);
  }
  const fr = (t: number) => Math.max(0, Math.min(frames - 1, Math.round((t * SR - N / 2) / H)));
  const beats = steps.filter((_, i) => i % 4 === 0), nbeats = Math.min(beats.length - 1, nb * 4);
  const perBeat = (X: Float32Array, w: number, i: number) => {
    const a = fr(beats[i]), z = Math.max(a + 1, fr(beats[i + 1])), v = new Array(w).fill(0);
    for (let t = a; t < z; t++) for (let k = 0; k < w; k++) v[k] += X[t * w + k];
    return v.map((x) => x / (z - a));
  };
  const barOf = (X: Float32Array) => Array.from({ length: nb }, (_, b) => [0, 1, 2, 3].flatMap((q) => { const v = (b * 4 + q < nbeats ? perBeat(X, 12, b * 4 + q) : new Array(12).fill(0)).map((x) => x ** 1.3); const l = Math.hypot(...v) || 1; return v.map((x) => x / l); }));
  const loud = Array.from({ length: nb }, (_, b) => { const a = fr(steps[b * 16]), z = Math.max(a + 1, fr(steps[Math.min(steps.length - 1, b * 16 + 15)])); return mean(Array.from(rms.subarray(a, z))); });
  const lmax = Math.max(...loud) || 1;
  const E = Array.from({ length: nbeats }, (_, i) => perBeat(bandE, 4, i));
  const entries: number[] = [];
  const tops = [0, 1, 2, 3].map((k) => quantile(E.map((e) => e[k]), 0.98));
  for (let i = 9; i < nbeats; i++) {
    let jumps = 0;
    for (let k = 0; k < 4; k++) {
      const m = median(E.slice(i - 8, i).map((e) => e[k])) + 1e-9;
      if (E[i][k] >= 2 * m && E[i][k] >= 0.25 * tops[k] && E[i - 1][k] < 2 * m) jumps++;
    }
    if (jumps >= 2) entries.push(i);
  }
  return { bass: unit(barOf(bassC)), chords: unit(barOf(chordC)), loud: loud.map((l) => l / lmax), entries };
}

/** A loop's drums from its repeats: per 16th (and per position of a shorter drum pattern) the median attack in each
 *  band over every repeat, then kick, snare and hats as for one section. */
function consensusDrums({ R, tone, ring }: Rises, bars: number[], length: number): [number, number[]][] {
  const at = (p: number) => bars.flatMap((s) => { const v: number[] = []; for (let q = p % length; q < 64; q += length) v.push(s * 16 + q); return v; });
  const out: [number, number[]][] = [];
  for (let p = 0; p < 64; p++) {
    const ix = at(p), m = (a: Float64Array) => median(ix.map((i) => a[i]));
    const low = m(R.low), mid = m(R.mid), high = m(R.high), lanes: number[] = [];
    if (low >= 6 && low >= mid - 2 && m(tone) < 12) lanes.push(0);
    const snare = mid >= 7.5 && mid - low >= 2.5;
    if (snare) lanes.push(2);
    if (high >= 6 && (!snare || high - mid >= 3.5)) lanes.push(m(ring) > 0.15 ? 5 : 4);
    if (lanes.length) out.push([p, lanes]);
  }
  return out;
}

/** A loop's notes from its repeats: each repeat's bassline, chords and lead (arrangeNotes), a note kept when at least
 *  half the repeats (and the repeats of a shorter pattern inside them) have it; its length the median. */
function consensusNotes(notes: AudioNote[], grids: number[][], lengths: Record<Part, number>): Pick<Section, "bass" | "keys" | "lead"> {
  const parts = grids.map((g) => arrangeNotes(notes, g));
  const vote = (lines: [number, number, number][][], len: number) => {
    const n = lines.length * (64 / len), by = new Map<string, number[]>();
    for (const line of lines) for (const [st, ln, p] of line) { const k = `${st % len},${p}`; by.set(k, [...(by.get(k) ?? []), ln]); }
    const kept = [...by.entries()].filter(([, v]) => v.length >= Math.max(1, Math.ceil(n / 2)));
    const out: [number, number, number][] = [];
    for (let rep = 0; rep < 64; rep += len)
      for (const [k, v] of kept) { const [st, p] = k.split(",").map(Number); out.push([st + rep, median(v), p]); }
    return out.sort((a, b) => a[0] - b[0] || a[2] - b[2]);
  };
  const mono = (line: [number, number, number][]) => {
    const one = new Map<number, [number, number, number]>();
    for (const n of line) if (!one.has(n[0])) one.set(n[0], n);                  // (one note a step: the lowest)
    const l = [...one.values()].sort((a, b) => a[0] - b[0]);
    return l.map(([st, ln, p], i): [number, number, number] => [st, Math.max(1, Math.min(ln, i + 1 < l.length ? l[i + 1][0] - st : ln, 64 - st)), p]);
  };
  const bass = mono(vote(parts.map((p) => p.bass), lengths.bass));
  const lead = mono([...vote(parts.map((p) => p.lead), lengths.lead)].sort((a, b) => a[0] - b[0] || b[2] - a[2]));
  const keyNotes = vote(parts.map((p) => p.keys.flatMap(([st, ln, ps]) => ps.map((x): [number, number, number] => [st, ln, x]))), lengths.keys);
  const chords = new Map<number, { ln: number; ps: number[] }>();
  for (const [st, ln, p] of keyNotes) { const c = chords.get(st) ?? { ln, ps: [] }; c.ln = Math.max(c.ln, ln); if (c.ps.length < 4) c.ps.push(p); chords.set(st, c); }
  const keys = [...chords.entries()].sort((a, b) => a[0] - b[0]).map(([st, c]): [number, number, number[]] => [st, Math.min(c.ln, 64 - st), c.ps]);
  return { bass, keys, lead };
}

const dot = (a: number[], b: number[]) => { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * b[i]; return s; };
const unit = (rows: number[][]) => rows.map((r) => { const l = Math.hypot(...r) || 1; return r.map((v) => v / l); });
const sum = (a: number[]) => a.reduce((x, v) => x + v, 0);
const mean = (a: number[]) => (a.length ? sum(a) / a.length : 0);
const meanTop = (a: number[], k: number) => mean([...a].sort((x, y) => y - x).slice(0, k));
function median(a: number[]) { const s = [...a].sort((x, y) => x - y); return s[s.length >> 1] ?? 0; }
function quantile(a: number[], q: number) { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(q * (s.length - 1)))] ?? 0; }
