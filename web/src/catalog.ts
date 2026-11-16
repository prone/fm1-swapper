// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Where firmware comes from (mirrors App/Catalog.swift). Browsers can only download from servers that allow it
// (CORS): The Firmware Hub, GitHub Pages and raw.githubusercontent.com do; GitHub release files and M-VAVE's server
// don't, so those open as a normal download for the user to drop into the app.
import { Family, STOCK, familyOf, parseIdentity, readPackage } from "./fm1kit/package";
import { HUB, HubFirmware, loadHub } from "./hub";
import { workbenchPackages } from "./fm1kit/workbench";
import { Firmware, store, uid } from "./store";

export interface Featured { id: string; name: string; author: string; blurb: string; repo?: string; website: string; howToGet: string }

export const FEATURED: Featured[] = [
  { id: "official", name: "M-VAVE official", author: "M-VAVE", blurb: "The stock DX7-style FM firmware (V15, V16 adds stereo FX and presets). Keep a copy so you can always go back.",
    website: "https://www.m-vave.com/download", howToGet: "Download FM-1.fwsc from M-VAVE (or get V15 from the FM1 Open Workbench below), then drop it here." },
  { id: "fm1open", name: "FM1 Open", author: "M-VAVE", blurb: "M-VAVE's open-source branch: 8-track 64-step sequencer, six engines with samples, DX7 library.",
    repo: "m-vave/fm1_open", website: "https://github.com/m-vave/fm1_open/releases", howToGet: "Download the Workbench .html from M-VAVE's release and drop it here: the app takes FM1 Open and the original V15 out of it." },
  { id: "felucca", name: "Felucca", author: "Hügelton Instruments", blurb: "Multi-engine synth firmware (13+ engines, FM6, samples). The base for many community firmwares.",
    repo: "hugelton/Felucca", website: "https://github.com/hugelton/Felucca/wiki", howToGet: "One-click download from The Firmware Hub." },
  { id: "fm1dock", name: "fm1-dock", author: "joakimeriksson", blurb: "One firmware with synths as modules in flash slots, deployed over MIDI.",
    repo: "joakimeriksson/fm1-dock", website: "https://github.com/joakimeriksson/fm1-dock", howToGet: "Download from its GitHub releases." },
];

export interface CatalogEntry {
  id: string; repo?: string; url?: string; description?: string; license?: string; stars?: number; pushed?: string;
  upstream_releases?: { tag?: string; name?: string; url?: string; size?: number; prerelease?: boolean }[];
}
export interface HubPackage { name: string; version: string; author: string; url: string; repo: string; about: string }

export const entryTitle = (e: CatalogEntry) => e.repo?.split("/")[1] ?? e.id;
export const entryOwner = (e: CatalogEntry) => e.repo?.split("/")[0] ?? "";
export const packagesOf = (e: CatalogEntry) => (e.upstream_releases ?? []).filter((r) => r.url && (r.name ?? "").toLowerCase().endsWith(".fwsc"));

export async function loadCommunity(): Promise<CatalogEntry[]> {
  const r = await fetch("https://raw.githubusercontent.com/2bbb/fm1-firmware-collection/main/catalog/firmwares.json");
  if (!r.ok) throw new Error(`Catalog: HTTP ${r.status}`);
  const j = await r.json();
  return (j.firmwares as CatalogEntry[]).filter((e) => packagesOf(e).length).sort((a, b) => (b.pushed ?? "").localeCompare(a.pushed ?? ""));
}

