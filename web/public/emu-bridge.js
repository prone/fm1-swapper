// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// The bridge into the fm1-emu emulator page, shared by the iOS app (a WKWebView user script: App/Views/EmulatorView.swift
// loads this file from the app bundle) and the web app (web/public/emu/index.html loads it first). It locks the zoom,
// hands the page a package through its own file input, drives its save/import/reset controls, plays tutorial demos,
// draws spotlights over the panel and reports the user's touches. Panel geometry: fm1-emu crates/fm1-live/src/panel.rs (MIT).
(() => {
  // --- lock the zoom: a fixed-scale viewport, no double-tap zoom, and 16px+ menus (iOS zooms into
  // any focused control whose text is smaller than 16px)
  const lockZoom = () => {
    let vp = document.querySelector('meta[name="viewport"]');
    if (!vp) { vp = document.createElement("meta"); vp.name = "viewport"; document.head.append(vp); }
    vp.content = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover";
    const st = document.createElement("style");
    st.textContent = "html, body { touch-action: manipulation; } select, input { font-size: 16px !important; }";
    document.head.append(st);
  };
  if (document.head) lockZoom(); else document.addEventListener("DOMContentLoaded", lockZoom);
  // --- Web MIDI stand-in: every MIDI input of the iPhone/iPad, forwarded by the app
  const input = { id: "ios-all", name: "All MIDI inputs (app)", manufacturer: "", type: "input",
    state: "connected", connection: "open", onmidimessage: null,
    addEventListener() {}, removeEventListener() {},
    open: async () => input, close: async () => input };
  const access = { inputs: new Map([[input.id, input]]), outputs: new Map(), sysexEnabled: false,
    onstatechange: null, addEventListener() {}, removeEventListener() {} };
  // in the iOS app (no Web MIDI in WebKit) the app forwards CoreMIDI; browsers keep their own Web MIDI
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fm1tutorial) {
    try { Object.defineProperty(navigator, "requestMIDIAccess", { value: async () => access, configurable: true }); } catch (e) {}
  }
  window.__fm1midi = (msgs) => {
    for (const b of msgs) if (input.onmidimessage) input.onmidimessage({ data: new Uint8Array(b), timeStamp: performance.now() });
  };

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const $ = (id) => document.getElementById(id);
  const fileFrom = (data, name) => {
    const dt = new DataTransfer();
    dt.items.add(new File([data], name, { type: "application/octet-stream" }));
    return dt.files;
  };

  // --- the app answers the page's confirm() for its own actions
  let autoConfirm = 0;
  const pageConfirm = window.confirm.bind(window);
  window.confirm = (m) => { if (autoConfirm > 0) { autoConfirm--; return true; } return pageConfirm(m); };

  // --- exports: the page saves a .fm1save through a download link; hand it to the app instead
  let exportWaiter = null;
  const click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (this.download && this.href.startsWith("blob:") && exportWaiter) {
      const w = exportWaiter, name = this.download;
      exportWaiter = null;
      fetch(this.href).then((r) => r.text()).then((text) => w({ name, text }), () => w(null));
      return;
    }
    return click.call(this);
  };

  window.__fm1load = async (b64, name) => {
    for (let i = 0; i < 300; i++) {
      const sel = $("fw");
      if (sel && sel.options.length > 0 && $("open")) break;
      await sleep(100);
    }
    await sleep(400); // the page's module attaches its handlers right after filling the list
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const open = $("open");
    if (!open) return "The emulator page changed: no file input found.";
    open.files = fileFrom(bytes, name);
    open.dispatchEvent(new Event("change"));
    const midi = $("midi");
    if (midi && !midi.disabled) { midi.value = "*"; midi.dispatchEvent(new Event("change")); }
    return "ok";
  };

  // --- tutorials: the FM-1 panel as fm1-emu draws it (crates/fm1-live/src/panel.rs), 1280 x 820
  const PANEL = (() => {
    const c = {};
    const circ = (n, x, y, r) => { c[n] = { x: x - r - 6, y: y - r - 6, w: 2 * r + 12, h: 2 * r + 12, cx: x, cy: y, kind: "knob" }; };
    circ("MASTER", 110, 135, 44); circ("SELECT", 250, 135, 44); circ("PRESETS", 110, 295, 44); circ("ALGORITHM", 250, 295, 44);
    [935, 1027, 1119, 1211].forEach((x, i) => circ("KNOB" + (i + 1), x, 120, 36));
    const btn = (n, x, y, w, h) => { c[n] = { x, y, w, h, cx: x + w / 2, cy: y + h / 2, kind: "button" }; };
    btn("OCT-", 62, 398, 112, 44); btn("OCT+", 186, 398, 112, 44);
    [["FX", "SCL", "ENV", "LFO", "EDIT", "GLO"], ["HOME", "SAVE", "ARP", "SEQ", "PLAY", "REC"]].forEach((row, r) =>
      row.forEach((n, i) => btn(n, 906 + i * 58, 232 + r * 76, 50, 64)));
    c.SCREEN = { x: 370, y: 42, w: 480, h: 480, kind: "area" };
    c.KEYS = { x: 55, y: 570, w: 1175, h: 222, kind: "area" };
    // note keys F3..G5 (MIDI 53..79): whites then blacks, as panel.rs lays them out
    const whites = [0, 2, 4, 6, 7, 9, 11, 12, 14, 16, 18, 19, 21, 23, 24, 26];
    whites.forEach((n, i) => { c["#" + (53 + n)] = { x: 61 + i * 73, y: 680, w: 62, h: 106, cx: 61 + i * 73 + 31, cy: 750, kind: "key" }; });
    [[1, 0], [3, 1], [5, 2], [8, 4], [10, 5], [13, 7], [15, 8], [17, 9], [20, 11], [22, 12], [25, 14]].forEach(([n, a]) => {
      const cx = 61 + (a + 1) * 73 - 5; c["#" + (53 + n)] = { x: cx - 31, y: 574, w: 62, h: 94, cx, cy: 640, kind: "key" };
    });
    return c;
  })();
  const NOTE = /^([A-Ga-g])(#|b)?(-?\d)$/;
  const midiOf = (name) => {
    const m = NOTE.exec(name); if (!m) return null;
    const pc = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }[m[1].toUpperCase()] + (m[2] === "#" ? 1 : m[2] === "b" ? -1 : 0);
    return (Number(m[3]) + 1) * 12 + pc;
  };
  const ctl = (name) => { const n = midiOf(name); return n != null ? PANEL["#" + n] : PANEL[name]; };
  // keyboard shortcuts the page understands (web/main.js)
  const KEYOF = { "OCT-": "z", "OCT+": "x", PLAY: " ", REC: "r", FX: "1", SCL: "2", ENV: "3", LFO: "4", EDIT: "5",
                  GLO: "6", HOME: "7", SAVE: "8", ARP: "9", SEQ: "0" };
  const PIANO = "awsedftgyhujkolp;'";               // C4 (60) .. F5 (77)
  const keyFor = (name) => {
    if (KEYOF[name]) return KEYOF[name];
    const n = midiOf(name); return n != null && n >= 60 && n < 60 + PIANO.length ? PIANO[n - 60] : null;
  };
  const canvas = () => $("panel");
  const toPage = (r) => {
    const cv = canvas(); if (!cv) return null;
    const b = cv.getBoundingClientRect(), sx = b.width / (cv.width || 1280), sy = b.height / (cv.height || 820);
    return { left: b.left + r.x * sx, top: b.top + r.y * sy, width: r.w * sx, height: r.h * sy, cx: b.left + (r.cx ?? r.x + r.w / 2) * sx, cy: b.top + (r.cy ?? r.y + r.h / 2) * sy };
  };
  const key = (k, down) => window.dispatchEvent(new KeyboardEvent(down ? "keydown" : "keyup", { key: k, bubbles: true }));
  const wheel = (r, clicks) => {
    const p = toPage(r); if (!p) return;
    const steps = Math.abs(clicks), dy = clicks > 0 ? -40 : 40;
    for (let i = 0; i < steps; i++)
      canvas().dispatchEvent(new WheelEvent("wheel", { clientX: p.cx, clientY: p.cy, deltaY: dy, bubbles: true, cancelable: true }));
  };

  // spotlight: a canvas pinned over the panel canvas itself (same parent, same box), drawn in the
  // panel's own 1280 x 820 coordinates, so it stays aligned however the page is zoomed or scrolled
  let spot = null, spotNames = [], spotRaf = 0;
  const drawSpot = () => {
    const panel = canvas();
    if (!spot || !panel) return;
    const dpr = devicePixelRatio || 1;
    const cssW = panel.offsetWidth, cssH = panel.offsetHeight;
    Object.assign(spot.style, { left: panel.offsetLeft + "px", top: panel.offsetTop + "px", width: cssW + "px", height: cssH + "px" });
    if (spot.width !== Math.round(cssW * dpr) || spot.height !== Math.round(cssH * dpr)) {
      spot.width = Math.round(cssW * dpr); spot.height = Math.round(cssH * dpr);
    }
    const g = spot.getContext("2d");
    const k = spot.width / (panel.width || 1280);                 // panel units -> overlay pixels
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, spot.width, spot.height);
    const rects = spotNames.map(ctl).filter(Boolean);
    if (rects.length) {
      const pad = 6, r = 10;
      g.setTransform(k, 0, 0, k, 0, 0);
      g.fillStyle = "rgba(0,0,0,0.6)";
      g.fillRect(0, 0, panel.width || 1280, panel.height || 820);
      g.globalCompositeOperation = "destination-out";
      for (const c of rects) { g.beginPath(); g.roundRect(c.x - pad, c.y - pad, c.w + 2 * pad, c.h + 2 * pad, r); g.fill(); }
      g.globalCompositeOperation = "source-over";
      g.strokeStyle = "#f2a33a"; g.lineWidth = 4;
      for (const c of rects) { g.beginPath(); g.roundRect(c.x - pad, c.y - pad, c.w + 2 * pad, c.h + 2 * pad, r); g.stroke(); }
    }
    spotRaf = requestAnimationFrame(drawSpot);
  };
  window.__fm1spot = (names) => {
    spotNames = names || [];
    const panel = canvas();
    if (!spot && panel) {
      spot = document.createElement("canvas");
      spot.style.cssText = "position:absolute;pointer-events:none;z-index:2";
      panel.parentElement.append(spot);
      const start = $("start"); if (start) start.style.zIndex = "3";   // the Start button stays on top
    }
    cancelAnimationFrame(spotRaf); drawSpot();
    const first = spotNames.map(ctl).filter(Boolean)[0];
    if (first) { const p = toPage(first); if (p && (p.top < 0 || p.top + p.height > innerHeight)) panel?.scrollIntoView({ block: "center", behavior: "smooth" }); }
    return spotNames.filter((n) => !ctl(n));      // unknown names, for the app to report
  };

  // actions: press / hold / release a control or note, turn a knob, wait
  window.__fm1do = async (actions) => {
    const held = [];
    for (const a of actions || []) {
      if (a.wait) { await sleep(a.wait); continue; }
      const name = a.press || a.hold || a.release || a.note;
      if (a.turn) {
        const r = ctl(a.turn);
        if (!r) return "unknown control " + a.turn;
        if (["SELECT", "PRESETS", "ALGORITHM"].includes(a.turn)) {
          const k = { SELECT: ["ArrowLeft", "ArrowRight"], PRESETS: ["ArrowDown", "ArrowUp"], ALGORITHM: [",", "."] }[a.turn];
          for (let i = 0; i < Math.abs(a.clicks || 1); i++) { key(k[(a.clicks || 1) > 0 ? 1 : 0], true); await sleep(60); }
        } else wheel(r, a.clicks || 1);
        await sleep(120); continue;
      }
      const k = keyFor(name);
      if (!k) return "can't press " + name + " from the app (only buttons and the keys C4–F5)";
      if (a.release) { key(k, false); continue; }
      key(k, true);
      if (a.hold) { held.push(k); continue; }
      await sleep(a.ms || 160);
      key(k, false);
      await sleep(80);
    }
    return "ok";
  };

  // your turn: report every control the user touches on the panel or keyboard
  // to the iOS app, or to the web app that hosts this page in a same-origin frame
  const report = (name, down) => {
    try { if (window.webkit && window.webkit.messageHandlers.fm1tutorial) window.webkit.messageHandlers.fm1tutorial.postMessage({ name, down }); } catch (e) {}
    try { if (window.parent !== window && window.parent.__fm1onEvent) window.parent.__fm1onEvent(name, down); } catch (e) {}
  };
  const hitName = (x, y) => {
    const cv = canvas(); if (!cv) return null;
    const b = cv.getBoundingClientRect(), px = (x - b.left) * (cv.width / b.width), py = (y - b.top) * (cv.height / b.height);
    for (const [n, r] of Object.entries(PANEL)) {
      if (r.kind !== "area" && px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h) return n;
    }
    return null;
  };
  // the user's own touches on the panel: presses, releases, knob turns
  const onPanel = (prefix, down, trusted) => (e) => {
    const n = e.target === canvas() && (!trusted || e.isTrusted) ? hitName(e.clientX, e.clientY) : null;
    if (n) report(prefix + n, down);
  };
  document.addEventListener("pointerdown", onPanel("", true), true);
  document.addEventListener("pointerup", onPanel("", false), true);
  document.addEventListener("wheel", onPanel("turn:", true, true), true);
  const KEYNAME = Object.fromEntries(Object.entries(KEYOF).map(([n, k]) => [k, n]));
  const onKey = (down) => (e) => {
    if (!e.isTrusted || (down && e.repeat)) return;
    const k = e.key.toLowerCase(), i = PIANO.indexOf(k);
    if (KEYNAME[k]) report(KEYNAME[k], down); else if (i >= 0) report("#" + (60 + i), down);
  };
  addEventListener("keydown", onKey(true), true);
  addEventListener("keyup", onKey(false), true);

  // save | export | import (arg: .fm1save text) | reset  ->  { ok, message, name?, text? }
  window.__fm1action = async (kind, arg) => {
    const status = $("save-status");
    const result = (extra = {}) => ({ ok: status?.dataset.error !== "true", message: status?.textContent || "", ...extra });
    const before = status?.textContent;
    const changed = async (ms) => { for (let t = 0; t < ms; t += 100) { if (status?.textContent !== before) break; await sleep(100); } await sleep(150); };
    // the page asks "are you sure?" for an import or a reset: the app already asked, so the bridge says yes once
    const confirmed = async (act) => { autoConfirm = 1; act(); await changed(6000); autoConfirm = 0; return result(); };
    if (status) status.dataset.error = "false";
    switch (kind) {
      case "save": {
        const b = $("save-now"); if (!b) return { ok: false, message: "No save control on the page." };
        b.click(); await changed(3000); return result();
      }
      case "export": {
        const b = $("export-save"); if (!b) return { ok: false, message: "No export control on the page." };
        const got = await new Promise((resolve) => {
          exportWaiter = resolve;
          b.click();
          setTimeout(() => { if (exportWaiter === resolve) { exportWaiter = null; resolve(null); } }, 8000);
        });
        if (!got) return { ok: false, message: (status?.textContent || "") || "Start the firmware first, then save." };
        return { ok: true, message: "Exported", name: got.name, text: got.text };
      }
      case "import": {
        const inp = $("import-save"); if (!inp) return { ok: false, message: "No import control on the page." };
        return confirmed(() => { inp.files = fileFrom(arg, "restore.fm1save"); inp.dispatchEvent(new Event("change")); });
      }
      case "reset": {
        const b = $("reset-save"); if (!b) return { ok: false, message: "No reset control on the page." };
        return confirmed(() => b.click());
      }
    }
    return { ok: false, message: "unknown action" };
  };
})();
