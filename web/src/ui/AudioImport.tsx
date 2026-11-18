// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The song editor's Import from audio: a file or a recording, its tempo and up to four 4-bar sections (moveable, to
// hear against the original), then their bass, chords, lead and drums onto the tracks chosen.
import { useEffect, useRef, useState } from "preact/hooks";
import { DRUM_LANES, SongDoc } from "../fm1kit/sloopsong";
import { SR } from "../audio/dsp";
import { AudioNote, Section, SongAudio, analyseSection, dropGhosts, suggestSections } from "../audio/analysis";
import { decode, startRecording, transcribe } from "../audio/input";
import { findLoops } from "../audio/loops";
import { bothLoop, originalLoop, sloopLoop } from "../audio/preview";
import { fmtDateTime } from "./common";
import { DEFAULT_TRACKS, Part, applyImport } from "../audio/toSong";
import { Bar, FileDrop } from "./common";

const PARTS: [Part, string][] = [["bass", "Bassline"], ["keys", "Chords"], ["lead", "Lead"], ["drums", "Drums"]];
type Preview = "original" | "sloop" | "both";
const PREVIEWS: [Preview, string][] = [["original", "Original"], ["sloop", "What SLOOP will play"], ["both", "Both"]];
const mmss = (t: number) => `${Math.floor(t / 60)}:${(t % 60).toFixed(1).padStart(4, "0")}`;
const yieldUI = () => new Promise((r) => setTimeout(r, 30));                     // (let the page paint the status)

