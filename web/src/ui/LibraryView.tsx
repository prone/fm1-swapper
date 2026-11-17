// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { useMemo, useRef, useState } from "preact/hooks";
import { Backup, Firmware, STATUS_LABEL, TryStatus, store } from "../store";
import { importFile, stockV15 } from "../catalog";
import { device, viaV15Recommended } from "../device";
import { FAMILY_NAMES, STOCK, familyOf, isLoader, supportsArchive } from "../fm1kit/package";
import { FeluccaArchive } from "../fm1kit/archive";
import { tutorialFor } from "../tutorial";
import { CHIP_TEXT, Chip, MyChip, RESCUE_URL, chipOf, myChip, setMyChip, useHub } from "../hub";
import { ChipBadge } from "./GetFirmware";
import { DeviceBusy, FileDrop, Library, Stars, ago, fmtBytes, fmtDate, fmtDateTime, saveFile, useDevice } from "./common";

type Sort = "recent" | "name" | "rating" | "installed";
const STOCK_V15 = STOCK.find((s) => s.version === "V15")!.sha256;

export function LibraryView({ lib, openId, setOpenId, tryIt, swapNow, swapped }: { lib: Library; openId: string | null; setOpenId: (id: string | null) => void; tryIt: (f: Firmware, tutorial: boolean) => void; swapNow?: boolean; swapped?: () => void }) {
  const [filter, setFilter] = useState<TryStatus | null>(null);
  const [q, setQ] = useState("");
  const [sort, setSort] = useState<Sort>("recent");
  const [msg, setMsg] = useState<string[] | null>(null);
  const dev = useDevice();
  const open = lib.firmwares.find((f) => f.id === openId);
  const list = useMemo(() => lib.firmwares
    .filter((f) => (!filter || f.status === filter) && (!q || `${f.name} ${f.product} ${f.author} ${f.summary}`.toLowerCase().includes(q.toLowerCase())))
    .sort((a, b) => sort === "name" ? a.name.localeCompare(b.name) : sort === "rating" ? b.rating - a.rating || a.name.localeCompare(b.name)
      : sort === "installed" ? (b.lastInstalledAt ?? 0) - (a.lastInstalledAt ?? 0) : b.addedAt - a.addedAt), [lib.firmwares, filter, q, sort]);

  if (open) return <Detail f={open} lib={lib} back={() => setOpenId(null)} tryIt={tryIt} swapNow={swapNow} swapped={swapped} />;

  const add = async (files: File[]) => {
    const out: string[] = [];
    for (const f of files) {
      try {
        if (f.name.endsWith(".json")) { const r = await store.importLibrary(await f.text()); out.push(`Imported a library: ${r.firmwares} firmwares, ${r.backups} backups`); }
        else out.push(...(await importFile(f)));
      } catch (e) { out.push(`${f.name}: ${(e as Error).message}`); }
    }
    setMsg(out);
  };

  return (
    <>
      <h1>Library</h1>
      {lib.firmwares.length > 0 && (
        <>
          <div class="chips">
            <button class={"chip" + (filter ? "" : " on")} onClick={() => setFilter(null)}>All {lib.firmwares.length}</button>
            {(Object.keys(STATUS_LABEL) as TryStatus[]).map((s) => {
              const n = lib.firmwares.filter((f) => f.status === s).length;
              return n ? <button key={s} class={"chip" + (filter === s ? " on" : "")} onClick={() => setFilter(s)}>{STATUS_LABEL[s]} {n}</button> : null;
            })}
          </div>
          <div style={{ display: "flex", gap: 8, marginBottom: 10 }}>
            <input type="search" placeholder="Name, description, author" value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} />
            <select value={sort} onChange={(e) => setSort((e.target as HTMLSelectElement).value as Sort)} aria-label="Sort by">
              <option value="recent">Recently added</option><option value="name">Name</option><option value="rating">Rating</option><option value="installed">Last installed</option>
            </select>
          </div>
          <div class="rows">
            {list.map((f) => (
              <button key={f.id} class="rowbtn" onClick={() => setOpenId(f.id)}>
                <div class="row-main">
                  <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                    <b class="ellipsis">{f.name}</b>
                    {dev.identity?.text === f.product && f.sha256 && <span class="badge green">On FM-1</span>}
                    {!f.sha256 && <span class="badge">No file</span>}
                  </div>
                  <div class="dim small ellipsis">{f.summary || `${f.product} · ${FAMILY_NAMES[f.family]}`}</div>
                  <div class="faint small">{STATUS_LABEL[f.status]}{f.lastInstalledAt ? ` · installed ${ago(f.lastInstalledAt)}` : ""}</div>
                </div>
                {f.rating > 0 && <Stars value={f.rating} />}
              </button>
            ))}
            {!list.length && <div class="dim">Nothing matches.</div>}
          </div>
        </>
      )}
      <h2>Add firmware</h2>
      <FileDrop accept=".fwsc,.html,.htm,.json" multiple onFiles={add}>
        Drop a <b>.fwsc</b> package, M-VAVE's FM1 Open Workbench <b>.html</b>, or a library export <b>.json</b> here.
        {!lib.firmwares.length && <div class="small" style={{ marginTop: 6 }}>Or use <b>Get firmware</b> to download Felucca and hundreds of community firmwares.</div>}
      </FileDrop>
      {msg && <div class="banner ok">{msg.map((m) => <div key={m}>{m}</div>)}</div>}
      <DeviceBusy s={dev} />
      {lib.firmwares.length > 0 && (
        <div class="btnrow">
          <button class="btn" onClick={async () => saveFile(`fm1-library-${new Date().toISOString().slice(0, 10)}.json`, await store.exportLibrary(), "application/json")}>Export library</button>
        </div>
      )}
      <p class="small faint">The library lives in this browser. Export it to move it to another computer, or to keep a copy.</p>
    </>
  );
}

