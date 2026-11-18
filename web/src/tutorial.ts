// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Tutorials (../Tutorials/*.json, shared with the iOS app) and their matching and "Your turn" logic
// (mirrors App/Tutorial.swift and App/Views/TutorialPlayer.swift).
import type { Firmware } from "./store";

export type Action = { press?: string; hold?: string; release?: string; turn?: string; clicks?: number; note?: string; ms?: number; wait?: number };
/** SLOOP's song mode from the TRACKS screen: SAVE opens the SONG screen, OCT− toggles loop / song (SLOOP starts in
 *  loop mode), PLAY plays the sections in the song's order. */
export const PLAY_THE_SONG: Action[] = [{ press: "SAVE" }, { wait: 700 }, { press: "OCT-" }, { wait: 500 }, { press: "PLAY" }];
export interface Await { press?: string[]; turn?: string; anyNote?: boolean; hint?: string }
export interface Step { title: string; text: string; highlight?: string[]; show?: Action[]; await?: Await }
export interface Tutorial {
  format: number; id: string; title: string; summary?: string; firmwareVersion?: string; reviewed?: boolean; author?: string;
  sources?: string[]; setup?: Action[]; steps: Step[];
  match: { sha256?: string[]; repos?: string[]; productPrefixes?: string[]; families?: string[]; names?: string[] };
}

const files = import.meta.glob("../../Tutorials/*.json", { eager: true, import: "default" }) as Record<string, Tutorial>;
export const TUTORIALS: Tutorial[] = Object.values(files).filter((t) => t?.format === 1 && Array.isArray(t.steps));

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
function matches(t: Tutorial, f: Firmware) {
  const m = t.match;
  return !!(m.sha256?.includes(f.sha256) || m.families?.includes(f.family) || (f.repo && m.repos?.some((r) => eq(r, f.repo)))
    || m.productPrefixes?.some((p) => f.product.startsWith(p)) || m.names?.some((n) => f.name.toLowerCase().includes(n.toLowerCase())));
}
export function tutorialFor(f: Firmware): Tutorial | undefined {
  return TUTORIALS.find((t) => f.sha256 && t.match.sha256?.includes(f.sha256))
    ?? TUTORIALS.find((t) => f.repo && t.match.repos?.some((r) => eq(r, f.repo)))
    ?? TUTORIALS.find((t) => matches(t, f));
}

/** "C4" -> "#60"; panel names unchanged. */
export function canonical(name: string): string {
  const pcs: Record<string, number> = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
  const m = /^([A-Ga-g])([#b]?)(-?\d)$/.exec(name);
  if (!m) return name;
  return "#" + ((+m[3] + 1) * 12 + pcs[m[1].toUpperCase()] + (m[2] === "#" ? 1 : m[2] === "b" ? -1 : 0));
}

/** Tracks the user's touches for a step's await. */
export class AwaitTracker {
  private held = new Set<string>();
  done: boolean;
  constructor(readonly a: Await | undefined) { this.done = !a; }
  /** A control touched: panel names ("PLAY", "turn:KNOB1") or notes ("#60"). True when this completed the await. */
  event(name: string, down: boolean): boolean {
    if (!down) { this.held.delete(name); return false; }
    this.held.add(name);
    const a = this.a;
    if (!a || this.done) return false;
    if (a.turn && (name === "turn:" + a.turn || name === a.turn)) this.done = true;
    if (a.anyNote && name.startsWith("#")) this.done = true;
    if (a.press?.length && name === canonical(a.press[a.press.length - 1]) && a.press.slice(0, -1).map(canonical).every((n) => this.held.has(n))) this.done = true;
    return this.done;
  }
}

export function awaitText(a?: Await): string | null {
  if (!a) return null;
  return a.hint ?? (a.press ? "Press " + a.press.join(" + ") : a.turn ? "Turn " + a.turn : a.anyNote ? "Play any note" : null);
}

export type Dock = "bottom" | "top" | "left" | "right";
