// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// fm1-emu (served from emu/, same origin) with a firmware loaded, and the tutorial card docked beside it
// (mirrors App/Views/EmulatorView.swift and TutorialPlayer.swift). The bridge is public/emu-bridge.js.
import { useEffect, useRef, useState } from "preact/hooks";
import { Firmware, store } from "../store";
import { toB64 } from "../fm1kit/archive";
import { sleep } from "../fm1kit/ota";
import { Action, AwaitTracker, Dock, Tutorial, awaitText } from "../tutorial";

interface EmuWindow extends Window {
  __fm1load?: (b64: string, name: string) => Promise<string | undefined>;
  __fm1spot?: (names: string[]) => string[];
  __fm1do?: (actions: Action[]) => Promise<string>;
  __fm1action?: (kind: string, arg: string) => Promise<{ ok: boolean; message: string }>;
}
declare global { interface Window { __fm1onEvent?: (name: string, down: boolean) => void } }
const DOCKS: Dock[] = ["bottom", "top", "left", "right"];
function savedDock(): Dock { try { const d = localStorage.getItem("tutorialDock") as Dock; return DOCKS.includes(d) ? d : "bottom"; } catch { return "bottom"; } }

/** `start`: an emulator save to import once the firmware is loaded (a SLOOP song from the song editor), and what to say. */
export function Emulator({ f, tutorial, start, title, close }: { f: Firmware; tutorial?: Tutorial; start?: { save: string; hint: string }; title?: string; close: () => void }) {
  const frame = useRef<HTMLIFrameElement>(null);
  const [status, setStatus] = useState("Loading the emulator…");
  const [dock, setDock] = useState<Dock>(savedDock);
  const emu = () => frame.current?.contentWindow as EmuWindow | null;

  const onLoad = async () => {
    const w = emu();
    for (let i = 0; i < 100 && !w?.__fm1load; i++) await sleep(100);
    const bytes = await store.packageBytes(f.sha256);
    if (!w?.__fm1load || !bytes) { setStatus("The emulator didn't load."); return; }
    const err = await w.__fm1load(toB64(bytes), f.fileName || `${f.product}.fwsc`);
    if (err && err !== "ok") { setStatus(err); return; }
    if (start) {
      const r = await w.__fm1action?.("import", start.save);
      setStatus(r?.ok ? start.hint : `Couldn't load the song: ${r?.message ?? "the emulator has no import"}`);
      return;
    }
    setStatus("Press Start, then play the panel (or your computer keyboard / a MIDI keyboard).");
  };

  useEffect(() => { const k = (e: KeyboardEvent) => { if (e.key === "Escape" && !frame.current?.contains(document.activeElement)) close(); }; addEventListener("keydown", k); return () => removeEventListener("keydown", k); }, []);

  return (
    <div class="emu" role="dialog" aria-label={`${f.name} in the emulator`}>
      <div class="emu-top">
        <button class="btn" onClick={close}>Close</button>
        <b class="ellipsis" style={{ flex: 1 }}>{tutorial?.title ?? title ?? f.name}</b>
        <span class="small dim ellipsis" style={{ maxWidth: "45%" }}>{status}</span>
      </div>
      <div class={"emu-body " + dock}>
        <iframe ref={frame} src="emu/" title="FM-1 emulator" allow="midi; autoplay" onLoad={onLoad} />
        {tutorial && <TutorialCard t={tutorial} emu={emu} dock={dock} setDock={(d) => { setDock(d); try { localStorage.setItem("tutorialDock", d); } catch { /* private window */ } }} close={close} frame={frame} />}
      </div>
    </div>
  );
}

