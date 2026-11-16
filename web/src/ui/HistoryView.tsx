// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { Library, fmtDateTime } from "./common";

export function HistoryView({ lib, open }: { lib: Library; open: (id: string) => void }) {
  const events = [...lib.installs].sort((a, b) => b.date - a.date);
  const name = (id: string) => lib.firmwares.find((f) => f.id === id)?.name;
  return (
    <>
      <h1>History</h1>
      <div class="rows">
        {events.length ? events.map((e) => (
          <div key={e.id}>
            <span class="row-main">
              {name(e.firmwareId) ? <button class="linkbtn" onClick={() => open(e.firmwareId)}><b>{name(e.firmwareId)}</b></button> : <b>{e.to}</b>}
              <div class="small dim">{fmtDateTime(e.date)} · {e.from ? `${e.from} → ` : ""}{e.to} · {Math.round(e.duration)} s</div>
              {!e.success && <div class="small" style={{ color: "var(--red)" }}>{e.message}</div>}
              {(e.backupTaken || e.restored) && <div class="small faint">{[e.backupTaken && "backed up first", e.restored && "work restored"].filter(Boolean).join(" · ")}</div>}
            </span>
            <span class={"badge" + (e.success ? " green" : "")}>{e.success ? "Installed" : "Failed"}</span>
          </div>
        )) : <div class="dim">Installs you make appear here, with dates and what was on the FM-1 before.</div>}
      </div>
    </>
  );
}
