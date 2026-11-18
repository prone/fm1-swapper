// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Editors for work saved from each firmware, used without the FM-1 (mirrors FirmwareEditorView.swift and
// SLOOPSongEditor.swift): one entry per firmware, SLOOP first. Saving from the FM-1 stays on the Device tab.
import { useEffect, useRef, useState } from "preact/hooks";
import { Backup, Firmware, store, uid } from "../store";
import { emulatorSaveText, emulatorSectors, putSong } from "../fm1kit/sloopflash";
import { autoSongName, backupRecord, device } from "../device";
import { totalBytes } from "../fm1kit/archive";
import { Clip, SONG_EXT, readSongFile, sameSong, songFile, stepNotes, DIV_NAMES, DRUM_LANES, DRUM_TRACK, MAX_ENTRIES, MAX_STEPS, SLOTS, Slot, SongDoc, Track, sectionSlot, slotName, slotSection, totalBars } from "../fm1kit/sloopsong";
import { DeviceBusy, FileDrop, Library, fmtDateTime, saveFile, useDevice } from "./common";
import { AudioImport } from "./AudioImport";

/** Whether the song editor has unsaved changes (main.tsx asks before another tab replaces it). */
export const unsavedEdits = { dirty: false };

type Play = (f: Firmware, save: string, title: string) => void;

export function FirmwareEditor({ lib, play }: { lib: Library; play: Play }) {
  const [view, setView] = useState<"home" | "sloop">("home");
  const songs = lib.backups.filter((b) => b.kind === "song");
  if (view === "sloop") return <SloopSongs lib={lib} play={play} back={() => setView("home")} />;
  return (
    <>
      <h1>Firmware Editor</h1>
      <div class="rows">
        <button class="rowbtn" onClick={() => setView("sloop")}>
          <span class="row-main"><b>SLOOP</b><div class="small dim">Songs: the song order, sections A–D, notes, drums, bars</div></span>
          <span class="dim">{songs.length ? `${songs.length} song${songs.length === 1 ? "" : "s"}` : "No songs yet"} ›</span>
        </button>
      </div>
      <p class="small faint">Edit what you've saved from each firmware, without the FM-1 connected. Send it back to the FM-1 when you're done.</p>
    </>
  );
}

const sectionsOf = (b: Backup) => {
  const used = (b.archive?.parts ?? []).filter((p) => ["2", "3", "4", "5"].includes(p.id) && p.data).map((p) => "ABCD"[Number(p.id) - 2]);
  return used.length ? "sections " + used.join(" ") : "no sections";
};

