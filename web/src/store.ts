// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The library in the browser (IndexedDB): firmware records, their package files, backups and install history.
// Same fields as the iOS app's SwiftData models. Everything can be exported to one JSON file and imported elsewhere.
import { DeviceArchive, toB64, fromB64 } from "./fm1kit/archive";
import { Family } from "./fm1kit/package";
import { sha256Hex } from "./fm1kit/sysex";

export type TryStatus = "notTried" | "tried" | "favorite" | "keeper" | "notForMe";
export const STATUS_LABEL: Record<TryStatus, string> = { notTried: "Not tried", tried: "Tried", favorite: "Favorite", keeper: "Daily driver", notForMe: "Not for me" };

export interface Firmware {
  id: string; name: string; author: string; version: string; product: string; sha256: string; family: Family;
  sourceURL: string; repo: string; notes: string; summary: string; rating: number; status: TryStatus;
  addedAt: number; fileName: string; size: number; lastInstalledAt?: number; installCount: number;
}
export interface Backup {
  id: string; firmwareId: string; date: number; identity: string; family: Family; label: string;
  kind: "device" | "auto" | "import" | "file" | "song"; sizeBytes: number; partsSummary: string;   // song: a saved SLOOP song
  archive?: DeviceArchive; file?: { name: string; data: string };
}
export interface InstallEvent {
  id: string; firmwareId: string; date: number; from: string; to: string; success: boolean; message: string;
  duration: number; backupTaken: boolean; restored: boolean;
}

/** A whole-flash image read through m-bootloader's MIDI mode (1 MB on the FM-1). */
export interface FlashImage {
  id: string; date: number; unit: string; jedec: number; chipKey: number; firmware: string; mboot: string;
  size: number; crc: number; data: Uint8Array;
}

const DB = "fm1-swapper", VERSION = 2;
const STORES = ["firmwares", "packages", "backups", "installs", "flash"] as const;
type StoreName = (typeof STORES)[number];

let dbp: Promise<IDBDatabase> | null = null;
function db(): Promise<IDBDatabase> {
  dbp ??= new Promise((resolve, reject) => {
    const r = indexedDB.open(DB, VERSION);
    r.onupgradeneeded = () => { for (const s of STORES) if (!r.result.objectStoreNames.contains(s)) r.result.createObjectStore(s); };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  return dbp;
}

async function tx<T>(store: StoreName, mode: IDBTransactionMode, f: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const d = await db();
  // done when the transaction has committed (a write that fails late, e.g. over quota, rejects instead)
  return new Promise((resolve, reject) => {
    const t = d.transaction(store, mode), req = f(t.objectStore(store));
    t.oncomplete = () => resolve(req.result);
    t.onerror = t.onabort = () => reject(t.error ?? req.error ?? new Error("Couldn't save in this browser."));
  });
}

const all = <T>(s: StoreName) => tx<T[]>(s, "readonly", (o) => o.getAll() as IDBRequest<T[]>);
const put = <T>(s: StoreName, key: string, v: T) => tx(s, "readwrite", (o) => o.put(v, key));
const del = (s: StoreName, key: string) => tx(s, "readwrite", (o) => o.delete(key));
const get = <T>(s: StoreName, key: string) => tx<T | undefined>(s, "readonly", (o) => o.get(key) as IDBRequest<T | undefined>);

export const uid = () => crypto.randomUUID();

// change notifications, so screens refresh after any write
const listeners = new Set<() => void>();
export const onChange = (f: () => void) => { listeners.add(f); return () => { listeners.delete(f); }; };
const changed = () => listeners.forEach((f) => f());

export const store = {
  firmwares: () => all<Firmware>("firmwares"),
  backups: () => all<Backup>("backups"),
  installs: () => all<InstallEvent>("installs"),
  /** A package file, re-checked against its SHA-256 on every read (null when missing or not matching): an install
   *  or the emulator never gets bytes other than the ones the checksum names. */
  async packageBytes(sha: string): Promise<Uint8Array | null> {
    const b = await get<Uint8Array>("packages", sha);
    return b && await sha256Hex(b) === sha ? b : null;
  },

  async saveFirmware(f: Firmware, bytes?: Uint8Array) {
    if (bytes) { await put("packages", f.sha256, bytes); f.size = bytes.length; }
    await put("firmwares", f.id, f);
    changed();
  },
  async deleteFirmware(f: Firmware) {
    await del("firmwares", f.id);
    if (f.sha256 && !(await all<Firmware>("firmwares")).some((o) => o.sha256 === f.sha256)) await del("packages", f.sha256);
    for (const b of (await all<Backup>("backups")).filter((b) => b.firmwareId === f.id)) await del("backups", b.id);
    changed();
  },
  async saveBackup(b: Backup) { await put("backups", b.id, b); changed(); },
  async deleteBackup(b: Backup) { await del("backups", b.id); changed(); },
  async saveInstall(e: InstallEvent) { await put("installs", e.id, e); changed(); },
  flashImages: () => all<FlashImage>("flash"),
  async saveFlash(f: FlashImage) { await put("flash", f.id, f); changed(); },
  async deleteFlash(f: FlashImage) { await del("flash", f.id); changed(); },

  /** Everything, packages included, as one JSON file (to move to another browser or keep as a backup). */
  async exportLibrary(): Promise<string> {
    const firmwares = await all<Firmware>("firmwares");
    const packages: Record<string, string> = {};
    for (const f of firmwares) { const b = f.sha256 ? await get<Uint8Array>("packages", f.sha256) : undefined; if (b) packages[f.sha256] = toB64(b); }
    return JSON.stringify({ format: "fm1-swapper-library", version: 1, exported: new Date().toISOString(),
      firmwares, packages, backups: await all<Backup>("backups"), installs: await all<InstallEvent>("installs") });
  },

  /** Adds an exported library to this one (records with the same id are replaced). */
  async importLibrary(text: string) {
    const j = JSON.parse(text);
    if (j?.format !== "fm1-swapper-library" || j.version !== 1) throw new Error("Not an FM-1 Swapper library file.");
    // a package is kept only under its own checksum: a shared library file can't put other bytes behind a trusted SHA
    for (const [sha, b64] of Object.entries(j.packages ?? {})) {
      if (!/^[0-9a-f]{64}$/.test(sha)) continue;
      const bytes = fromB64(String(b64));
      if (await sha256Hex(bytes) === sha) await put("packages", sha, bytes);
    }
    // records of the expected shape only (their text is shown as text; archives are checked again before a restore)
    const str = (v: unknown, max = 500) => typeof v === "string" && v.length <= max;
    for (const f of j.firmwares ?? []) if (str(f?.id) && str(f.name) && /^([0-9a-f]{64})?$/.test(f.sha256 ?? "")) await put("firmwares", f.id, f);
    for (const b of j.backups ?? []) if (str(b?.id) && str(b.label) && ["device", "auto", "import", "file", "song"].includes(b.kind)) await put("backups", b.id, b);
    for (const e of j.installs ?? []) if (str(e?.id) && typeof e.date === "number") await put("installs", e.id, e);
    changed();
    return { firmwares: (j.firmwares ?? []).length, backups: (j.backups ?? []).length };
  },
};
