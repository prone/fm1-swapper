// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Puts a SLOOP song into an emulator save (mirrors SLOOPFlash.swift): written the way SLOOP's storage.c writes it
// (an A/B pair of 4 KB sectors per object: payload at +256, a 32-byte commit header at +0 with "FELU", type, copy,
// seq, length, CRC-32s; the valid copy with the highest seq wins; a save writes the other copy with seq + 1).
// Sections A-D are objects 1-4, the loop in progress object 7, the settings object 0 (only its song order changes).
import { DeviceArchive, SLOOPArchive, SLOOP_FORMAT, partBytes, toB64, fromB64 } from "./archive";
import { crc32, le32 as u32 } from "./sysex";
import { FM1Error } from "./ota";
import { readOrder, writeOrder } from "./sloopsong";

export const SECTOR = 4096;
const MAGIC = 0x554c4546, PAYLOAD = 256, SIDE = 64;
const SETTINGS = 0, PROJECT0 = 1, AUTOSAVE = 7;
export type Sectors = Map<number, Uint8Array>;

const sectorOf = (obj: number, copy: number) =>
  obj === SETTINGS ? 0xfc000 + copy * SECTOR : obj === AUTOSAVE ? (copy ? 0xfe000 : 0x9f000) : 0x97000 + (obj - PROJECT0) * 2 * SECTOR + copy * SECTOR;

function header(s: Sectors, obj: number, copy: number): { seq: number; len: number } | null {
  const b = s.get(sectorOf(obj, copy));
  if (!b) return null;
  const len = u32(b, 12);
  if (u32(b, 0) !== MAGIC || (b[4] | (b[5] << 8)) !== obj || (b[6] | (b[7] << 8)) !== copy || len > SECTOR - PAYLOAD ||
      u32(b, 28) !== crc32(b.subarray(0, 28)) || u32(b, 16) !== crc32(b.subarray(PAYLOAD, PAYLOAD + len))) return null;
  return { seq: u32(b, 8), len };
}
function current(s: Sectors, obj: number) {
  const a = header(s, obj, 0), b = header(s, obj, 1);
  if (b && (!a || b.seq > a.seq)) return { copy: 1, h: b };
  return a ? { copy: 0, h: a } : null;
}
export function readObject(s: Sectors, obj: number): Uint8Array | null {
  const c = current(s, obj);
  return c ? s.get(sectorOf(obj, c.copy))!.slice(PAYLOAD, PAYLOAD + c.h.len) : null;
}
export function writeObject(s: Sectors, obj: number, payload: Uint8Array, keepSide = false) {
  if (payload.length > SECTOR - PAYLOAD) throw new FM1Error("badpkg", "A song part is too large for SLOOP's flash.");
  const cur = current(s, obj), copy = cur?.copy === 0 ? 1 : 0;
  const b = new Uint8Array(SECTOR).fill(0xff);
  b.set(payload, PAYLOAD);
  if (keepSide && cur) b.set(s.get(sectorOf(obj, cur.copy))!.subarray(SIDE, PAYLOAD), SIDE);
  const h = new Uint8Array(32), v = new DataView(h.buffer);
  v.setUint32(0, MAGIC, true); v.setUint16(4, obj, true); v.setUint16(6, copy, true);
  v.setUint32(8, ((cur?.h.seq ?? 0) + 1) >>> 0, true); v.setUint32(12, payload.length, true); v.setUint32(16, crc32(payload), true);
  v.setUint32(20, 0xffffffff, true); v.setUint32(24, 0xffffffff, true); v.setUint32(28, crc32(h.subarray(0, 28)), true);
  b.set(h, 0);
  s.set(sectorOf(obj, copy), b);
}

/** The song's loop, sections A-D (an empty one: a record of length 0) and song order written over the sectors. */
export function putSong(song: DeviceArchive, s: Sectors) {
  if (song.format !== SLOOP_FORMAT) throw new FM1Error("badpkg", "This isn't a SLOOP song.");
  SLOOPArchive.restoreOrder(song);
  const part = (id: string) => song.parts.find((p) => p.id === id);
  const loop = part("0");
  if (loop?.data) writeObject(s, AUTOSAVE, partBytes(loop));
  for (let i = 0; i < 4; i++) { const p = part(String(i + 2)); writeObject(s, PROJECT0 + i, p?.data ? partBytes(p) : new Uint8Array()); }
  const sp = part("1"), settings = sp?.data ? partBytes(sp) : null, order = settings && readOrder(settings);
  if (!settings || !order) return;
  const mine = readObject(s, SETTINGS);
  if (mine && readOrder(mine)) writeObject(s, SETTINGS, writeOrder(order, mine), true);
  else writeObject(s, SETTINGS, settings);
}

/** fm1-emu's save file (persistence.js exportSave) for `pkg`, with these sectors and the package inside. */
export function emulatorSaveText(pkg: Uint8Array, hash: string, name: string, s: Sectors): string {
  if (s.size > 256) throw new FM1Error("badpkg", "Too many flash sectors for an emulator save.");
  return JSON.stringify({ format: "fm1-emulator-save", version: 1, hash, name, package: toB64(pkg),
    sectors: [...s.keys()].sort((a, b) => a - b).map((at) => ({ at, data: toB64(s.get(at)!) })) });
}
/** The sectors of an emulator save, checked as fm1-emu checks them (aligned, in range, 4 KB each, 256 at most). */
export function sectorsOfSave(text: string): Sectors {
  const j = JSON.parse(text);
  if (j?.format !== "fm1-emulator-save" || !Array.isArray(j.sectors) || j.sectors.length > 256) throw new FM1Error("badpkg", "Not an emulator save.");
  const s: Sectors = new Map();
  for (const x of j.sectors) {
    const data = typeof x?.data === "string" ? fromB64(x.data) : null;
    if (!Number.isInteger(x?.at) || x.at < 0 || x.at >= 1 << 20 || x.at % SECTOR || s.has(x.at) || data?.length !== SECTOR) {
      throw new FM1Error("badpkg", "The emulator save is damaged.");
    }
    s.set(x.at, data);
  }
  return s;
}

/** The sectors fm1-emu keeps for a package in this browser (its IndexedDB "fm1-emulator", same origin), if any. */
export async function emulatorSectors(hash: string): Promise<Sectors> {
  try {
    const db = await new Promise<IDBDatabase>((res, rej) => {
      const r = indexedDB.open("fm1-emulator");
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
      r.onupgradeneeded = () => { r.transaction?.abort(); };
    });
    if (!db.objectStoreNames.contains("states")) { db.close(); return new Map(); }
    const state = await new Promise<{ sectors?: { at: number; data: Uint8Array }[] } | undefined>((res, rej) => {
      const t = db.transaction("states", "readonly"), q = t.objectStore("states").get(hash);
      t.oncomplete = () => res(q.result); t.onerror = () => rej(t.error);
    });
    db.close();
    const out: Sectors = new Map();
    for (const x of state?.sectors ?? []) if (x.data instanceof Uint8Array && x.data.length === SECTOR && x.at % SECTOR === 0) out.set(x.at, x.data.slice());
    return out;
  } catch { return new Map(); }
}
