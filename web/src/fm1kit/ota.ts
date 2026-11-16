// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments (Felucca web/fm1ota.js, tools/fm1_install.py)
// Copyright (C) 2026 FM-1 Swapper contributors (TypeScript port, modified)
// The FM-1 USB-MIDI update protocol (mirrors OTAUpdater.swift). Step 1: the running firmware reads parts of
// the package and starts the update loader. Step 2: the loader reads the whole image and writes it. In both
// steps the device asks (cmd 0x30 read requests) and we answer.
import { FirmwarePackage, Identity, isLoader, logicalImage, parseIdentity } from "./package";
import { PortProvider, SysExLink, looksLikeFM1 } from "./midi";
import { le32, le32Bytes, pack7, unpack7 } from "./sysex";

export const HANDSHAKE = [0xf0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7f, 0xf7];
export const UPGRADE = [0xf0, 0x22, 0x24, 0x35, 0x7f, 0xf7];
export const FINISH_CHECK = 0xe0000000, FINISH_WRITE = 0xf0000000, MAX_DATA = 512;

export const RESCUE_URL = "https://thefirmwarehub.com/tools/rescue/#chip";

export class FM1Error extends Error {
  constructor(readonly code: string, message: string) { super(message); }
}

export function response(addr: number, data: ArrayLike<number>, flags = 0): number[] {
  const n = data.length;
  const body = [0x00, 0x59, 0x30, (n + 8) & 0xff, ((n + 8) >> 8) & 0xff, 0, flags, ...le32Bytes(addr), n & 0xff, (n >> 8) & 0xff, 0, ...Array.from(data)];
  let s = 0;
  for (let i = 6; i < body.length; i++) s += body[i];
  body.push(~s & 0xff);
  return [0xf0, ...pack7(body), 0xf7];
}

export interface ReadRequest { flags: number; addr: number; len: number }

export function parseRequest(pkt: number[]): ReadRequest | null {
  if (pkt.length < 2 || pkt[0] !== 0xf0 || pkt[pkt.length - 1] !== 0xf7) return null;
  const u = unpack7(pkt.slice(1, -1));
  if (u.length !== 15 || u[0] !== 0 || u[1] !== 0x59 || u[2] !== 0x30) return null;
  let s = 0;
  for (let i = 6; i < 14; i++) s += u[i];
  if ((~s & 0xff) !== u[14]) return null;
  return { flags: u[6], addr: le32(u, 7), len: u[11] | (u[12] << 8) | (u[13] << 16) };
}

export function request(addr: number, len: number, flags = 0): number[] {
  const u = [0, 0x59, 0x30, 0, 0, 0, flags, ...le32Bytes(addr), len & 0xff, (len >> 8) & 0xff, (len >> 16) & 0xff];
  let s = 0;
  for (let i = 6; i < u.length; i++) s += u[i];
  u.push(~s & 0xff);
  return [0xf0, ...pack7(u), 0xf7];
}

export function parseIdentityReply(pkt: number[]): Identity | null {
  if (pkt.length < 2 || pkt[0] !== 0xf0 || pkt[pkt.length - 1] !== 0xf7) return null;
  const d = unpack7(pkt.slice(1, -1));
  if (d.length !== 34 || d[0] !== 0 || d[1] !== 0x59 || d[2] !== 0x11) return null;
  const txt = d.slice(6, 33).map((c) => (c >= 32 && c < 127 ? String.fromCharCode(c) : c === 0 ? "\0" : "?")).join("").replace(/\0+$/, "");
  return parseIdentity(txt);
}

export function identityReply(text: string): number[] {
  const t = Array.from(new TextEncoder().encode(text)).slice(0, 27);
  while (t.length < 27) t.push(0);
  return [0xf0, ...pack7([0, 0x59, 0x11, 0, 0, 0, ...t, 0]), 0xf7];
}

export interface Connected { link: SysExLink; identity: Identity; portName: string }

