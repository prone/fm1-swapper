// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The audio import for the iOS app: the same analysis as the web app, in a hidden web view the app drives
// (App/AudioImport.swift). The app hands over the file's bytes; progress goes back through the "fm1audio" message
// handler; results come back as JSON.
import { AudioNote, Section, SongAudio, analyseSection, dropGhosts, suggestSections } from "./analysis";
import { decode, notesFromOutput, transcribe } from "./input";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { fm1audio?: { postMessage: (m: unknown) => void } } };
    __fm1audio?: { analyse: (b64: string) => Promise<string>; section: (start: number) => Promise<string> | string };
  }
}

let song: SongAudio | null = null, notes: AudioNote[] = [];
const tell = (status: string, progress: number | null = null) => window.webkit?.messageHandlers?.fm1audio?.postMessage({ status, progress });
const wait = () => new Promise((r) => setTimeout(r, 0));
/** A section as plain objects (the app decodes them with Codable). */
const plain = (s: Section) => ({
  start: s.start, bpm: s.bpm,
  bass: s.bass.map(([step, len, pitch]) => ({ step, len, pitch })),
  lead: s.lead.map(([step, len, pitch]) => ({ step, len, pitch })),
  keys: s.keys.map(([step, len, pitches]) => ({ step, len, pitches })),
  drums: s.drums.map(([step, lanes]) => ({ step, lanes })),
});

/** Errors come back as {"error": …} (the app shows the message: WebKit only says "an exception occurred"). */
const guarded = async (f: () => Promise<string> | string) => {
  try { return await f(); } catch (e) { return JSON.stringify({ error: e instanceof Error ? e.message || String(e) : String(e) }); }
};

const api = {
  /** `b64`: the file's bytes; or empty: the app has decoded the audio already (mono 22050 Hz float samples, served as
   *  input.pcm: far less memory in the web view than decoding a whole song here). */
  async analyse(b64: string) {
    tell("Reading the audio…"); await wait();
    const y = b64 ? await decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)).buffer)
      : new Float32Array(await (await fetch("input.pcm")).arrayBuffer());
    if (y.length < 22050 * 4) throw new Error("That's under 4 seconds: a 4-bar section needs more.");
    tell("Finding the notes (Basic Pitch)…", 0);
    const out = b64 ? null : await fetch("pitch.bin").then((r) => (r.ok ? r.arrayBuffer() : null)).catch(() => null);
    notes = dropGhosts(out ? await notesFromOutput(...rows(out)) : await transcribe(y, (f) => tell("Finding the notes (Basic Pitch)…", f)));
    tell("Finding the beat and the drums…"); await wait();
    song = new SongAudio(y);
    const sections: ReturnType<typeof plain>[] = [];
    for (const [i, t] of suggestSections(song, notes, 4).entries()) {
      tell(`Analysing section ${"ABCD"[i]}…`); await wait();
      sections.push(plain(analyseSection(song, notes, t)));
    }
    return JSON.stringify({ bpm: song.bpm, duration: song.duration, sections });
  },
  section(start: number) {
    if (!song) throw new Error("No audio analysed yet.");
    return JSON.stringify(plain(analyseSection(song, notes, start)));
  },
};
/** pitch.bin (from the app's Core ML run): Int32 frame count, then note (n x 88), onset (n x 88), contour (n x 264). */
function rows(buf: ArrayBuffer): [number[][], number[][], number[][]] {
  const n = new Int32Array(buf, 0, 1)[0], f = new Float32Array(buf, 4);
  const take = (from: number, w: number) => Array.from({ length: n }, (_, i) => Array.from(f.subarray(from + i * w, from + (i + 1) * w)));
  return [take(0, 88), take(n * 88, 88), take(n * 176, 264)];
}

window.__fm1audio = {
  analyse: (b64) => guarded(() => api.analyse(b64)),
  section: (start) => guarded(() => api.section(start)) as unknown as string,
};
tell("ready");
