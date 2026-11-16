// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Tests with a virtual FM-1 (mirrors Packages/FM1Kit/Tests/FM1KitTests/Simulator.swift).
import { describe, expect, it } from "vitest";
import { crc32, le32Bytes, maskPack, maskUnpack, pack7, u32From7, u32To7, unpack7, unpack7Strict } from "./sysex";
import { familyOf, logicalImage, parseIdentity, readPackage } from "./package";
import { DEFAULT_TIMING, FM1Error, HANDSHAKE, Timing, UPGRADE, Updater, identityReply, parseIdentityReply, parseRequest, request } from "./ota";
import { Inbox, PortCandidate, PortProvider, SysExLink } from "./midi";
import { DeviceArchive, FELUCCA_IDS, FM1OpenArchive, FeluccaArchive, captureArchive, part, partBytes, readArchiveFile, restoreArchive } from "./archive";

const FAST: Timing = { ...DEFAULT_TIMING, replyDelay: 0, afterUpgrade: 5, beforeLoader: 5, beforeReboot: 5, idleCheck: 800, idleWrite: 1500, waitLoader: 1500, waitReboot: 1500, poll: 20, handshake: 150 };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function makePackage(product: string, size = 60_000): Uint8Array {
  const raw = new Uint8Array(size);
  for (let i = 0; i < size; i++) raw[i] = (i * 131 + 7) & 0xff;
  const chars = [...product].map((c) => c.charCodeAt(0));
  for (let i = 0; i < 20; i++) raw[i * 0x30 + 0x2f] = i < chars.length ? (chars[i] + i + 1) & 0xff : 0x7d;
  return raw;
}

class VirtualFM1 {
  loader = false; attached = true; installed: Uint8Array | null = null;
  expectedSize = 0; newIdentity = ""; dropAfter = -1;
  refuse: "" | "app" | "loader" = "";   // a firmware/loader that doesn't know the flash chip answers nothing
  fromHost = new Inbox();
  link: SimLink | null = null;
  felucca = new Map<number, Uint8Array>();
  open = { project: new Uint8Array(4264).map((_, i) => (i * 7) & 0xff), timbres: [...Array(8)].map((_, t) => new Uint8Array(223).fill(t)),
    dx7: [...Array(4)].map((_, g) => new Uint8Array(4096).map((_, i) => (i + g) & 0x7f)), samples: new Uint8Array(300).map((_, i) => i & 0xff) };
  private put: { id: number; size: number; crc: number; buf: number[] } | null = null;
  private transfer: { kind: number; target: number; buf: number[] } | null = null;
  private sampleIn: number[] = [];
  constructor(public identity: string) {}
  get current() { return this.loader ? "ota-" + this.identity.split("_")[0] + "_001" : this.identity; }
  reply(m: number[]) { this.link?.toHost.push(m); }

  handle(m: number[]) {
    if (m.join() === HANDSHAKE.join()) return this.reply(identityReply(this.current));
    if (m.join() === UPGRADE.join()) { void this.runUpdate(); return; }
    if (m[1] === 0x7d && m[2] === 0x46 && m[3] === 0x4c) return this.feluccaCmd(m[4], m.slice(5, -1));
    if (m[1] === 0x7d && m[2] === 0x46 && m[3] === 0x4d) return this.openCmd(m);
    if (!parseRequest(m)) this.fromHost.push(m);
  }

  async fetch(addr: number, len: number) {
    this.reply(request(addr, len));
    const r = await this.fromHost.read(2000);
    if (!r) return null;
    const u = unpack7(r.slice(1, -1));
    return u.slice(14, 14 + len);
  }

  async runUpdate() {
    if (this.refuse === "app" && !this.loader) return;
    if (this.refuse === "loader" && this.loader) return;
    if (!this.loader) {
      for (let a = 0; a < 4096; a += 512) if (!(await this.fetch(a, 512))) return;
      await this.fetch(0xe0000000, 8);
      this.loader = true; await this.reattach();
    } else {
      const img: number[] = [];
      let n = 0;
      while (img.length < this.expectedSize) {
        if (this.dropAfter >= 0 && n >= this.dropAfter) { this.dropAfter = -1; return; }
        const c = await this.fetch(img.length, Math.min(512, this.expectedSize - img.length));
        if (!c) return;
        img.push(...c); n++;
      }
      await this.fetch(0xf0000000, 8);
      this.installed = Uint8Array.from(img); this.loader = false; this.identity = this.newIdentity || this.identity;
      await this.reattach();
    }
  }
  async reattach() { this.attached = false; await sleep(30); this.attached = true; }

