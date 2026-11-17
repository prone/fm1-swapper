// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments (Felucca web/fm1backup.js)
// Copyright (C) 2026 FM-1 Swapper contributors (TypeScript port, modified)
// Saved work read from and written back to the FM-1 (mirrors DeviceArchive.swift, FeluccaArchive.swift and
// FM1OpenArchive.swift). The JSON matches the iOS app's, so backups move between the two.
import { Family } from "./package";
import { SysExLink } from "./midi";
import { crc32, le32, le32Bytes, maskPack, maskUnpack, pack7, u32From7, u32To7, unpack7Strict } from "./sysex";
import { FM1Error, Connected } from "./ota";

export interface Part { id: string; label: string; data: string; crc: number }   // data: base64
export interface DeviceArchive {
  format: string; family: Family; firmware: string;
  created: number;                        // seconds since 1970 (as the iOS app stores it)
  parts: Part[]; info: Record<string, string>;
}
export type Progress = (done: number, total: number) => void;

export const toB64 = (b: Uint8Array) => { let s = ""; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };
export const fromB64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export const part = (id: string, label: string, bytes: Uint8Array): Part => ({ id, label, data: toB64(bytes), crc: crc32(bytes) });
export const partBytes = (p: Part) => fromB64(p.data);
export const totalBytes = (a: DeviceArchive) => a.parts.reduce((n, p) => n + Math.floor((p.data.length * 3) / 4), 0);

// ---------------------------------------------------------------- Felucca

export const FELUCCA_IDS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 32, 33, 34];
const FELUCCA_V2 = FELUCCA_IDS.filter((i) => i !== 9), FELUCCA_V1 = FELUCCA_V2.filter((i) => i !== 8);
const feluccaIds = (n: number) => [FELUCCA_IDS, FELUCCA_V2, FELUCCA_V1].find((x) => x.length === n) ?? null;
const feluccaLabel = (id: number) =>
  ({ 0: "Current music", 1: "Settings", 8: "FM6 patch bank (old)", 9: "FM6 user patches", 32: "Sample slot 1", 33: "Sample slot 2", 34: "Sample slot 3" } as Record<number, string>)[id]
  ?? `Saved music ${id - 1}`;

export class FeluccaArchive {
  constructor(private link: SysExLink) {}

