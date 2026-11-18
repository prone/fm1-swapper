// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { describe, expect, it } from "vitest";
import { DeviceArchive, SLOOPArchive, SLOOP_FORMAT, part, partBytes, sloopLabel } from "./archive";
import { Pattern, SongDoc, fnv, readOrder, writeOrder } from "./sloopsong";

/** A format-6 SLOOP project built byte by byte, as SLOOPSongTests.swift does. */
function project(fill = 0): Uint8Array {
  const b = new Uint8Array(3816);
  const put32 = (v: number, at: number) => { for (let i = 0; i < 4; i++) b[at + i] = (v >>> (8 * i)) & 255; };
  put32(0x46554e36, 0); put32(3816, 4); b[8] = 120;
  for (let k = 0; k < 4; k++) {
    const t = 76 + k * 934;
    b[t + 58] = 16; b[t + 60] = 2; b[t + 122] = fill;
    if (k !== 3) for (let i = 0; i < 64; i++) b[t + 134 + i * 10 + 5] = 2;
    for (let l = 0; l < 24; l++) b[t + 838 + l * 4] = 0xff;
  }
  put32(fnv(b.subarray(0, 3812)), 3812);
  return b;
}
function settings(order = [[0, 4], [1, 4], [2, 4], [3, 4]]) {
  const b = new Uint8Array(88).fill(7); b.set([0x33, 0x52, 0x45, 0x50]);
  return writeOrder({ entries: order.map(([section, bars]) => ({ section, bars })), loops: false }, b);
}
function song(sections = [0]): DeviceArchive {
  const parts = [part("0", "Loop in progress", project()), part("1", "Settings and song order", settings())];
  for (let i = 0; i < 4; i++) parts.push(part(String(i + 2), sloopLabel(i + 2), sections.includes(i) ? project(i + 1) : new Uint8Array()));
  return { format: SLOOP_FORMAT, family: "felucca", firmware: "FELUCCA 2.8.5", created: 0, parts, info: { contents: "song" } };
}

