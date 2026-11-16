// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Installing the app (Chrome/Edge "Install"), offline support (sw.js) and updates.
import { useEffect, useState } from "preact/hooks";

interface InstallPrompt extends Event { prompt(): Promise<void>; userChoice: Promise<{ outcome: "accepted" | "dismissed" }> }

let installEvent: InstallPrompt | null = null;
let waiting: ServiceWorker | null = null;
let userAskedReload = false;   // never reload on our own: an FM-1 install may be running
const listeners = new Set<() => void>();
const changed = () => listeners.forEach((f) => f());

export const isInstalled = () => matchMedia("(display-mode: standalone)").matches;

export function startPWA() {
  addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); installEvent = e as InstallPrompt; changed(); });
  addEventListener("appinstalled", () => { installEvent = null; changed(); });
  // keep the library even when the computer runs low on space (Chrome grants this to installed apps)
  void navigator.storage?.persist?.().catch(() => {});
  if (!("serviceWorker" in navigator) || import.meta.env.DEV) return;
  navigator.serviceWorker.addEventListener("controllerchange", () => { if (userAskedReload) { userAskedReload = false; location.reload(); } });
  navigator.serviceWorker.register("./sw.js").then((reg) => {
    const track = (w: ServiceWorker | null) => w?.addEventListener("statechange", () => {
      if (w.state === "installed" && navigator.serviceWorker.controller) { waiting = w; changed(); }
    });
    if (reg.waiting && navigator.serviceWorker.controller) { waiting = reg.waiting; changed(); }
    track(reg.installing);
    reg.addEventListener("updatefound", () => track(reg.installing));
    setInterval(() => void reg.update().catch(() => {}), 60 * 60 * 1000);
  }).catch(() => { /* offline support unavailable: the app still works online */ });
}

export function usePWA() {
  const [, tick] = useState(0);
  useEffect(() => { const f = () => tick((n) => n + 1); listeners.add(f); return () => { listeners.delete(f); }; }, []);
  return {
    canInstall: !!installEvent,
    install: async () => { const e = installEvent; if (!e) return; installEvent = null; changed(); await e.prompt(); },
    updateReady: !!waiting,
    update: () => { if (!waiting) return; userAskedReload = true; waiting.postMessage("skipWaiting"); },
  };
}