  async request(cmd: number, args: number[], timeout = 1200, retries = 0): Promise<number[]> {
    for (let attempt = 0; attempt <= retries; attempt++) {
      this.link.drain();
      if (!this.link.send([0xf0, 0x7d, 0x46, 0x4c, cmd, ...args, 0xf7])) throw new FM1Error("lost", "The FM-1 was disconnected.");
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        const d = await this.link.read(end - Date.now());
        if (!d) break;
        if (d.length >= 6 && d[1] === 0x7d && d[2] === 0x46 && d[3] === 0x4c && d[4] === cmd) return d.slice(5, -1);
      }
    }
    throw new FM1Error("timeout", "Backup timed out. Keep the FM-1 connected and stopped.");
  }

  static check(rc: number) {
    if (!rc) return;
    const m: Record<number, string> = { 1: "Invalid archive object", 2: "Archive data failed validation", 3: "Stop playback first", 4: "Flash write failed", 5: "Start a fresh backup" };
    throw new FM1Error("device", m[rc] ?? `Archive error ${rc}`);
  }

  async info() {
    const a = await this.request(1, []);
    let pos = a.indexOf(0);
    if (pos < 0) throw new Error("Invalid INFO");
    const version = String.fromCharCode(...a.slice(0, pos));
    pos++;
    if (pos >= a.length) return { version, supported: false };
    const engines = a[pos]; pos += 5;
    for (let i = 0; i < engines; i++) { const end = a.indexOf(0, pos); if (end < 0) throw new Error("Invalid INFO"); pos = end + 1; }
    const ext = a.slice(pos + 1);
    const supported = /^FELUCCA /i.test(version) && ext.length > 10 && ext[0] === 16 && ext[1] === 0x55 && ext[2] === 1 &&
      ext[4] === 0x4d && ext[5] === 1 && ext[8] === 0x42 && ext[9] === 1 && (ext[10] & 1) !== 0;
    return { version, supported };
  }

  static manifest(a: number[]) {
    if (a[0] !== 1) throw new Error("Unsupported archive protocol");
    FeluccaArchive.check(a[1]);
    const ids = feluccaIds(a[2]);
    if (!ids || a.length !== 3 + a[2] * 11) throw new Error("Incomplete archive manifest");
    return ids.map((id, i) => {
      const p = 3 + i * 11;
      if (a[p] !== id) throw new Error("Unexpected archive object");
      const size = u32From7(a, p + 1), crc = u32From7(a, p + 6);
      if (size > (id >= 32 ? 81920 : 3840) || (!size && crc)) throw new Error("Archive object too large");
      return { id, size, crc };
    });
  }

  async capture(identity: string, progress: Progress = () => {}): Promise<DeviceArchive> {
    const info = await this.info();
    if (!info.supported) throw new FM1Error("unsupported", `This Felucca (${info.version}) does not support complete backups. Update Felucca first.`);
    const manifest = FeluccaArchive.manifest(await this.request(65, [], 3000));
    const total = manifest.reduce((n, o) => n + o.size, 0);
    let done = 0;
    const parts: Part[] = [];
    for (const o of manifest) {
      const bytes = new Uint8Array(o.size);
      for (let off = 0; off < o.size; off += 256) {
        const size = Math.min(256, o.size - off);
        const a = await this.request(66, [o.id, ...u32To7(off), size & 127, size >>> 7], 1000, 1);
        FeluccaArchive.check(a[1]);
        if (a[0] !== o.id || u32From7(a, 2) !== off || (a[7] | (a[8] << 7)) !== size) throw new Error("Unexpected backup reply");
        bytes.set(maskUnpack(a.slice(9), size), off);
        done += size; progress(done, total);
      }
      if (crc32(bytes) !== o.crc) throw new FM1Error("device", "The FM-1 changed during the backup. Stop playback and try again.");
      parts.push(part(String(o.id), feluccaLabel(o.id), bytes));
    }
    const archive: DeviceArchive = { format: "felucca-backup", family: "felucca", firmware: info.version, created: Date.now() / 1000, parts, info: { identity } };
    FeluccaArchive.validate(archive);
    return archive;
  }

  /** Every part known, in order, within the device's limits, checksum matching. Imported files are untrusted. */
  static validate(a: DeviceArchive) {
    const ids = a.format === "felucca-backup" ? feluccaIds(a.parts.length) : null;
    if (!ids) throw new FM1Error("badpkg", "Not a complete Felucca backup.");
    a.parts.forEach((p, i) => {
      const id = ids[i], b = partBytes(p);
      if (p.id !== String(id)) throw new FM1Error("badpkg", `Unexpected object ${p.id} in the backup.`);
      if (b.length > (id >= 32 ? 81920 : 3840)) throw new FM1Error("badpkg", `Object ${id} is too large.`);
      if (id >= 32 && b.length && b.length < 512) throw new FM1Error("badpkg", "Short sample backup.");
      if (crc32(b) !== p.crc) throw new FM1Error("badpkg", "Backup checksum mismatch.");
    });
    if (!partBytes(a.parts[0]).length || !partBytes(a.parts[1]).length) throw new FM1Error("badpkg", "The backup is missing the current music or settings.");
  }

  async restore(a: DeviceArchive, progress: Progress = () => {}) {
    FeluccaArchive.validate(a);
    const info = await this.info();
    if (!info.supported) throw new FM1Error("unsupported", `This Felucca (${info.version}) cannot restore complete backups. Update Felucca first.`);
    const total = totalBytes(a);
    let done = 0;
    const ask = (cmd: number, args: number[]) => this.request(cmd, args, 4000);
    const put = async (args: number[]) => { const r = await ask(67, args); FeluccaArchive.check(r[2]); return r; };
    // live music last; other objects commit individually
    for (const o of [...a.parts.slice(2), a.parts[1], a.parts[0]]) {
      const id = Number(o.id), bytes = partBytes(o);
      if (id >= 32) {
        const slot = id - 32;
        const checkSample = (r: number[]) => { if (r[0] !== slot) throw new Error("Unexpected sample reply"); FeluccaArchive.check(r[r.length - 1]); };
        if (!bytes.length) { checkSample(await ask(14, [slot])); continue; }
        checkSample(await ask(11, [slot]));
        for (let off = 512; off < bytes.length; off += 256) {
          const c = bytes.subarray(off, off + 256);
          checkSample(await ask(12, [slot, off & 127, (off >> 7) & 127, (off >> 14) & 127, ...maskPack(c)]));
          done += c.length; progress(done, total);
        }
        checkSample(await ask(13, [slot, ...maskPack(bytes.subarray(0, 480))]));
        done += 512; progress(done, total);
        continue;
      }
      const begin = [0, id, ...u32To7(bytes.length), ...u32To7(o.crc)];
      if (id === 9) {
        const r = await ask(67, begin);
        if (r[2] === 1) { done += bytes.length; progress(done, total); continue; }   // firmware before 1.0.3
        FeluccaArchive.check(r[2]);
      } else await put(begin);
      try {
        for (let off = 0; off < bytes.length; off += 256) {
          const c = bytes.subarray(off, off + 256);
          await put([1, id, ...u32To7(off), ...maskPack(c)]);
          done += c.length; progress(done, total);
        }
        await put([2, id]);
      } catch (e) { await put([3, id]).catch(() => {}); throw e; }
    }
  }

  /** A file from Felucca's own installer or editor. */
  static fromNativeJSON(text: string): DeviceArchive {
    const j = JSON.parse(text);
    if (j?.format !== "felucca-backup" || !Array.isArray(j.objects) || !feluccaIds(j.objects.length)) throw new FM1Error("badpkg", "Not a complete Felucca backup.");
    const parts = j.objects.map((o: { id: number; data: string; crc: number }) => {
      if (!Number.isInteger(o.id) || o.id < 0 || o.id > 255 || typeof o.data !== "string" || !Number.isInteger(o.crc) || o.crc < 0 || o.crc > 0xffffffff)
        throw new FM1Error("badpkg", "Backup checksum mismatch.");
      const b = fromB64(o.data);
      if (crc32(b) !== o.crc) throw new FM1Error("badpkg", "Backup checksum mismatch.");
      return part(String(o.id), feluccaLabel(o.id), b);
    });
    const created = Date.parse(j.created);
    const a: DeviceArchive = { format: "felucca-backup", family: "felucca", firmware: String(j.firmware ?? "Felucca"),
      created: Number.isFinite(created) ? created / 1000 : Date.now() / 1000, parts, info: {} };
    FeluccaArchive.validate(a);
    return a;
  }

  static toNativeJSON(a: DeviceArchive): string {
    return JSON.stringify({ format: "felucca-backup", version: 1, firmware: a.firmware, created: new Date(a.created * 1000).toISOString(),
      objects: a.parts.map((p) => ({ id: Number(p.id), size: partBytes(p).length, crc: p.crc, data: p.data })) });
  }
}

