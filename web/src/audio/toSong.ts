// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Analysed sections into a SLOOP song (the song editor's Import from audio): each section's bass, chords, lead and
// drums onto the tracks chosen, the song's tempo and order if asked. The sounds of the tracks stay as they are.
import { DRUM_TRACK, SongDoc, Slot, sectionSlot } from "../fm1kit/sloopsong";
import { Section } from "./analysis";

export type Part = "bass" | "keys" | "lead" | "drums";
export interface ImportPlan {
  sections: Section[];
  /** Where each section goes (0..3: A..D); same length as `sections`. */
  targets: number[];
  /** The track (0..2, or 3 for drums) each part goes on; null: not imported. */
  tracks: Record<Part, number | null>;
  /** Set every section's (and the loop's) tempo to the song's. */
  tempo: number | null;
  /** Make the song order the imported sections, 4 bars each, in order. */
  order: boolean;
}

export const DEFAULT_TRACKS: Record<Part, number | null> = { bass: 0, keys: 1, lead: 2, drums: DRUM_TRACK };

export function applyImport(doc: SongDoc, plan: ImportPlan) {
  plan.sections.forEach((sec, i) => {
    const slot: Slot = sectionSlot(plan.targets[i]);
    if (doc.locked.has(slot)) return;
    if (!doc.patterns[slot]) doc.copy(doc.patterns.loop ? "loop" : "a", slot);   // (an empty section: the loop's sounds)
    const p = doc.patterns[slot];
    if (!p) return;
    if (plan.tempo) setBpm(p.raw, plan.tempo);
    const track = (part: Part) => {
      const k = plan.tracks[part];
      if (k == null) return null;
      const t = p.track(k);
      t.raw[60] = 2;                                              // DIV 1/16 (p[30], see SLOOPTrack.divAt)
      t.length = sec.lengths?.[part] ?? 64;                       // (a loop's part: its own pattern's length)
      t.clearAll();
      return t;
    };
    const bass = track("bass"), keys = track("keys"), lead = track("lead"), drums = track("drums");
    for (const [st, ln, n] of sec.bass) bass?.place(n, st, ln);
    for (const [st, ln, ns] of sec.keys) for (const n of ns) keys?.place(n, st, ln);
    for (const [st, ln, n] of sec.lead) lead?.place(n, st, ln);
    if (drums?.isDrum) for (const [st, lanes] of sec.drums) for (const l of lanes) drums.toggleDrum(l, st);
  });
  // the loop is what SLOOP plays when it starts: a silent one gets the first piece, so the song plays at once
  const loop = doc.patterns.loop;
  if (plan.targets.length && loop && !doc.locked.has("loop") && [0, 1, 2, 3].every((k) => loop.track(k).isSilent)) doc.copy(sectionSlot(plan.targets[0]), "loop");
  if (plan.tempo && doc.patterns.loop && !doc.locked.has("loop")) setBpm(doc.patterns.loop.raw, plan.tempo);
  if (plan.order && doc.order) doc.order = { loops: doc.order.loops, entries: plan.targets.map((section) => ({ section, bars: 4 })) };
}

/** A section's tempo (g[0], G_BPM: 40..240). */
function setBpm(raw: Uint8Array, bpm: number) {
  const v = Math.max(40, Math.min(240, Math.round(bpm)));
  raw[8] = v & 255; raw[9] = v >> 8;
}
