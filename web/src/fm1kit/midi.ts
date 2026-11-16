// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// SysEx links over Web MIDI (Chrome, Edge, Opera, Chrome for Android; Safari has no Web MIDI).
// Same shape as MIDITransport.swift, so the protocol code can be tested with a simulated device.

export interface SysExLink {
  readonly name: string;
  send(bytes: number[]): boolean;
  /** Next SysEx message, or null after `ms`. */
  read(ms: number): Promise<number[] | null>;
  drain(): void;
  readonly lost: boolean;
  close(): void;
}

export interface PortCandidate { id: string; name: string }

export interface PortProvider {
  candidates(): PortCandidate[];
  open(c: PortCandidate): Promise<SysExLink>;
}

/** Ports the FM-1 (or its update loader) shows up as. Other gear is never probed. */
export const looksLikeFM1 = (name: string) => /fm-1|fm1|felucca|ota|composite|sinco|usb-midi/i.test(name);

/** A queue of received SysEx messages with a timed read. */
export class Inbox {
  private q: number[][] = [];
  private waiter: ((m: number[] | null) => void) | null = null;
  push(m: number[]) {
    if (this.waiter) { const w = this.waiter; this.waiter = null; w(m); } else this.q.push(m);
  }
  drain() { this.q.length = 0; }
  read(ms: number): Promise<number[] | null> {
    const m = this.q.shift();
    if (m) return Promise.resolve(m);
    return new Promise((resolve) => {
      const t = setTimeout(() => { if (this.waiter === done) { this.waiter = null; resolve(null); } }, Math.max(0, ms));
      const done = (v: number[] | null) => { clearTimeout(t); resolve(v); };
      this.waiter = done;
    });
  }
}

class WebMIDILink implements SysExLink {
  private inbox = new Inbox();
  private closed = false;
  constructor(readonly name: string, private input: MIDIInput, private output: MIDIOutput) {
    input.onmidimessage = (e: MIDIMessageEvent) => { if (e.data && e.data[0] === 0xf0) this.inbox.push(Array.from(e.data)); };
  }
  get lost() { return this.closed || this.input.state === "disconnected" || this.output.state === "disconnected"; }
  send(bytes: number[]) {
    if (this.lost) return false;
    try { this.output.send(bytes); return true; } catch { return false; }
  }
  read(ms: number) { return this.inbox.read(ms); }
  drain() { this.inbox.drain(); }
  close() { this.closed = true; this.input.onmidimessage = null; }
}

/** Web MIDI with SysEx. Ask for access from a user gesture (a Connect button). */
export class WebMIDIProvider implements PortProvider {
  private constructor(readonly access: MIDIAccess) {}

  static supported() { return typeof navigator !== "undefined" && "requestMIDIAccess" in navigator; }

  static async request(): Promise<WebMIDIProvider> {
    if (!WebMIDIProvider.supported()) throw new Error("This browser has no Web MIDI. Use Chrome or Edge (on a Mac, Windows, Linux, ChromeOS or Android).");
    try { return new WebMIDIProvider(await navigator.requestMIDIAccess({ sysex: true })); }
    catch { throw new Error("MIDI access was refused. Allow MIDI (with SysEx) for this site in the browser's settings."); }
  }

  onChange(cb: () => void) { this.access.onstatechange = () => cb(); }

  candidates(): PortCandidate[] {
    const outs = [...this.access.outputs.values()];
    return [...this.access.inputs.values()]
      .filter((i) => i.state !== "disconnected" && outs.some((o) => o.name === i.name && o.state !== "disconnected"))
      .map((i) => ({ id: i.id, name: i.name ?? "?" }));
  }

  async open(c: PortCandidate): Promise<SysExLink> {
    const input = this.access.inputs.get(c.id);
    const output = [...this.access.outputs.values()].find((o) => o.name === c.name && o.state !== "disconnected");
    if (!input || !output) throw new Error("The FM-1 is no longer connected.");
    await input.open(); await output.open();
    return new WebMIDILink(c.name, input, output);
  }
}
