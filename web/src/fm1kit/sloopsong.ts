// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// A SLOOP song as data you can edit (mirrors SLOOPSong.swift): the loop in progress, sections A-D and the song order,
// read from a saved song and written back as one. Layouts follow SLOOP 2.6 and later (isod89/sloop-fm1
// firmware/src/project.c project_t "FUN6", core.h step_t / dstep_t, arranger.h arr_config_t at bytes 48-83 of the
// settings, the bytes SLOOP's own web editor edits). Older formats are kept as they are and not edited.
// The edits match SLOOP's web editor (its piano roll: a NOTE step holds a chord of up to 4 notes, the TIE steps after
// it hold it, a REST is silence; the drum track is 16 lanes). A pattern is 64 steps at most; a longer song is the
// sections chained in the song order (16 entries, each 1-64 bars).
import { DeviceArchive, SLOOP_FORMAT, part, partBytes, sloopLabel } from "./archive";
import { FM1Error } from "./ota";

export const PROJ_MAGIC = 0x46554e36, PROJ_SIZE = 3816;
const TRACK_BASE = 76, TRACK_SIZE = 934, SUM_AT = 3812;
export const DRUM_TRACK = 3, MAX_STEPS = 64;
const LEN_AT = 58, DIV_AT = 60, ENGINE_AT = 132, STEPS_AT = 134, MF_AT = 774, LOCKS_AT = 838, N_LOCKS = 24;
export const STEPS_PER_BAR = [4, 8, 16, 32, 12, 24, 2, 1, 0.5];
export const DIV_NAMES = ["1/4", "1/8", "1/16", "1/32", "8T", "16T", "1/2", "1 bar", "2 bars"];
export const DRUM_LANES = ["KICK", "KICK 2", "SNARE", "CLAP", "HAT", "OPEN HAT", "PEDAL", "RIM", "SNARE 2",
  "LOW TOM", "HI TOM", "CRASH", "RIDE", "SHAKER", "CONGA", "COWBELL"];

const u32 = (b: Uint8Array, at: number) => (b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)) >>> 0;
export function fnv(b: Uint8Array): number {
  let s = 0x811c9dc5;
  for (const x of b) s = Math.imul(s ^ x, 16777619) >>> 0;
  return s >>> 0;
}

// ---- steps: 10 bytes. Synth: notes 0-3, count, time (0 note, 1 tie, 2 rest), flags, velocity, levels, ratchets.
// Drum: a bit per lane, 2 bits of level and of ratchet per lane.
export type Step = Uint8Array;
const REST = [0, 0, 0, 0, 0, 2, 0, 0, 0, 0], TIE = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0];
export const isNote = (s: Step) => s[5] === 0 && s[4] > 0;
export const isTie = (s: Step) => s[5] === 1;
export const stepNotes = (s: Step) => [...s.subarray(0, Math.min(4, s[4]))];
export const drumOn = (s: Step, lane: number) => ((s[lane >> 3] >> (lane & 7)) & 1) === 1;

export interface Chord { at: number; length: number; notes: number[]; velocity: number }
export interface Clip { isDrum: boolean; steps: Step[]; mf: number[]; locks: { step: number; param: number; val: [number, number] }[] }

/** One track of a section, edited in place (a view onto the section's bytes). */
export class Track {
  constructor(readonly raw: Uint8Array, readonly isDrum: boolean) {}
  get engine() { return this.raw[ENGINE_AT]; }
  get length() { const v = (this.raw[LEN_AT] | (this.raw[LEN_AT + 1] << 8)) << 16 >> 16; return Math.max(1, Math.min(MAX_STEPS, v)); }
  set length(n: number) { const v = Math.max(1, Math.min(MAX_STEPS, Math.round(n))); this.raw[LEN_AT] = v & 255; this.raw[LEN_AT + 1] = v >> 8; }
  get div() { return Math.max(0, Math.min(8, this.raw[DIV_AT])); }
  get stepsPerBar() { return STEPS_PER_BAR[this.div]; }
  /** Whole steps in a bar, or null when a step is longer than a bar (bar edits don't apply). */
  get barSteps(): number | null { return this.stepsPerBar >= 1 ? this.stepsPerBar : null; }
  get bars() { return Math.ceil(this.length / this.stepsPerBar); }
  step(i: number): Step { return this.raw.slice(STEPS_AT + i * 10, STEPS_AT + i * 10 + 10); }
  private set(i: number, s: ArrayLike<number>) { this.raw.set(s, STEPS_AT + i * 10); }
  private empty() { return this.isDrum ? new Array(10).fill(0) : REST; }
  get isEmpty() { for (let i = 0; i < this.length; i++) { const s = this.step(i); if (this.isDrum ? (s[0] | s[1]) : isNote(s)) return false; } return true; }

