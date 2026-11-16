// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { describe, expect, it } from "vitest";
import { viaV15Recommended } from "./device";
import { parseIdentity } from "./fm1kit/package";
import type { Firmware } from "./store";

const fw = (sha256: string) => ({ sha256 } as Firmware);
const V15 = "db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a";

describe("going via official V15", () => {
  it("is recommended unless the FM-1 is on V15 already, the target is V15, or it's in update mode", () => {
    expect(viaV15Recommended(parseIdentity("FM-1_918"), fw("a".repeat(64)))).toBe(true);
    expect(viaV15Recommended(parseIdentity("FM-1_016"), fw("a".repeat(64)))).toBe(true);
    expect(viaV15Recommended(parseIdentity("FM-1_015"), fw("a".repeat(64)))).toBe(false);
    expect(viaV15Recommended(parseIdentity("FM-1_918"), fw(V15))).toBe(false);
    expect(viaV15Recommended(parseIdentity("ota-FM-1_001"), fw("a".repeat(64)))).toBe(false);
    expect(viaV15Recommended(null, fw("a".repeat(64)))).toBe(false);
  });
});