  feluccaCmd(cmd: number, a: number[]) {
    const send = (p: number[]) => this.reply([0xf0, 0x7d, 0x46, 0x4c, cmd, ...p, 0xf7]);
    if (cmd === 1) return send([...[..."FELUCCA 1.8.2"].map((c) => c.charCodeAt(0)), 0, 1, 0, 0, 0, 0, ...[..."FM6"].map((c) => c.charCodeAt(0)), 0, 0, 16, 0x55, 1, 0, 0x4d, 1, 0, 0, 0x42, 1, 1]);
    if (cmd === 65) {
      const p = [1, 0, FELUCCA_IDS.length];
      for (const id of FELUCCA_IDS) { const o = this.felucca.get(id) ?? new Uint8Array(); p.push(id, ...u32To7(o.length), ...u32To7(o.length ? crc32(o) : 0)); }
      return send(p);
    }
    if (cmd === 66) {
      const id = a[0], off = u32From7(a, 1), size = a[6] | (a[7] << 7), o = this.felucca.get(id)!;
      return send([id, 0, ...u32To7(off), size & 127, size >> 7, ...maskPack(o.subarray(off, off + size))]);
    }
    if (cmd === 67) {
      const op = a[0], id = a[1];
      if (op === 0) this.put = { id, size: u32From7(a, 2), crc: u32From7(a, 7), buf: [] };
      if (op === 1) { const off = u32From7(a, 2); this.put!.buf.push(...maskUnpack(a.slice(7), Math.min(256, this.put!.size - off))); }
      if (op === 2) this.felucca.set(id, Uint8Array.from(this.put!.buf));
      return send([op, id, 0]);
    }
    if (cmd === 11) { this.sampleIn = []; return send([a[0], 0]); }
    if (cmd === 12) { const n = a.length - 4; this.sampleIn.push(...maskUnpack(a.slice(4), n - Math.ceil(n / 8))); return send([a[0], 0]); }
    if (cmd === 13) { this.felucca.set(32 + a[0], Uint8Array.from([...maskUnpack(a.slice(1), 480), ...new Array(32).fill(0), ...this.sampleIn])); return send([a[0], 0]); }
    if (cmd === 14) { this.felucca.set(32 + a[0], new Uint8Array()); return send([a[0], 0]); }
  }

  openCmd(m: number[]) {
    const cmd = m[5], d = unpack7Strict(m.slice(8, -2))!;
    let out: number[] = [], status = 0;
    const kinds: Record<number, () => Uint8Array> = { 0: () => this.open.project.subarray(0, 4064), 3: () => this.open.project, 2: () => this.open.timbres[d[1]], 4: () => this.open.dx7[d[1]] };
    switch (cmd) {
      case 0: out = [4, 16, 3, 0xe0, 0x0f, 0, 1, 1, 1, 1, 1, 1, 1, 1]; break;
      case 9: out = [...`SLOT ${d[0]}`.padEnd(12)].map((c) => c.charCodeAt(0)); break;
      case 11: out = [2, ...le32Bytes(this.open.samples.length), 0, 0, 16, 0]; break;
      case 12: this.sampleIn = []; break;
      case 13: this.sampleIn.push(...d.slice(4)); break;
      case 14: this.open.samples = Uint8Array.from(this.sampleIn); break;
      case 15: { const at = d[0] | (d[1] << 8); out = [...this.open.samples.subarray(at, at + d[4])]; break; }
      case 21: out = [1, 0xa8, 0x10, 0, 0, 0, 0]; break;
      case 22: out = [1, 128, 4, 1, 0, 0, 0, 0, 3]; break;
      case 1: { const b = kinds[d[0]](); this.transfer = { kind: d[0], target: d[1], buf: [...b] }; out = [b.length & 0xff, b.length >> 8]; break; }
      case 2: { const at = d[0] | (d[1] << 8); out = this.transfer!.buf.slice(at, at + d[2]); break; }
      case 3: this.transfer = { kind: d[0], target: d[1], buf: [] }; break;
      case 4: this.transfer!.buf.push(...d.slice(2)); break;
      case 5: {
        const t = this.transfer!, b = Uint8Array.from(t.buf);
        if ((d[0] | (d[1] << 8) | (d[2] << 16) | (d[3] << 24)) >>> 0 !== crc32(b)) { status = 71; break; }
        if (t.kind === 0) this.open.project = b; if (t.kind === 2) this.open.timbres[t.target] = b; if (t.kind === 4) this.open.dx7[t.target] = b;
        break;
      }
      case 6: this.transfer = null; break;
      default: status = 71;
    }
    const r = [...m.slice(0, 8)]; r[5] |= 64; r.push(...pack7([status, ...out]));
    const sum = r.slice(1).reduce((s, b) => s + b, 0);
    this.reply([...r, (128 - (sum % 128)) % 128, 0xf7]);
  }
}