  get chords(): Chord[] {
    if (this.isDrum) return [];
    const out: Chord[] = [];
    for (let i = 0; i < this.length; i++) {
      const s = this.step(i);
      if (!isNote(s)) continue;
      let d = 1;
      while (i + d < this.length && isTie(this.step(i + d))) d++;
      out.push({ at: i, length: d, notes: stepNotes(s), velocity: s[7] });
    }
    return out;
  }
  owner(i: number): number | null {
    for (let k = i; k >= 0; k--) { const s = this.step(k); if (isNote(s)) return k; if (!isTie(s)) return null; }
    return null;
  }
  private cutTies(end: number) { for (let k = end; k < this.length && isTie(this.step(k)); k++) this.set(k, REST); }
  /** `pitch` at step `at` for `dur` steps; on a chord's first step it joins the chord (4 notes at most). */
  place(pitch: number, at: number, dur: number) {
    if (this.isDrum || at < 0 || at >= this.length) return;
    const s = this.step(at);
    if (isNote(s)) {
      const n = stepNotes(s);
      if (n.includes(pitch) || n.length >= 4) return;
      n.push(pitch); for (let i = 0; i < 4; i++) s[i] = n[i] ?? 0; s[4] = n.length; this.set(at, s);
      return;
    }
    this.set(at, [pitch & 127, 0, 0, 0, 1, 0, 0, 96, 0, 0]);
    let k = 1;
    for (; k < dur && at + k < this.length && !isNote(this.step(at + k)); k++) this.set(at + k, TIE);
    this.cutTies(at + k);
  }
  remove(pitch: number, at: number) {
    if (this.isDrum || at < 0 || at >= this.length) return;
    const s = this.step(at);
    if (!isNote(s) || !stepNotes(s).includes(pitch)) return;
    const left = stepNotes(s).filter((n) => n !== pitch);
    if (!left.length) { this.set(at, REST); this.cutTies(at + 1); return; }
    for (let i = 0; i < 4; i++) s[i] = left[i] ?? 0; s[4] = left.length; this.set(at, s);
  }
  resize(at: number, dur: number) {
    if (this.isDrum || at < 0 || at >= this.length || !isNote(this.step(at))) return;
    let cur = 1;
    while (at + cur < this.length && isTie(this.step(at + cur))) cur++;
    const d = Math.max(1, Math.min(dur, this.length - at));
    if (d < cur) for (let k = d; k < cur; k++) this.set(at + k, REST);
    else for (let k = cur; k < d && !isNote(this.step(at + k)); k++) this.set(at + k, TIE);
  }
  toggleDrum(lane: number, at: number) {
    if (!this.isDrum || at < 0 || at >= MAX_STEPS || lane < 0 || lane > 15) return;
    const s = this.step(at), on = !drumOn(s, lane), sh = (lane & 3) * 2, b = (lane >> 2) & 3;
    if (on) s[lane >> 3] |= 1 << (lane & 7); else s[lane >> 3] &= ~(1 << (lane & 7));
    s[2 + b] &= ~(3 << sh); s[6 + b] &= ~(3 << sh);
    this.set(at, s);
  }

