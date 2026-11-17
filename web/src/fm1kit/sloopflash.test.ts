// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { describe, expect, it } from "vitest";
import { crc32 } from "./sysex";
import { Sectors, emulatorSaveText, putSong, readObject, sectorsOfSave, writeObject } from "./sloopflash";
import { SongDoc, readOrder, writeOrder } from "./sloopsong";
import { DeviceArchive, SLOOP_FORMAT, part, partBytes, sloopLabel } from "./archive";
import { fnv } from "./sloopsong";

function project(fill = 0): Uint8Array {
  const b = new Uint8Array(3816);
  const put32 = (v: number, at: number) => { for (let i = 0; i < 4; i++) b[at + i] = (v >>> (8 * i)) & 255; };
  put32(0x46554e36, 0); put32(3816, 4); b[8] = 120;
  for (let k = 0; k < 4; k++) { const t = 76 + k * 934; b[t + 58] = 16; b[t + 60] = 2; b[t + 122] = fill; for (let l = 0; l < 24; l++) b[t + 838 + l * 4] = 0xff; }
  put32(fnv(b.subarray(0, 3812)), 3812);
  return b;
}
const settings = (order: [number, number][]) => { const b = new Uint8Array(88).fill(7); b.set([0x33, 0x52, 0x45, 0x50]); return writeOrder({ entries: order.map(([section, bars]) => ({ section, bars })), loops: false }, b); };
function song(sections: number[]): DeviceArchive {
  const parts = [part("0", "Loop in progress", project()), part("1", "Settings and song order", settings([[0, 4], [1, 2]]))];
  for (let i = 0; i < 4; i++) parts.push(part(String(i + 2), sloopLabel(i + 2), sections.includes(i) ? project(i + 1) : new Uint8Array()));
  return { format: SLOOP_FORMAT, family: "felucca", firmware: "FELUCCA 2.8.5", created: 0, parts, info: {} };
}

describe("SLOOP song in the emulator's flash", () => {
  it("uses zlib's CRC-32 as storage.c does", () => expect(crc32(new TextEncoder().encode("123456789"))).toBe(0xcbf43926));

  it("writes what SLOOP loads, over the emulator's own settings", () => {
    const base: Sectors = new Map();
    const mine = new Uint8Array(600).fill(0x5a); mine.set(settings([[3, 1]]));
    writeObject(base, 0, mine);
    base.get(0xfc000)!.fill(0x77, 64, 80);
    const a = song([0, 1]);
    const s = sectorsOfSave(emulatorSaveText(new Uint8Array([1]), "a".repeat(64), "SLOOP", base));
    putSong(a, s);
    expect([...readObject(s, 7)!]).toEqual([...partBytes(a.parts[0])]);
    expect([...readObject(s, 2)!]).toEqual([...partBytes(a.parts[3])]);
    expect(readObject(s, 3)!.length).toBe(0);
    const set = readObject(s, 0)!;
    expect(set.length).toBe(600);
    expect(readOrder(set)!.entries).toEqual([{ section: 0, bars: 4 }, { section: 1, bars: 2 }]);
    expect([...s.get(0xfd000)!.subarray(64, 80)]).toEqual(new Array(16).fill(0x77));
    expect(SongDoc.open(a)).toBeTruthy();
  });
});