// ---------------------------------------------------------------- FM1 Open

const TRACKS = 8, TIMBRE = 223, DX7 = 4096, MAX_SAMPLES = 4 << 20;
enum Kind { project = 0, timbre = 2, tuned = 3, dx7 = 4 }

export class FM1OpenArchive {
  private token = 1;
  constructor(private link: SysExLink) {}

  static message(cmd: number, token: number, data: number[]): number[] {
    const m = [0xf0, 0x7d, 0x46, 0x4d, 0x02, cmd, token & 0x7f, (token >> 7) & 0x7f, ...pack7(data)];
    const sum = m.slice(1).reduce((s, b) => s + b, 0);
    return [...m, (128 - (sum % 128)) % 128, 0xf7];
  }

  static parseReply(m: number[], cmd: number, token: number): number[] | null {
    if (m.length < 10 || m[0] !== 0xf0 || m[m.length - 1] !== 0xf7 || m[1] !== 0x7d || m[2] !== 0x46 || m[3] !== 0x4d || m[4] !== 2) return null;
    if (m[5] !== (cmd | 64) || m[6] !== (token & 0x7f) || m[7] !== ((token >> 7) & 0x7f)) return null;
    if (m.slice(1, -1).reduce((s, b) => s + b, 0) % 128) return null;
    const d = unpack7Strict(m.slice(8, -2));
    return d && d.length ? d : null;
  }

