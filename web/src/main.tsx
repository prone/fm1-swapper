// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// FM-1 Swapper for the web: the iOS app's Device, Library, Get firmware and History screens, plus the emulator and tutorials.
import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import "./style.css";
import { Firmware } from "./store";
import { Tutorial, tutorialFor } from "./tutorial";
import { useDevice, useLibrary } from "./ui/common";
import { DeviceView } from "./ui/DeviceView";
import { LibraryView } from "./ui/LibraryView";
import { GetFirmware } from "./ui/GetFirmware";
import { HistoryView } from "./ui/HistoryView";
import { FirmwareEditor, unsavedEdits } from "./ui/FirmwareEditor";
import { Emulator } from "./ui/Emulator";
import { startPWA, usePWA } from "./pwa";

const TABS = ["Device", "Library", "Get firmware", "Firmware Editor", "History"] as const;
type Tab = (typeof TABS)[number];

function App() {
  const lib = useLibrary();
  const pwa = usePWA();
  const dev = useDevice();
  const [tab, setTab] = useState<Tab>("Library");
  const [openId, setOpenId] = useState<string | null>(null);
  const [swapNow, setSwapNow] = useState(false);
  const [emu, setEmu] = useState<{ f: Firmware; t?: Tutorial; start?: { save: string; hint: string }; title?: string } | null>(null);
  useEffect(() => { if (lib.loaded && !lib.firmwares.length && tab === "Library") setTab("Get firmware"); }, [lib.loaded]);
  const open = (id: string, swap = false) => { setOpenId(id); setSwapNow(swap); setTab("Library"); scrollTo(0, 0); };

  return (
    <>
      <header class="top">
        <div class="brand"><i aria-hidden="true" /><span>FM-1 Swapper</span></div>
        {pwa.canInstall && <button class="btn small" onClick={pwa.install} title="Adds FM-1 Swapper to your apps; it then works offline">Install app</button>}
        <nav class="tabs">
          {TABS.map((t) => <button key={t} aria-current={t === tab ? "page" : undefined} onClick={() => {
            if (t !== tab && unsavedEdits.dirty && !confirm("Leave the song editor without saving your changes?")) return;
            unsavedEdits.dirty = false;
            setTab(t); if (t === "Library") setOpenId(null);
          }}>{t}</button>)}
        </nav>
      </header>
      <main class="shell">
        {pwa.updateReady && (
          <div class="banner ok" style={{ display: "flex", gap: 10, alignItems: "center" }}>
            <span style={{ flex: 1 }}>A new version of FM-1 Swapper is ready.</span>
            <button class="btn" disabled={!!dev.busy || !!emu} title={dev.busy ? "Wait for the FM-1 to finish" : ""} onClick={pwa.update}>Reload</button>
          </div>
        )}
        {tab === "Device" && <DeviceView lib={lib} open={open} />}
        {tab === "Library" && <LibraryView lib={lib} openId={openId} setOpenId={(id) => { setOpenId(id); setSwapNow(false); }} swapNow={swapNow} swapped={() => setSwapNow(false)} tryIt={(f, tut) => setEmu({ f, t: tut ? tutorialFor(f) : undefined })} />}
        {tab === "Get firmware" && <GetFirmware lib={lib} opened={open} />}
        {tab === "Firmware Editor" && <FirmwareEditor lib={lib} play={(f, save, title) => setEmu({ f, title, start: { save, hint: "Song loaded. Press Start, then PLAY for the loop; for the song order, SAVE + key 13 (song mode), then PLAY." } })} />}
        {tab === "History" && <HistoryView lib={lib} open={open} />}
        <footer class="small faint" style={{ marginTop: 40 }}>
          Beta. Not affiliated with M-VAVE. Firmware is written at your own risk; the FM-1's update loader lets an interrupted install be finished.
          {" "}<a href="https://github.com/prone/fm1-swapper" target="_blank" rel="noopener noreferrer">Source (GPL-3.0)</a>
          {" · "}Emulator: <a href="https://github.com/joakimeriksson/fm1-emu" target="_blank" rel="noopener noreferrer">fm1-emu</a> (MIT)
        </footer>
      </main>
      {emu && <Emulator f={emu.f} tutorial={emu.t} start={emu.start} title={emu.title} close={() => setEmu(null)} />}
    </>
  );
}

// closing or reloading the page with unsaved song edits asks first
addEventListener("beforeunload", (e) => { if (unsavedEdits.dirty) e.preventDefault(); });

startPWA();
render(<App />, document.getElementById("app")!);
