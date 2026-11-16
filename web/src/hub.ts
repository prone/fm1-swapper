// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The Firmware Hub's firmware list (https://thefirmwarehub.com/catalog.json, CC-BY-4.0: credit "The Firmware Hub" with a
// link, read at most once a day; card texts belong to each firmware's maker). It gives, per package: the SHA-256 to
// check downloads against, which FM-1 flash chips the firmware supports, its kind and its links. See docs/flash-chips.md.
import { useEffect, useState } from "preact/hooks";
import { STOCK } from "./fm1kit/package";

export const HUB = "https://thefirmwarehub.com/";
export { RESCUE_URL } from "./fm1kit/ota";

/** new: works with both flash chips · any: doesn't check the chip · old: only the first FM-1s' chip. */
export type Chip = "new" | "any" | "old";
export interface HubFirmware {
  id: string; name: string; author: string; repo: string; kind: string[]; what: string; version: string; date: string;
  stars: number; lic: string; pkg: string; sha256: string; product: string; size: number; chip: Chip; beta: boolean;
  editor?: string; play?: string; cheat?: string; site?: string; talk?: string; source?: string; linkOnly?: boolean;
}
export interface Hub { list: HubFirmware[]; bySha: Map<string, HubFirmware>; byRepo: Map<string, HubFirmware>; stockURL: string; loadedAt: number }

export const KIND_LABEL: Record<string, string> = { synth: "Synths", groove: "Grooveboxes", drums: "Drums & samplers", chords: "Chords", tracker: "Trackers", dev: "For devs", other: "Other" };
export const ATTRIBUTION = "Firmware list: The Firmware Hub";

const KEY = "hubCatalog", DAY = 86_400_000;
/** A package path on the hub itself: no "..", no scheme, no leading slash. */
const safePath = (p: string) => /^[\w-]+(\/[\w.-]+)*\.fwsc$/.test(p) && !p.split("/").some((seg) => seg === ".." || seg === ".");
const https = (u: unknown) => (typeof u === "string" && u.startsWith("https://") ? u : undefined);

function parse(j: unknown, loadedAt: number): Hub {
  const d = j as { firmwares?: unknown[]; stock?: { pkg?: string } };
  const list: HubFirmware[] = [];
  for (const raw of d.firmwares ?? []) {
    const f = raw as Record<string, unknown>;
    if (typeof f.id !== "string" || typeof f.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(f.sha256) || typeof f.pkg !== "string") continue;
    if (!safePath(f.pkg)) continue;
    list.push({
      id: f.id, name: String(f.name ?? f.id), author: String(f.author ?? ""), repo: typeof f.repo === "string" ? f.repo : "",
      kind: Array.isArray(f.kind) ? f.kind.map(String) : f.kind ? [String(f.kind)] : [], what: String(f.what ?? ""),
      version: String(f.version ?? ""), date: String(f.date ?? ""), stars: Number(f.stars) || 0, lic: String(f.lic ?? ""),
      pkg: f.pkg, sha256: f.sha256, product: String(f.product ?? ""), size: Number(f.size) || 0,
      chip: f.chip === "new" || f.chip === "any" ? f.chip : "old", beta: !!f.beta, linkOnly: !!f.linkOnly,
      editor: https(f.editor), play: https(f.play), cheat: https(f.cheat), site: https(f.site), talk: https(f.talk), source: https(f.source),
    });
  }
  const stockPkg = typeof d.stock?.pkg === "string" && safePath(d.stock.pkg) ? d.stock.pkg : "fw/mvave/FM-1_015.fwsc";
  return { list, bySha: new Map(list.map((f) => [f.sha256, f])), byRepo: new Map(list.filter((f) => f.repo).map((f) => [f.repo.toLowerCase(), f])),
    stockURL: HUB + stockPkg, loadedAt };
}

let hubP: Promise<Hub | null> | null = null;
/** Cached for a day in the browser; null when it can't be loaded (offline with no copy). */
export function loadHub(): Promise<Hub | null> {
  hubP ??= (async () => {
    let cached: { at: number; data: unknown } | null = null;
    try { cached = JSON.parse(localStorage.getItem(KEY) ?? "null"); } catch { /* no storage */ }
    if (cached && Date.now() - cached.at < DAY) return parse(cached.data, cached.at);
    try {
      const r = await fetch(HUB + "catalog.json");
      if (!r.ok) throw new Error(String(r.status));
      const data = await r.json();
      try { localStorage.setItem(KEY, JSON.stringify({ at: Date.now(), data })); } catch { /* too big or private: fine */ }
      return parse(data, Date.now());
    } catch { return cached ? parse(cached.data, cached.at) : null; }
  })();
  return hubP;
}

export function useHub(): Hub | null {
  const [h, setH] = useState<Hub | null>(null);
  useEffect(() => { void loadHub().then(setH); }, []);
  return h;
}

/** Which chips a package supports, by its exact SHA-256. M-VAVE's own firmware works on both. Unknown: undefined. */
export function chipOf(hub: Hub | null, sha256: string): Chip | undefined {
  if (STOCK.some((s) => s.sha256 === sha256)) return "new";
  return hub?.bySha.get(sha256)?.chip;
}

export const CHIP_TEXT: Record<Chip | "unknown", string> = {
  new: "Works on every FM-1, including newer units (flash chip 0xB36014)",
  any: "Doesn't check the flash chip: should work on every FM-1 (not confirmed on the newer chip)",
  old: "Only for the first FM-1s. On a newer FM-1 (flash chip 0xB36014) it keeps saves in RAM only, and it can't update itself afterwards",
  unknown: "Flash chip support unknown: this exact package isn't in The Firmware Hub's list",
};

// the user's own FM-1: the chip can't be read over USB MIDI (only in download mode, e.g. M-Flasher), so they tell us
export type MyChip = "unknown" | "old" | "new";
export function myChip(): MyChip { try { const v = localStorage.getItem("myFlashChip"); return v === "old" || v === "new" ? v : "unknown"; } catch { return "unknown"; } }
export function setMyChip(v: MyChip) { try { localStorage.setItem("myFlashChip", v); } catch { /* private window */ } }