function SloopSongs({ lib, play, back }: { lib: Library; play: Play; back: () => void }) {
  const s = useDevice();
  const busy = !!s.busy;
  const [q, setQ] = useState("");
  const [editing, setEditing] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);
  const [renaming, setRenaming] = useState<string | null>(null);
  const [newName, setNewName] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const songs = lib.backups.filter((b) => b.kind === "song").sort((a, b) => b.date - a.date);
  const shown = q ? songs.filter((b) => b.label.toLowerCase().includes(q.toLowerCase())) : songs;
  const open = songs.find((b) => b.id === editing);
  if (open) return <SongEditor song={open} lib={lib} play={play} reopen={setEditing} close={() => setEditing(null)} />;
  const fwName = (b: Backup) => lib.firmwares.find((f) => f.id === b.firmwareId)?.name;
  return (
    <>
      <p><button class="linkbtn" onClick={back}>‹ Firmware Editor</button></p>
      <h1>SLOOP songs</h1>
      <DeviceBusy s={s} />
      {songs.length > 3 && <input type="text" placeholder="Search songs" value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} style={{ width: "100%", marginBottom: 10 }} />}
      {!songs.length && <div class="card dim">No SLOOP songs yet. With SLOOP on the FM-1, use Device → SLOOP songs → Save the song on the FM-1, or import a song file below (Share song file in the iPhone or iPad app).</div>}
      {shown.length > 0 && <div class="rows">
        {shown.map((b) => (
          <div key={b.id}>
            {renaming === b.id ? (
              <>
                <input type="text" value={newName} maxLength={60} aria-label="New name" onInput={(e) => setNewName((e.target as HTMLInputElement).value)} />
                <button class="linkbtn small" onClick={async () => { if (newName.trim()) await store.saveBackup({ ...b, label: newName.trim() }); setRenaming(null); }}>Save</button>
                <button class="linkbtn small" onClick={() => setRenaming(null)}>Cancel</button>
              </>
            ) : confirm === b.id ? (
              <>
                <span class="row-main">Replace the song on the FM-1 with “{b.label}”? Save the FM-1's song first to keep it.</span>
                <button class="btn small" disabled={busy} onClick={() => { setConfirm(null); void device.loadSong(b, autoSongName()); }}>Save it, then load</button>
                <button class="btn small danger" disabled={busy} onClick={() => { setConfirm(null); void device.loadSong(b); }}>Replace</button>
                <button class="linkbtn small" onClick={() => setConfirm(null)}>Cancel</button>
              </>
            ) : (
              <>
                <button class="linkbtn row-main" style={{ textAlign: "left", color: "var(--text)" }} onClick={() => setEditing(b.id)}>
                  {b.label}<div class="dim small">{fmtDateTime(b.date)}{fwName(b) ? ` · ${fwName(b)}` : ""} · {sectionsOf(b)}</div>
                </button>
                <button class="linkbtn small" onClick={() => setEditing(b.id)}>Edit</button>
                <button class="linkbtn small" disabled={busy} onClick={() => setConfirm(b.id)}>Load</button>
                <button class="linkbtn small" onClick={() => void store.saveBackup({ ...b, id: uid(), label: `${b.label} copy`, date: Date.now() })}>Duplicate</button>
                <button class="linkbtn small" onClick={() => { setNewName(b.label); setRenaming(b.id); }}>Rename</button>
                <button class="linkbtn small" onClick={() => { if (b.archive) { const f = songFile(b.archive, b.label); saveFile(f.name, f.text, "application/json"); } }}>Download</button>
                <button class="linkbtn small" style={{ color: "var(--red)" }} onClick={() => window.confirm(`Delete “${b.label}”? The FM-1 isn't changed.`) && void store.deleteBackup(b)}>Delete</button>
              </>
            )}
          </div>
        ))}
      </div>}
      <h2>Import song files</h2>
      <FileDrop accept={`.${SONG_EXT},.json`} multiple onFiles={async (files) => {
        const out: string[] = [], have = (await store.backups()).filter((x) => x.kind === "song" && x.archive);
        for (const f of files) {
          try {
            const { archive, name } = readSongFile(await f.text());
            const label = name ?? f.name.replace(/\.(fm1song|json)$/i, "").replace(/\.sloop-song$/i, "");
            const twin = have.find((x) => sameSong(x.archive!, archive));
            if (twin) { out.push(`“${twin.label}” is already here, with the same notes.`); continue; }
            const fw = lib.firmwares.find((x) => x.product === (archive.info.identity ?? archive.firmware));
            const added = { ...backupRecord(archive, fw?.id ?? "", "song"), label };
            await store.saveBackup(added);
            have.push(added);
            out.push(`Added “${label}”.`);
          } catch (e) { out.push(`${f.name}: ${(e as Error).message}`); }
        }
        setMsg(out.join(" "));
      }}>A <b>.{SONG_EXT}</b> song file shared from the iPhone or iPad app (or downloaded here). Older .sloop-song.json downloads work too.</FileDrop>
      {msg && <div class="banner ok">{msg}</div>}
    </>
  );
}

// ---- the song editor

const LENGTHS: [string, number][] = [["1/16", 1 / 16], ["1/8", 1 / 8], ["1/4", 1 / 4], ["1/2", 1 / 2], ["1 bar", 1]];
const NOTE = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"];
const noteName = (p: number) => `${NOTE[p % 12]}${Math.floor(p / 12) - 1}`;
const fmtBars = (b: number) => Number.isInteger(b) ? String(b) : b.toFixed(2).replace(/0+$/, "");