class SimLink implements SysExLink {
  toHost = new Inbox(); closed = false;
  constructor(readonly name: string, private dev: VirtualFM1) {}
  send(b: number[]) { if (this.lost) return false; this.dev.handle(b); return true; }
  read(ms: number) { return this.toHost.read(ms); }
  drain() { this.toHost.drain(); }
  get lost() { return this.closed || !this.dev.attached; }
  close() { this.closed = true; }
}

class SimProvider implements PortProvider {
  constructor(private dev: VirtualFM1) {}
  candidates(): PortCandidate[] { return [{ id: "iac", name: "IAC Bus" }, ...(this.dev.attached ? [{ id: "fm1", name: this.dev.loader ? "OTA Composite" : "FM-1" }] : [])]; }
  async open(c: PortCandidate) { if (c.id !== "fm1" || !this.dev.attached) throw new Error("gone"); const l = new SimLink(c.name, this.dev); this.dev.link = l; return l; }
}

describe("codecs", () => {
  it("round-trips pack7 and mask packing, CRC-32 and 7-bit numbers", () => {
    for (const n of [0, 1, 7, 8, 513]) {
      const d = [...Array(n)].map((_, i) => (i * 37 + 11) & 0xff);
      expect(unpack7(pack7(d))).toEqual(d);
      expect(unpack7Strict(pack7(d))).toEqual(d);
      expect([...maskUnpack(maskPack(d), n)]).toEqual(d);
    }
    expect(crc32([..."123456789"].map((c) => c.charCodeAt(0)))).toBe(0xcbf43926);
    for (const v of [0, 300, 81920, 0xffffffff]) expect(u32From7(u32To7(v))).toBe(v);
    expect(parseRequest(request(0x1234, 512, 3))).toEqual({ flags: 3, addr: 0x1234, len: 512 });
    expect(parseIdentityReply(identityReply("FM-1_918"))?.text).toBe("FM-1_918");
  });

  it("reads packages and identities", async () => {
    const p = await readPackage(makePackage("FM-1_918"));
    expect(p.product).toBe("FM-1_918");
    expect(logicalImage(p.bytes).length).toBe(p.bytes.length - 20);
    expect(familyOf(parseIdentity("FM-1_8000014")!)).toBe("fm1Open");
    expect(familyOf(parseIdentity("ota-FM-1_001")!)).toBe("updateLoader");
    await expect(readPackage(new Uint8Array(10))).rejects.toThrow();
  });
});

describe("update", () => {
  it("installs a package end to end", async () => {
    const pkg = await readPackage(makePackage("FM-1_918"));
    const dev = new VirtualFM1("FM-1_015");
    dev.expectedSize = pkg.bytes.length - 20; dev.newIdentity = "FM-1_918";
    const id = await new Updater(new SimProvider(dev), FAST).install(pkg);
    expect(id.text).toBe("FM-1_918");
    expect(dev.installed).toEqual(logicalImage(pkg.bytes));
  });

  it("goes via V15: two installs in a row, each verified", async () => {
    const v15 = await readPackage(makePackage("FM-1_015", 50_000));
    const target = await readPackage(makePackage("FM-1_918"));
    const dev = new VirtualFM1("FM-1_8000014");
    const up = new Updater(new SimProvider(dev), FAST);
    dev.expectedSize = v15.bytes.length - 20; dev.newIdentity = "FM-1_015";
    expect((await up.install(v15)).text).toBe("FM-1_015");
    expect(dev.installed).toEqual(logicalImage(v15.bytes));
    dev.expectedSize = target.bytes.length - 20; dev.newIdentity = "FM-1_918";
    expect((await up.install(target)).text).toBe("FM-1_918");
    expect(dev.installed).toEqual(logicalImage(target.bytes));
  }, 20_000);

  it("refuses a package for another model", async () => {
    const pkg = await readPackage(makePackage("SMK-37_100"));
    const dev = new VirtualFM1("FM-1_015");
    await expect(new Updater(new SimProvider(dev), FAST).install(pkg)).rejects.toMatchObject({ code: "model" });
    expect(dev.installed).toBeNull();
  });

  it("resumes an interrupted write", async () => {
    const pkg = await readPackage(makePackage("FM-1_8000014"));
    const dev = new VirtualFM1("FM-1_015");
    dev.expectedSize = pkg.bytes.length - 20; dev.newIdentity = "FM-1_8000014"; dev.dropAfter = 20;
    const up = new Updater(new SimProvider(dev), FAST);
    await expect(up.install(pkg)).rejects.toBeInstanceOf(FM1Error);
    expect(dev.loader).toBe(true);
    expect((await up.resume(pkg))?.text).toBe("FM-1_8000014");
    expect(dev.installed).toEqual(logicalImage(pkg.bytes));
  }, 20_000);
});

