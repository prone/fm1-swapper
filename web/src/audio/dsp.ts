// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The signal processing the audio import needs (what librosa does in the Python prototype): an FFT, a magnitude
// spectrogram, harmonic/percussive separation by median filtering, onset strength, and librosa's beat tracker.
// Everything works on mono Float32Array audio at 22050 Hz.

export const SR = 22050;

/** In-place radix-2 FFT of re/im (length a power of 2). */
function fft(re: Float64Array, im: Float64Array) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len, wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k, b = a + len / 2;
        const tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
        const t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t;
      }
    }
  }
}

/** A magnitude spectrogram: `frames` x `bins`, row-major (frame t, bin k at t * bins + k). */
export interface Spec { mag: Float32Array; frames: number; bins: number; nFft: number; hop: number }

/** STFT magnitudes with a Hann window, centred frames (reflect-padded, as librosa does). */
export function stft(y: Float32Array, nFft: number, hop: number): Spec {
  const pad = nFft / 2, n = y.length;
  const at = (i: number) => y[i < 0 ? Math.min(n - 1, -i) : i >= n ? Math.max(0, 2 * n - 2 - i) : i] ?? 0;
  const frames = 1 + Math.floor(n / hop), bins = nFft / 2 + 1;
  const win = new Float64Array(nFft).map((_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / nFft));
  const mag = new Float32Array(frames * bins), re = new Float64Array(nFft), im = new Float64Array(nFft);
  for (let t = 0; t < frames; t++) {
    const s = t * hop - pad;
    for (let i = 0; i < nFft; i++) { re[i] = at(s + i) * win[i]; im[i] = 0; }
    fft(re, im);
    for (let k = 0; k < bins; k++) mag[t * bins + k] = Math.hypot(re[k], im[k]);
  }
  return { mag, frames, bins, nFft, hop };
}

export const binHz = (s: Spec, k: number) => (k * SR) / s.nFft;

/** The median of `n` values gathered by `get` (a small scratch array, sorted). */
function median(buf: Float32Array, n: number) {
  const a = buf.subarray(0, n).sort();
  return a[n >> 1];
}

/** Harmonic/percussive separation (librosa.decompose.hpss): medians across time (harmonic) and across frequency
 *  (percussive), kernel 31, soft masks with margins (1, 3) as the prototype uses. The masks are worked out on `coarse`
 *  (2048 / 512, as librosa.effects.hpss) and applied to `fine` (the resolution the drums are timed at): the same split
 *  as separating at 2048 / 512 and analysing the result finely, without resynthesising. */
export function hpss(coarse: Spec, fine: Spec, kernel = 31, marginH = 1, marginP = 3): { harm: Spec; perc: Spec } {
  const { mag, frames, bins } = coarse, h = kernel >> 1, buf = new Float32Array(kernel);
  const H = new Float32Array(mag.length), P = new Float32Array(mag.length);
  for (let k = 0; k < bins; k++) {                                     // across time, per bin
    for (let t = 0; t < frames; t++) {
      let n = 0;
      for (let j = Math.max(0, t - h); j <= Math.min(frames - 1, t + h); j++) buf[n++] = mag[j * bins + k];
      H[t * bins + k] = median(buf, n);
    }
  }
  for (let t = 0; t < frames; t++) {                                   // across frequency, per frame
    const row = t * bins;
    for (let k = 0; k < bins; k++) {
      let n = 0;
      for (let j = Math.max(0, k - h); j <= Math.min(bins - 1, k + h); j++) buf[n++] = mag[row + j];
      P[row + k] = median(buf, n);
    }
  }
  const soft = (x: number, ref: number) => { const z = Math.max(x, ref) || 1; const a = (x / z) ** 2, b = (ref / z) ** 2; return a / (a + b || 1); };
  const harm = new Float32Array(fine.mag.length), perc = new Float32Array(fine.mag.length);
  const tScale = fine.hop / coarse.hop, kScale = coarse.nFft / fine.nFft;
  for (let t = 0; t < fine.frames; t++) {
    const ct = Math.min(frames - 1, Math.round(t * tScale));
    for (let k = 0; k < fine.bins; k++) {
      const c = ct * bins + Math.min(bins - 1, Math.round(k * kScale)), i = t * fine.bins + k;
      harm[i] = fine.mag[i] * soft(H[c], P[c] * marginH);
      perc[i] = fine.mag[i] * soft(P[c], H[c] * marginP);
    }
  }
  return { harm: { ...fine, mag: harm }, perc: { ...fine, mag: perc } };
}

/** The summed magnitude of bins from `lo` to `hi` Hz, per frame. */
export function band(s: Spec, lo: number, hi: number): Float32Array {
  const out = new Float32Array(s.frames);
  const k0 = Math.ceil((lo * s.nFft) / SR), k1 = Math.min(s.bins - 1, Math.ceil((hi * s.nFft) / SR) - 1);
  for (let t = 0; t < s.frames; t++) { let sum = 0; for (let k = k0; k <= k1; k++) sum += s.mag[t * s.bins + k]; out[t] = sum; }
  return out;
}

/** Onset strength (like librosa.onset.onset_strength): log power in ~64 log-spaced bands, the positive change from
 *  the frame before, averaged over the bands; one value per frame. */
