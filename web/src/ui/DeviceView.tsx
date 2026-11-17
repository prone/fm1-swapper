// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { useEffect, useState } from "preact/hooks";
import { backupRecord, device, mboot } from "../device";
import { FAMILY_NAMES, familyOf, isLoader, supportsArchive } from "../fm1kit/package";
import { readArchiveFile } from "../fm1kit/archive";
import { FlashImage, Firmware, store } from "../store";
import { DeviceBusy, FileDrop, Library, fmtBytes, fmtDateTime, saveFile, useDevice, useLibrary } from "./common";
import { officialFirmware } from "../catalog";
import { MyChip, RESCUE_URL, chipOf, myChip, setMyChip, useHub } from "../hub";
import { chipOfJedec, helperFor, hex } from "../fm1kit/mboot";

export function DeviceView({ lib, open }: { lib: Library; open: (id: string, swap?: boolean) => void }) {
  const s = useDevice();
  const [samples, setSamples] = useState(true);
  const [msg, setMsg] = useState<string | null>(null);
  const [chip, setChip] = useState<MyChip>(myChip());
  const [getting, setGetting] = useState(false);
  const id = s.identity;
  const fam = id ? familyOf(id) : null;
  const installed = id ? lib.firmwares.find((f) => f.product === id.text && f.sha256) : undefined;
  const loader = id && isLoader(id);
  const latest = installed ? lib.backups.filter((b) => b.firmwareId === installed.id && b.archive && b.kind !== "song").sort((a, b) => b.date - a.date)[0] : undefined;

  if (s.midi === "unsupported") return (
    <>
      <h1>Device</h1>
      <div class="banner warn">
        This browser can't talk to MIDI devices. Open this page in <b>Chrome</b> or <b>Edge</b> on a Mac, Windows PC, Linux, ChromeOS or Android.
        Safari and Firefox don't support Web MIDI with SysEx. You can still browse firmware, keep a library and try firmware in the emulator.
      </div>
    </>
  );

  return (
    <>
      <h1>Device</h1>
      <DeviceBusy s={s} />
      {s.midi === "none" ? (
        <div class="card">
          <p style={{ marginTop: 0 }}>Connect the FM-1 with a USB cable, then allow MIDI access when the browser asks. SysEx is needed to read and write the synth.</p>
          <button class="btn primary" onClick={() => device.connect()}>Connect to FM-1</button>
        </div>
      ) : !id ? (
        <div class="card">
          <b>No FM-1 found.</b>
          <p class="dim">Check the USB cable (a data cable, not charge-only) and close other apps that use the FM-1, such as a DAW or the Felucca editor. On Android, connect it with a USB-C OTG cable.</p>
          <button class="btn" disabled={!!s.busy} onClick={() => device.identify()}>Look again</button>
        </div>
      ) : (
        <>
          <div class="card">
            <div class="dim small">Connected · {s.port}</div>
            <div style={{ fontSize: 22, fontWeight: 700 }}>{installed?.name ?? id.text}</div>
            <div class="dim">{id.text} · {FAMILY_NAMES[fam!]}</div>
            {installed && <button class="linkbtn small" onClick={() => open(installed.id)}>Open in library</button>}
            {!installed && !loader && <p class="small dim">This firmware isn't in your library. Add its .fwsc file to keep notes and backups for it.</p>}
          </div>
          {loader && s.mboot && <MBootCard lib={lib} />}
          {loader && !s.mboot && (
            <div class="banner warn">
              The FM-1 is in <b>update mode</b>: an install didn't finish. Open the firmware you were installing in the library and choose
              <b> Finish install</b>. The FM-1 stays in this mode until the write completes, so unplugging it is safe.
            </div>
          )}
          {!loader && (
            <>
              <h2>Saved work</h2>
              <div class="card">
                {supportsArchive(fam!) || fam === "unknown" ? (
                  <>
                    <div>Reads everything {FAMILY_NAMES[fam!]} can export (projects, voices, settings{samples ? ", samples" : ""}) and saves it in this browser.</div>
                    <label class="check"><input type="checkbox" checked={samples} onChange={(e) => setSamples((e.target as HTMLInputElement).checked)} /> Include sample banks</label>
                    <div class="btnrow">
                      <button class="btn primary" disabled={!!s.busy} onClick={() => device.backup(installed, samples)}>Back up now</button>
                      <button class="btn" disabled={!!s.busy || !latest} onClick={() => latest && confirm(`Restore the backup from ${fmtDateTime(latest.date)}? It replaces the saved work on the FM-1.`) && device.restore(latest, samples)}>
                        Restore latest{latest ? ` (${fmtDateTime(latest.date)})` : ""}
                      </button>
                    </div>
                  </>
                ) : (
                  <div class="dim">{fam === "official"
                    ? "M-VAVE's official firmware has no backup protocol, so its patterns can't be read out. Note anything you want to keep in the firmware's notes."
                    : `${id.text} has no backup protocol this app knows. Use the firmware's own editor, or attach its files in the library.`}</div>
                )}
              </div>
              {(fam === "felucca" || fam === "unknown") && <SloopSongs lib={lib} owner={installed} busy={!!s.busy} />}
              <h2>Restore from a file</h2>
              <FileDrop accept=".json" onFiles={async ([f]) => {
                try {
                  const a = readArchiveFile(await f.text());
                  const b = backupRecord(a, installed?.id ?? "", "import");
                  await store.saveBackup(b);
                  // kept in the library first; written to the FM-1 only when asked
                  if (!confirm(`Imported ${f.name}. Restore it to the FM-1 now? It replaces the saved work on the FM-1.`)) { setMsg(`Imported ${f.name}: it's in your backups.`); return; }
                  setMsg(null);
                  await device.restore(b, samples);
                } catch (e) { setMsg((e as Error).message); }
              }}>A backup .json from this app, the iOS app, or Felucca's own editor.</FileDrop>
              {msg && <div class="banner warn">{msg}</div>}
            </>
          )}
        </>
      )}
      {id && !loader && fam !== "official" && (
        <>
          <h2>Back to official firmware</h2>
          <div class="card">
            <div>Put M-VAVE's own firmware back (V15, checked against its known checksum). It works on every FM-1.</div>
            <div class="btnrow"><button class="btn" disabled={!!s.busy || getting} onClick={async () => {
              setGetting(true); setMsg(null);
              try { const f = await officialFirmware(); open(f.id, true); } catch (e) { setMsg((e as Error).message); } finally { setGetting(false); }
            }}>{getting ? "Downloading…" : "Back to official firmware…"}</button></div>
          </div>
        </>
      )}
      {id && !loader && helperFor(fam!) && (
        <>
          <h2>Check this FM-1</h2>
          <div class="card">
            <div>Reads which flash chip this FM-1 has and can back up its <b>whole flash</b> (1 MB), using m-bootloader's helper.</div>
            <p class="small dim">The helper is sent like a firmware update but only runs from memory: nothing is installed. The firmware uses about 20 KB
              of free space to hold it. When you're done, the FM-1 restarts into {installed?.name ?? id.text} as before.</p>
            <div class="btnrow"><button class="btn" disabled={!!s.busy} onClick={() => mboot.startHelper()}>Start the helper</button></div>
          </div>
        </>
      )}
      <FlashImages />
      {s.midi === "ready" && (
        <>
          <h2>Flash chip</h2>
          <div class="card">
            <div style={{ display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
              <span style={{ flex: 1 }}>This FM-1's flash chip</span>
              <select value={chip} onChange={(e) => { const v = (e.target as HTMLSelectElement).value as MyChip; setMyChip(v); setChip(v); }}>
                <option value="unknown">I don't know</option><option value="old">Older unit (0x856014)</option><option value="new">Newer unit (0xB36014)</option>
              </select>
            </div>
            <p class="small dim" style={{ marginBottom: 0 }}>FM-1s sold since autumn 2026 have a different flash chip. Some firmware only knows the older one: on a newer FM-1 it loses
              saves at power-off and can't update itself. The chip can't be read over USB, so tell the app which you have (M-Flasher shows it in download mode),
              and installs of firmware that don't support it will warn you. <a href={RESCUE_URL} target="_blank" rel="noopener noreferrer">More, and the rescue guide ↗</a></p>
          </div>
        </>
      )}
      {s.log.length > 0 && (<><h2>Activity</h2><div class="card mono log">{s.log.join("\n")}</div></>)}
    </>
  );
}

function MBootCard({ lib }: { lib: Library }) {
  const s = useDevice();
  const m = s.mboot!;
  const [pick, setPick] = useState("");
  const chip = chipOfJedec(m.jedec);
  const hub = useHub();
  const choices = lib.firmwares.filter((f: Firmware) => f.sha256 && f.product.startsWith("FM-1_"));
  /** Through the helper too: firmware that only knows the older flash chip isn't put on a newer unit. */
  const installThrough = (f: Firmware) => {
    if (chip === "new" && chipOf(hub, f.sha256) === "old") { alert(`${f.name} only works on older FM-1s, and this one has the newer flash chip (${hex(m.jedec)}).`); return; }
    if (confirm(`Install ${f.name} through m-bootloader? The FM-1's saved work stays; restore a backup afterwards if you need to.`)) void device.install(f, { backupFirst: false, restoreAfter: false, resume: true });
  };
  return (
    <>
      <h2>m-bootloader {m.kind === "stage" ? "helper" : ""}</h2>
      <div class="card">
        <div>The FM-1 is in <b>m-bootloader's MIDI mode</b> ({m.kind === "stage" ? "its helper, running from memory" : "the installed bootloader"}, {m.version}).</div>
        <div class="rows" style={{ marginTop: 10 }}>
          <div><span class="row-main">Flash chip</span><span class="dim">{hex(m.jedec)} · {chip === "new" ? "newer unit" : chip === "old" ? "older unit" : "unknown kind"} · {fmtBytes(m.capacity)}</span></div>
          <div><span class="row-main">Unit ID</span><span class="mono dim">{m.uid}</span></div>
        </div>
        {chip !== "unknown" && <p class="small dim">The app's flash chip setting now says {chip === "new" ? "newer unit (0xB36014)" : "older unit (0x856014)"}.</p>}
        <div class="btnrow">
          <button class="btn primary" disabled={!!s.busy} onClick={() => mboot.backupFlash(s.identity?.text ?? "")}>Back up the whole flash</button>
          <button class="btn" disabled={!!s.busy} onClick={() => mboot.restart()}>Restart the FM-1</button>
        </div>
        <div style={{ display: "flex", gap: 8, marginTop: 12, alignItems: "center", flexWrap: "wrap" }}>
          <span class="small">Install firmware through it:</span>
          <select value={pick} onChange={(e) => setPick((e.target as HTMLSelectElement).value)}>
            <option value="">Choose…</option>
            {choices.map((f) => <option key={f.id} value={f.id}>{f.name}</option>)}
          </select>
          <button class="btn" disabled={!pick || !!s.busy} onClick={() => { const f = choices.find((x) => x.id === pick); if (f) installThrough(f); }}>Install</button>
        </div>
        <p class="small faint" style={{ marginBottom: 0 }}>Its installer writes only the firmware area, checks the package against this unit, skips unchanged parts and writes the first part last.</p>
      </div>
    </>
  );
}

function FlashImages() {
  const [list, setList] = useState<FlashImage[]>([]);
  const lib = useLibrary();
  useEffect(() => { void store.flashImages().then((l) => setList(l.sort((a, b) => b.date - a.date))); }, [lib]);
  if (!list.length) return null;
  return (
    <>
      <h2>Whole-flash backups</h2>
      <div class="rows">
        {list.map((f) => (
          <div key={f.id}>
            <span class="row-main">{fmtDateTime(f.date)} · {f.firmware || "FM-1"}
              <div class="small dim">unit {f.unit.slice(0, 8)}… · chip {hex(f.jedec)} · {fmtBytes(f.size)} · CRC-32 {hex(f.crc, 8)}</div></span>
            <button class="linkbtn small" onClick={() => saveFile(`fm1-flash-${f.unit.slice(0, 8)}-${new Date(f.date).toISOString().slice(0, 10)}.bin`, f.data)}>Download .bin</button>
            <button class="linkbtn small" style={{ color: "var(--red)" }} onClick={() => confirm("Delete this whole-flash backup?") && store.deleteFlash(f)}>Delete</button>
          </div>
        ))}
      </div>
      <p class="small faint">Raw 1 MB images, read through m-bootloader and checked against the chip's own CRC-32. M-Flasher can restore them from a computer.</p>
    </>
  );
}

/** SLOOP keeps one song on the FM-1. This keeps as many as you like: save the one on the FM-1 under a name, put
 *  another back (the loop, the song order and sections A-D; presets, kits and samples stay as they are). */
function SloopSongs({ lib, owner, busy }: { lib: Library; owner: Firmware | undefined; busy: boolean }) {
  const songs = lib.backups.filter((b) => b.kind === "song" && (!owner || b.firmwareId === owner.id)).sort((a, b) => b.date - a.date);
  const [name, setName] = useState("");

  const [check, setCheck] = useState<{ saved?: string; unsaved?: true; failed?: string } | null>(null);
  const [checking, setChecking] = useState(false);
  const autoName = `Song ${songs.length + 1} · ${fmtDateTime(Date.now())}`;
  const startClear = async () => { setChecking(true); setCheck(await device.checkSongSaved(songs)); setChecking(false); };
  const clear = (saveAs: string | null) => { setCheck(null); void device.clearSong(owner, saveAs); };
  const save = () => { void device.saveSong(owner, name.trim() || `Song ${songs.length + 1}`).then((b) => { if (b) setName(""); }); };
  return (
    <>
      <h2>SLOOP songs</h2>
      <div class="card">
        <div class="small dim">SLOOP holds one song: the loop, sections A–D and their order. Save it here under a name, then start a new one on
          the FM-1 with Clear (it offers to save first; SLOOP 2.7 or later).
          Presets, drum kits and samples on the FM-1 aren't touched. Saving and loading work with SLOOP 2.3 or later and firmware built on it.</div>
        <div class="btnrow">
          <input type="text" placeholder={`Song ${songs.length + 1}`} value={name} maxLength={60} aria-label="Song name"
            onInput={(e) => setName((e.target as HTMLInputElement).value)} onKeyDown={(e) => { if (e.key === "Enter" && !busy) save(); }} />
          <button class="btn primary" disabled={busy} onClick={save}>Save the song on the FM-1</button>
        </div>
        {!check ? (
          <div class="btnrow">
            <button class="btn" style={{ color: "var(--red)" }} disabled={busy || checking} onClick={startClear}>{checking ? "Checking…" : "Clear the song on the FM-1…"}</button>
          </div>
        ) : (
          <div class="banner warn">
            <b>{check.saved ? "Clear the song on the FM-1?" : "The song on the FM-1 isn't saved"}</b>
            <div class="small">{check.saved
              ? `It's saved as “${check.saved}”. This erases every note in the loop and empties sections A–D. Sounds, presets, kits and samples stay.`
              : check.failed
              ? `Couldn't check whether it's saved (${check.failed}). Save it first to be safe. Clearing erases every note in the loop and sections A–D.`
              : `Save it first (as “${autoName}”, rename it later), or clear it for good: every note in the loop and sections A–D.`}</div>
            <div class="btnrow">
              {!check.saved && <button class="btn primary" disabled={busy} onClick={() => clear(autoName)}>Save, then clear</button>}
              <button class="btn" style={{ color: "var(--red)" }} disabled={busy} onClick={() => clear(null)}>{check.saved ? "Clear" : "Clear without saving"}</button>
              <button class="linkbtn" onClick={() => setCheck(null)}>Cancel</button>
            </div>
          </div>
        )}
        <p class="small dim" style={{ marginBottom: 0 }}>{songs.length ? `${songs.length} saved song${songs.length === 1 ? "" : "s"}` : "No saved songs yet"}: review, edit and load them in the Firmware Editor tab (no FM-1 needed to edit).</p>
      </div>
    </>
  );
}