  /** Reply data after the status byte; status 1 ("empty") returns null. */
  async command(cmd: number, data: number[] = [], timeout = 1000, retries = 3): Promise<number[] | null> {
    this.token = this.token >= 16383 ? 1 : this.token + 1;
    const t = this.token, msg = FM1OpenArchive.message(cmd, t, data);
    for (let i = 0; i <= retries; i++) {
      if (!this.link.send(msg)) throw new FM1Error("lost", "The FM-1 was disconnected.");
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        const r = await this.link.read(end - Date.now());
        if (!r) break;
        const d = FM1OpenArchive.parseReply(r, cmd, t);
        if (!d) continue;
        if (d[0] === 0) return d.slice(1);
        if (d[0] === 1) return null;
        throw new FM1Error("device", 64 - d[0] === -7 ? "The FM-1 rejected the data (invalid)." : `FM1 Open error ${64 - d[0]}.`);
      }
    }
    throw new FM1Error("timeout", `The FM-1 did not answer (FM1 Open command ${cmd}). Keep it connected and stopped.`);
  }

  private async read(kind: Kind, target: number): Promise<Uint8Array | null> {
    const r = await this.command(1, [kind, target]);
    if (!r) return null;
    const size = r[0] | (r[1] << 8), out = new Uint8Array(size);
    for (let at = 0; at < size;) {
      const n = Math.min(64, size - at);
      const d = await this.command(2, [at & 0xff, at >> 8, n]);
      if (!d || d.length !== n) throw new Error("Short FM1 Open chunk");
      out.set(d, at); at += n;
    }
    return out;
  }

  private async write(kind: Kind, target: number, bytes: Uint8Array) {
    if (bytes.length > 0xffff) throw new FM1Error("badpkg", "A backup part is too large.");
    await this.command(3, [kind, target, bytes.length & 0xff, bytes.length >> 8]);
    try {
      for (let at = 0; at < bytes.length; at += 64) await this.command(4, [at & 0xff, at >> 8, ...bytes.subarray(at, at + 64)]);
      await this.command(5, le32Bytes(crc32(bytes)), 4000);
    } catch (e) { await this.command(6).catch(() => {}); throw e; }
  }

  async capture(identity: string, includeSamples = true, progress: Progress = () => {}): Promise<DeviceArchive> {
    const status = await this.command(0);
    if (!status || status.length < 3) throw new Error("Short FM1 Open status");
    const caps = await this.command(22).catch(() => null);
    const hasLibrary = !!caps && caps.length >= 4 && caps[3] !== 0;
    const tuning = (await this.command(21).catch(() => null))?.[0] === 1;
    const si = includeSamples ? await this.command(11).catch(() => null) : null;
    const sampleSize = Math.min(si && si.length >= 5 && si[0] === 2 ? le32(si, 1) : 0, MAX_SAMPLES);
    const total = 4300 + TRACKS * TIMBRE + (hasLibrary ? 4 * DX7 : 0) + sampleSize;
    let done = 0;
    const step = (n: number) => { done += n; progress(done, total); };
    const parts: Part[] = [];
    const project = (tuning ? await this.read(Kind.tuned, 0) : null) ?? await this.read(Kind.project, 0);
    if (!project) throw new FM1Error("device", "The FM-1 did not export its current project.");
    parts.push(part("project", "Current project", project)); step(4300);
    for (let t = 0; t < TRACKS; t++) {
      const d = await this.read(Kind.timbre, t);
      if (d) parts.push(part(`timbre-${t}`, `Track ${t + 1} timbre`, d));
      step(TIMBRE);
    }
    if (hasLibrary) for (let g = 0; g < 4; g++) {
      const d = await this.read(Kind.dx7, g);
      if (d) parts.push(part(`dx7-${g}`, `DX7 library group ${"ABCD"[g]}`, d));
      step(DX7);
    }
    const names: string[] = [];
    for (let s = 0; s < Math.min(status[1], 32); s++) {
      const n = await this.command(9, [s]).catch(() => null);
      names.push(n ? String.fromCharCode(...n.slice(0, 12)).trim() : "");
    }
    if (sampleSize > 0) {
      const bank = new Uint8Array(sampleSize);
      for (let at = 0; at < sampleSize;) {
        const n = Math.min(64, sampleSize - at);
        const d = await this.command(15, [...le32Bytes(at), n]);
        if (!d || d.length !== n) throw new Error("Short sample chunk");
        bank.set(d, at); at += n; step(n);
      }
      parts.push(part("samples", "Sample bank", bank));
    }
    return { format: "fm1open-backup", family: "fm1Open", firmware: identity, created: Date.now() / 1000, parts,
      info: { identity, currentSlot: String(status[2]), slotNames: names.join("|") } };
  }

  static validate(a: DeviceArchive) {
    if (a.format !== "fm1open-backup") throw new FM1Error("badpkg", "Not an FM1 Open backup.");
    for (const p of a.parts) {
      const n = partBytes(p).length;
      let ok = false;
      const t = /^timbre-(\d)$/.exec(p.id), g = /^dx7-(\d)$/.exec(p.id);
      if (p.id === "project") ok = [4048, 4064, 4264].includes(n);
      else if (p.id === "samples") ok = n > 0 && n <= MAX_SAMPLES;
      else if (t && +t[1] < TRACKS) ok = n === TIMBRE;
      else if (g && +g[1] < 4) ok = n === DX7;
      if (!ok) throw new FM1Error("badpkg", `Unexpected part ${p.id} (${n} bytes) in the backup.`);
      if (crc32(partBytes(p)) !== p.crc) throw new FM1Error("badpkg", "Backup checksum mismatch.");
    }
  }

  async restore(a: DeviceArchive, includeSamples = true, progress: Progress = () => {}) {
    FM1OpenArchive.validate(a);
    const get = (id: string) => a.parts.find((p) => p.id === id);
    const total = a.parts.filter((p) => includeSamples || p.id !== "samples").reduce((n, p) => n + partBytes(p).length, 0);
    let done = 0;
    const step = (n: number) => { done += n; progress(done, total); };
    const s = get("samples");
    if (includeSamples && s) {
      const bytes = partBytes(s);
      await this.command(12, le32Bytes(bytes.length), 6000);
      try {
        for (let off = 0; off < bytes.length; off += 128) {
          const c = bytes.subarray(off, off + 128);
          await this.command(13, [...le32Bytes(off), ...c], 3000); step(c.length);
        }
        await this.command(14, [], 6000);
      } catch (e) { await this.command(16).catch(() => {}); throw e; }
    }
    for (let g = 0; g < 4; g++) { const p = get(`dx7-${g}`); if (p) { await this.write(Kind.dx7, g, partBytes(p)); step(DX7); } }
    for (let t = 0; t < TRACKS; t++) { const p = get(`timbre-${t}`); if (p) { await this.write(Kind.timbre, t, partBytes(p)); step(TIMBRE); } }
    const pr = get("project");
    if (pr) { const b = partBytes(pr); await this.write(Kind.project, 0, b); step(b.length); }
  }
}

