// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The connected FM-1 and every operation on it (mirrors App/DeviceController.swift). One operation at a time.
import { WebMIDIProvider } from "./fm1kit/midi";
import { FM1Error, Step, Updater } from "./fm1kit/ota";
import { FirmwarePackage, Identity, STOCK, familyOf, isLoader, readPackage, supportsArchive } from "./fm1kit/package";
import { DeviceArchive, SLOOPArchive, SLOOP_SONG_IDS, captureArchive, restoreArchive, totalBytes } from "./fm1kit/archive";
import { HELPERS, MbootInfo, chipOfJedec, helperFor } from "./fm1kit/mboot";
import { crc32, sha256Hex } from "./fm1kit/sysex";
import { setMyChip } from "./hub";
import { Backup, Firmware, store, uid } from "./store";

export interface DeviceState {
  midi: "none" | "unsupported" | "ready";
  identity: Identity | null; port: string;
  /** m-bootloader (or its helper) answering in MIDI mode. */
  mboot: MbootInfo | null;
  busy: string | null;                      // what is running, for the UI
  progress: number | null;                  // 0…1
  log: string[]; error: string | null;
}

let state: DeviceState = { midi: WebMIDIProvider.supported() ? "none" : "unsupported", identity: null, port: "", mboot: null, busy: null, progress: null, log: [], error: null };
let provider: WebMIDIProvider | null = null;
const listeners = new Set<(s: DeviceState) => void>();
const set = (p: Partial<DeviceState>) => { state = { ...state, ...p }; listeners.forEach((f) => f(state)); };
const note = (s: string) => set({ log: [...state.log.slice(-60), `${new Date().toLocaleTimeString()}  ${s}`] });

const V15 = STOCK.find((s) => s.version === "V15")!;

/** Route an install through official V15 whenever the FM-1 isn't already on it (unless V15 is the target): most community
 *  firmware expects stock V15 underneath, and custom-to-custom installs fail most often. */
export const viaV15Recommended = (from: Identity | null, target: Firmware) =>
  !!from && !isLoader(from) && from.text !== V15.product && target.sha256 !== V15.sha256;

// keep the computer awake and the tab open while the FM-1 is being written
let wake: { release(): Promise<void> } | null = null;
const guardLeave = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ""; };
async function holdAwake(on: boolean) {
  if (on) {
    addEventListener("beforeunload", guardLeave);
    try { wake = await (navigator as Navigator & { wakeLock?: { request(t: "screen"): Promise<{ release(): Promise<void> }> } }).wakeLock?.request("screen") ?? null; } catch { wake = null; }
  } else {
    removeEventListener("beforeunload", guardLeave);
    await wake?.release().catch(() => {}); wake = null;
  }
}

/** The FM-1's song checksums from the last song check, so a clear can make sure the song is still that one. */
let checkedSong: Map<number, { size: number; crc: number }> | null = null;

/** A name for a song saved automatically before it's replaced or cleared. */
export const autoSongName = () => `Saved ${new Date().toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}`;

