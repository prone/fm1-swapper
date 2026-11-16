// SPDX-License-Identifier: GPL-3.0-only
import { defineConfig } from "vite";
import preact from "@preact/preset-vite";

// Relative base: the built app works from any folder (GitHub Pages, sakedo.co/fm1/app, a USB stick).
export default defineConfig({
  base: "./",
  plugins: [preact()],
  server: { fs: { allow: [".."] } },          // Tutorials/*.json live in the repo root
  build: { target: "es2022", chunkSizeWarningLimit: 800 },
  test: { environment: "node" },
});