/** The Firmware Hub's packages (via the emulator's catalog), keyed by lower-case "owner/name": downloadable from a browser. */
let hub: Promise<Map<string, HubPackage>> | null = null;
export function hubPackages(): Promise<Map<string, HubPackage>> {
  hub ??= fetch("emu/firmwares.json").then((r) => r.json()).then((j) => {
    const m = new Map<string, HubPackage>();
    for (const f of j.firmwares ?? []) {
      const repo = /github\.com\/([^/]+\/[^/#?]+)/.exec(f.repo ?? "")?.[1]?.toLowerCase();
      const url = f.package ?? f.download;
      if (repo && typeof url === "string" && url.startsWith("https://")) {
        m.set(repo, { name: f.name, version: f.version ?? "", author: f.author ?? "", url, repo, about: f.about ?? "" });
      }
    }
    return m;
  }).catch(() => new Map());
  return hub;
}

/** Downloads over https when the server allows it; null when the browser isn't allowed to (CORS). */
export async function tryDownload(url: string, maxBytes = 32 << 20): Promise<Uint8Array | null> {
  if (!url.startsWith("https://")) throw new Error("Only https downloads.");
  let r: Response;
  try { r = await fetch(url); } catch { return null; }
  if (!r.ok) throw new Error(`Download failed: HTTP ${r.status}`);
  const b = new Uint8Array(await r.arrayBuffer());
  if (b.length > maxBytes) throw new Error("That file is too large.");
  return b;
}

export interface AddResult { firmware: Firmware; isNew: boolean; warning?: string }

/** Adds a package to the library, or fills in the file of an entry that is waiting for one. */
export async function addPackage(bytes: Uint8Array, meta: Partial<Firmware> & { fileName: string }): Promise<AddResult> {
  const pkg = await readPackage(bytes);
  const all = await store.firmwares();
  const same = all.find((f) => f.sha256 === pkg.sha256);
  if (same) return { firmware: same, isNew: false };
  const waiting = all.find((f) => f.product === pkg.product && !f.sha256);
  const family: Family = familyOf(parseIdentity(pkg.product)!);
  const base = (meta.fileName.replace(/\.fwsc$/i, "") || "").trim();
  const f: Firmware = waiting ?? {
    id: uid(), name: meta.name ?? (base && base !== "FM-1" ? base : `Firmware ${pkg.product}`), author: "", version: "", product: pkg.product,
    sha256: "", family, sourceURL: "", repo: "", notes: "", summary: "", rating: 0, status: "notTried", addedAt: Date.now(),
    fileName: meta.fileName, size: 0, installCount: 0,
  };
  Object.assign(f, { sha256: pkg.sha256, fileName: meta.fileName });
  if (pkg.stock) Object.assign(f, { name: `M-VAVE official ${pkg.stock.version}`, author: "M-VAVE", version: pkg.stock.version });
  else for (const k of ["name", "author", "version", "sourceURL", "repo", "summary"] as const) if (meta[k]) f[k] = meta[k] as string;
  await store.saveFirmware(f, bytes);
  return { firmware: f, isNew: !waiting, warning: pkg.model === "FM-1" ? undefined : `This package is for ${pkg.model}, not the FM-1. It will be refused at install time.` };
}

/** A dropped or chosen file: a .fwsc, or M-VAVE's Workbench .html (FM1 Open + original V15 inside). */
export async function importFile(file: File): Promise<string[]> {
  if (file.size > 40 << 20) throw new Error(`${file.name} is too large.`);
  if (/\.html?$/i.test(file.name)) {
    const found = await workbenchPackages(await file.text());
    if (!found.length) throw new Error("No firmware packages found in that page.");
    const out: string[] = [];
    for (const e of found) {
      const r = await addPackage(e.pkg.bytes, { fileName: `${e.product}.fwsc`, name: e.isStock ? undefined : `FM1 Open ${e.releaseVersion}`,
        author: "M-VAVE", version: e.releaseVersion, repo: "m-vave/fm1_open",
        summary: e.isStock ? undefined : "M-VAVE's open-source branch: 8-track 64-step sequencer, six engines with samples, DX7 library." });
      out.push(`${r.isNew ? "Added" : "Already have"} ${r.firmware.name}`);
    }
    return out;
  }
  const r = await addPackage(new Uint8Array(await file.arrayBuffer()), { fileName: file.name });
  return [`${r.isNew ? "Added" : "Already have"} ${r.firmware.name}${r.warning ? ` — ${r.warning}` : ""}`];
}

/** Downloads a package from The Firmware Hub and checks it against the SHA-256 the hub publishes before adding it. */
export async function addFromHub(e: HubFirmware): Promise<AddResult> {
  const bytes = await tryDownload(HUB + e.pkg);
  if (!bytes) throw new Error("The Firmware Hub couldn't be reached. Check the connection and try again.");
  const pkg = await readPackage(bytes);
  if (pkg.sha256 !== e.sha256) throw new Error(`The download doesn't match the checksum The Firmware Hub publishes for ${e.name} ${e.version}, so it wasn't added.`);
  return addPackage(bytes, { fileName: e.pkg.split("/").pop()!, name: `${e.name} ${e.version}`.trim(), author: e.author, version: e.version,
    repo: e.repo, sourceURL: HUB + e.pkg, summary: e.what });
}

/** M-VAVE's official firmware: the copy in the library, or V15 downloaded from The Firmware Hub and checked against its known digest. */
export async function officialFirmware(): Promise<Firmware> {
  const all = await store.firmwares();
  const have = STOCK.slice().reverse().map((s) => all.find((f) => f.sha256 === s.sha256)).find(Boolean);
  if (have) return have;
  const hub = await loadHub();
  const bytes = await tryDownload(hub?.stockURL ?? HUB + "fw/mvave/FM-1_015.fwsc");
  if (!bytes) throw new Error("Couldn't download the official firmware. Check the connection, or add FM-1.fwsc from M-VAVE's site.");
  const pkg = await readPackage(bytes);
  if (!pkg.stock) throw new Error("The downloaded file isn't M-VAVE's official firmware (its checksum doesn't match), so it wasn't added.");
  return (await addPackage(bytes, { fileName: "FM-1.fwsc", sourceURL: hub?.stockURL ?? "" })).firmware;
}