/** `show`: opens a section in the editor (after Apply, the first one imported); `named`: the audio's name, on Apply. */
export function AudioImport({ doc, edit, show, named, close }: { doc: SongDoc; edit: (f: (d: SongDoc) => void) => void; show: (section: number) => void; named: (name: string) => void; close: () => void }) {
  const [phase, setPhase] = useState<"pick" | "recording" | "working" | "review">("pick");
  const [status, setStatus] = useState(""), [progress, setProgress] = useState<number | null>(null), [err, setErr] = useState("");
  const [name, setName] = useState("");
  const song = useRef<SongAudio | null>(null), notes = useRef<AudioNote[]>([]);
  const [sections, setSections] = useState<Section[]>([]);
  const [targets, setTargets] = useState<number[]>([]);
  const [tracks, setTracks] = useState(DEFAULT_TRACKS);
  const [setTempo, setSetTempo] = useState(true), [setOrder, setSetOrder] = useState(true);
  const rec = useRef<Awaited<ReturnType<typeof startRecording>> | null>(null);
  const [level, setLevel] = useState(0), [recFor, setRecFor] = useState(0);
  const player = useRef<{ ctx: AudioContext; src?: AudioBufferSourceNode } | null>(null);

  useEffect(() => () => { rec.current?.cancel(); void player.current?.ctx.close(); }, []);
  useEffect(() => {                                                              // the recording's level meter and time
    if (phase !== "recording") return;
    const t0 = Date.now(), id = setInterval(() => { setLevel(rec.current?.level() ?? 0); setRecFor((Date.now() - t0) / 1000); }, 100);
    return () => clearInterval(id);
  }, [phase]);

  /** The audio in: notes (Basic Pitch), beats, and the suggested sections analysed. */
  const analyse = async (y: Float32Array, label: string) => {
    setErr(""); setName(label); setPhase("working");
    try {
      if (y.length < SR * 4) throw new Error("That's under 4 seconds: a 4-bar section needs more.");
      setStatus("Finding the notes (Basic Pitch)…"); setProgress(0); await yieldUI();
      notes.current = dropGhosts(await transcribe(y, (f) => setProgress(f)));
      setStatus("Finding the beat and the drums…"); setProgress(null); await yieldUI();
      song.current = new SongAudio(y);
      // the song's own loops; a short recording that doesn't repeat: the busiest 4-bar stretches instead
      setStatus("Finding the loops…"); setProgress(0); await yieldUI();
      const secs: Section[] = await findLoops(song.current, notes.current, 4, async (f) => { setProgress(f); await yieldUI(); });
      setProgress(null);
      if (!secs.length) for (const [i, t] of suggestSections(song.current, notes.current, 4).entries()) {
        setStatus(`Analysing section ${"ABCD"[i]}…`); await yieldUI();
        secs.push(analyseSection(song.current, notes.current, t));
      }
      setSections(secs); setTargets(secs.map((_, i) => i)); setPhase("review");
    } catch (e) { setErr((e as Error).message || String(e)); setPhase("pick"); }
  };

  const moveSection = (i: number, by: number) => moveTo(i, sections[i].start + by * (60 / (song.current?.bpm ?? 120)));
  /** The piece analysed again from `t` (snapped by the analysis to the downbeat nearby). */
  const moveTo = async (i: number, t: number) => {
    stopPreview();
    const s = song.current; if (!s) return;
    const start = Math.max(0, Math.min(s.duration - 16 * (60 / s.bpm), t));
    setStatus(`Analysing section ${"ABCD"[targets[i]]}…`); setPhase("working"); await yieldUI();
    const sec = analyseSection(s, notes.current, start);
    setSections(sections.map((x, j) => (j === i ? sec : x))); setPhase("review");
  };
  const addSection = async () => {
    const s = song.current; if (!s || sections.length >= 4) return;
    const last = sections[sections.length - 1], beat = 60 / s.bpm;
    const start = last ? Math.min(s.duration - 16 * beat, last.start + 16 * beat) : 0;
    setStatus("Analysing…"); setPhase("working"); await yieldUI();
    const sec = analyseSection(s, notes.current, Math.max(0, start));
    setSections([...sections, sec]);
    setTargets([...targets, [0, 1, 2, 3].find((k) => !targets.includes(k)) ?? 0]);
    setPhase("review");
  };

  /** A piece on repeat: its original 4 bars, what SLOOP will play from it (the parts going onto tracks, each at its
   *  track's length), or both; the same again stops it. */
  const [playing, setPlaying] = useState<{ i: number; mode: Preview } | null>(null);
  const stopPreview = () => { try { player.current?.src?.stop(); } catch { /* not started */ } setPlaying(null); };
  const preview = (i: number, mode: Preview) => {
    const y = song.current?.y, sec = sections[i]; if (!y || !sec) return;
    const same = playing?.i === i && playing.mode === mode;
    stopPreview();
    if (same) return;
    const parts = new Set(PARTS.map(([p]) => p).filter((p) => tracks[p] != null));
    const orig = mode !== "sloop" ? originalLoop(y, sec) : null, sloop = mode !== "original" ? sloopLoop(sec, parts) : null;
    const x = orig && sloop ? bothLoop(orig, sloop) : (orig ?? sloop)!;
    const ctx = player.current?.ctx ?? new AudioContext();
    const buf = ctx.createBuffer(1, x.length, SR); buf.copyToChannel(x as Float32Array<ArrayBuffer>, 0);
    const src = ctx.createBufferSource(); src.buffer = buf; src.loop = true; src.connect(ctx.destination); src.start();
    player.current = { ctx, src }; setPlaying({ i, mode });
  };

  const apply = () => {
    stopPreview();
    const bpm = song.current?.bpm ?? 120;
    edit((d) => applyImport(d, { sections, targets, tracks, tempo: setTempo ? bpm : null, order: setOrder }));
    if (targets.length) show(targets[0]);
    named(name);
    close();
  };

  return (
    <div class="card" style={{ marginTop: 10 }}>
      <div class="tools" style={{ marginTop: 0 }}>
        <b style={{ flex: 1 }}>Import from audio{name ? ` · ${name}` : ""}</b>
        <button class="linkbtn" onClick={() => {
          // (the results took a while: ask before they go)
          if (phase === "review" && !window.confirm(`Close without importing? The analysis of “${name}” goes, and you'd have to run it again.`)) return;
          close();
        }}>Close</button>
      </div>
      {err && <div class="banner warn">{err}</div>}
      {phase === "pick" && (
        <>
          <p class="small dim">Turns audio into SLOOP parts: the tempo, then for up to four 4-bar sections a bassline, chords, a lead
            and drums (kick, snare, hats), on 16ths. A song works; one instrument at a time works best. Use audio you have the
            rights to. It's analysed here, in this browser: nothing is uploaded.</p>
          <FileDrop accept="audio/*,.mp3,.m4a,.wav,.aif,.aiff,.flac,.ogg" maxBytes={200 << 20} onFiles={async ([f]) => {
            try { void analyse(await decode(await f.arrayBuffer()), f.name.replace(/\.[^.]+$/, "")); }
            catch (e) { setErr(`${f.name}: this browser can't decode that audio (${(e as Error).message || e}).`); }
          }}>An audio file (MP3, M4A, WAV, AIFF, FLAC…).</FileDrop>
          <div class="tools">
            <button class="btn" onClick={async () => {
              setErr("");
              try { rec.current = await startRecording(); setPhase("recording"); } catch { setErr("The microphone isn't available (allow it for this site, then try again)."); }
            }}>● Record from the microphone</button>
          </div>
        </>
      )}
      {phase === "recording" && (
        <>
          <p class="small">Recording… {recFor.toFixed(0)} s. Play the part (or the song near the mic), then stop. 10–30 seconds is plenty.</p>
          <Bar value={Math.min(1, level * 4)} />
          <div class="tools">
            <button class="btn primary" onClick={async () => { const r = rec.current; rec.current = null; if (r) { setPhase("working"); setStatus("Reading the recording…"); try { void analyse(await r.stop(), `Recording ${fmtDateTime(Date.now())}`); } catch (e) { setErr((e as Error).message); setPhase("pick"); } } }}>■ Stop and analyse</button>
            <button class="linkbtn" onClick={() => { rec.current?.cancel(); rec.current = null; setPhase("pick"); }}>Cancel</button>
          </div>
        </>
      )}
      {phase === "working" && (<><p class="small">{status}</p><Bar value={progress} /></>)}
      {phase === "review" && song.current && (
        <>
          <p class="small" style={{ marginTop: 0 }}>{mmss(song.current.duration)} at about <b>{Math.round(song.current.bpm)} BPM</b>.{" "}
            {sections.length ? <>{sections.length === 1 ? "One 4-bar piece" : `${sections.length} 4-bar pieces`} of the song, picked from
              different parts of it. <b>All of them are imported</b>, each into the SLOOP section it's set to (A–D). Leave out any you
              don't want.</> : "No pieces left to import: add one below."}</p>
          <Overview y={song.current.y} duration={song.current.duration} pieces={sections.map((s, i) => [s.start, 16 * (60 / s.bpm), "ABCD"[targets[i]]] as const)} />
          <p class="small dim">Drag a piece's slider to where it should start, then fine-tune by a beat or a bar; it snaps to the nearest
            downbeat when you let go. The ▶ buttons play a piece on repeat: the original, what SLOOP will play from it (the parts going
            onto tracks, each looping at its own length, in plain sounds: on the FM-1 they play with the tracks' own sounds), or both.</p>
          <div class="rows" style={{ background: "transparent" }}>
            {sections.map((sec, i) => (
              <div key={i} style={{ flexWrap: "wrap", padding: "8px 0", alignItems: "flex-start" }}>
                <div style={{ minWidth: 220, flex: 1 }}>
                  <div class="tools" style={{ marginTop: 0 }}>
                    <b class="small">Piece {i + 1} → into</b>
                    <select value={targets[i]} aria-label={`Piece ${i + 1} goes into`} onChange={(e) => setTargets(targets.map((x, j) => (j === i ? Number((e.target as HTMLSelectElement).value) : x)))}>
                      {[0, 1, 2, 3].map((k) => <option key={k} value={k}>Section {"ABCD"[k]}{doc.isEmpty(["a", "b", "c", "d"][k] as "a") ? "" : " (replaces it)"}</option>)}
                    </select>
                    <span class="small mono">{mmss(sec.start)}–{mmss(sec.start + 16 * (60 / sec.bpm))}</span>
                    <input type="range" min={0} max={Math.max(0.1, song.current!.duration - 16 * (60 / sec.bpm))} step={0.05} value={sec.start}
                      style={{ flex: "1 1 160px" }} aria-label={`Where piece ${i + 1} starts`}
                      onChange={(e) => void moveTo(i, Number((e.target as HTMLInputElement).value))} />
                    <button class="btn small" onClick={() => void moveSection(i, -4)} aria-label="A bar earlier">−bar</button>
                    <button class="btn small" onClick={() => void moveSection(i, -1)} aria-label="A beat earlier">−beat</button>
                    <button class="btn small" onClick={() => void moveSection(i, 1)} aria-label="A beat later">+beat</button>
                    <button class="btn small" onClick={() => void moveSection(i, 4)} aria-label="A bar later">+bar</button>
                    <button class="linkbtn small" style={{ color: "var(--red)" }} onClick={() => { stopPreview(); setSections(sections.filter((_, j) => j !== i)); setTargets(targets.filter((_, j) => j !== i)); }}>Leave out</button>
                  </div>
                  {sec.repeats ? <div class="small">A loop of the song: plays <b>{sec.repeats}×</b>{sec.lengths ? ` · drums ${bars(sec.lengths.drums)}, bass ${bars(sec.lengths.bass)}, chords ${bars(sec.lengths.keys)}` : ""}.
                    {sec.unsure ? <span class="dim"> Not sure of this one: it repeats little, or a new sound comes in during it.</span> : null}</div>
                    : <div class="small dim">Your pick (not one of the song's loops).</div>}
                  <div class="tools" role="group" aria-label={`Hear piece ${i + 1} on repeat`}>
                    {PREVIEWS.map(([mode, label]) => {
                      const on = playing?.i === i && playing.mode === mode;
                      return <button key={mode} class={"btn small" + (on ? " primary" : "")} aria-pressed={on} onClick={() => preview(i, mode)}>{on ? "■" : "▶"} {label}</button>;
                    })}
                  </div>
                  <div class="small dim">{sec.bass.length} bass notes · {sec.keys.length} chords · {sec.lead.length} lead notes · {sec.drums.length} drum steps</div>
                  <DrumRows sec={sec} />
                </div>
              </div>
            ))}
          </div>
          {sections.length < 4 && <div class="tools"><button class="btn small" onClick={() => void addSection()}>Add another piece</button></div>}
          <h2 style={{ marginLeft: 0 }}>Onto the tracks</h2>
          <div class="tools">
            {PARTS.map(([part, label]) => (
              <label key={part} class="small">{label}
                <select value={tracks[part] ?? ""} onChange={(e) => { const v = (e.target as HTMLSelectElement).value; setTracks({ ...tracks, [part]: v === "" ? null : Number(v) }); }}>
                  {part === "drums" ? <option value="3">Drums</option> : [0, 1, 2].map((k) => <option key={k} value={k}>Track {k + 1}</option>)}
                  <option value="">Skip</option>
                </select>
              </label>
            ))}
          </div>
          <div class="tools">
            <label class="small"><input type="checkbox" checked={setTempo} onChange={(e) => setSetTempo((e.target as HTMLInputElement).checked)} /> Set the tempo to {Math.round(song.current.bpm)} BPM</label>
            <label class="small"><input type="checkbox" checked={setOrder} onChange={(e) => setSetOrder((e.target as HTMLInputElement).checked)} /> Song order: these sections in turn, 4 bars each</label>
          </div>
          {new Set(Object.values(tracks).filter((v) => v != null)).size < Object.values(tracks).filter((v) => v != null).length &&
            <div class="banner warn small">Two parts go on the same track: the later one replaces the earlier.</div>}
          <p class="small faint">The tracks chosen get 64 steps of 16ths with these notes; their sounds stay (change them on the FM-1). An empty section starts as a copy of the loop's sounds; an empty loop gets the first piece, so it plays as soon as SLOOP starts. Undo puts it all back.</p>
          <div class="tools">
            <button class="btn primary" disabled={!sections.length} onClick={apply}>Import into {[...new Set(targets.map((k) => "ABCD"[k]))].join(", ")}</button>
            <button class="linkbtn" onClick={() => { stopPreview(); setPhase("pick"); setSections([]); }}>Use other audio</button>
          </div>
        </>
      )}
    </div>
  );
}

const bars = (steps: number) => (steps === 16 ? "1 bar" : `${steps / 16} bars`);

/** A section's drums as rows of the lanes found (to check by eye against the original). */
function DrumRows({ sec }: { sec: Section }) {
  const lanes = [...new Set(sec.drums.flatMap(([, l]) => l))].sort((a, b) => a - b);
  if (!lanes.length) return <div class="small faint">No drums found.</div>;
  const at = new Set(sec.drums.flatMap(([st, ls]) => ls.map((l) => `${st},${l}`)));
  return (
    <div class="mono small" style={{ marginTop: 4, overflowX: "auto", whiteSpace: "pre" }} aria-label="Drums found">
      {lanes.map((l) => `${DRUM_LANES[l].padEnd(8)} ${[0, 1, 2, 3].map((b) => Array.from({ length: 16 }, (_, s) => (at.has(`${b * 16 + s},${l}`) ? "x" : "·")).join("")).join(" ")}`).join("\n")}
    </div>
  );
}

/** The whole audio's loudness, with each piece's 4 bars marked by the section it goes into. */
function Overview({ y, duration, pieces }: { y: Float32Array; duration: number; pieces: readonly (readonly [number, number, string])[] }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const env = useRef<Float32Array | null>(null);
  if (!env.current) {                                                     // (the peak of each of 400 slices, once)
    const n = 400, size = Math.max(1, Math.floor(y.length / n)), e = new Float32Array(n);
    for (let k = 0; k < n; k++) { let m = 0; for (let i = k * size; i < Math.min(y.length, (k + 1) * size); i += 4) m = Math.max(m, Math.abs(y[i])); e[k] = m; }
    const top = Math.max(...e) || 1;
    env.current = e.map((v) => v / top);
  }
  useEffect(() => {
    const c = canvas.current, g = c?.getContext("2d"); if (!c || !g || !env.current) return;
    const w = (c.width = c.clientWidth * devicePixelRatio), h = (c.height = 56 * devicePixelRatio), css = getComputedStyle(c);
    g.clearRect(0, 0, w, h);
    const x = (t: number) => (t / duration) * w;
    g.font = `bold ${11 * devicePixelRatio}px system-ui`;
    for (const [start, len, name] of pieces) {
      g.fillStyle = css.getPropertyValue("--accent-soft") || "rgba(80,140,255,.25)";
      g.fillRect(x(start), 0, Math.max(2, x(start + len) - x(start)), h);
      g.fillStyle = css.color; g.fillText(name, x(start) + 3 * devicePixelRatio, 12 * devicePixelRatio);
    }
    g.fillStyle = css.color; g.globalAlpha = 0.55;
    const bw = w / env.current.length;
    env.current.forEach((v, k) => { const bh = Math.max(1, v * (h - 16 * devicePixelRatio)); g.fillRect(k * bw, h - bh, Math.max(1, bw - 0.5), bh); });
    g.globalAlpha = 1;
  }, [pieces.map((p) => p.join()).join("|")]);
  return <canvas ref={canvas} style={{ width: "100%", height: 56, display: "block", margin: "6px 0" }} aria-label="The audio, with the pieces marked" />;
}