  private clearExtras(lo: number, hi: number) {
    for (let i = lo; i < hi; i++) this.raw[MF_AT + i] = 0;
    for (let l = 0; l < N_LOCKS; l++) {
      const a = LOCKS_AT + l * 4;
      if (this.raw[a] !== 0xff && this.raw[a] >= lo && this.raw[a] < hi) this.raw.set([0xff, 0, 0, 0], a);
    }
  }
  clearAll() { this.clear(0, MAX_STEPS); }
  /** Empties steps lo..hi (their nudges and locks too); LEN stays. */
  clear(lo: number, hi: number) {
    lo = Math.max(0, lo); hi = Math.min(MAX_STEPS, hi);
    for (let i = lo; i < hi; i++) this.set(i, this.empty());
    this.clearExtras(lo, hi);
    this.tidy();
  }
  /** Empty steps added at the end (LEN grows, 64 at most). */
  extend(n: number) { const from = this.length, to = Math.min(MAX_STEPS, from + n); if (to > from) { this.clear(from, to); this.length = to; } }

  copy(lo: number, hi: number): Clip {
    lo = Math.max(0, lo); hi = Math.min(MAX_STEPS, hi);
    const locks: Clip["locks"] = [];
    for (let l = 0; l < N_LOCKS; l++) {
      const a = LOCKS_AT + l * 4, st = this.raw[a];
      if (st !== 0xff && st >= lo && st < hi) locks.push({ step: st - lo, param: this.raw[a + 1], val: [this.raw[a + 2], this.raw[a + 3]] });
    }
    const steps: Step[] = [];
    for (let i = lo; i < hi; i++) steps.push(this.step(i));
    return { isDrum: this.isDrum, steps, mf: [...this.raw.subarray(MF_AT + lo, MF_AT + hi)], locks };
  }
  /** The clip over the steps from `at` (what doesn't fit in 64 steps is dropped); LEN grows to cover it. */
  paste(c: Clip, at: number): boolean {
    if (c.isDrum !== this.isDrum || at < 0 || at >= MAX_STEPS) return false;
    const n = Math.min(c.steps.length, MAX_STEPS - at);
    this.clearExtras(at, at + n);
    for (let i = 0; i < n; i++) { this.set(at + i, c.steps[i]); this.raw[MF_AT + at + i] = c.mf[i]; }
    for (const l of c.locks) {
      if (l.step >= n) continue;
      let free = -1;
      for (let k = 0; k < N_LOCKS; k++) if (this.raw[LOCKS_AT + k * 4] === 0xff) { free = k; break; }
      if (free < 0) break;
      this.raw.set([at + l.step, l.param, ...l.val], LOCKS_AT + free * 4);
    }
    if (at + n > this.length) this.length = at + n;
    this.tidy();
    return true;
  }
  /** Room made at `at`, the clip pasted there: later steps move later, LEN grows (64 at most). */
  insert(c: Clip, at: number): boolean {
    if (c.isDrum !== this.isDrum || at < 0 || at > this.length || at >= MAX_STEPS) return false;
    const len = Math.min(MAX_STEPS, this.length + c.steps.length);
    this.move(at, at + c.steps.length);
    this.length = len;
    return this.paste(c, at);
  }
  /** Steps lo..hi taken out: later steps move earlier, LEN shrinks (1 at least). */
  delete(lo: number, hi: number) {
    lo = Math.max(0, lo); hi = Math.min(this.length, hi);
    if (hi <= lo) return;
    const len = Math.max(1, this.length - (hi - lo));
    this.clearExtras(lo, hi);
    this.move(hi, lo);
    this.length = len;
    this.tidy();
  }
  private move(from: number, to: number) {
    if (from === to) return;
    const steps: Step[] = [], mf = [...this.raw.subarray(MF_AT, MF_AT + MAX_STEPS)];
    for (let i = 0; i < MAX_STEPS; i++) steps.push(this.step(i));
    const lo = Math.min(from, to);
    for (let i = lo; i < MAX_STEPS; i++) {
      const src = i - to + from, ok = src >= from && src < MAX_STEPS;
      this.set(i, ok ? steps[src] : this.empty());
      this.raw[MF_AT + i] = ok ? mf[src] : 0;
    }
    for (let l = 0; l < N_LOCKS; l++) {
      const a = LOCKS_AT + l * 4, s = this.raw[a];
      if (s === 0xff) continue;
      if (s >= from) { const d = s - from + to; if (d < MAX_STEPS) this.raw[a] = d; else this.raw.set([0xff, 0, 0, 0], a); }
      else if (s >= lo) this.raw.set([0xff, 0, 0, 0], a);
    }
  }
  /** A tie with no chord before it (left by a cut or a paste) becomes a rest. */
  tidy() { if (!this.isDrum) for (let i = 0; i < MAX_STEPS; i++) if (isTie(this.step(i)) && this.owner(i) == null) this.set(i, REST); }
}

