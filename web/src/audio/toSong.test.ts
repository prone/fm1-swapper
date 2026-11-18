// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { describe, expect, it } from "vitest";
import { DeviceArchive, SLOOP_FORMAT, part, sloopLabel } from "../fm1kit/archive";
import { Pattern, SongDoc, fnv, writeOrder } from "../fm1kit/sloopsong";
import { DEFAULT_TRACKS, applyImport } from "./toSong";

function project(): Uint8Array {
  const b = new Uint8Array(3816), v = new DataView(b.buffer);
  v.setUint32(0, 0x46554e36, true); v.setUint32(4, 3816, true); b[8] = 120;
  for (let k = 0; k < 4; k++) { const t = 76 + k * 934; b[t + 58] = 16; b[t + 60] = 0; b[t + 122] = 7; for (let l = 0; l < 24; l++) b[t + 838 + l * 4] = 0xff; }
  v.setUint32(3812, fnv(b.subarray(0, 3812)), true);
  return b;
}
function song(): DeviceArchive {
  const set = new Uint8Array(88); set.set([0x33, 0x52, 0x45, 0x50]);
  const parts = [part("0", "Loop in progress", project()), part("1", "Settings", writeOrder({ entries: [{ section: 0, bars: 4 }], loops: false }, set))];
  for (let i = 2; i < 6; i++) parts.push(part(String(i), sloopLabel(i), new Uint8Array()));
  return { format: SLOOP_FORMAT, family: "felucca", firmware: "FELUCCA 2.8.5", created: 0, parts, info: {} };
}

describe("import into a song", () => {
  it("puts each part on its track, keeps the sounds, sets tempo and order", () => {
    const doc = SongDoc.open(song());
    const sec = { start: 0, bpm: 92, bass: [[0, 4, 36]], keys: [[4, 2, [60, 64]]], lead: [[8, 1, 72]], drums: [[0, [0, 4]], [4, [2]]] } as const;
    applyImport(doc, { sections: [sec as never, sec as never], targets: [1, 3], tracks: DEFAULT_TRACKS, tempo: 92, order: true });
    const b = doc.patterns.b!, d = doc.patterns.d!;
    expect(doc.isEmpty("a")).toBe(true);                                      // only the targets change
    for (const p of [b, d]) {
      expect(p.bpm).toBe(92);
      expect(p.track(0).length).toBe(64);
      expect(p.track(0).div).toBe(2);
      expect(p.track(0).chords).toEqual([{ at: 0, length: 4, notes: [36], velocity: 96 }]);
      expect(p.track(1).chords[0].notes).toEqual([60, 64]);
      expect(p.track(2).chords[0]).toMatchObject({ at: 8, notes: [72] });
      expect([p.track(3).drum(0, 0), p.track(3).drum(0, 4), p.track(3).drum(4, 2), p.track(3).drum(4, 0)]).toEqual([true, true, true, false]);
      expect(p.raw[76 + 122]).toBe(7);                                           // a sound byte of track 1: kept
    }
    expect(doc.patterns.loop!.bpm).toBe(92);
    expect(doc.patterns.loop!.track(0).chords[0].notes).toEqual([36]);        // the silent loop: the first piece
    expect(doc.order!.entries).toEqual([{ section: 1, bars: 4 }, { section: 3, bars: 4 }]);
    expect(Pattern.parse(b.data)).not.toBeNull();                                 // SLOOP would load it
  });

  it("skips parts set to Skip and leaves the order alone when asked", () => {
    const doc = SongDoc.open(song());
    const sec = { start: 0, bpm: 92, bass: [[0, 4, 36]], keys: [], lead: [[8, 1, 72]], drums: [] };
    applyImport(doc, { sections: [sec as never], targets: [0], tracks: { ...DEFAULT_TRACKS, lead: null }, tempo: null, order: false });
    expect(doc.patterns.a!.track(2).chords).toEqual([]);
    expect(doc.patterns.a!.track(2).length).toBe(16);                              // untouched
    expect(doc.patterns.a!.bpm).toBe(120);
    expect(doc.order!.entries).toEqual([{ section: 0, bars: 4 }]);
  });
});