// ---------------------------------------------------------------- SLOOP (mirrors SLOOPArchive.swift)
// isod89/sloop-fm1 firmware/src/editor.c, editor protocol 6+ (SLOOP 2.3 and later, and its forks). Same frame as
// Felucca's archive, its own commands: 34 LIST (snapshots the working project), 35 GET, 36 PUT (begin, data,
// commit; each object checked as a load would and written through SLOOP's A/B commit). Objects: 0 the loop in
// progress, 1 the settings (with the song order), 2-5 sections A-D, 6-7 user presets, 8 FM6 patches, 9 SYN kits,
// 10 MIDI learn, 11 theme, 32-35 sample slots. Sample slots are read but not written back.

export const SLOOP_FORMAT = "sloop-backup";
/** A SLOOP song: the loop in progress, the settings (they hold the song order) and sections A-D. */
export const SLOOP_SONG_IDS = [0, 1, 2, 3, 4, 5];
export function sloopLabel(id: number): string {
  if (id >= 2 && id <= 5) return `Section ${"ABCD"[id - 2]}`;
  if (id >= 32 && id <= 35) return `Sample slot USR${id - 31}`;
  return ({ 0: "Loop in progress", 1: "Settings and song order", 6: "User presets 1–16", 7: "User presets 17–32", 8: "FM6 patches",
    9: "SYN drum kits", 10: "MIDI learn", 11: "Theme" } as Record<number, string>)[id] ?? `Object ${id}`;
}

