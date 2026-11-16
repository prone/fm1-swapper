// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { useState } from "preact/hooks";
import { device } from "../device";
import { FAMILY_NAMES, familyOf, isLoader, supportsArchive } from "../fm1kit/package";
import { readArchiveFile } from "../fm1kit/archive";
import { backupRecord } from "../device";
import { store } from "../store";
import { DeviceBusy, FileDrop, Library, fmtDateTime, useDevice } from "./common";
import { officialFirmware } from "../catalog";
import { MyChip, RESCUE_URL, myChip, setMyChip } from "../hub";

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
  const latest = installed ? lib.backups.filter((b) => b.firmwareId === installed.id && b.archive).sort((a, b) => b.date - a.date)[0] : undefined;

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
          {loader && (
            <div class="banner warn">
              The FM-1 is in <b>update mode</b>: an install didn't finish. Open the firmware you were installing in the library and choose
              <b> Finish install</b>. The FM-1 stays in this mode until the write completes, so unplugging it is safe.
            </div>
          )}
          {!loader && (
            <>
              <h2>Saved work</h2>
              <div class="card">
                {supportsArchive(fam!) ? (
                  <>
                    <div>Reads everything {FAMILY_NAMES[fam!]} can export (projects, voices, settings{samples ? ", samples" : ""}) and saves it in this browser.</div>
                    <label class="check"><input type="checkbox" checked={samples} onChange={(e) => setSamples((e.target as HTMLInputElement).checked)} /> Include sample banks</label>
                    <div class="btnrow">
                      <button class="btn primary" disabled={!!s.busy} onClick={() => device.backup(installed, samples)}>Back up now</button>
                      <button class="btn" disabled={!!s.busy || !latest} onClick={() => latest && device.restore(latest, samples)}>
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
              <h2>Restore from a file</h2>
              <FileDrop accept=".json" onFiles={async ([f]) => {
                try {
                  const a = readArchiveFile(await f.text());
                  const b = backupRecord(a, installed?.id ?? "", "import");
                  await store.saveBackup(b);
                  setMsg(`Imported ${f.name}. Restoring…`);
                  await device.restore(b, samples);
                  setMsg(null);
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