export const device = {
  get state() { return state; },
  subscribe(f: (s: DeviceState) => void) { listeners.add(f); return () => { listeners.delete(f); }; },
  clearError() { set({ error: null }); },

  /** Must run from a click (the browser asks for MIDI permission). */
  async connect() {
    try {
      provider ??= await WebMIDIProvider.request();
      provider.onChange(() => { if (!state.busy) void device.identify(); });
      set({ midi: "ready", error: null });
      await device.identify();
    } catch (e) { set({ error: (e as Error).message }); }
  },

  async identify() {
    if (!provider) return null;
    const d = await new Updater(provider).identify();
    let mboot: MbootInfo | null = null;
    if (d && isLoader(d.identity)) {
      const m = await new Updater(provider).findMBoot();
      mboot = m?.mboot.info ?? null;
      m?.link.close();
      if (mboot) rememberChip(mboot);
    }
    set({ identity: d?.identity ?? null, port: d?.portName ?? "", mboot });
    return d?.identity ?? null;
  },

  async run<T>(label: string, f: (u: Updater) => Promise<T>): Promise<T | null> {
    if (!provider) { set({ error: "Connect to the FM-1 first." }); return null; }
    if (state.busy) return null;
    set({ busy: label, progress: null, error: null });
    note(label);
    await holdAwake(true);
    try { return await f(new Updater(provider, undefined, note)); }
    catch (e) { const m = (e as Error).message; note("✗ " + m); set({ error: m }); return null; }
    finally { await holdAwake(false); set({ busy: null, progress: null }); void device.identify(); }
  },

  /** Saves the FM-1's current work to the library entry it belongs to. */
  backup(owner: Firmware | undefined, includeSamples = true, kind: Backup["kind"] = "device") {
    return device.run("Backing up", async (u) => {
      const d = await u.find((id) => !isLoader(id));
      if (!d) throw new FM1Error("notfound", "FM-1 not found.");
      try {
        const a = await captureArchive(d, familyOf(d.identity), includeSamples, (n, t) => set({ progress: t ? n / t : null }));
        const b = backupRecord(a, owner?.id ?? "", kind);
        await store.saveBackup(b);
        note(`✓ saved ${b.partsSummary}`);
        return b;
      } finally { d.link.close(); }
    });
  },

  restore(b: Backup, includeSamples = true) {
    return device.run("Restoring", async (u) => {
      if (!b.archive) throw new FM1Error("unsupported", "This backup cannot be written back.");
      const d = await u.find((id) => !isLoader(id));
      if (!d) throw new FM1Error("notfound", "FM-1 not found.");
      try { await restoreArchive(b.archive, d, familyOf(d.identity), includeSamples, (n, t) => set({ progress: t ? n / t : null })); note("✓ restored"); return true; }
      finally { d.link.close(); }
    });
  },

  /** Saves the SLOOP song on the FM-1 (the loop in progress, the song order, sections A-D) under a name. */
  saveSong(owner: Firmware | undefined, name: string) {
    return device.run("Saving the song", async (u) => {
      const d = await u.find((id) => !isLoader(id));
      if (!d) throw new FM1Error("notfound", "FM-1 not found.");
      try {
        const s = new SLOOPArchive(d.link);
        if (!(await s.supported())) throw new FM1Error("unsupported", `${d.identity.text} doesn't have SLOOP's song backup. It works with SLOOP 2.3 or later and firmware built on it.`);
        const a = await s.capture(d.identity.text, SLOOP_SONG_IDS, (n, t) => set({ progress: t ? n / t : null }));
        const b = { ...backupRecord(a, owner?.id ?? "", "song"), label: name };
        await store.saveBackup(b);
        note(`✓ saved the song "${name}"`);
        return b;
      } finally { d.link.close(); }
    });
  },

  /** The saved song that matches what's on the FM-1 ("saved"), none ("unsaved"), or why it couldn't tell. */
  async checkSongSaved(songs: Backup[]): Promise<{ saved?: string; unsaved?: true; failed?: string }> {
    if (!provider) return { failed: "Connect to the FM-1 first." };
    if (state.busy) return { failed: "The FM-1 is busy." };
    set({ busy: "Checking the song on the FM-1", progress: null });           // (nothing else uses the port meanwhile)
    checkedSong = null;
    const u = new Updater(provider, undefined, note);
    const d = await u.find((id) => !isLoader(id));
    if (!d) { set({ busy: null }); return { failed: "FM-1 not found." }; }
    try {
      const now = await new SLOOPArchive(d.link).checksums();
      checkedSong = now;
      const s = songs.find((b) => b.archive && SLOOPArchive.matches(b.archive, now));
      return s ? { saved: s.label } : { unsaved: true };
    } catch (e) { return { failed: (e as Error).message }; }
    finally { d.link.close(); set({ busy: null }); }
  },

  /** Puts a saved song on the FM-1; with `saveFirstAs`, the FM-1's song is saved first (a failed save stops it). */
  loadSong(song: Backup, saveFirstAs: string | null = null) {
    return device.run("Loading the song", async (u) => {
      const d = await u.find((id) => !isLoader(id));
      if (!d) throw new FM1Error("notfound", "FM-1 not found.");
      try {
        if (!song.archive) throw new FM1Error("badpkg", "This song can't be read.");
        if (saveFirstAs) {
          const a = await new SLOOPArchive(d.link).capture(d.identity.text, SLOOP_SONG_IDS, (n, t) => set({ busy: "Saving the FM-1's song", progress: t ? n / t : null }));
          await store.saveBackup({ ...backupRecord(a, song.firmwareId, "song"), label: saveFirstAs });
          note(`✓ saved the FM-1's song as "${saveFirstAs}"`);
        }
        await restoreArchive(song.archive, d, familyOf(d.identity), false, (n, t) => set({ busy: "Loading the song", progress: t ? n / t : null }));
        note(`✓ loaded "${song.label}"`);
        return true;
      } finally { d.link.close(); }
    });
  },

  /** Clears the song on the FM-1 (every note of the loop, sections A-D), saving it first when asked. */
  clearSong(owner: Firmware | undefined, saveFirstAs: string | null) {
    return device.run("Clearing the song", async (u) => {
      const d = await u.find((id) => !isLoader(id));
      if (!d) throw new FM1Error("notfound", "FM-1 not found.");
      try {
        const s = new SLOOPArchive(d.link);
        if (saveFirstAs) {
          const a = await s.capture(d.identity.text, SLOOP_SONG_IDS, (n, t) => set({ busy: "Saving the song", progress: t ? n / t : null }));
          await store.saveBackup({ ...backupRecord(a, owner?.id ?? "", "song"), label: saveFirstAs });
          note(`✓ saved the song "${saveFirstAs}"`);
        }
        // (not saved first: only if it's still the song that was checked)
        await s.clearSong((n, t) => set({ busy: "Clearing the song", progress: n / t }), saveFirstAs ? null : checkedSong);
        note("✓ cleared the song on the FM-1");
        return true;
      } finally { d.link.close(); }
    });
  },

  /** The swap: back up what's on the FM-1, install, then put back this firmware's latest backup. */
  install(target: Firmware, opts: { backupFirst: boolean; restoreAfter: boolean; resume?: boolean; viaV15?: Firmware }) {
    return device.run(opts.resume ? "Finishing the install" : `Installing ${target.name}`, async (u) => {
      const bytes = await store.packageBytes(target.sha256);
      if (!bytes) throw new FM1Error("badpkg", "This firmware has no package file. Add the .fwsc first.");
      const pkg = await readPackage(bytes);
      const started = Date.now();
      const all = await store.firmwares();
      let from = "", backupTaken = false;
      if (!opts.resume) {
        const now = await u.identify();
        if (!now) throw new FM1Error("notfound", "FM-1 not found. Check the USB cable, and close any other app using the FM-1.");
        from = now.identity.text;
        const fam = familyOf(now.identity);
        // (unknown firmware: Felucca's and SLOOP's backups are tried; a backup that fails stops the install)
        if (opts.backupFirst && (supportsArchive(fam) || fam === "unknown")) {
          const owner = all.find((f) => f.product === from && f.sha256);
          const d = await u.find((id) => !isLoader(id));
          if (!d) throw new FM1Error("notfound", "The FM-1 couldn't be backed up (it wasn't found). Nothing was installed.");
          try {
            const a = await captureArchive(d, fam, true, (n, t) => set({ progress: t ? n / t : null })).catch((e: Error) => {
              throw new FM1Error("unsupported", `${e.message} Nothing was installed: untick “Back up first” to install without a backup.`);
            });
            await store.saveBackup(backupRecord(a, owner?.id ?? "", "auto"));
            backupTaken = true; note("✓ backed up the current firmware's work");
          } finally { d.link.close(); }
        }
      }
      const steps = (prefix: string, size: number) => {
        const total = Updater.expectedRequests(size - 20);
        return (s: Step) => {
          if (s.kind === "verify") set({ busy: prefix + "Checking the package", progress: null });
          if (s.kind === "loader") { set({ busy: prefix + "Starting the update loader", progress: null }); note("update loader starting"); }
          if (s.kind === "write") set({ busy: prefix + "Writing firmware (keep the USB cable in)", progress: s.n / total });
          if (s.kind === "reboot") { set({ busy: prefix + "Restarting", progress: null }); note("restarting"); }
        };
      };
      // official V15 first, as a clean base
      if (opts.viaV15 && !opts.resume) {
        const v15Bytes = await store.packageBytes(opts.viaV15.sha256);
        const v15 = v15Bytes ? await readPackage(v15Bytes) : null;
        if (!v15 || v15.stock?.version !== "V15") throw new FM1Error("badpkg", "The official V15 file in your library is missing or doesn't match the release.");
        const hop = { id: uid(), firmwareId: opts.viaV15.id, date: Date.now(), from, to: v15.product, success: false, message: `Step 1 of 2, on the way to ${target.name}`, duration: 0, backupTaken, restored: false };
        const t0 = Date.now();
        try { await u.install(v15, steps("Step 1 of 2: official V15 – ", v15.bytes.length)); hop.success = true; note("✓ installed official V15"); }
        catch (e) { hop.message = (e as Error).message; throw e; }
        finally {
          hop.duration = (Date.now() - t0) / 1000;
          await store.saveInstall(hop);
          if (hop.success) await store.saveFirmware(Object.assign(opts.viaV15, { lastInstalledAt: Date.now(), installCount: opts.viaV15.installCount + 1 }));
        }
        from = v15.product;
        await new Promise((r) => setTimeout(r, 2000));
      }
      const onStep = steps(opts.viaV15 && !opts.resume ? "Step 2 of 2: " : "", pkg.bytes.length);
      const event = { id: uid(), firmwareId: target.id, date: Date.now(), from, to: pkg.product, success: false, message: "", duration: 0, backupTaken, restored: false };
      try {
        const id = opts.resume ? await u.resume(pkg, onStep) : await u.install(pkg, onStep);
        if (!id) throw new FM1Error("noloader", "The FM-1 is not in update mode. Use Install instead.");
        note(`✓ installed ${id.text}`);
        Object.assign(event, { success: true, message: "Installed" });
        Object.assign(target, { lastInstalledAt: Date.now(), installCount: target.installCount + 1, status: target.status === "notTried" ? "tried" : target.status });
        await store.saveFirmware(target);
        if (opts.restoreAfter) {
          const latest = (await store.backups()).filter((b) => b.firmwareId === target.id && b.archive && b.kind !== "song").sort((a, b) => b.date - a.date)[0];
          if (latest?.archive) {
            const d = await u.find((i) => !isLoader(i));
            // the install itself succeeded: a restore that fails is said as such (not as a failed install)
            try {
              if (!d) throw new Error("the FM-1 wasn't found after the restart");
              await restoreArchive(latest.archive, d, familyOf(d.identity), true, (n, t) => set({ busy: "Putting your work back", progress: t ? n / t : null }));
              event.restored = true; note("✓ restored the last backup for this firmware");
            } catch (e) {
              throw new FM1Error("restore", `${id.text} is installed, but putting your work back failed (${(e as Error).message}). Restore it from Device → Restore latest.`);
            } finally { d?.link.close(); }
          }
        }
        return id;
      } catch (e) { event.message = (e as Error).message; throw e; }
      finally { event.duration = (Date.now() - started) / 1000; await store.saveInstall(event); }
    });
  },
};