function SongEditor({ song, lib, play, reopen, close }: { song: Backup; lib: Library; play: Play; reopen: (id: string) => void; close: () => void }) {
  const s = useDevice();
  const [doc, setDoc] = useState<SongDoc | null>(null);
  const [saved, setSaved] = useState<SongDoc | null>(null);
  const [err, setErr] = useState("");
  const [tick, setTick] = useState(0);
  const undo = useRef<SongDoc[]>([]);
  const [slot, setSlot] = useState<Slot>("loop");
  const [track, setTrack] = useState(0);
  const [bars, setBars] = useState<[number, number] | null>(null);
  const [allTracks, setAllTracks] = useState(true);
  const [clip, setClip] = useState<{ clips: Map<number, Clip>; text: string } | null>(null);
  const [noteLen, setNoteLen] = useState(0);
  const [low, setLow] = useState<Record<string, number>>({});
  const [sending, setSending] = useState(false);
  const [problem, setProblem] = useState("");
  const [importing, setImporting] = useState(false);

  useEffect(() => {
    try { if (!song.archive) throw new Error("The saved song can't be read."); const d = SongDoc.open(song.archive); setDoc(d); setSaved(d.clone()); }
    catch (e) { setErr((e as Error).message); }
  }, [song.id]);
  if (!doc) return (<><p><button class="linkbtn" onClick={close}>‹ SLOOP songs</button></p><div class="banner err">Can't open this song. {err}</div></>);

  const dirty = !!saved && !doc.same(saved);
  unsavedEdits.dirty = dirty;
  const edit = (f: (d: SongDoc) => void) => {
    const before = doc.clone();
    f(doc);
    if (doc.same(before)) return;
    undo.current.push(before);
    if (undo.current.length > 100) undo.current.shift();
    setTick((t) => t + 1);
  };
  const doUndo = () => { const last = undo.current.pop(); if (last) { setDoc(last); setTick((t) => t + 1); } };
  /** Saves the edits into the song (as a new song with `asLabel`); null, with the reason shown, when that failed. */
  const save = async (asLabel?: string): Promise<Backup | null> => {
    const a = doc.archive();
    const b: Backup = { ...song, ...(asLabel ? { id: uid(), label: asLabel } : {}), archive: a, date: Date.now(), sizeBytes: totalBytes(a), partsSummary: `${a.parts.length} parts` };
    try { await store.saveBackup(b); } catch (e) { setProblem(`Couldn't save: ${(e as Error).message}`); return null; }
    setSaved(doc.clone());
    return b;
  };
  /** Saves as a new song and goes on editing that one (the original stays as it was). */
  const saveCopy = async () => {
    const name = prompt("Save as a new song", `${song.label} (edit)`);
    if (name == null) return;
    const b = await save(name.trim() || `${song.label} (edit)`);
    if (b) reopen(b.id);
  };
  const send = async (saveFirst: boolean) => {
    setSending(false);
    const b = dirty ? await save() : song;
    if (b) void device.loadSong(b, saveFirst ? autoSongName() : null);
  };
  /** SLOOP in the emulator with the song as it is now (edits included): written into the emulator's saved flash. */
  const playIt = async () => {
    setProblem("");
    // the song's own SLOOP first, then the newest; the first one whose package is in the library
    const sloop = lib.firmwares.filter((f) => f.sha256 && /sloop/i.test(f.name))
      .sort((a, b) => Number(b.id === song.firmwareId) - Number(a.id === song.firmwareId) || b.version.localeCompare(a.version, undefined, { numeric: true }));
    let fw: Firmware | undefined, pkg: Uint8Array | null = null;
    for (const f of sloop) if ((pkg = await store.packageBytes(f.sha256))) { fw = f; break; }
    if (!fw || !pkg) { setProblem("The emulator needs SLOOP in your library. Add it from Get firmware (SLOOP 2.6 or later), then try again."); return; }
    try {
      const sectors = await emulatorSectors(fw.sha256);
      putSong(doc.archive(), sectors);
      play(fw, emulatorSaveText(pkg, fw.sha256, fw.name, sectors), `${song.label} · ${fw.name}`);
    } catch (e) { setProblem((e as Error).message); }
  };
  const leave = () => { if (!dirty || window.confirm("Close without saving your changes?")) { unsavedEdits.dirty = false; close(); } };

  const p = doc.patterns[slot];
  const t = p?.track(track);
  const order = doc.order;
  const bpm = doc.patterns.loop?.bpm ?? 120;
  const tracks = allTracks ? [0, 1, 2, 3] : [track];
  const stepRange = (tr: Track): [number, number] | null => {
    const per = tr.barSteps;
    return bars && per ? [per * bars[0], Math.min(MAX_STEPS, per * (bars[1] + 1))] : null;
  };
  const forTracks = (f: (tr: Track) => void) => edit((d) => { const pat = d.patterns[slot]; if (pat) for (const k of tracks) f(pat.track(k)); });
  const tapBar = (b: number) => setBars(bars && bars[0] === b && bars[1] === b ? null : bars && bars[0] === bars[1] ? [Math.min(bars[0], b), Math.max(bars[1], b)] : [b, b]);
  const copyBars = (r: [number, number]) => {
    if (!p) return;
    const clips = new Map<number, Clip>();
    for (const k of tracks) { const tr = p.track(k), per = tr.barSteps; if (per) clips.set(k, tr.copy(per * r[0], per * (r[1] + 1))); }
    const one = r[0] === r[1];
    setClip({ clips, text: `${slot === "loop" ? "the loop" : `section ${slotName(slot)}`}, bar${one ? "" : "s"} ${r[0] + 1}${one ? "" : `–${r[1] + 1}`}, ${clips.size === 1 ? (track === DRUM_TRACK ? "drums" : `track ${track + 1}`) : "all tracks"}` });
    return clips;
  };
  const pasteBars = (at: number | null, insert: boolean, from = clip?.clips) => {
    if (!from) return;
    const one = from.size === 1 ? [...from.values()][0] : null;
    edit((d) => {
      const pat = d.patterns[slot];
      if (!pat) return;
      for (const k of one ? [track] : [...from.keys()]) {
        const c = one ?? from.get(k)!, tr = pat.track(k), per = tr.barSteps;
        if (!per) continue;
        const pos = at == null ? tr.length : at * per;
        if (insert) tr.insert(c, Math.min(pos, tr.length)); else tr.paste(c, pos);
      }
    });
  };
  const secs = order ? Math.round(totalBars(order) * 4 * 60 / Math.max(40, bpm)) : 0;
  const key = `${slot}${track}`;
  const lowNote = low[key] ?? (() => { const n = t?.chords.flatMap((c) => c.notes) ?? []; return n.length ? Math.min(103, Math.floor(Math.min(...n) / 12) * 12) : 48; })();

  return (
    <>
      <div class="tools" style={{ marginTop: 12 }}>
        <button class="linkbtn" onClick={leave}>‹ SLOOP songs</button>
        <span style={{ flex: 1 }} />
        <button class="btn small" disabled={!undo.current.length} onClick={doUndo}>Undo</button>
        <button class="btn small" disabled={!dirty} onClick={() => void save()}>Save changes</button>
        <button class="btn small" onClick={() => void saveCopy()}>Save as new…</button>
        <button class="btn small" onClick={() => { const f = songFile(doc.archive(), song.label); saveFile(f.name, f.text, "application/json"); }}>Download</button>
        <button class="btn small" onClick={() => setImporting(!importing)}>Import from audio…</button>
        <button class="btn small" onClick={() => void playIt()}>▶ Play in the emulator</button>
        <button class="btn small primary" disabled={!!s.busy} onClick={() => setSending(true)}>Send to FM-1…</button>
      </div>
      <h1>{song.label}{dirty && <span class="dim small"> · edited</span>}</h1>
      <DeviceBusy s={s} />
      {problem && <div class="banner warn">{problem}</div>}
      {importing && <AudioImport doc={doc} edit={edit} close={() => setImporting(false)} />}
      {sending && (
        <div class="banner warn">
          <b>Send “{song.label}” to the FM-1?</b>
          <div class="small">Saves your changes here, then replaces the loop, sections A–D and the song order on the FM-1 (SLOOP connected).
            Save the FM-1's song first to keep it.{doc.emptyEntries.length ? " Some song-order entries point at empty sections: SLOOP won't play song mode until they're filled." : ""}</div>
          <div class="btnrow">
            <button class="btn primary" disabled={!!s.busy} onClick={() => void send(true)}>Save the FM-1's song first, then send</button>
            <button class="btn danger" disabled={!!s.busy} onClick={() => void send(false)}>Send without saving it</button>
            <button class="linkbtn" onClick={() => setSending(false)}>Cancel</button>
          </div>
        </div>
      )}

      <h2>Song order</h2>
      <div class="card">
        {!order ? <div class="dim small">This song has no song order (SLOOP 2.5 or later keeps one).</div> : (
          <>
            <div class="rows" style={{ background: "transparent" }}>
              {order.entries.map((e, i) => (
                <div key={i} style={{ padding: "6px 0", flexWrap: "wrap" }}>
                  <span class="dim" style={{ width: 24, textAlign: "right" }}>{i + 1}</span>
                  <select value={e.section} onChange={(ev) => edit((d) => { d.order!.entries[i].section = Number((ev.target as HTMLSelectElement).value); })}>
                    {[0, 1, 2, 3].map((k) => <option key={k} value={k}>{"ABCD"[k]}{doc.isEmpty(sectionSlot(k)) ? " (empty)" : ""}</option>)}
                  </select>
                  <button class="btn small" disabled={e.bars <= 1} onClick={() => edit((d) => { d.order!.entries[i].bars--; })} aria-label={`Entry ${i + 1}: fewer bars`}>−</button>
                  <span style={{ minWidth: 64, textAlign: "center" }}>{e.bars} bar{e.bars === 1 ? "" : "s"}</span>
                  <button class="btn small" disabled={e.bars >= 64} onClick={() => edit((d) => { d.order!.entries[i].bars++; })} aria-label={`Entry ${i + 1}: more bars`}>+</button>
                  {doc.isEmpty(sectionSlot(e.section)) && <span style={{ color: "var(--orange)" }} title="Empty section" role="img" aria-label="Empty section">⚠︎</span>}
                  <span style={{ flex: 1 }} />
                  <button class="linkbtn" disabled={i === 0} onClick={() => edit((d) => { const x = d.order!.entries; [x[i - 1], x[i]] = [x[i], x[i - 1]]; })} aria-label={`Move entry ${i + 1} up`}>↑</button>
                  <button class="linkbtn" disabled={i === order.entries.length - 1} onClick={() => edit((d) => { const x = d.order!.entries; [x[i + 1], x[i]] = [x[i], x[i + 1]]; })} aria-label={`Move entry ${i + 1} down`}>↓</button>
                  <button class="linkbtn" style={{ color: "var(--red)" }} disabled={order.entries.length === 1} onClick={() => edit((d) => { d.order!.entries.splice(i, 1); })}>Remove</button>
                </div>
              ))}
            </div>
            <div class="tools">
              <button class="btn small" disabled={order.entries.length >= MAX_ENTRIES} onClick={() => {
                const k = slotSection(slot) ?? 0;
                edit((d) => { d.order!.entries.push({ section: k, bars: d.patterns[sectionSlot(k)]?.bars ?? 4 }); });
              }}>Add {"ABCD"[slotSection(slot) ?? 0]}</button>
              <label class="small"><input type="checkbox" checked={order.loops} onChange={(ev) => edit((d) => { d.order!.loops = (ev.target as HTMLInputElement).checked; })} /> Loop the song</label>
            </div>
            <p class="small dim" style={{ marginBottom: 0 }}>{order.entries.length} of {MAX_ENTRIES} entries · {totalBars(order)} bars · {Math.floor(secs / 60)}:{String(secs % 60).padStart(2, "0")} at {bpm} BPM{order.loops ? ", then again" : ""}.
              Each entry plays its section for that many bars, repeating the section's loop. On the FM-1, play it in song mode (SONG screen, or SAVE + key 13).
              {doc.emptyEntries.length > 0 && ` ⚠︎ Entries ${doc.emptyEntries.map((i) => i + 1).join(", ")} point at empty sections.`}</p>
          </>
        )}
      </div>

      <h2>Patterns</h2>
      <nav class="tabs" style={{ display: "inline-flex", marginBottom: 10 }}>
        {SLOTS.map((x) => <button key={x} aria-current={x === slot ? "page" : undefined} onClick={() => { setSlot(x); setBars(null); }}>{slotName(x)}{doc.isEmpty(x) ? " (empty)" : ""}</button>)}
      </nav>
      <div class="card">
        {doc.locked.has(slot) ? <div class="dim small">This one was saved by an older SLOOP (before 2.6). It's kept as it is and can't be edited here.</div>
          : !p || !t ? (
            <>
              <div class="small dim">Section {slotName(slot)} is empty. Start it as a copy of another pattern (sounds, notes and tempo), then change it.</div>
              <div class="tools">{SLOTS.filter((x) => x !== slot && doc.patterns[x]).map((x) => <button key={x} class="btn small" onClick={() => edit((d) => d.copy(x, slot))}>Copy {slotName(x)}</button>)}</div>
            </>
          ) : (
            <>
              <div class="small dim" style={{ marginBottom: 8 }}>{slot === "loop" ? "Loop in progress" : `Section ${slotName(slot)} · ${p.bars} bar${p.bars === 1 ? "" : "s"}`} · {p.bpm} BPM</div>
              <nav class="tabs" style={{ display: "inline-flex" }}>
                {[0, 1, 2, 3].map((k) => <button key={k} aria-current={k === track ? "page" : undefined} onClick={() => { setTrack(k); setBars(null); }}>{k === DRUM_TRACK ? "Drums" : `Track ${k + 1}`}</button>)}
              </nav>
              <div class="tools">
                <span>Length</span>
                <button class="btn small" disabled={t.length <= 1} onClick={() => edit((d) => { d.patterns[slot]!.track(track).length = t.length - 1; })} aria-label="Shorter">−</button>
                <span>{t.length} steps</span>
                <button class="btn small" disabled={t.length >= 64} onClick={() => edit((d) => { d.patterns[slot]!.track(track).length = t.length + 1; })} aria-label="Longer">+</button>
                <span class="dim small">{DIV_NAMES[t.div]} steps · {fmtBars(t.length / t.stepsPerBar)} bars</span>
                <span style={{ flex: 1 }} />
                <select value="" onChange={(ev) => {
                  const v = (ev.target as HTMLSelectElement).value; (ev.target as HTMLSelectElement).value = "";
                  if (v === "erase") edit((d) => d.erase(slot));
                  else if (v === "clear") edit((d) => d.patterns[slot]!.track(track).clearAll());
                  else if (v) edit((d) => d.copy(slot, v as Slot));
                }}>
                  <option value="">Section…</option>
                  {SLOTS.filter((x) => x !== slot && !doc.locked.has(x)).map((x) => <option key={x} value={x}>Copy {slotName(slot)} to {slotName(x)}{doc.isEmpty(x) ? "" : " (replaces it)"}</option>)}
                  {slot !== "loop" && <option value="erase">Erase section {slotName(slot)}</option>}
                  <option value="clear">Clear this track's notes</option>
                </select>
              </div>
              {t.barSteps ? (
                <>
                  <div style={{ display: "flex", gap: 4, overflowX: "auto", alignItems: "center", padding: "4px 0" }}>
                    <span class="small dim">Bars</span>
                    {Array.from({ length: Math.ceil(MAX_STEPS / t.barSteps) }, (_, b) => {
                      const inLen = b < Math.ceil(t.length / t.barSteps!), sel = bars && b >= bars[0] && b <= bars[1];
                      return <button key={b} class={"btn small" + (sel ? " primary" : "")} style={{ minWidth: 38, opacity: inLen ? 1 : 0.5 }} onClick={() => tapBar(b)}>{b + 1}</button>;
                    })}
                  </div>
                  <div class="tools">
                    <label class="small"><input type="radio" checked={allTracks} onChange={() => setAllTracks(true)} /> All 4 tracks</label>
                    <label class="small"><input type="radio" checked={!allTracks} onChange={() => setAllTracks(false)} /> This track</label>
                    {bars ? (
                      <>
                        <button class="btn small" onClick={() => copyBars(bars)}>Copy</button>
                        <button class="btn small" onClick={() => { const c = copyBars(bars); pasteBars(bars[1] + 1, true, c); }}>Duplicate</button>
                        <button class="btn small" onClick={() => forTracks((tr) => { const per = tr.barSteps; if (per) tr.clear(per * bars[0], per * (bars[1] + 1)); })}>Clear</button>
                        <button class="btn small danger" onClick={() => { forTracks((tr) => { const per = tr.barSteps; if (per) tr.delete(per * bars[0], per * (bars[1] + 1)); }); setBars(null); }}>Delete</button>
                        {clip && <button class="btn small" onClick={() => pasteBars(bars[0], false)}>Paste over</button>}
                        {clip && <button class="btn small" onClick={() => pasteBars(bars[0], true)}>Insert before</button>}
                      </>
                    ) : (
                      <>
                        <button class="btn small" disabled={t.length >= MAX_STEPS} onClick={() => forTracks((tr) => { if (tr.barSteps) tr.extend(tr.barSteps); })}>Add an empty bar</button>
                        {clip && <button class="btn small" onClick={() => pasteBars(null, false)}>Paste at the end</button>}
                      </>
                    )}
                  </div>
                  <p class="small faint">{bars ? "" : "Click a bar to select it, then another to select a run of bars. "}{clip ? `Copied: ${clip.text}. ` : ""}
                    A pattern holds 64 steps at most (4 bars of 1/16): make the song longer with more sections in the song order.</p>
                </>
              ) : <p class="small dim">Each step of this track is longer than a bar, so bar edits don't apply to it.</p>}
              {t.isDrum ? (
                <Grid version={`${slot}${track}${tick}`} track={t} rows={16} label={(r) => DRUM_LANES[r]} sel={stepRange(t)} onTap={(r, i) => edit((d) => d.patterns[slot]!.track(track).toggleDrum(r, i))} />
              ) : (
                <>
                  <div class="tools">
                    <span class="small">Note length</span>
                    {LENGTHS.map(([n], i) => <button key={n} class={"btn small" + (i === noteLen ? " primary" : "")} onClick={() => setNoteLen(i)}>{n}</button>)}
                    <span style={{ flex: 1 }} />
                    <button class="btn small" onClick={() => setLow({ ...low, [key]: Math.max(0, lowNote - 12) })} aria-label="Octave down">▼</button>
                    <span class="small dim">{noteName(lowNote)}–{noteName(Math.min(127, lowNote + 24))}</span>
                    <button class="btn small" onClick={() => setLow({ ...low, [key]: Math.min(103, lowNote + 12) })} aria-label="Octave up">▲</button>
                  </div>
                  <Grid version={`${slot}${track}${tick}`} track={t} rows={Math.min(25, 128 - lowNote)} low={lowNote} label={(r) => { const pt = lowNote + Math.min(25, 128 - lowNote) - 1 - r; return pt % 12 === 0 || r === Math.min(25, 128 - lowNote) - 1 ? noteName(pt) : ""; }}
                    sel={stepRange(t)} onTap={(r, i) => {
                      const pitch = lowNote + Math.min(25, 128 - lowNote) - 1 - r;
                      const steps = Math.max(1, Math.round(t.stepsPerBar * LENGTHS[noteLen][1]));
                      edit((d) => {
                        const tr = d.patterns[slot]!.track(track), o = tr.owner(i);
                        if (o != null && stepNotes(tr.step(o)).includes(pitch)) tr.remove(pitch, o); else tr.place(pitch, i, steps);
                      });
                    }} />
                </>
              )}
              <p class="small faint" style={{ marginBottom: 0 }}>{t.isDrum ? "Click a square to add or remove a hit." : "Click to add a note of the chosen length (notes on the same step make a chord, 4 at most); click a note to remove it."} Steps past the length are dimmed: SLOOP doesn't play them.</p>
            </>
          )}
      </div>
    </>
  );
}

/** What a grid holds, for screen readers (the canvas has no elements of its own). */
function gridSummary(t: Track): string {
  if (t.isDrum) { let hits = 0; for (let i = 0; i < t.length; i++) for (let l = 0; l < 16; l++) hits += +t.drum(i, l); return `Drum grid, ${t.length} steps, ${hits} hits`; }
  const c = t.chords;
  return `Piano roll, ${t.length} steps, ${c.length} note${c.length === 1 ? "" : "s"}` + (c[0] ? `, first ${c[0].notes.map(noteName).join(" ")} on step ${c[0].at + 1}` : "");
}

/** A piano roll (with `low`: rows are pitches, high at the top) or the drum grid (16 lanes), 64 steps across.
 *  `version` changes with every edit (and the slot and track shown): the canvas is drawn again only then. */
function Grid({ version, track, rows, low, label, sel, onTap }: { version: string; track: Track; rows: number; low?: number; label: (r: number) => string; sel: [number, number] | null; onTap: (row: number, step: number) => void }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const W = 22, H = low == null ? 20 : 18, L = low == null ? 76 : 40;
  useEffect(() => {
    const c = ref.current;
    if (!c) return;
    const dpr = devicePixelRatio || 1, w = L + W * 64, h = H * rows;
    c.width = w * dpr; c.height = h * dpr; c.style.width = `${w}px`; c.style.height = `${h}px`;
    const g = c.getContext("2d")!;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    const css = getComputedStyle(document.documentElement), col = (v: string) => css.getPropertyValue(v).trim();
    g.fillStyle = col("--card2"); g.fillRect(0, 0, w, h);
    const per = track.barSteps ?? 16;
    if (sel) { g.fillStyle = "rgba(10,132,255,.18)"; g.fillRect(L + sel[0] * W, 0, (sel[1] - sel[0]) * W, h); }
    g.font = "11px -apple-system, system-ui, sans-serif"; g.textBaseline = "middle";
    for (let r = 0; r < rows; r++) {
      if (low != null && [1, 3, 6, 8, 10].includes((low + rows - 1 - r) % 12)) { g.fillStyle = "rgba(255,255,255,.05)"; g.fillRect(L, r * H, W * 64, H); }
      g.fillStyle = col("--dim"); g.fillText(label(r), 4, r * H + H / 2);
    }
    if (low == null) {
      for (let r = 0; r < 16; r++) for (let i = 0; i < 64; i++) {
        const on = track.drum(i, r);
        g.fillStyle = on ? col("--blue") : Math.floor(i / per) % 2 ? "rgba(255,255,255,.05)" : "rgba(255,255,255,.1)";
        g.fillRect(L + i * W + 2, r * H + 2, W - 4, H - 4);
      }
    } else {
      for (let i = 0; i <= 64; i++) { g.fillStyle = i % per ? "rgba(255,255,255,.08)" : "rgba(255,255,255,.35)"; g.fillRect(L + i * W, 0, i % per ? 0.5 : 1.5, h); }
      g.fillStyle = col("--blue");
      for (const ch of track.chords) for (const n of ch.notes) {
        if (n < low || n >= low + rows) continue;
        g.fillRect(L + ch.at * W + 1, (low + rows - 1 - n) * H + 2, ch.length * W - 2, H - 4);
      }
    }
    if (track.length < 64) { g.fillStyle = "rgba(0,0,0,.55)"; g.fillRect(L + track.length * W, 0, (64 - track.length) * W, h); }
  }, [version, rows, low, sel?.[0], sel?.[1]]);
  return (
    <div style={{ overflowX: "auto", borderRadius: 10, margin: "8px 0" }}>
      <canvas ref={ref} style={{ display: "block", cursor: "pointer" }} role="img" aria-label={gridSummary(track)} onClick={(e) => {
        const b = (e.target as HTMLCanvasElement).getBoundingClientRect(), x = e.clientX - b.left, y = e.clientY - b.top;
        if (x < L) return;
        const i = Math.floor((x - L) / W), r = Math.floor(y / H);
        if (i < track.length && r >= 0 && r < rows) onTap(r, i);
      }} />
    </div>
  );
}