describe("flash chip refusals", () => {
  it("explains a firmware that won't start an update, and writes nothing", async () => {
    const pkg = await readPackage(makePackage("FM-1_918"));
    const dev = new VirtualFM1("FM-1_915"); dev.refuse = "app";
    const e = await new Updater(new SimProvider(dev), FAST).install(pkg).catch((x) => x);
    expect(e).toMatchObject({ code: "refused" });
    expect(String(e.message)).toContain("0xB36014");
    expect(dev.installed).toBeNull();
  });

  it("explains an update loader that won't write", async () => {
    const pkg = await readPackage(makePackage("FM-1_918"));
    const dev = new VirtualFM1("FM-1_015"); dev.refuse = "loader";
    const e = await new Updater(new SimProvider(dev), FAST).install(pkg).catch((x) => x);
    expect(e).toMatchObject({ code: "refused" });
    expect(dev.loader).toBe(true);
  }, 20_000);
});

describe("archives", () => {
  const connect = async (dev: VirtualFM1) => (await new Updater(new SimProvider(dev), FAST).find())!;

  it("captures and restores a Felucca archive, and reads Felucca's own file format", async () => {
    const dev = new VirtualFM1("FM-1_918");
    for (const id of FELUCCA_IDS) if (id < 32) dev.felucca.set(id, new Uint8Array(id < 2 ? 3000 : 700).map((_, i) => (i + id) & 0xff));
    dev.felucca.set(32, new Uint8Array(2000).map((_, i) => i & 0xff));
    const d = await connect(dev);
    const a = await captureArchive(d, "felucca", true, () => {});
    expect(a.parts.length).toBe(FELUCCA_IDS.length);
    const again = readArchiveFile(FeluccaArchive.toNativeJSON(a));
    expect(again.parts.map((p) => p.data)).toEqual(a.parts.map((p) => p.data));
    const before = new Map(dev.felucca);
    dev.felucca.clear();
    await restoreArchive(readArchiveFile(JSON.stringify(a)), d, "felucca", true, () => {});
    for (const id of FELUCCA_IDS) if (id < 32) expect(dev.felucca.get(id) ?? new Uint8Array()).toEqual(before.get(id) ?? new Uint8Array());
    expect([...dev.felucca.get(32)!.subarray(512)]).toEqual([...before.get(32)!.subarray(512)]);
  });

  it("captures and restores an FM1 Open archive", async () => {
    const dev = new VirtualFM1("FM-1_8000014");
    const d = await connect(dev);
    const a = await captureArchive(d, "fm1Open", true, () => {});
    expect(a.parts.filter((p) => p.id.startsWith("timbre")).length).toBe(8);
    const orig = { ...dev.open };
    dev.open = { project: new Uint8Array(), timbres: [], dx7: [], samples: new Uint8Array() };
    await restoreArchive(a, d, "fm1Open", true, () => {});
    expect(dev.open.project).toEqual(orig.project);
    expect(dev.open.dx7).toEqual(orig.dx7);
    expect(dev.open.samples).toEqual(orig.samples);
  });

  it("rejects bad backups before writing", () => {
    const bad: DeviceArchive = { format: "fm1open-backup", family: "fm1Open", firmware: "x", created: 0, info: {}, parts: [part("project", "p", new Uint8Array(70000))] };
    expect(() => FM1OpenArchive.validate(bad)).toThrow();
    const objs = FELUCCA_IDS.map((id) => ({ id, size: 0, crc: -1, data: "" }));
    expect(() => readArchiveFile(JSON.stringify({ format: "felucca-backup", version: 1, objects: objs }))).toThrow();
    expect(partBytes(part("x", "x", new Uint8Array([1, 2, 3])))).toEqual(new Uint8Array([1, 2, 3]));
  });

  it("reads an archive written by the iOS app", () => {
    // DeviceArchive as Swift's JSONEncoder writes it: base64 Data, seconds since 1970
    const swift = { format: "fm1open-backup", family: "fm1Open", firmware: "FM-1_8000014", created: 1794815000.5, info: { identity: "FM-1_8000014" },
      parts: [{ id: "timbre-0", label: "Track 1 timbre", data: btoa(String.fromCharCode(...new Uint8Array(223))), crc: crc32(new Uint8Array(223)) }] };
    expect(readArchiveFile(JSON.stringify(swift)).parts[0].id).toBe("timbre-0");
  });
});
