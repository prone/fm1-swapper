// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments (Felucca web/fm1pkg.js)
// Copyright (C) 2026 FM-1 Swapper contributors (TypeScript port, modified)
// FM-1 firmware packages (.fwsc) and device identities (mirrors FirmwarePackage.swift).
import { sha256Hex } from "./sysex";

const BLOCKS = 20, BLK = 0x30, KEEP = 0x2f;

export type Family = "official" | "fm1Open" | "felucca" | "updateLoader" | "unknown";

export const FAMILY_NAMES: Record<Family, string> = {
  official: "M-VAVE official",
  fm1Open: "FM1 Open (official open-source)",
  felucca: "Felucca (or a Felucca fork)",
  updateLoader: "Update loader (mid-install)",
  unknown: "Community firmware",
};

export interface Identity { text: string; model: string; number: number }

/** "<model>_<number>", e.g. "FM-1_918"; the update loader answers "ota-FM-1_001". */
export function parseIdentity(text: string): Identity | null {
  const m = /^([^_]+)_(\d+)$/.exec(text);
  return m ? { text, model: m[1], number: parseInt(m[2], 10) } : null;
}

export const isLoader = (id: Identity) => id.model.toLowerCase().startsWith("ota-");

export function familyOf(id: Identity): Family {
  if (isLoader(id)) return "updateLoader";
  if (id.number >= 1 && id.number < 100) return "official";
  if (id.number >= 900 && id.number < 1000) return "felucca";
  if (id.number >= 8_000_000 && id.number < 9_000_000) return "fm1Open";
  return "unknown";
}

export const supportsArchive = (f: Family) => f === "felucca" || f === "fm1Open";

/** The unmodified official releases (FM-1.fwsc from M-VAVE), pinned by digest. */
export const STOCK = [
  { version: "V15", size: 699_956, sha256: "db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a", product: "FM-1_015" },
  { version: "V16", size: 718_196, sha256: "d017fb65e70aca97ee29d944470c3515a74581df5c0576bf70de917c7b2b61d5", product: "FM-1_016" },
];
/** Official V15, the version the app installs as a clean base. */
export const STOCK_V15 = STOCK.find((s) => s.version === "V15")!;

export interface FirmwarePackage {
  bytes: Uint8Array;
  product: string;
  model: string;
  sha256: string;
  stock?: (typeof STOCK)[number];
}

/** The package identity: one marker byte after each of the first 20 blocks. */
export function productOf(b: Uint8Array): string {
  let s = "";
  for (let i = 0; i < BLOCKS; i++) {
    const m = b[i * BLK + KEEP];
    if (m !== 0x7d) s += String.fromCharCode((m - i - 1) & 0xff);
  }
  return s;
}

/** The image the device reads during an update: the package without the 20 marker bytes. */
export function logicalImage(b: Uint8Array): Uint8Array {
  const out = new Uint8Array(b.length - BLOCKS);
  for (let i = 0; i < BLOCKS; i++) out.set(b.subarray(i * BLK, i * BLK + KEEP), i * KEEP);
  out.set(b.subarray(BLOCKS * BLK), BLOCKS * KEEP);
  return out;
}

export async function readPackage(bytes: Uint8Array): Promise<FirmwarePackage> {
  if (bytes.length < BLOCKS * BLK + 1024) throw new Error("This is not an FM-1 firmware package (.fwsc): the file is too short.");
  const product = productOf(bytes);
  const id = parseIdentity(product);
  if (!id || !/^[A-Za-z0-9-]+$/.test(id.model)) throw new Error("This is not an FM-1 firmware package (.fwsc): no package identity found.");
  const sha256 = await sha256Hex(bytes);
  return { bytes, product, model: id.model, sha256, stock: STOCK.find((s) => s.sha256 === sha256) };
}