function Detail({ f, lib, back, tryIt, swapNow, swapped }: { f: Firmware; lib: Library; back: () => void; tryIt: (f: Firmware, tutorial: boolean) => void; swapNow?: boolean; swapped?: () => void }) {
  const dev = useDevice();
  const hub = useHub();
  const [swap, setSwap] = useState(!!swapNow && !!f.sha256);
  const h = f.sha256 ? hub?.bySha.get(f.sha256) ?? (f.repo ? hub?.byRepo.get(f.repo.toLowerCase()) : undefined) : undefined;
  const exact = !!(f.sha256 && hub?.bySha.has(f.sha256));
  const chip = f.sha256 ? chipOf(hub, f.sha256) : undefined;
  const [notes, setNotes] = useState(f.notes);
  const save = (p: Partial<Firmware>) => store.saveFirmware(Object.assign(f, p));
  const backups = lib.backups.filter((b) => b.firmwareId === f.id).sort((a, b) => b.date - a.date);
  const installs = lib.installs.filter((e) => e.firmwareId === f.id).sort((a, b) => b.date - a.date);
  const tut = tutorialFor(f);
  const inLoader = dev.identity && isLoader(dev.identity);
  const attach = async ([file]: File[]) => {
    if (file.size > 8 << 20) return alert("That file is too large (8 MB max).");
    const data = new Uint8Array(await file.arrayBuffer());
    let s = ""; for (let i = 0; i < data.length; i += 0x8000) s += String.fromCharCode(...data.subarray(i, i + 0x8000));
    await store.saveBackup({ id: crypto.randomUUID(), firmwareId: f.id, date: Date.now(), identity: f.product, family: f.family, kind: "file",
      label: file.name, sizeBytes: data.length, partsSummary: "attached file", file: { name: file.name, data: btoa(s) } });
  };

  return (
    <>
      <button class="linkbtn" style={{ marginTop: 14 }} onClick={back}>‹ Library</button>
      <div class="card" style={{ marginTop: 10 }}>
        <div style={{ fontSize: 24, fontWeight: 700 }}>{f.name}</div>
        <div class="dim">{[f.author, FAMILY_NAMES[f.family]].filter(Boolean).join(" · ")}</div>
        {f.summary && <p style={{ margin: "6px 0 0" }}>{f.summary}</p>}
        <DeviceBusy s={dev} />
        {f.sha256 ? (
          <>
            <button class="btn primary wide" style={{ marginTop: 12 }} disabled={!!dev.busy} onClick={() => setSwap(true)}>Install on FM-1</button>
            {inLoader && <button class="btn wide" style={{ marginTop: 8 }} disabled={!!dev.busy}
              onClick={() => device.install(f, { backupFirst: false, restoreAfter: false, resume: true })}>Finish install (FM-1 is in update mode)</button>}
            <div class="btnrow">
              <button class="btn" onClick={() => tryIt(f, false)}>▶ Try it</button>
              {tut && <button class="btn" onClick={() => tryIt(f, true)}>🎓 Tutorial</button>}
            </div>
          </>
        ) : <p class="dim">Add the .fwsc file for this firmware on the Library page to install or try it.</p>}
      </div>

      <h2>My take</h2>
      <div class="rows">
        <div><span class="row-main">Status</span>
          <select value={f.status} onChange={(e) => save({ status: (e.target as HTMLSelectElement).value as TryStatus })}>
            {(Object.keys(STATUS_LABEL) as TryStatus[]).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
          </select></div>
        <div><span class="row-main">Rating</span><Stars value={f.rating} onChange={(n) => save({ rating: n })} /></div>
        <div><textarea placeholder="Notes: favorite engines, knob settings, what to try next…" value={notes}
          onInput={(e) => setNotes((e.target as HTMLTextAreaElement).value)} onBlur={() => notes !== f.notes && save({ notes })} /></div>
      </div>

      <h2>Installs</h2>
      <div class="rows">
        {installs.length ? installs.map((e) => (
          <div key={e.id}><span class="row-main">{fmtDateTime(e.date)}<div class="small dim">{e.success ? `from ${e.from || "?"}${e.backupTaken ? " · backed up first" : ""}${e.restored ? " · work restored" : ""}` : e.message}</div></span>
            <span class={"badge" + (e.success ? " green" : "")}>{e.success ? "OK" : "Failed"}</span></div>
        )) : <div class="dim">Not installed with this app yet.</div>}
      </div>

      <h2>Saved settings &amp; backups</h2>
      <div class="rows">
        {backups.map((b) => <BackupRow key={b.id} b={b} f={f} />)}
        <div><FileDrop accept="*/*" onFiles={attach}>Attach a file (a backup JSON, .syx, a photo of your settings…)</FileDrop></div>
      </div>
      <p class="small faint">{supportsArchive(f.family)
        ? "Backups are kept in this browser. After installing this firmware, the newest backup is put back automatically (you can turn that off)."
        : "This firmware has no backup protocol the app knows, so attach files or write notes to keep its settings."}</p>

      <h2>Package</h2>
      <div class="rows">
        <div><span class="row-main">Identity</span><span class="dim">{f.product}</span></div>
        {f.sha256 && <div style={{ alignItems: "flex-start" }}><span class="row-main">Flash chip<div class="small dim">{CHIP_TEXT[chip ?? "unknown"]}</div></span><ChipBadge chip={chip} /></div>}
        {f.sha256 && <div><span class="row-main">Checksum</span><span class="small dim">{exact ? "✓ Matches The Firmware Hub's published SHA-256" : chip ? "✓ M-VAVE's official release" : "Not in The Firmware Hub's list"}</span></div>}
        {f.sha256 && <div><span class="row-main">Size</span><span class="dim">{fmtBytes(f.size)}</span></div>}
        {f.sha256 && <div><span class="row-main">SHA-256</span><span class="mono dim ellipsis" style={{ maxWidth: "50%" }} title={f.sha256}>{f.sha256}</span></div>}
        <div><span class="row-main">Added</span><span class="dim">{fmtDate(f.addedAt)}</span></div>
        {f.repo && <div><a href={`https://github.com/${f.repo}`} target="_blank" rel="noopener noreferrer">github.com/{f.repo}</a></div>}
        {h && (h.editor || h.play || h.cheat || h.talk) && <div style={{ flexWrap: "wrap", gap: 14 }}>
          {h.editor && <a href={h.editor} target="_blank" rel="noopener noreferrer">Editor ↗</a>}
          {h.cheat && <a href={h.cheat} target="_blank" rel="noopener noreferrer">Manual ↗</a>}
          {h.play && <a href={h.play} target="_blank" rel="noopener noreferrer">Play in browser ↗</a>}
          {h.talk && <a href={h.talk} target="_blank" rel="noopener noreferrer">Discussions ↗</a>}
          {!exact && <span class="small faint">(links for {h.name} {h.version})</span>}
        </div>}
        {f.sha256 && <div><button class="linkbtn" onClick={async () => { const b = await store.packageBytes(f.sha256); if (b) saveFile(f.fileName || `${f.product}.fwsc`, b); }}>Download .fwsc</button></div>}
        <div><button class="linkbtn" style={{ color: "var(--red)" }} onClick={() => { if (confirm(`Delete ${f.name} and its backups from this browser?`)) { void store.deleteFirmware(f); back(); } }}>Delete from library</button></div>
      </div>
      {swap && <SwapDialog f={f} lib={lib} chip={chip} close={() => { setSwap(false); swapped?.(); }} />}
    </>
  );
}

function BackupRow({ b, f }: { b: Backup; f: Firmware }) {
  const dev = useDevice();
  const canRestore = !!b.archive && dev.identity && !isLoader(dev.identity) && familyOf(dev.identity) === b.family;
  return (
    <div>
      <span class="row-main">{b.label}<div class="small dim">{fmtDateTime(b.date)} · {b.partsSummary}{b.sizeBytes ? ` · ${fmtBytes(b.sizeBytes)}` : ""}</div></span>
      {b.archive && <button class="linkbtn small" disabled={!canRestore || !!dev.busy} title={canRestore ? "" : `Install ${f.name} first`} onClick={() => confirm(`Restore “${b.label}”? It replaces the saved work on the FM-1.`) && device.restore(b)}>Restore</button>}
      <button class="linkbtn small" onClick={() => {
        if (b.archive) saveFile(`${f.name}-${new Date(b.date).toISOString().slice(0, 10)}.json`, b.family === "felucca" ? FeluccaArchive.toNativeJSON(b.archive) : JSON.stringify(b.archive), "application/json");
        else if (b.file) saveFile(b.file.name, Uint8Array.from(atob(b.file.data), (c) => c.charCodeAt(0)));
      }}>Download</button>
      <button class="linkbtn small" style={{ color: "var(--red)" }} onClick={() => confirm("Delete this backup?") && store.deleteBackup(b)}>Delete</button>
    </div>
  );
}

function ChipWarning({ chip, mine, setMine, ack, setAck }: { chip: Chip | undefined; mine: MyChip; setMine: (c: MyChip) => void; ack: boolean; setAck: (b: boolean) => void }) {
  if (chip === "new") return null;
  const risky = chip === "old" ? mine !== "old" : mine === "new";
  if (!risky && chip !== "old") return chip === "any" ? null : <div class="small faint" style={{ margin: "6px 0" }}>{CHIP_TEXT.unknown}.</div>;
  if (!risky) return null;
  return (
    <div class="banner warn small">
      <b>{chip === "old" ? "This firmware only knows the first FM-1s' flash chip." : "Flash chip support for this package is unknown."}</b>{" "}
      Newer FM-1s (sold since autumn 2026, flash chip 0xB36014) keep its saves in RAM only, and it can't update itself afterwards:
      getting off it then needs download mode and M-Flasher (<a href={RESCUE_URL} target="_blank" rel="noopener noreferrer">guide</a>).
      <div style={{ marginTop: 8 }}>Your FM-1:{" "}
        <select value={mine} onChange={(e) => { const v = (e.target as HTMLSelectElement).value as MyChip; setMyChip(v); setMine(v); }}>
          <option value="unknown">I don't know</option><option value="old">An older unit (0x856014)</option><option value="new">A newer unit (0xB36014)</option>
        </select>
      </div>
      <div class="faint" style={{ marginTop: 4 }}>The chip can't be read over USB; M-Flasher shows it in download mode. A unit bought before autumn 2026 has the older chip.</div>
      {(mine !== "old") && <label class="check"><input type="checkbox" checked={ack} onChange={(e) => setAck((e.target as HTMLInputElement).checked)} />I understand, install anyway</label>}
    </div>
  );
}

function SwapDialog({ f, lib, chip, close }: { f: Firmware; lib: Library; chip: Chip | undefined; close: () => void }) {
  const [mine, setMine] = useState<MyChip>(myChip());
  const [ack, setAck] = useState(false);
  const [viaV15, setViaV15] = useState(true);
  const [preparing, setPreparing] = useState<string | null>(null);
  const needAck = (chip === "old" && mine !== "old") || (chip === undefined && mine === "new");
  const dev = useDevice();
  const ref = useRef<HTMLDialogElement>(null);
  const [backupFirst, setBackupFirst] = useState(true);
  const [restoreAfter, setRestoreAfter] = useState(true);
  const cur = dev.identity;
  const curFam = cur ? familyOf(cur) : null;
  const curName = (cur && lib.firmwares.find((x) => x.product === cur.text)?.name) ?? cur?.text ?? "";
  const hasBackup = lib.backups.some((b) => b.firmwareId === f.id && b.archive);
  return (
    <dialog ref={(d) => { (ref as { current: HTMLDialogElement | null }).current = d; if (d && !d.open) d.showModal(); }} onClose={close}>
      <h3 style={{ marginTop: 0 }}>Install {f.name}</h3>
      {!cur ? <p class="dim">Connect the FM-1 on the Device page first.</p> : (
        <>
          <p class="dim" style={{ marginTop: 0 }}>The FM-1 is running <b>{curName}</b>. It will restart a few times; keep the USB cable in until it's done (about a minute).</p>
          {curFam && (supportsArchive(curFam) || curFam === "unknown") && <label class="check"><input type="checkbox" checked={backupFirst} onChange={(e) => setBackupFirst((e.target as HTMLInputElement).checked)} />Back up {curName}'s work first</label>}
          {curFam === "official" && <div class="banner warn small">M-VAVE's official firmware can't be backed up. Its patterns are usually erased by other firmware.</div>}
          <ChipWarning chip={chip} mine={mine} setMine={setMine} ack={ack} setAck={setAck} />
          {viaV15Recommended(cur, f) && (
            <label class="check"><input type="checkbox" checked={viaV15} onChange={(e) => setViaV15((e.target as HTMLInputElement).checked)} />
              <span><b>Go via official V15 (recommended)</b><br /><span class="small dim">Installs M-VAVE's V15 first{lib.firmwares.some((x) => x.sha256 === STOCK_V15) ? "" : " (downloaded and checked, about 700 KB)"}, then {f.name}.
                Most community firmware expects official V15 underneath, and installs straight from one community firmware to another fail most often. Adds about two minutes.</span></span></label>
          )}
          {hasBackup && <label class="check"><input type="checkbox" checked={restoreAfter} onChange={(e) => setRestoreAfter((e.target as HTMLInputElement).checked)} />Put back my latest {f.name} backup afterwards</label>}
        </>
      )}
      {cur && (
        <div class="small dim" style={{ marginTop: 10 }}>
          <b style={{ color: "var(--text)" }}>Before you start</b>
          <ul style={{ margin: "4px 0 0", paddingLeft: 18 }}>
            <li>A data USB cable, straight into the computer (no hub)</li>
            <li>The FM-1 charged, or on power</li>
            <li>Other music and MIDI apps closed (DAWs, editors, other installer tabs)</li>
            <li>Keep this tab open until it's done; the screen is kept on</li>
          </ul>
        </div>
      )}
      {preparing && <div class="banner warn small">{preparing}</div>}
      <div class="btnrow">
        <button class="btn" onClick={close}>Cancel</button>
        <button class="btn primary" disabled={!cur || !!dev.busy || !!preparing && preparing.startsWith("Getting") || (needAck && !ack)} onClick={async () => {
          let base: Firmware | undefined;
          if (viaV15 && viaV15Recommended(cur, f)) {
            setPreparing("Getting official V15…");
            try { base = await stockV15(); setPreparing(null); } catch (e) { setPreparing((e as Error).message); return; }
          }
          close();
          void device.install(f, { backupFirst, restoreAfter: restoreAfter && hasBackup, viaV15: base });
        }}>Install</button>
      </div>
    </dialog>
  );
}