/** The editor protocol version when INFO is SLOOP-style (ends with the track count and the version, and has no
 *  Felucca archive extension), else null. */
export function sloopProtocol(a: number[]): number | null {
  let pos = a.indexOf(0);
  if (pos < 0 || ++pos >= a.length) return null;
  const engines = a[pos]; pos += 5;
  for (let i = 0; i < engines; i++) { const end = a.indexOf(0, pos); if (end < 0) return null; pos = end + 1; }
  return a.length - pos === 2 && a[pos] >= 1 && a[pos] <= 8 ? a[pos + 1] : null;
}

export class SLOOPArchive {
  private f: FeluccaArchive;
  constructor(link: SysExLink) { this.f = new FeluccaArchive(link); }

  async supported(): Promise<boolean> {
    try { return (sloopProtocol(await this.f.request(1, [])) ?? 0) >= 6; } catch { return false; }
  }

  static manifest(a: number[]) {
    if (a.length < 2) throw new FM1Error("protocol", "Short backup list");
    FeluccaArchive.check(a[0]);
    const n = a[1];
    if (a.length !== 2 + n * 11) throw new FM1Error("protocol", "Incomplete backup list");
    return Array.from({ length: n }, (_, i) => {
      const p = 2 + i * 11, size = u32From7(a, p + 1), crc = u32From7(a, p + 6);
      if (size > 256 * 1024) throw new FM1Error("protocol", "Backup object too large");
      return { id: a[p], size, crc };
    });
  }

  async capture(identity: string, only: number[] | null = null, progress: Progress = () => {}): Promise<DeviceArchive> {
    if (!(await this.supported())) throw new FM1Error("unsupported", "This firmware doesn't have SLOOP's backup (SLOOP 2.3 or later).");
    const manifest = SLOOPArchive.manifest(await this.f.request(34, [], 5000)).filter((o) => !only || only.includes(o.id));
    const total = manifest.reduce((n, o) => n + o.size, 0);
    let done = 0;
    const parts: Part[] = [];
    for (const o of manifest) {
      const bytes = new Uint8Array(o.size);
      for (let off = 0; off < o.size; off += 256) {
        const size = Math.min(256, o.size - off);
        const a = await this.f.request(35, [o.id, ...u32To7(off), size & 127, size >>> 7], 1000, 1);
        if (a.length < 9) throw new FM1Error("protocol", "Short backup reply");
        FeluccaArchive.check(a[1]);
        if (a[0] !== o.id || u32From7(a, 2) !== off || (a[7] | (a[8] << 7)) !== size) throw new FM1Error("protocol", "Unexpected backup reply");
        bytes.set(maskUnpack(a.slice(9), size), off);
        done += size; progress(done, total);
      }
      if (crc32(bytes) !== o.crc) throw new FM1Error("device", "The FM-1 changed during the backup. Stop playback and try again.");
      parts.push(part(String(o.id), sloopLabel(o.id), bytes));
    }
    if (!parts.some((p) => p.id === "0" && p.data) || !parts.some((p) => p.id === "1" && p.data))
      throw new FM1Error("device", "The backup is missing the loop in progress or the settings.");
    const song = !!only && only.length === SLOOP_SONG_IDS.length && SLOOP_SONG_IDS.every((i) => only.includes(i));
    return { format: SLOOP_FORMAT, family: "felucca", firmware: identity, created: Date.now() / 1000, parts, info: { identity, contents: song ? "song" : "all" } };
  }

