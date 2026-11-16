// SPDX-License-Identifier: GPL-3.0-only
// Copies the published fm1-emu build (https://github.com/joakimeriksson/fm1-emu, MIT) into public/emu/, so the app
// serves the emulator from its own origin and the tutorial bridge can drive it. Run: npm run emu
import { mkdir, writeFile } from "node:fs/promises";

const BASE = "https://joakimeriksson.github.io/fm1-emu/";
const FILES = ["index.html", "style.css", "main.js", "fwsc.js", "persistence.js", "tryout.js", "worklet.js", "jit.js",
  "firmwares.json", "smk37/firmwares.json", "fm1_web.wasm"];
const OUT = new URL("../public/emu/", import.meta.url);

await mkdir(new URL("smk37/", OUT), { recursive: true });
for (const f of FILES) {
  const r = await fetch(BASE + f);
  if (!r.ok) throw new Error(`${f}: HTTP ${r.status}`);
  let body = Buffer.from(await r.arrayBuffer());
  if (f === "index.html") {
    // the bridge must run before the emulator's own module scripts
    body = Buffer.from(body.toString("utf8").replace("<head>", '<head>\n<script src="../emu-bridge.js"></script>'));
  }
  await writeFile(new URL(f, OUT), body);
  console.log(`${f}  ${body.length} bytes`);
}
const lic = await fetch("https://raw.githubusercontent.com/joakimeriksson/fm1-emu/master/LICENSE");
const licText = await lic.text();
if (!lic.ok || !/MIT License/.test(licText)) throw new Error(`fm1-emu LICENSE: HTTP ${lic.status}; not shipping the emulator without its licence`);
await writeFile(new URL("LICENSE", OUT), licText);
await writeFile(new URL("SOURCE.txt", OUT), `fm1-emu by Joakim Eriksson, MIT licence (see LICENSE).\nCopied from ${BASE} on ${new Date().toISOString()}.\nSource: https://github.com/joakimeriksson/fm1-emu\n`);