export function onsetStrength(s: Spec): Float32Array {
  const edges: number[] = [];
  for (let i = 0; i <= 64; i++) edges.push(Math.round(1 + (s.bins - 2) * ((2 ** (i / 64 * 9) - 1) / 511)));
  const bands = edges.slice(0, -1).map((a, i) => [a, Math.max(a + 1, edges[i + 1])] as const);
  const db = new Float32Array(s.frames * bands.length);
  let top = -Infinity;
  for (let t = 0; t < s.frames; t++) {
    bands.forEach(([a, b], j) => {
      let p = 0;
      for (let k = a; k < b; k++) p += s.mag[t * s.bins + k] ** 2;
      const v = 10 * Math.log10(p + 1e-10);
      db[t * bands.length + j] = v; top = Math.max(top, v);
    });
  }
  for (let i = 0; i < db.length; i++) db[i] = Math.max(db[i], top - 80);       // (librosa's top_db)
  const env = new Float32Array(s.frames);
  for (let t = 1; t < s.frames; t++) {
    let sum = 0;
    for (let j = 0; j < bands.length; j++) sum += Math.max(0, db[t * bands.length + j] - db[(t - 1) * bands.length + j]);
    env[t] = sum / bands.length;
  }
  return env;
}

/** librosa.beat.beat_track's tempo and beats (the same steps: an autocorrelation tempo with a log-normal prior around
 *  120 BPM, then dynamic programming over the onset envelope). `env` has one value per `hop` samples; beat times in s. */
export function beatTrack(env: Float32Array, hop: number): { bpm: number; beats: number[] } {
  const fps = SR / hop, n = env.length;
  // tempo: the autocorrelation of the (mean-removed) envelope, weighted by the prior
  const mean = env.reduce((a, b) => a + b, 0) / n;
  const x = env.map((v) => v - mean);
  const maxLag = Math.min(n - 1, Math.round(fps * 60 / 30));
  let best = 120, bestScore = -Infinity;
  const ac0 = x.reduce((a, v) => a + v * v, 0) || 1;
  for (let lag = Math.round(fps * 60 / 320); lag <= maxLag; lag++) {
    let sum = 0;
    for (let i = lag; i < n; i++) sum += x[i] * x[i - lag];
    const bpm = (60 * fps) / lag, prior = Math.exp(-0.5 * Math.log2(bpm / 120) ** 2);
    const score = Math.log1p(1e6 * Math.max(0, sum / ac0)) + Math.log(prior);
    if (score > bestScore) { bestScore = score; best = bpm; }
  }
  // beats: dynamic programming (Ellis 2007), as librosa's __beat_tracker
  const period = Math.round((60 * fps) / best);
  let sd = Math.sqrt(x.reduce((a, v) => a + v * v, 0) / n) || 1;
  const norm = env.map((v) => v / sd);
  const local = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let k = -period; k <= period; k++) { const j = i + k; if (j >= 0 && j < n) s += norm[j] * Math.exp(-0.5 * ((k * 32) / period) ** 2); }
    local[i] = s;
  }
  const cum = new Float64Array(n), back = new Int32Array(n).fill(-1);
  const w0 = -2 * period, w1 = -Math.round(period / 2);
  let firstBeat = true;
  const localMax = Math.max(...local);
  for (let i = 0; i < n; i++) {
    let bestV = -Infinity, bestJ = -1;
    for (let k = w0; k <= w1; k++) {
      const j = i + k;
      if (j < 0) continue;
      const v = cum[j] - 100 * Math.log(-k / period) ** 2;
      if (v > bestV) { bestV = v; bestJ = j; }
    }
    cum[i] = local[i] + (bestJ >= 0 ? bestV : 0);
    if (firstBeat && local[i] < 0.01 * localMax) back[i] = -1; else { back[i] = bestJ; firstBeat = false; }
  }
  // the last beat: the last local maximum of the cumulative score above half its median
  const maxes: number[] = [];
  for (let i = 1; i < n - 1; i++) if (cum[i] >= cum[i - 1] && cum[i] >= cum[i + 1]) maxes.push(i);
  const med = maxes.map((i) => cum[i]).sort((a, b) => a - b)[maxes.length >> 1] ?? 0;
  let i = [...maxes].reverse().find((m) => cum[m] >= 0.5 * med) ?? n - 1;
  const frames: number[] = [];
  while (i >= 0) { frames.push(i); i = back[i]; }
  frames.reverse();
  // trim weak beats at the ends (librosa: below half the RMS of the local score)
  const rms = Math.sqrt(local.reduce((a, v) => a + v * v, 0) / n) * 0.5;
  while (frames.length && local[frames[0]] < rms) frames.shift();
  while (frames.length && local[frames[frames.length - 1]] < rms) frames.pop();
  sd = 0;
  return { bpm: best, beats: frames.map((f) => (f * hop) / SR) };
}

/** A straight line through points (least squares): slope and offset. */
export function linefit(xs: number[], ys: number[]): [number, number] {
  const n = xs.length, mx = xs.reduce((a, b) => a + b, 0) / n, my = ys.reduce((a, b) => a + b, 0) / n;
  let sxy = 0, sxx = 0;
  for (let i = 0; i < n; i++) { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) ** 2; }
  const k = sxx ? sxy / sxx : 0;
  return [k, my - k * mx];
}
