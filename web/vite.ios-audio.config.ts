// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The audio import as a bundle for the iOS app (App/AudioImport/): the analysis and Basic Pitch with its model, served
// to a hidden web view from the app's own files. Run: npm run build:ios-audio (then rebuild the app).
import { defineConfig } from "vite";
import { cpSync } from "node:fs";
import { resolve } from "node:path";

const out = resolve(__dirname, "../App/AudioImport");
export default defineConfig({
  root: resolve(__dirname, "ios-audio"),
  base: "./",
  publicDir: false,
  build: {
    target: "es2022", outDir: out, emptyOutDir: true, chunkSizeWarningLimit: 1500,
    rollupOptions: { output: { inlineDynamicImports: true, entryFileNames: "audio-import.js" } },
  },
  plugins: [{ name: "basic-pitch-model", closeBundle() { cpSync(resolve(__dirname, "public/basic-pitch"), resolve(out, "basic-pitch"), { recursive: true }); } }],
});
