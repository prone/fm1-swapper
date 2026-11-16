// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Byte codecs used by the FM-1 SysEx protocols (mirrors Packages/FM1Kit/Sources/FM1Kit/SysExCoding.swift).

/** LSB-first stream of 8-bit bytes packed into 7-bit MIDI data (update and FM1 Open protocols). */
export function pack7(data: ArrayLike<number>): number[] {
  const out: number[] = [];
  let acc = 0, nb = 0;
  for (let i = 0; i < data.length; i++) {
    acc |= (data[i] & 0xff) << nb;
    nb += 8;
    while (nb >= 7) { out.push(acc & 0x7f); acc >>>= 7; nb -= 7; }
  }
  if (nb) out.push(acc & 0x7f);
  return out;
}

export function unpack7(data: ArrayLike<number>): number[] {
  const out: number[] = [];
  let acc = 0, nb = 0;
  for (let i = 0; i < data.length; i++) {
    acc |= (data[i] & 0x7f) << nb;
    nb += 7;
    while (nb >= 8) { out.push(acc & 0xff); acc >>>= 8; nb -= 8; }
  }
  return out;
}

/** Strict unpack: null when leftover bits are non-zero or a whole 7-bit group is left over. */
export function unpack7Strict(data: ArrayLike<number>): number[] | null {
  const out: number[] = [];
  let acc = 0, nb = 0;
  for (let i = 0; i < data.length; i++) {
    if (data[i] > 0x7f) return null;
    acc |= data[i] << nb;
    nb += 7;
    if (nb >= 8) { out.push(acc & 0xff); acc >>>= 8; nb -= 8; }
  }
  return acc !== 0 || nb >= 7 ? null : out;
}

/** Felucca archive packing: groups of 7 bytes, each preceded by a mask of their high bits. */
export function maskPack(bytes: ArrayLike<number>): number[] {
  const out: number[] = [];
  for (let off = 0; off < bytes.length; off += 7) {
    const n = Math.min(7, bytes.length - off);
    let mask = 0;
    for (let i = 0; i < n; i++) mask |= ((bytes[off + i] >> 7) & 1) << i;
    out.push(mask);
    for (let i = 0; i < n; i++) out.push(bytes[off + i] & 0x7f);
  }
  return out;
}

export function maskUnpack(a: ArrayLike<number>, size: number): Uint8Array {
  const out = new Uint8Array(size);
  let i = 0, j = 0;
  while (j < size) {
    const n = Math.min(7, size - j);
    if (i >= a.length) throw new Error("Invalid archive bytes");
    const mask = a[i++];
    if (mask >>> n) throw new Error("Invalid archive bytes");
    for (let k = 0; k < n; k++) {
      if (i >= a.length || a[i] > 127) throw new Error("Short archive chunk");
      out[j++] = a[i++] | (((mask >>> k) & 1) << 7);
    }
  }
  if (i !== a.length) throw new Error("Trailing archive bytes");
  return out;
}

/** 32-bit number as five 7-bit groups (Felucca archive). */
export const u32To7 = (n: number): number[] => [0, 1, 2, 3, 4].map((i) => (n >>> (i * 7)) & (i === 4 ? 15 : 127));

export function u32From7(a: ArrayLike<number>, off = 0): number {
  if (a.length < off + 5 || a[off + 4] > 15) throw new Error("Invalid archive number");
  return (a[off] | (a[off + 1] << 7) | (a[off + 2] << 14) | (a[off + 3] << 21) | (a[off + 4] << 28)) >>> 0;
}

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? (c >>> 1) ^ 0xedb88320 : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();

/** Standard CRC-32 (IEEE). */
export function crc32(bytes: ArrayLike<number>): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (~c) >>> 0;
}

export const le32 = (a: ArrayLike<number>, o: number): number => (a[o] | (a[o + 1] << 8) | (a[o + 2] << 16) | (a[o + 3] << 24)) >>> 0;
export const le32Bytes = (v: number): number[] => [v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff];

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, "0")).join("");
}
