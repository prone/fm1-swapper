// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The connected FM-1 and every operation on it (mirrors App/DeviceController.swift). One operation at a time.
import { WebMIDIProvider } from "./fm1kit/midi";
import { FM1Error, Step, Updater } from "./fm1kit/ota";
import { FirmwarePackage, Identity, STOCK, familyOf, isLoader, readPackage, supportsArchive } from "./fm1kit/package";
import { DeviceArchive, captureArchive, restoreArchive, totalBytes } from "./fm1kit/archive";
import { Backup, Firmware, store, uid } from "./store";

export interface DeviceState {
  midi: "none" | "unsupported" | "ready";
  identity: Identity | null; port: string;
  busy: string | null;                      // what is running, for the UI
  progress: number | null;                  // 0…1
  log: string[]; error: string | null;
}

let state: DeviceState = { midi: WebMIDIProvider.supported() ? "none" : "unsupported", identity: null, port: "", busy: null, progress: null, log: [], error: null };
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
    set({ identity: d?.identity ?? null, port: d?.portName ?? "" });
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
        if (opts.backupFirst && supportsArchive(fam)) {
          const owner = all.find((f) => f.product === from && f.sha256);
          const d = await u.find((id) => !isLoader(id));
          if (d) try {
            const a = await captureArchive(d, fam, true, (n, t) => set({ progress: t ? n / t : null }));
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
          const latest = (await store.backups()).filter((b) => b.firmwareId === target.id && b.archive).sort((a, b) => b.date - a.date)[0];
          if (latest?.archive) {
            const d = await u.find((i) => !isLoader(i));
            if (d) try {
              await restoreArchive(latest.archive, d, familyOf(d.identity), true, (n, t) => set({ busy: "Putting your work back", progress: t ? n / t : null }));
              event.restored = true; note("✓ restored the last backup for this firmware");
            } finally { d.link.close(); }
          }
        }
        return id;
      } catch (e) { event.message = (e as Error).message; throw e; }
      finally { event.duration = (Date.now() - started) / 1000; await store.saveInstall(event); }
    });
  },
};

export function backupRecord(a: DeviceArchive, firmwareId: string, kind: Backup["kind"]): Backup {
  return { id: uid(), firmwareId, date: Date.now(), identity: a.info.identity ?? a.firmware, family: a.family, kind,
    label: kind === "auto" ? "Before a swap" : "Backup", sizeBytes: totalBytes(a), partsSummary: `${a.parts.length} parts`, archive: a };
}

export type { FirmwarePackage };