function TutorialCard({ t, emu, dock, setDock, close, frame }: { t: Tutorial; emu: () => EmuWindow | null; dock: Dock; setDock: (d: Dock) => void; close: () => void; frame: { current: HTMLIFrameElement | null } }) {
  const [i, setI] = useState(0);
  const [done, setDone] = useState(false);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [sources, setSources] = useState(false);
  const tracker = useRef<AwaitTracker>(new AwaitTracker(undefined));
  const step = t.steps[i] ?? { title: t.title, text: "This tutorial has no steps." };
  const setupDone = useRef(false);

  const running = () => { try { return frame.current?.contentDocument?.getElementById("start")?.hidden === true; } catch { return false; } };

  async function run(actions: Action[]) {
    setBusy(true);
    try {
      for (let n = 0; !running(); n++) {
        if (n === 0) setProblem("Press Start on the synth, and the demo will play.");
        if (n > 120) return;
        await sleep(500);
      }
      setProblem(null);
      const r = await emu()?.__fm1do?.(actions);
      if (r && r !== "ok") setProblem(r);
    } finally { setBusy(false); }
  }

  // spotlight and await for each step
  useEffect(() => {
    tracker.current = new AwaitTracker(step.await);
    setDone(!step.await);
    setProblem(null);
    let stop = false;
    (async () => {
      for (let n = 0; n < 100 && !emu()?.__fm1spot; n++) await sleep(100);
      if (stop) return;
      const unknown = emu()?.__fm1spot?.(step.highlight ?? []) ?? [];
      if (unknown.length) setProblem(`Unknown control names: ${unknown.join(", ")}`);
      if (!setupDone.current && t.setup?.length) { setupDone.current = true; void run(t.setup); }
    })();
    return () => { stop = true; };
  }, [i]);

  useEffect(() => {
    window.__fm1onEvent = (name, down) => { if (tracker.current.event(name, down)) setDone(true); };
    // the emulator's own Web MIDI input (a keyboard or pad) arrives inside the page; notes from the bridge use "#<note>"
    return () => { window.__fm1onEvent = undefined; try { emu()?.__fm1spot?.([]); } catch { /* frame gone */ } };
  }, []);

  const last = i === t.steps.length - 1;
  const at = awaitText(step.await);
  return (
    <section class="tut" aria-live="polite">
      <div style={{ display: "flex", gap: 8, alignItems: "flex-start" }}>
        <h3 style={{ flex: 1 }}>{step.title}</h3>
        <span class="small dim">{i + 1} / {t.steps.length}</span>
        <button class="linkbtn" aria-label="Close tutorial" onClick={close}>✕</button>
      </div>
      <div class="bar"><i style={{ width: `${((i + 1) / Math.max(t.steps.length, 1)) * 100}%` }} /></div>
      <div>{step.text}</div>
      {at && <div class="await">{done ? "✓ Done" : "👉 " + at}</div>}
      {problem && <div class="small" style={{ color: "var(--orange)" }}>{problem}</div>}
      <div class="btnrow">
        <button class="btn" disabled={i === 0 || busy} onClick={() => setI(i - 1)}>‹ Back</button>
        {step.show?.length ? <button class="btn" disabled={busy} onClick={() => run(step.show!)}>{busy ? "Playing…" : "▶ Show me"}</button> : null}
        <button class="btn primary" disabled={busy} onClick={() => last ? close() : setI(i + 1)}>{last ? "Finish" : done ? "Next ›" : "Skip ›"}</button>
      </div>
      <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }} class="small">
        {!t.reviewed && <span class="badge" title="Drafted from the firmware's docs; not yet checked by a person">DRAFT</span>}
        {t.sources?.length ? <button class="linkbtn small" onClick={() => setSources(!sources)}>Sources ({t.sources.length})</button> : null}
        <span class="dockpick" style={{ marginLeft: "auto" }} aria-label="Card position">
          {DOCKS.map((d) => <button key={d} class={d === dock ? "on" : ""} onClick={() => setDock(d)}>{d}</button>)}
        </span>
      </div>
      {sources && <ul class="small" style={{ margin: 0, paddingLeft: 18 }}>{t.sources!.map((s) => <li key={s}><a href={s} target="_blank" rel="noopener noreferrer">{s}</a></li>)}</ul>}
    </section>
  );
}
