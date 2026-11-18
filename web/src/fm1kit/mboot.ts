// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// m-bootloader's MIDI mode (github.com/jvitkauskas/m-bootloader, MIT; docs/SPEC.md §11.6–11.7, src/midi_update.c):
// a bootloader, or its RAM "stage" helper sent as a normal update, that answers the update protocol as
// `ota-FM-1_900` and also reports the flash chip and serves raw flash reads. Mirrors MBoot.swift.
//
// SAFETY: M-VAVE's stock update service uses the same frame, and on some versions its 0x21 erases a flash sector
// with no check; 0x21 and 0x23 differ by one bit and the checksum doesn't cover the command. So reads are only
// possible through an `MBoot` object, and the only way to get one is `MBoot.probe`, which requires the `MBOOT`
// answer to 0x12 first.
import { Family } from "./package";
import { SysExLink } from "./midi";
import { crc32, le32, le32Bytes, pack7, sum59, unwrap } from "./sysex";

export const MBOOT_VERSION = "2.4-395e6cc";
/** The helper packages we ship (web/public/mboot, App/MBoot), pinned to m-bootloader's release SHA256SUMS. */
export const HELPERS = {
  stage: { file: "fm1-stage.fwsc", sha256: "e861ad2ec1a7fe0088e8281d566442acb93a8b7e2dba41437e4edaa16ff25a6c" },
  listed: { file: "fm1-stage-listed.fwsc", sha256: "7c14b0cd3159c1c1ef6e93d3f3394a572ab03ad66093a3f561166b6792ed3606" },
} as const;
export type HelperKind = keyof typeof HELPERS;

/** Which helper package a running firmware accepts, or null when it isn't known to accept one (spec §11.7):
 *  M-VAVE's firmware takes the plain one; Felucca-family firmware (Felucca, SLOOP, Melodee, ChoralRoot…) only the
 *  "listed" one. Community firmware outside the number ranges (Melodee FM-1_91061, AMB-1 FM-1_7010302, X0X
 *  FM-1_9010202) is almost all Felucca-based, so it gets the listed one too; firmware with M-VAVE's update service
 *  refuses that package without writing anything. FM1 Open isn't sent the message until tested. */
export function helperFor(family: Family): HelperKind | null {
  return family === "official" ? "stage" : family === "felucca" || family === "unknown" ? "listed" : null;
}

export const RESTART = [0xf0, 0x22, 0x24, 0x35, 0x7e, 0xf7];
export const SECTOR = 0x1000, READ_MAX = 512;

/** A JieLi "00 59" command (the same framing as the FM-1's update loader), packed for SysEx. */
export function frame(cmd: number, body: ArrayLike<number> = []): number[] {
  const n = body.length;
  return [0xf0, ...pack7([0, 0x59, cmd, n & 0xff, (n >> 8) & 0xff, 0, ...Array.from(body), sum59(body)]), 0xf7];
}

export function parseFrame(pkt: number[]): { cmd: number; body: number[] } | null {
  const d = unwrap(pkt);
  if (!d || d.length < 7 || d[0] !== 0 || d[1] !== 0x59 || d[5] !== 0 || (d[3] | (d[4] << 8)) !== d.length - 7) return null;
  if (sum59(d, 6) !== 0) return null;
  return { cmd: d[2], body: d.slice(6, -1) };
}

export interface MbootInfo {
  protocol: number; kind: "bootloader" | "stage"; flags: number; chipKey: number; capacity: number;
  jedec: number; uid: string; version: string;
}

export function parseInfo(body: number[]): MbootInfo | null {
  if (body.length < 29 || String.fromCharCode(...body.slice(0, 5)) !== "MBOOT") return null;
  const end = body.indexOf(0, 28);
  return {
    protocol: body[5], kind: body[6] === 2 ? "stage" : "bootloader", flags: body[7], chipKey: body[8] | (body[9] << 8),
    capacity: le32(body, 10), jedec: le32(body, 14), uid: body.slice(18, 26).map((b) => b.toString(16).padStart(2, "0")).join(""),
    version: String.fromCharCode(...body.slice(28, end < 0 ? body.length : end)),
  };
}

