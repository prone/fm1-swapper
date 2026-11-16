// SPDX-License-Identifier: GPL-3.0-only
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { defineConfig, Plugin } from "vite";
import preact from "@preact/preset-vite";

/** Writes dist/sw.js listing every built file, versioned by their contents. */
function serviceWorker(): Plugin {
  let out = "dist";
  return {
    name: "fm1-service-worker",
    apply: "build",
    configResolved(c) { out = c.build.outDir; },
    closeBundle() {
      const files: string[] = [];
      const walk = (d: string) => { for (const n of readdirSync(d)) { const p = join(d, n); statSync(p).isDirectory() ? walk(p) : files.push(p); } };
      walk(out);
      const list = files.map((p) => relative(out, p).split("\\").join("/")).filter((f) => f !== "sw.js" && !f.endsWith(".txt") && f !== "emu/LICENSE").sort();
      const h = createHash("sha256");
      for (const f of list) h.update(f).update(readFileSync(join(out, f)));
      const sw = readFileSync("sw.template.js", "utf8")
        .replace("__VERSION__", h.digest("hex").slice(0, 12))
        .replace("__FILES__", JSON.stringify(["./", "./emu/", ...list.map((f) => "./" + f)]));
      writeFileSync(join(out, "sw.js"), sw);
    },
  };
}

// Relative base: the built app works from any folder (sakedo.co/fm1/app, GitHub Pages, a local server).
export default defineConfig({
  base: "./",
  plugins: [preact(), serviceWorker()],
  server: { fs: { allow: [".."] } },          // Tutorials/*.json live in the repo root
  build: { target: "es2022", chunkSizeWarningLimit: 800 },
  test: { environment: "node" },
});
