// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// M-VAVE's FM1 Open Workbench HTML carries its firmware packages (FM1 Open and the original V15) as base64
// JSON records; pull them out and check each against its own digest (mirrors WorkbenchExtractor.swift).
import { FirmwarePackage, readPackage } from "./package";

export interface Embedded { product: string; releaseVersion: string; isStock: boolean; hardwareValidated: boolean | null; pkg: FirmwarePackage }

export async function workbenchPackages(html: string): Promise<Embedded[]> {
  const out: Embedded[] = [];
  for (const m of html.matchAll(/\{"schema":1,[^{}]*?"data":"([A-Za-z0-9+/=]+)"/g)) {
    const header = m[0].slice(0, m[0].length - m[1].length);
    const field = (k: string) => new RegExp(`"${k}":"([^"]*)"`).exec(header)?.[1];
    const product = field("product"), sha = field("sha256");
    if (!product || !sha) continue;
    let bytes: Uint8Array;
    try { bytes = Uint8Array.from(atob(m[1]), (c) => c.charCodeAt(0)); } catch { continue; }
    try {
      const pkg = await readPackage(bytes);
      if (pkg.sha256 !== sha || pkg.product !== product) continue;
      out.push({ product, releaseVersion: field("release_version") ?? "", isStock: field("kind") === "stock",
        hardwareValidated: header.includes('"hardware_validated":false') ? false : header.includes('"hardware_validated":true') ? true : null, pkg });
    } catch { continue; }
  }
  return out;
}