export const OLD_CHIP = 0x856014, NEW_CHIP = 0xb36014;
export const chipOfJedec = (j: number): "old" | "new" | "unknown" => (j === OLD_CHIP ? "old" : j === NEW_CHIP ? "new" : "unknown");
export const hex = (n: number, w = 6) => "0x" + n.toString(16).toUpperCase().padStart(w, "0");

export class MBootError extends Error {}

export class MBoot {
  private constructor(private link: SysExLink, readonly info: MbootInfo) {}

  /** Asks what's answering. Only m-bootloader (or its helper) answers `MBOOT`; anything else gives null. */
  static async probe(link: SysExLink, ms = 1500): Promise<MBoot | null> {
    link.drain();
    if (!link.send(frame(0x12))) return null;
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const p = await link.read(end - Date.now());
      if (!p) break;
      const f = parseFrame(p);
      if (f?.cmd === 0x12) { const info = parseInfo(f.body); return info ? new MBoot(link, info) : null; }
      if (f?.cmd === 0) return null;          // a refusal: not ours
    }
    return null;
  }

  private async ask(cmd: 0x23 | 0x24, addr: number, count: number, tries = 3): Promise<number[]> {
    if (count < 1 || addr < 0 || addr + count > this.info.capacity || (cmd === 0x23 && count > READ_MAX)) throw new MBootError("Read outside the flash.");
    const body = [0, ...le32Bytes(addr), count & 0xff, (count >> 8) & 0xff, (count >> 16) & 0xff];
    for (let t = 0; t < tries; t++) {
      this.link.drain();
      if (!this.link.send(frame(cmd, body))) throw new MBootError("The FM-1 was disconnected.");
      const end = Date.now() + (cmd === 0x24 ? 8000 : 1500);
      while (Date.now() < end) {
        const p = await this.link.read(end - Date.now());
        if (!p) break;
        const f = parseFrame(p);
        if (!f) continue;
        if (f.cmd === 0) throw new MBootError("The FM-1 refused the read.");
        if (f.cmd === cmd && f.body.slice(0, 8).every((b, i) => b === body[i])) return f.body.slice(8);
      }
    }
    throw new MBootError("The FM-1 stopped answering. Keep it connected and try again.");
  }

  async read(addr: number, count: number): Promise<Uint8Array> {
    const d = await this.ask(0x23, addr, count);
    if (d.length !== count) throw new MBootError("Short read from the FM-1.");
    return Uint8Array.from(d);
  }

  /** The CRC-32 the chip computes of a range. */
  async crc(addr: number, count: number): Promise<number> {
    const d = await this.ask(0x24, addr, count);
    if (d.length !== 4) throw new MBootError("Bad checksum answer.");
    return le32(d, 0);
  }

  /** The whole flash, each 64 KB block checked against the chip's own CRC-32 (read again once on a mismatch). */
  async backup(progress: (done: number, total: number) => void = () => {}): Promise<Uint8Array> {
    const total = this.info.capacity, out = new Uint8Array(total), BLOCK = 0x10000;
    if (total < SECTOR || total > 16 << 20 || total % SECTOR) throw new MBootError(`Unexpected flash size ${total}.`);
    for (let at = 0; at < total; at += BLOCK) {
      const size = Math.min(BLOCK, total - at), want = await this.crc(at, size);
      for (let attempt = 0; ; attempt++) {
        for (let o = 0; o < size; o += READ_MAX) {
          out.set(await this.read(at + o, Math.min(READ_MAX, size - o)), at + o);
          progress(at + o + Math.min(READ_MAX, size - o), total);
        }
        if (crc32(out.subarray(at, at + size)) === want) break;
        if (attempt === 1) throw new MBootError(`The flash at ${hex(at)} read differently twice. Nothing was changed; try again.`);
      }
    }
    return out;
  }

  /** Leaves MIDI mode: the unit restarts into its firmware. */
  restart() { this.link.send(RESTART); }
}