/** A format-6 section (or the loop). `raw` is edited through `track(k)`; `data` adds the checksum SLOOP checks. */
export class Pattern {
  readonly raw: Uint8Array;
  private constructor(raw: Uint8Array) { this.raw = raw; }
  static parse(b: Uint8Array): Pattern | null {
    if (b.length !== PROJ_SIZE || u32(b, 0) !== PROJ_MAGIC || u32(b, 4) !== PROJ_SIZE || u32(b, SUM_AT) !== fnv(b.subarray(0, SUM_AT))) return null;
    return new Pattern(b.slice());
  }
  clone() { return new Pattern(this.raw.slice()); }
  get data(): Uint8Array {
    const b = this.raw.slice(), s = fnv(b.subarray(0, SUM_AT));
    for (let i = 0; i < 4; i++) b[SUM_AT + i] = (s >>> (8 * i)) & 255;
    return b;
  }
  get bpm() { return (this.raw[8] | (this.raw[9] << 8)) << 16 >> 16; }
  track(k: number) { return new Track(this.raw.subarray(TRACK_BASE + k * TRACK_SIZE, TRACK_BASE + (k + 1) * TRACK_SIZE), k === DRUM_TRACK); }
  get bars() { let b = 1; for (let k = 0; k < 4; k++) b = Math.max(b, this.track(k).bars); return Math.min(64, b); }
  same(o: Pattern) { for (let i = 0; i < SUM_AT; i++) if (this.raw[i] !== o.raw[i]) return false; return true; }
}

// ---- the song order (arr_config_t in the settings)
export interface OrderEntry { section: number; bars: number }
export interface Order { entries: OrderEntry[]; loops: boolean }
const ORDER_AT = 48, SETTINGS_MAGIC = 0x50455233;
export const MAX_ENTRIES = 16;
export function readOrder(b: Uint8Array): Order | null {
  if (b.length < ORDER_AT + 36 || u32(b, 0) !== SETTINGS_MAGIC) return null;
  const n = b[ORDER_AT];
  if (n < 1 || n > MAX_ENTRIES) return null;
  const entries: OrderEntry[] = [];
  for (let i = 0; i < n; i++) entries.push({ section: b[ORDER_AT + 4 + 2 * i] & 3, bars: Math.max(1, Math.min(64, b[ORDER_AT + 5 + 2 * i])) });
  return { entries, loops: b[ORDER_AT + 1] === 1 };
}
export function writeOrder(o: Order, settings: Uint8Array): Uint8Array {
  const b = settings.slice();
  b[ORDER_AT] = o.entries.length; b[ORDER_AT + 1] = o.loops ? 1 : 0; b[ORDER_AT + 2] = 0; b[ORDER_AT + 3] = 0;
  for (let i = 0; i < MAX_ENTRIES; i++) {
    const e = o.entries[i] ?? { section: i % 4, bars: 4 };
    b[ORDER_AT + 4 + 2 * i] = e.section & 3; b[ORDER_AT + 5 + 2 * i] = Math.max(1, Math.min(64, e.bars));
  }
  return b;
}
export const totalBars = (o: Order) => o.entries.reduce((n, e) => n + e.bars, 0);

