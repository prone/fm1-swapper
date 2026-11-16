// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { useState } from "preact/hooks";
import { device } from "../device";
import { FAMILY_NAMES, familyOf, isLoader, supportsArchive } from "../fm1kit/package";
import { readArchiveFile } from "../fm1kit/archive";
import { backupRecord } from "../device";
import { store } from "../store";
import { DeviceBusy, FileDrop, Library, fmtDateTime, useDevice } from "./common";

export function DeviceView({ lib, open }: { lib: Library; open: (id: string) => void }) {
  const s = useDevice();
  const [samples, setSamples] = useState(true);
  const [msg, setMsg] = useState<string | null>(null);
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
      {s.log.length > 0 && (<><h2>Activity</h2><div class="card mono log">{s.log.join("\n")}</div></>)}
    </>
  );
}