describe("SLOOP songs", () => {
  it("reads a section and keeps the checksum right after edits", () => {
    const p = Pattern.parse(project())!;
    expect(p.bpm).toBe(120);
    expect(p.track(0).length).toBe(16);
    expect(p.track(3).isDrum).toBe(true);
    expect([...p.data]).toEqual([...project()]);
    const bad = project(); bad[200] ^= 1;
    expect(Pattern.parse(bad)).toBeNull();
    p.track(0).place(60, 0, 4);
    expect(Pattern.parse(p.data)!.track(0).chords).toEqual([{ at: 0, length: 4, notes: [60], velocity: 96 }]);
  });

  it("edits notes as SLOOP's piano roll does", () => {
    const t = Pattern.parse(project())!.track(0);
    t.place(60, 0, 4); t.place(64, 0, 1);
    expect(t.chords).toEqual([{ at: 0, length: 4, notes: [60, 64], velocity: 96 }]);
    t.place(67, 2, 4);
    expect(t.chords.map((c) => [c.at, c.length])).toEqual([[0, 2], [2, 4]]);
    t.remove(60, 0); t.remove(64, 0);
    expect(t.chords.map((c) => c.at)).toEqual([2]);
  });

  it("cuts a held chord where a paste lands, as placing a note does", () => {
    const t = Pattern.parse(project())!.track(0), one = Pattern.parse(project())!.track(0);
    t.place(60, 0, 16); one.place(64, 0, 1);
    t.paste(one.copy(0, 1), 4);
    expect(t.chords.map((c) => c.length)).toEqual([4, 1]);
  });

  it("toggles drum lanes", () => {
    const t = Pattern.parse(project())!.track(3);
    t.toggleDrum(9, 4);
    expect(t.step(4)[1]).toBe(0b10);
    t.toggleDrum(9, 4);
    expect([...t.step(4)]).toEqual(new Array(10).fill(0));
  });

  it("copies, inserts and deletes bars with their nudges and locks", () => {
    const t = Pattern.parse(project())!.track(0);
    t.place(60, 0, 2); t.place(62, 8, 1);
    t.raw[774 + 8] = 5; t.raw.set([8, 1, 9, 0], 838);
    const bar = t.copy(0, 16);
    t.insert(bar, 16);
    expect(t.length).toBe(32);
    expect(t.chords.map((c) => c.at)).toEqual([0, 8, 16, 24]);
    expect(t.raw[774 + 24]).toBe(5);
    t.insert(bar, 0);
    expect(t.copy(0, 48).locks.map((l) => l.step).sort((a, b) => a - b)).toEqual([8, 24, 40]);
    t.delete(0, 16);
    expect(t.length).toBe(32);
    expect(t.copy(0, 64).locks.map((l) => l.step).sort((a, b) => a - b)).toEqual([8, 24]);
    t.delete(1, 16);
    expect(t.chords[0]).toEqual({ at: 0, length: 1, notes: [60], velocity: 96 });
    expect(t.paste(Pattern.parse(project())!.track(3).copy(0, 16), 0)).toBe(false);
  });

  it("reads and writes the song order", () => {
    const s = settings([[0, 4], [1, 8]]);
    const o = readOrder(s)!;
    expect(o.entries).toEqual([{ section: 0, bars: 4 }, { section: 1, bars: 8 }]);
    o.entries.push({ section: 2, bars: 64 }); o.loops = true;
    const w = writeOrder(o, s);
    expect([...w.subarray(48, 50)]).toEqual([3, 1]);
    expect([...w.subarray(0, 48)]).toEqual([...s.subarray(0, 48)]);
    expect(readOrder(new Uint8Array(88))).toBeNull();
  });

  it("writes an edited song that restores like any saved song", () => {
    const d = SongDoc.open(song([0]));
    expect(d.emptyEntries).toEqual([1, 2, 3]);
    d.patterns.loop!.track(0).place(60, 0, 1);
    d.copy("loop", "b");
    d.order = { entries: [{ section: 0, bars: 4 }, { section: 1, bars: 2 }], loops: true };
    expect(d.emptyEntries).toEqual([]);
    const a = d.archive();
    expect(() => SLOOPArchive.restoreOrder(a)).not.toThrow();
    const back = SongDoc.open(a);
    expect(back.same(d)).toBe(true);
    expect(back.patterns.b!.track(0).chords[0].notes).toEqual([60]);
    const c = back.clone(); c.erase("b");
    expect(SongDoc.open(c.archive()).isEmpty("b")).toBe(true);
    expect(back.isEmpty("b")).toBe(false);
  });

  it("keeps sections from older SLOOPs as they are", () => {
    const a = song([0]);
    const old = new Uint8Array(3840).fill(1); old.set([0x35, 0x4e, 0x55, 0x46]);
    a.parts[2] = part("2", "Section A", old);
    const d = SongDoc.open(a);
    expect(d.locked.has("a")).toBe(true);
    d.copy("loop", "a");
    expect([...partBytes(d.archive().parts.find((p) => p.id === "2")!)]).toEqual([...old]);
  });
});

describe("song files", () => {
  it("round-trips with its name, keeps only the song, refuses others", async () => {
    const { readSongFile, songFile, sameSong } = await import("./sloopsong");
    const a = song([0, 2]);
    a.parts.push(part("32", "Sample slot USR1", new Uint8Array(100).fill(9)));
    const f = songFile(a, "Night drive");
    expect(f.name).toBe("Night drive.fm1song");
    const back = readSongFile(f.text);
    expect(back.name).toBe("Night drive");
    expect(back.archive.info.name).toBeUndefined();
    expect(back.archive.parts.map((p) => p.id)).toEqual(["0", "1", "2", "3", "4", "5"]);
    expect(sameSong(back.archive, a)).toBe(true);
    expect(() => readSongFile("{}")).toThrow();
    const bad = song(); bad.parts[0] = { ...bad.parts[0], crc: bad.parts[0].crc ^ 1 };
    expect(() => readSongFile(JSON.stringify(bad))).toThrow();
  });
});

describe("a new song", () => {
  it("is SLOOP's starting project, sections empty, default settings", async () => {
    const { blankSong } = await import("./sloopsong");
    const a = blankSong();
    expect(() => SLOOPArchive.restoreOrder(a)).not.toThrow();
    const d = SongDoc.open(a);
    expect(d.patterns.loop!.bpm).toBe(90);
    expect(d.patterns.loop!.track(0).chords).toEqual([]);
    expect(["a", "b", "c", "d"].every((s) => d.isEmpty(s as "a"))).toBe(true);
    expect(d.order!.entries.length).toBe(4);
  });
});