  /** The size and CRC-32 of each object as the FM-1 has it now (LIST: checksums only, nothing is read out). */
  async checksums(): Promise<Map<number, { size: number; crc: number }>> {
    if (!(await this.supported())) throw new FM1Error("unsupported", "This firmware doesn't have SLOOP's song backup (SLOOP 2.3 or later).");
    return new Map(SLOOPArchive.manifest(await this.f.request(34, [], 5000)).map((e) => [e.id, { size: e.size, crc: e.crc }]));
  }

  /** Whether a saved song holds what the FM-1 has now: the loop and sections A-D (the settings change too often). */
  static matches(song: DeviceArchive, now: Map<number, { size: number; crc: number }>): boolean {
    if (song.format !== SLOOP_FORMAT) return false;
    return [0, 2, 3, 4, 5].every((id) => {
      const p = song.parts.find((x) => x.id === String(id)), have = now.get(id) ?? { size: 0, crc: 0 };   // empty: CRC 0
      return (p ? partBytes(p).length : 0) === have.size && (p?.crc ?? 0) === have.crc;
    });
  }

  /** Clears the song on the FM-1 as SLOOP's own controls would: stops playback, erases every note of the four
   *  tracks (LIVE ERASE, as EDIT + a key; sounds, presets and tempo stay) and empties sections A-D. SLOOP 2.7+. */
  async clearSong(progress: Progress = () => {}) {
    let v: number | null = null;
    try { v = sloopProtocol(await this.f.request(1, [])); } catch { /* below */ }
    if ((v ?? 0) < 12) throw new FM1Error("unsupported", "Clearing from the app needs SLOOP 2.7 or later. On the FM-1: SAVE → TOOLS → NEW, then SECTION → ERASE for A–D.");
    const live = async (args: number[]) => {
      const r = await this.f.request(77, args, 1000, 1);
      if (r.length < 3 || r[0] !== args[0]) throw new FM1Error("protocol", "Unexpected reply from SLOOP");
      return r;
    };
    let state = await live([1, 0]);
    const end = Date.now() + 3000;
    while (state[1] & 3) {
      if (Date.now() > end) throw new FM1Error("device", "SLOOP didn't stop playing. Stop it on the FM-1 and try again.");
      await new Promise((r) => setTimeout(r, 50));
      state = await live([0, 0]);
    }
    const steps = 4 * 128 * 2 + 4;
    let done = 0;
    for (let track = 0; track < 4; track++)
      for (const down of [1, 0])
        for (let note = 0; note < 128; note++) { await live([7, track, note, down]); progress(++done, steps); }
    for (let id = 2; id <= 5; id++) {
      for (const args of [[0, id, ...u32To7(0), ...u32To7(0)], [2, id]]) {
        const r = await this.f.request(36, args, 5000);
        if (r.length < 3 || r[0] !== args[0] || r[1] !== id) throw new FM1Error("protocol", "Unexpected reply from SLOOP");
        FeluccaArchive.check(r[2]);
      }
      progress(++done, steps);
    }
  }

  /** What a restore writes, in order (everything else, then the settings, the loop in progress last); checked first. */
  static restoreOrder(a: DeviceArchive): { id: number; data: Uint8Array; crc: number }[] {
    if (a.format !== SLOOP_FORMAT) throw new FM1Error("badpkg", "This isn't a SLOOP backup.");
    const out: { id: number; data: Uint8Array; crc: number }[] = [];
    for (const p of a.parts) {
      const id = Number(p.id);
      if (!Number.isInteger(id) || id < 0) throw new FM1Error("badpkg", "Damaged backup.");
      if (id > 11) continue;                                              // sample slots: left as they are
      const data = partBytes(p);
      if (crc32(data) !== p.crc) throw new FM1Error("badpkg", `The backup is damaged (${p.label}).`);
      if (id < 2 && !data.length) throw new FM1Error("badpkg", `The backup is missing ${p.label}.`);
      out.push({ id, data, crc: p.crc });
    }
    if (!out.some((o) => o.id === 0)) throw new FM1Error("badpkg", "The backup is missing the loop in progress.");
    const rank = (id: number) => (id === 0 ? 2 : id === 1 ? 1 : 0);
    return out.sort((x, y) => rank(x.id) - rank(y.id));
  }

