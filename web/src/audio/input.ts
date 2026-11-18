// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Audio into the import: a file or a recording from the microphone, as mono 22050 Hz samples, and its notes from
// Basic Pitch (Spotify, Apache-2.0; its model in public/basic-pitch, loaded only when an import runs).
import { SR } from "./dsp";
import { AudioNote } from "./analysis";

/** Any audio the browser can decode, mixed to mono and resampled to 22050 Hz. */
export async function decode(bytes: ArrayBuffer): Promise<Float32Array> {
  // (offline contexts: no sound output is needed to decode)
  const buf = await new OfflineAudioContext(1, 1, 44100).decodeAudioData(bytes);
  const off = new OfflineAudioContext(1, Math.ceil(buf.duration * SR), SR);
  const src = off.createBufferSource();
  src.buffer = buf; src.connect(off.destination); src.start();
  return (await off.startRendering()).getChannelData(0);
}

/** A recording from the microphone (no echo cancelling or noise suppression: music, not speech). */
export async function startRecording(): Promise<{ stop: () => Promise<Float32Array>; cancel: () => void; level: () => number }> {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
  const rec = new MediaRecorder(stream), chunks: Blob[] = [];
  rec.ondataavailable = (e) => chunks.push(e.data);
  const ctx = new AudioContext(), an = ctx.createAnalyser();
  ctx.createMediaStreamSource(stream).connect(an);
  const buf = new Float32Array(an.fftSize);
  const end = () => { stream.getTracks().forEach((t) => t.stop()); void ctx.close(); };
  rec.start();
  return {
    level: () => { an.getFloatTimeDomainData(buf); return Math.sqrt(buf.reduce((a, v) => a + v * v, 0) / buf.length); },
    cancel: () => { rec.onstop = null; rec.stop(); end(); },
    stop: () => new Promise((resolve, reject) => {
      rec.onstop = async () => { end(); try { resolve(await decode(await new Blob(chunks, { type: rec.mimeType }).arrayBuffer())); } catch (e) { reject(e); } };
      rec.stop();
    }),
  };
}

/** Notes from Basic Pitch's model output (note, onset: n x 88; contour: n x 264, one row per frame), as transcribe()
 *  makes them: for output the iOS app computed with Core ML (on the iPad's Neural Engine / GPU). */
export async function notesFromOutput(frames: number[][], onsets: number[][], contours: number[][]): Promise<AudioNote[]> {
  const bp = await import("@spotify/basic-pitch");
  return toNotes(bp, frames, onsets, contours);
}

type BP = typeof import("@spotify/basic-pitch");
function toNotes(bp: BP, frames: number[][], onsets: number[][], contours: number[][]): AudioNote[] {
  const notes = bp.noteFramesToTime(bp.addPitchBendsToNoteEvents(contours, bp.outputToNotesPoly(frames, onsets, 0.5, 0.3, 7)));
  return notes.map((n) => ({ start: n.startTimeSeconds, end: n.startTimeSeconds + n.durationSeconds, pitch: n.pitchMidi, amp: n.amplitude }))
    .sort((a, b) => a.start - b.start || a.pitch - b.pitch);
}

/** The notes in the audio (Basic Pitch's settings as the prototype: onsets 0.5, frames 0.3, notes 80 ms or longer). */
export async function transcribe(y: Float32Array, progress: (f: number) => void): Promise<AudioNote[]> {
  const [bp, tf] = await Promise.all([import("@spotify/basic-pitch"), import("@tensorflow/tfjs")]);
  const run = async () => {
    const model = new bp.BasicPitch(new URL("basic-pitch/model.json", document.baseURI).href);
    const out = { frames: [] as number[][], onsets: [] as number[][], contours: [] as number[][] };
    await model.evaluateModel(y, (f, o, c) => { out.frames.push(...f); out.onsets.push(...o); out.contours.push(...c); }, progress);
    return out;
  };
  let r: Awaited<ReturnType<typeof run>>;
  try { r = await run(); } catch (e) {
    // the GPU (WebGL) path fails on some devices (an iPad's driver refusing a shader): the CPU path is slower but
    // runs everywhere
    if (tf.getBackend() === "cpu") throw e;
    await tf.setBackend("cpu");
    r = await run();
  }
  return toNotes(bp, r.frames, r.onsets, r.contours);
}
