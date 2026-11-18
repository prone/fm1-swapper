// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The audio import for the iOS app: the same analysis as the web app, in a hidden web view the app drives
// (App/AudioImport.swift). The app hands over the file's bytes; progress goes back through the "fm1audio" message
// handler; results come back as JSON.
import { AudioNote, Section, SongAudio, analyseSection, dropGhosts, suggestSections } from "./analysis";
import { decode, transcribe } from "./input";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { fm1audio?: { postMessage: (m: unknown) => void } } };
    __fm1audio?: { analyse: (b64: string) => Promise<string>; section: (start: number) => string };
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

window.__fm1audio = {
  async analyse(b64) {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    tell("Reading the audio…"); await wait();
    const y = await decode(bytes.buffer);
    if (y.length < 22050 * 4) throw new Error("That's under 4 seconds: a 4-bar section needs more.");
    tell("Finding the notes (Basic Pitch)…", 0);
    notes = dropGhosts(await transcribe(y, (f) => tell("Finding the notes (Basic Pitch)…", f)));
    tell("Finding the beat and the drums…"); await wait();
    song = new SongAudio(y);
    const sections: ReturnType<typeof plain>[] = [];
    for (const [i, t] of suggestSections(song, notes, 4).entries()) {
      tell(`Analysing section ${"ABCD"[i]}…`); await wait();
      sections.push(plain(analyseSection(song, notes, t)));
    }
    return JSON.stringify({ bpm: song.bpm, duration: song.duration, sections });
  },
  section(start) {
    if (!song) throw new Error("No audio analysed yet.");
    return JSON.stringify(plain(analyseSection(song, notes, start)));
  },
};
tell("ready");