  static validate(a: DeviceArchive) { SLOOPArchive.restoreOrder(a); }

  async restore(a: DeviceArchive, progress: Progress = () => {}) {
    const order = SLOOPArchive.restoreOrder(a);
    if (!(await this.supported())) throw new FM1Error("unsupported", "This firmware can't restore a SLOOP backup (SLOOP 2.3 or later).");
    const total = order.reduce((n, o) => n + o.data.length, 0);
    let done = 0;
    const put = async (args: number[]) => {
      const r = await this.f.request(36, args, 5000);
      if (r.length < 3 || r[0] !== args[0] || r[1] !== args[1]) throw new FM1Error("protocol", "Unexpected restore reply");
      FeluccaArchive.check(r[2]);
    };
    for (const o of order) {
      await put([0, o.id, ...u32To7(o.data.length), ...u32To7(o.crc)]);
      try {
        for (let off = 0; off < o.data.length; off += 256) {
          const c = o.data.subarray(off, Math.min(off + 256, o.data.length));
          await put([1, o.id, ...u32To7(off), ...maskPack(c)]);
          done += c.length; progress(done, total);
        }
        await put([2, o.id]);
      } catch (e) { try { await put([3, o.id]); } catch { /* already failing */ } throw e; }
    }
  }
}

// ---------------------------------------------------------------- by family

export async function captureArchive(dev: Connected, family: Family, includeSamples: boolean, progress: Progress): Promise<DeviceArchive> {
  switch (family) {
    case "felucca": {
      // SLOOP and its forks answer as Felucca but have their own backup commands.
      const s = new SLOOPArchive(dev.link);
      if (await s.supported()) return s.capture(dev.identity.text, null, progress);
      return new FeluccaArchive(dev.link).capture(dev.identity.text, progress);
    }
    case "fm1Open": return new FM1OpenArchive(dev.link).capture(dev.identity.text, includeSamples, progress);
    case "updateLoader": throw new FM1Error("unsupported", "The FM-1 is in update mode, so nothing can be backed up. Finish the install first.");
    case "official": throw new FM1Error("unsupported", "M-VAVE's official firmware has no backup protocol. Its patterns and settings stay on the device, and are usually erased when other firmware is installed.");
    default:
      try { return await new FeluccaArchive(dev.link).capture(dev.identity.text, progress); } catch { /* try SLOOP's */ }
      {
        const s = new SLOOPArchive(dev.link);
        if (await s.supported()) return s.capture(dev.identity.text, null, progress);
      }
      throw new FM1Error("unsupported", `${dev.identity.text} has no backup protocol this app knows. Save anything important on the device, or use the firmware's own editor.`);
  }
}

export async function restoreArchive(a: DeviceArchive, dev: Connected, family: Family, includeSamples: boolean, progress: Progress) {
  if (a.format === SLOOP_FORMAT) return new SLOOPArchive(dev.link).restore(a, progress);
  if (a.family === "felucca") return new FeluccaArchive(dev.link).restore(a, progress);
  if (a.family === "fm1Open") {
    if (family !== "fm1Open") throw new FM1Error("unsupported", `This backup is for FM1 Open; the FM-1 is running ${dev.identity.text}.`);
    return new FM1OpenArchive(dev.link).restore(a, includeSamples, progress);
  }
  throw new FM1Error("unsupported", "Backups of this kind cannot be written back.");
}

export function readArchiveFile(text: string): DeviceArchive {
  const j = JSON.parse(text);
  if (j?.format === "felucca-backup" && Array.isArray(j.objects)) return FeluccaArchive.fromNativeJSON(text);
  if (typeof j?.format !== "string" || !Array.isArray(j.parts)) throw new FM1Error("badpkg", "Not an FM-1 Swapper backup.");
  const a = j as DeviceArchive;
  if (a.format === SLOOP_FORMAT) SLOOPArchive.validate(a);
  else if (a.family === "felucca") FeluccaArchive.validate(a); else FM1OpenArchive.validate(a);
  return a;
}
