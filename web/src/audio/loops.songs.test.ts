// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Opt-in: the loops found in real songs (your own audio, never in the repo). LOOP_WAVS=a folder of 22050 Hz mono
// 16-bit WAV files; prints each song's loops, to compare with the Python prototype and by ear.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "vitest";
import { SongAudio } from "./analysis";
import { writeFileSync } from "node:fs";
import { debug, findLoops } from "./loops";

const dir = process.env.LOOP_WAVS;
const wav = (p: string) => { const b = readFileSync(p); const i = b.indexOf("data") + 8; const v = new Int16Array(b.buffer, b.byteOffset + i, (b.length - i) >> 1); return Float32Array.from(v, (x) => x / 32768); };
const clock = (t: number) => { const d = Math.round(t * 10); return `${Math.floor(d / 600)}:${((d % 600) / 10).toFixed(1).padStart(4, "0")}`; };

describe.skipIf(!dir)("loops in real songs", () => {
  for (const f of dir ? readdirSync(dir).filter((x) => x.endsWith(".wav")).sort() : []) {
    it(f, async () => {
      const t0 = Date.now(), song = new SongAudio(wav(join(dir!, f)));
      const loops = await findLoops(song, [], 8);
      const L = loops[0]?.lengths;
      if (process.env.LOOP_DUMP) writeFileSync(join(process.env.LOOP_DUMP, f.replace(".wav", ".loops.json")), JSON.stringify({ bpm: song.bpm, loops: loops.map((l) => ({ start: l.start, end: l.start + 64 * (15 / l.bpm), repeats: l.repeats, unsure: l.unsure, lengths: l.lengths })) }));
      if (process.env.LOOP_DUMP) writeFileSync(join(process.env.LOOP_DUMP, f.replace(".wav", ".json")), JSON.stringify({ steps: debug.last!.steps, F: debug.last!.F }));
      process.stderr.write(`${f}: ${song.bpm.toFixed(1)} BPM, ${loops.length} loops in ${((Date.now() - t0) / 1000).toFixed(1)} s; lengths ${JSON.stringify(L)}\n` +
        loops.map((l) => `   ${clock(l.start)} x${l.repeats}${l.unsure ? " (unsure)" : ""}: ${l.drums.length} drum steps`).join("\n") + "\n");
    }, 600_000);
  }
});
