// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { beforeEach, describe, expect, it, vi } from "vitest";

const sha = (c: string) => c.repeat(64);
const catalog = { license: {}, stock: { pkg: "fw/mvave/FM-1_015.fwsc" }, firmwares: [
  { id: "a", name: "A", sha256: sha("a"), pkg: "fw/a-1.fwsc", chip: "new", kind: ["synth"], repo: "x/a", play: "https://p", editor: "javascript:alert(1)" },
  { id: "b", name: "B", sha256: sha("b"), pkg: "fw/b-1.fwsc", chip: "old", kind: "groove" },
  { id: "c", name: "C", sha256: "nope", pkg: "fw/c.fwsc" },
  { id: "d", name: "D", sha256: sha("d"), pkg: "../../evil.fwsc" },
] };

describe("The Firmware Hub list", () => {
  beforeEach(() => { vi.resetModules(); vi.stubGlobal("localStorage", { getItem: () => null, setItem: () => {} }); });

  it("reads chips, keeps only safe entries and links, and knows M-VAVE's firmware", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify(catalog))));
    const { loadHub, chipOf } = await import("./hub");
    const h = await loadHub();
    expect(h!.list.map((f) => f.id)).toEqual(["a", "b"]);
    expect(chipOf(h, sha("a"))).toBe("new");
    expect(chipOf(h, sha("b"))).toBe("old");
    expect(chipOf(h, sha("e"))).toBeUndefined();
    expect(chipOf(h, "db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a")).toBe("new");
    expect(h!.list[0].editor).toBeUndefined();
    expect(h!.list[0].play).toBe("https://p");
    expect(h!.byRepo.get("x/a")?.id).toBe("a");
  });

  it("works without the network", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("offline"); }));
    const { loadHub } = await import("./hub");
    expect(await loadHub()).toBeNull();
  });
});
