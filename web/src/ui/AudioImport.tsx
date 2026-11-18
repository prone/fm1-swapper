// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The song editor's Import from audio: a file or a recording, its tempo and up to four 4-bar sections (moveable, to
// hear against the original), then their bass, chords, lead and drums onto the tracks chosen.
import { useEffect, useRef, useState } from "preact/hooks";
import { DRUM_LANES, SongDoc } from "../fm1kit/sloopsong";
import { SR } from "../audio/dsp";
import { AudioNote, Section, SongAudio, analyseSection, dropGhosts, suggestSections } from "../audio/analysis";
import { decode, startRecording, transcribe } from "../audio/input";
import { DEFAULT_TRACKS, Part, applyImport } from "../audio/toSong";
import { Bar, FileDrop } from "./common";

const PARTS: [Part, string][] = [["bass", "Bassline"], ["keys", "Chords"], ["lead", "Lead"], ["drums", "Drums"]];
const mmss = (t: number) => `${Math.floor(t / 60)}:${(t % 60).toFixed(1).padStart(4, "0")}`;
const yieldUI = () => new Promise((r) => setTimeout(r, 30));                     // (let the page paint the status)

/** `show`: opens a section in the editor (after Apply, the first one imported). */
export function AudioImport({ doc, edit, show, close }: { doc: SongDoc; edit: (f: (d: SongDoc) => void) => void; show: (section: number) => void; close: () => void }) {
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
      const starts = suggestSections(song.current, notes.current, 4);
      const secs: Section[] = [];
      for (const [i, t] of starts.entries()) {
        setStatus(`Analysing section ${"ABCD"[i]}…`); await yieldUI();
        secs.push(analyseSection(song.current, notes.current, t));
      }
      setSections(secs); setTargets(secs.map((_, i) => i)); setPhase("review");
    } catch (e) { setErr((e as Error).message || String(e)); setPhase("pick"); }
  };

  const moveSection = async (i: number, by: number) => {
    const s = song.current; if (!s) return;
    const beat = 60 / s.bpm, start = Math.max(0, Math.min(s.duration - 16 * beat, sections[i].start + by * beat));
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

  /** Plays the original audio of a section's 4 bars (to compare with what was found). */
  const listen = (sec: Section) => {
    const y = song.current?.y; if (!y) return;
    player.current?.src?.stop();
    const ctx = player.current?.ctx ?? new AudioContext();
    const buf = ctx.createBuffer(1, y.length, SR); buf.copyToChannel(y as Float32Array<ArrayBuffer>, 0);
    const src = ctx.createBufferSource(); src.buffer = buf; src.connect(ctx.destination);
    src.start(0, sec.start, 16 * (60 / sec.bpm));
    player.current = { ctx, src };
  };

  const apply = () => {
    const bpm = song.current?.bpm ?? 120;
    edit((d) => applyImport(d, { sections, targets, tracks, tempo: setTempo ? bpm : null, order: setOrder }));
    if (targets.length) show(targets[0]);
    close();
  };

  return (
    <div class="card" style={{ marginTop: 10 }}>
      <div class="tools" style={{ marginTop: 0 }}>
        <b style={{ flex: 1 }}>Import from audio{name ? ` · ${name}` : ""}</b>
        <button class="linkbtn" onClick={close}>Close</button>
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
            <button class="btn primary" onClick={async () => { const r = rec.current; rec.current = null; if (r) { setPhase("working"); setStatus("Reading the recording…"); try { void analyse(await r.stop(), "Recording"); } catch (e) { setErr((e as Error).message); setPhase("pick"); } } }}>■ Stop and analyse</button>
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
          <p class="small dim">Each piece starts on the downbeat found from the kicks and snares; move it by a beat or a bar if it's off, and ▶ to hear the original.</p>
          <div class="rows" style={{ background: "transparent" }}>
            {sections.map((sec, i) => (
              <div key={i} style={{ flexWrap: "wrap", padding: "8px 0", alignItems: "flex-start" }}>
                <div style={{ minWidth: 220, flex: 1 }}>
                  <div class="tools" style={{ marginTop: 0 }}>
                    <b class="small">Piece {i + 1} → into</b>
                    <select value={targets[i]} aria-label={`Piece ${i + 1} goes into`} onChange={(e) => setTargets(targets.map((x, j) => (j === i ? Number((e.target as HTMLSelectElement).value) : x)))}>
                      {[0, 1, 2, 3].map((k) => <option key={k} value={k}>Section {"ABCD"[k]}{doc.isEmpty(["a", "b", "c", "d"][k] as "a") ? "" : " (replaces it)"}</option>)}
                    </select>
                    <span class="small">from {mmss(sec.start)}</span>
                    <button class="btn small" onClick={() => void moveSection(i, -4)} aria-label="A bar earlier">−bar</button>
                    <button class="btn small" onClick={() => void moveSection(i, -1)} aria-label="A beat earlier">−beat</button>
                    <button class="btn small" onClick={() => void moveSection(i, 1)} aria-label="A beat later">+beat</button>
                    <button class="btn small" onClick={() => void moveSection(i, 4)} aria-label="A bar later">+bar</button>
                    <button class="btn small" onClick={() => listen(sec)}>▶ Listen</button>
                    <button class="linkbtn small" style={{ color: "var(--red)" }} onClick={() => { setSections(sections.filter((_, j) => j !== i)); setTargets(targets.filter((_, j) => j !== i)); }}>Leave out</button>
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
            <button class="linkbtn" onClick={() => { setPhase("pick"); setSections([]); }}>Use other audio</button>
          </div>
        </>
      )}
    </div>
  );
}

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