/** The flash chip m-bootloader reported becomes the app's chip setting (it can't be read any other way over USB). */
function rememberChip(info: MbootInfo) {
  const c = chipOfJedec(info.jedec);
  if (c !== "unknown") setMyChip(c);
  try {
    const all = JSON.parse(localStorage.getItem("chipByUnit") ?? "{}");
    all[info.uid] = info.jedec;
    localStorage.setItem("chipByUnit", JSON.stringify(all));
  } catch { /* private window */ }
}

async function helperPackage(kind: keyof typeof HELPERS): Promise<FirmwarePackage> {
  const h = HELPERS[kind];
  const r = await fetch(`mboot/${h.file}`);
  if (!r.ok) throw new FM1Error("badpkg", "m-bootloader's helper is missing from this app.");
  const bytes = new Uint8Array(await r.arrayBuffer());
  if (await sha256Hex(bytes) !== h.sha256) throw new FM1Error("badpkg", "m-bootloader's helper doesn't match its published checksum.");
  return readPackage(bytes);
}

/** m-bootloader operations (docs/flash-chips.md, levels 0–1 of the roadmap's safety track). */
export const mboot = {
  /** Sends m-bootloader's helper as an update; the FM-1 then runs MIDI mode from RAM (nothing installed permanently). */
  startHelper() {
    return device.run("Starting m-bootloader's helper", async (u) => {
      const now = await u.identify();
      if (!now) throw new FM1Error("notfound", "FM-1 not found.");
      const kind = helperFor(familyOf(now.identity));
      if (!kind) throw new FM1Error("unsupported", `${now.identity.text} isn't known to accept m-bootloader's helper. Install official V15 or a Felucca-family firmware first.`);
      const pkg = await helperPackage(kind);
      const { link, mboot: m } = await u.startHelper(pkg, (id) => helperFor(familyOf(id)) === kind, (s) => {
        if (s.kind === "verify") set({ busy: "Sending the helper", progress: null });
        if (s.kind === "loader") set({ busy: "Waiting for the helper", progress: null });
      });
      link.close();
      rememberChip(m.info);
      set({ mboot: m.info });
      note(`✓ m-bootloader ${m.info.kind === "stage" ? "helper" : ""} ${m.info.version}, flash ${m.info.jedec.toString(16)}`);
      return m.info;
    });
  },

  /** Reads the whole flash (checked against the chip's CRC-32) and keeps it in this browser. */
  backupFlash(firmwareName: string) {
    return device.run("Reading the whole flash", async (u) => {
      const d = await u.findMBoot();
      if (!d) throw new FM1Error("notfound", "m-bootloader isn't answering. Start the helper again.");
      try {
        const data = await d.mboot.backup((n, t) => set({ progress: n / t }));
        const i = d.mboot.info;
        await store.saveFlash({ id: uid(), date: Date.now(), unit: i.uid, jedec: i.jedec, chipKey: i.chipKey, firmware: firmwareName,
          mboot: i.version, size: data.length, crc: crc32(data), data });
        note(`✓ saved the whole flash (${data.length >> 10} KB)`);
        return true;
      } finally { d.link.close(); }
    });
  },

  /** Leaves MIDI mode; the FM-1 restarts into its firmware. */
  restart() {
    return device.run("Restarting the FM-1", async (u) => {
      const d = await u.findMBoot();
      if (!d) throw new FM1Error("notfound", "m-bootloader isn't answering.");
      d.mboot.restart(); d.link.close();
      set({ mboot: null });
      await new Promise((r) => setTimeout(r, 3000));
      return true;
    });
  },
};

export function backupRecord(a: DeviceArchive, firmwareId: string, kind: Backup["kind"]): Backup {
  return { id: uid(), firmwareId, date: Date.now(), identity: a.info.identity ?? a.firmware, family: a.family, kind,
    label: kind === "auto" ? "Before a swap" : kind === "song" ? "Song" : "Backup", sizeBytes: totalBytes(a), partsSummary: `${a.parts.length} parts`, archive: a };
}

export type { FirmwarePackage };
