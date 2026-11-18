// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { ComponentChildren } from "preact";
import { useEffect, useState } from "preact/hooks";
import { Backup, Firmware, InstallEvent, onChange, store } from "../store";
import { DeviceState, device } from "../device";

export interface Library { firmwares: Firmware[]; backups: Backup[]; installs: InstallEvent[]; loaded: boolean }

export function useLibrary(): Library {
  const [lib, setLib] = useState<Library>({ firmwares: [], backups: [], installs: [], loaded: false });
  useEffect(() => {
    const load = async () => setLib({ firmwares: await store.firmwares(), backups: await store.backups(), installs: await store.installs(), loaded: true });
    void load();
    return onChange(() => void load());
  }, []);
  return lib;
}

export function useDevice(): DeviceState {
  const [s, setS] = useState(device.state);
  useEffect(() => device.subscribe(setS), []);
  return s;
}

export const fmtDate = (ms: number) => new Date(ms).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
export const fmtDateTime = (ms: number) => new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
/** A date as YYYY-MM-DD, for file names. */
export const isoDay = (ms: number = Date.now()) => new Date(ms).toISOString().slice(0, 10);
export const fmtBytes = (n: number) => n < 1024 ? `${n} B` : n < 1 << 20 ? `${Math.round(n / 1024)} KB` : `${(n / (1 << 20)).toFixed(1)} MB`;
export function ago(ms: number) {
  const d = (Date.now() - ms) / 1000;
  if (d < 90) return "just now";
  if (d < 3600) return `${Math.round(d / 60)} min ago`;
  if (d < 86400) return `${Math.round(d / 3600)} h ago`;
  return `${Math.round(d / 86400)} days ago`;
}

export function saveFile(name: string, data: string | Uint8Array, type = "application/octet-stream") {
  const url = URL.createObjectURL(new Blob([typeof data === "string" ? data : new Uint8Array(data)], { type }));
  const a = Object.assign(document.createElement("a"), { href: url, download: name });
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

export function Stars({ value, onChange: set }: { value: number; onChange?: (n: number) => void }) {
  return (
    <span class="stars" role="radiogroup" aria-label="Rating">
      {[1, 2, 3, 4, 5].map((n) => (
        <button key={n} aria-label={`${n} star${n > 1 ? "s" : ""}`} aria-checked={value === n} role="radio" disabled={!set}
          onClick={() => set?.(value === n ? 0 : n)}>{n <= value ? "★" : "☆"}</button>
      ))}
    </span>
  );
}

export const Bar = ({ value }: { value: number | null }) => (
  <div class="bar" role="progressbar" aria-valuenow={value == null ? undefined : Math.round(value * 100)}><i style={{ width: `${value == null ? 100 : value * 100}%`, opacity: value == null ? 0.35 : 1 }} /></div>
);

/** Drag a file anywhere onto this, or click to choose. Files over `maxBytes` are refused before they're read. */
export function FileDrop({ accept, multiple, onFiles, children, maxBytes = 64 << 20 }: { accept: string; multiple?: boolean; onFiles: (f: File[]) => void; children: ComponentChildren; maxBytes?: number }) {
  const [over, setOver] = useState(false);
  const [tooBig, setTooBig] = useState("");
  const take = (f: File[]) => {
    const big = f.filter((x) => x.size > maxBytes);
    setTooBig(big.length ? `${big.map((x) => x.name).join(", ")}: too large (over ${fmtBytes(maxBytes)}).` : "");
    const ok = f.filter((x) => x.size <= maxBytes);
    if (ok.length) onFiles(ok);
  };
  let input: HTMLInputElement | null = null;
  return (
    <div class={"drop" + (over ? " over" : "")} onDragOver={(e) => { e.preventDefault(); setOver(true); }} onDragLeave={() => setOver(false)}
      onDrop={(e) => { e.preventDefault(); setOver(false); const f = [...(e.dataTransfer?.files ?? [])]; if (f.length) take(f); }}>
      {children}
      <div style={{ marginTop: 8 }}>
        <button class="btn" onClick={() => input?.click()}>Choose file…</button>
        <input ref={(r) => { input = r; }} type="file" accept={accept} multiple={multiple} hidden
          onChange={(e) => { const f = [...((e.target as HTMLInputElement).files ?? [])]; (e.target as HTMLInputElement).value = ""; if (f.length) take(f); }} />
      </div>
      {tooBig && <div class="small" style={{ color: "var(--orange)", marginTop: 6 }}>{tooBig}</div>}
    </div>
  );
}

export function DeviceBusy({ s }: { s: DeviceState }) {
  if (!s.busy && !s.error) return null;
  return (
    <div class={"banner " + (s.error ? "err" : "warn")} role="status">
      {s.busy ? <><div style={{ marginBottom: 8 }}>{s.busy}…{s.progress != null && ` ${Math.round(s.progress * 100)}%`}</div><Bar value={s.progress} /></>
        : <div style={{ display: "flex", gap: 10 }}><span style={{ flex: 1 }}>{linkify(s.error ?? "")}</span><button class="linkbtn" onClick={() => device.clearError()}>Dismiss</button></div>}
    </div>
  );
}

/** Plain text with its https links made clickable (error messages point to rescue guides). */
export function linkify(text: string) {
  return text.split(/(https:\/\/[^\s)]+)/).map((part, i) => i % 2 ? <a key={i} href={part} target="_blank" rel="noopener noreferrer">{part}</a> : part);
}