export type Step =
  | { kind: "start"; from: string } | { kind: "verify"; n: number } | { kind: "loader" }
  | { kind: "write"; n: number } | { kind: "reboot" } | { kind: "done"; identity: string };

export interface Timing { replyDelay: number; afterUpgrade: number; beforeLoader: number; beforeReboot: number;
  idleCheck: number; idleWrite: number; waitLoader: number; waitReboot: number; poll: number; handshake: number }

export const DEFAULT_TIMING: Timing = { replyDelay: 10, afterUpgrade: 2000, beforeLoader: 3000, beforeReboot: 3000,
  idleCheck: 8000, idleWrite: 180_000, waitLoader: 30_000, waitReboot: 40_000, poll: 1000, handshake: 1000 };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class Updater {
  probeAllPorts = false;
  constructor(readonly provider: PortProvider, readonly timing: Timing = DEFAULT_TIMING, readonly log: (s: string) => void = () => {}) {}

  static expectedRequests(imageSize: number) { return Math.ceil(imageSize / MAX_DATA); }

  private async handshake(link: SysExLink, tries = 3): Promise<Identity | null> {
    link.drain();
    for (let t = 0; t < tries; t++) {
      if (!link.send(HANDSHAKE)) return null;
      const end = Date.now() + this.timing.handshake;
      while (Date.now() < end) {
        const p = await link.read(end - Date.now());
        if (!p) break;
        const id = parseIdentityReply(p);
        if (id) return id;
      }
    }
    return null;
  }

  /** The first port pair that answers the handshake (and passes `filter`). The link is left open. */
  async find(filter: (id: Identity) => boolean = () => true): Promise<Connected | null> {
    for (const c of this.provider.candidates()) {
      if (!this.probeAllPorts && !looksLikeFM1(c.name)) continue;
      let link: SysExLink;
      try { link = await this.provider.open(c); } catch { continue; }
      const id = await this.handshake(link, 2);
      if (id && filter(id)) { this.log(`found ${id.text} on ${c.name}`); return { link, identity: id, portName: c.name }; }
      link.close();
    }
    return null;
  }

  async identify(): Promise<Connected | null> {
    const d = await this.find();
    d?.link.close();
    return d;
  }

  private async waitFor(filter: (id: Identity) => boolean, ms: number): Promise<Connected | null> {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const d = await this.find(filter);
      if (d) return d;
      await sleep(this.timing.poll);
    }
    return null;
  }

  private async serve(link: SysExLink, image: Uint8Array, finish: number, idle: number, progress: (n: number) => void) {
    let served = 0, last = Date.now();
    for (;;) {
      const pkt = await link.read(1000);
      if (!pkt) {
        if (link.lost) return { served, finished: false, lost: true };
        if (Date.now() - last > idle) return { served, finished: false, lost: false };
        continue;
      }
      const r = parseRequest(pkt);
      if (!r) continue;
      last = Date.now();
      if (r.addr === FINISH_CHECK || r.addr === FINISH_WRITE) {
        link.send(response(r.addr, [...new TextEncoder().encode("success"), 0]));
        if (r.addr === finish) return { served, finished: true, lost: false };
        continue;
      }
      if (r.len > MAX_DATA || r.addr + r.len > image.length) {
        throw new FM1Error("badreq", `The FM-1 asked for bytes outside the package (${r.addr.toString(16)}+${r.len}).`);
      }
      if (this.timing.replyDelay) await sleep(this.timing.replyDelay);
      if (!link.send(response(r.addr, image.subarray(r.addr, r.addr + r.len), r.flags))) return { served, finished: false, lost: true };
      served++;
      progress(served);
    }
  }

  /** Full install: running firmware -> update loader -> new firmware. Returns the identity reported afterwards. */
  async install(pkg: FirmwarePackage, onStep: (s: Step) => void = () => {}): Promise<Identity> {
    const image = logicalImage(pkg.bytes);
    const dev = await this.find((id) => !isLoader(id));
    if (!dev) throw new FM1Error("notfound", "FM-1 not found. Check the USB cable, and close any other app using the FM-1.");
    if (dev.identity.model !== pkg.model) {
      dev.link.close();
      throw new FM1Error("model", `The FM-1 is ${dev.identity.text}, but the package is for ${pkg.product}.`);
    }
    onStep({ kind: "start", from: dev.identity.text });
    dev.link.send(UPGRADE);
    await sleep(this.timing.afterUpgrade);
    const s1 = await this.serve(dev.link, image, FINISH_CHECK, this.timing.idleCheck, (n) => onStep({ kind: "verify", n }));
    dev.link.close();
    if (!s1.finished && !s1.lost && s1.served === 0) {
      throw new FM1Error("refused", "The FM-1's current firmware didn't start the update. Nothing was written. "
        + "On a newer FM-1 (flash chip 0xB36014), a firmware that only knows the older chip can't update itself, and trying again won't help: "
        + `the way out is download mode and M-Flasher (${RESCUE_URL}). Otherwise, check that this firmware supports updates over USB.`);
    }
    if (!s1.finished) {
      throw new FM1Error(s1.lost ? "lost" : "stopped", `The FM-1 ${s1.lost ? "was disconnected" : "stopped"} after ${s1.served} requests. Nothing was written.`);
    }
    onStep({ kind: "loader" });
    await sleep(this.timing.beforeLoader);
    const ota = await this.waitFor((id) => id.model === "ota-" + pkg.model, this.timing.waitLoader);
    if (!ota) throw new FM1Error("noloader", "The update loader did not appear. Replug the USB cable and press Install again: the FM-1 stays in update mode until the write finishes.");
    return this.finishWrite(ota, pkg, image, onStep);
  }

  /** The device is in update mode (an earlier install was cut off): finish the write. Null when no loader is connected. */
  async resume(pkg: FirmwarePackage, onStep: (s: Step) => void = () => {}): Promise<Identity | null> {
    const ota = await this.find((id) => id.model === "ota-" + pkg.model);
    if (!ota) return null;
    return this.finishWrite(ota, pkg, logicalImage(pkg.bytes), onStep);
  }

  private async finishWrite(ota: Connected, pkg: FirmwarePackage, image: Uint8Array, onStep: (s: Step) => void): Promise<Identity> {
    ota.link.send(UPGRADE);
    await sleep(this.timing.afterUpgrade);
    const s2 = await this.serve(ota.link, image, FINISH_WRITE, this.timing.idleWrite, (n) => onStep({ kind: "write", n }));
    ota.link.close();
    if (!s2.finished && !s2.lost && s2.served === 0) {
      throw new FM1Error("refused", "The update loader didn't start writing. The FM-1 is in update mode and nothing new was written. "
        + "On a newer FM-1 (flash chip 0xB36014), this package's loader may not support the chip; installing it again won't help. "
        + `Power-cycle the FM-1, then follow the rescue guide (download mode and M-Flasher): ${RESCUE_URL}`);
    }
    if (!s2.finished) {
      throw new FM1Error(s2.lost ? "lost" : "stopped", `The update loader ${s2.lost ? "was disconnected" : "stopped"} after ${s2.served} requests. Replug the FM-1 and choose Resume to finish.`);
    }
    onStep({ kind: "reboot" });
    await sleep(this.timing.beforeReboot);
    const back = await this.waitFor((id) => !isLoader(id), this.timing.waitReboot);
    if (!back) throw new FM1Error("noreturn", "The FM-1 did not come back after the update. Power-cycle it.");
    back.link.close();
    if (back.identity.text !== pkg.product) throw new FM1Error("mismatch", `Installed, but the FM-1 now reports ${back.identity.text}.`);
    onStep({ kind: "done", identity: back.identity.text });
    return back.identity;
  }
}