// ---- the whole song
export const SLOTS = ["loop", "a", "b", "c", "d"] as const;
export type Slot = (typeof SLOTS)[number];
export const slotName = (s: Slot) => s === "loop" ? "Loop" : s.toUpperCase();
export const slotObject = (s: Slot) => String(SLOTS.indexOf(s) === 0 ? 0 : SLOTS.indexOf(s) + 1);
export const sectionSlot = (i: number): Slot => SLOTS[1 + (i & 3)];
export const slotSection = (s: Slot) => s === "loop" ? null : SLOTS.indexOf(s) - 1;

export class SongDoc {
  patterns: Partial<Record<Slot, Pattern>>;
  readonly locked: Set<Slot>;
  order: Order | null;
  readonly base: DeviceArchive;
  private constructor(base: DeviceArchive, patterns: Partial<Record<Slot, Pattern>>, locked: Set<Slot>, order: Order | null) {
    this.base = base; this.patterns = patterns; this.locked = locked; this.order = order;
  }
  static open(a: DeviceArchive): SongDoc {
    if (a.format !== SLOOP_FORMAT) throw new FM1Error("badpkg", "This isn't a SLOOP song.");
    const p: Partial<Record<Slot, Pattern>> = {}, locked = new Set<Slot>();
    for (const s of SLOTS) {
      const part = a.parts.find((x) => x.id === slotObject(s));
      if (!part || !part.data) continue;
      const pat = Pattern.parse(partBytes(part));
      if (pat) p[s] = pat; else locked.add(s);
    }
    if (!p.loop && !locked.has("loop")) throw new FM1Error("badpkg", "The song is missing the loop in progress.");
    const settings = a.parts.find((x) => x.id === "1");
    return new SongDoc(a, p, locked, settings?.data ? readOrder(partBytes(settings)) : null);
  }
  clone(): SongDoc {
    const p: Partial<Record<Slot, Pattern>> = {};
    for (const s of SLOTS) if (this.patterns[s]) p[s] = this.patterns[s]!.clone();
    return new SongDoc(this.base, p, this.locked, this.order && { loops: this.order.loops, entries: this.order.entries.map((e) => ({ ...e })) });
  }
  same(o: SongDoc): boolean {
    for (const s of SLOTS) {
      const a = this.patterns[s], b = o.patterns[s];
      if (!!a !== !!b || (a && b && !a.same(b))) return false;
    }
    const a = this.order, b = o.order;
    if (!a || !b) return a === b;
    return a.loops === b.loops && a.entries.length === b.entries.length && a.entries.every((e, i) => e.section === b.entries[i].section && e.bars === b.entries[i].bars);
  }
  isEmpty(s: Slot) { return !this.patterns[s] && !this.locked.has(s); }
  copy(from: Slot, to: Slot) { const p = this.patterns[from]; if (from !== to && p && !this.locked.has(to)) this.patterns[to] = p.clone(); }
  erase(s: Slot) { if (s !== "loop" && !this.locked.has(s)) delete this.patterns[s]; }
  /** Order entries that point at an empty section (SLOOP won't play song mode until they're filled). */
  get emptyEntries(): number[] { return (this.order?.entries ?? []).flatMap((e, i) => this.isEmpty(sectionSlot(e.section)) ? [i] : []); }

  /** The song as a saved song again: the edited slots, the order in the settings, the rest as it was. */
  archive(): DeviceArchive {
    const parts = this.base.parts.map((p) => {
      const s = SLOTS.find((x) => slotObject(x) === p.id);
      if (s && !this.locked.has(s)) return part(p.id, p.label, this.patterns[s]?.data ?? new Uint8Array());
      if (p.id === "1" && this.order && p.data) return part(p.id, p.label, writeOrder(this.order, partBytes(p)));
      return p;
    });
    for (const s of SLOTS) {
      const pat = this.patterns[s];
      if (pat && !parts.some((p) => p.id === slotObject(s))) parts.push(part(slotObject(s), sloopLabel(Number(slotObject(s))), pat.data));
    }
    return { ...this.base, created: Date.now() / 1000, parts };
  }
}
