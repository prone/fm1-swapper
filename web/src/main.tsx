// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// FM-1 Swapper for the web: the iOS app's Device, Library, Get firmware and History screens, plus the emulator and tutorials.
import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import "./style.css";
import { Firmware } from "./store";
import { Tutorial, tutorialFor } from "./tutorial";
import { useLibrary } from "./ui/common";
import { DeviceView } from "./ui/DeviceView";
import { LibraryView } from "./ui/LibraryView";
import { GetFirmware } from "./ui/GetFirmware";
import { HistoryView } from "./ui/HistoryView";
import { Emulator } from "./ui/Emulator";

const TABS = ["Device", "Library", "Get firmware", "History"] as const;
type Tab = (typeof TABS)[number];

function App() {
  const lib = useLibrary();
  const [tab, setTab] = useState<Tab>("Library");
  const [openId, setOpenId] = useState<string | null>(null);
  const [emu, setEmu] = useState<{ f: Firmware; t?: Tutorial } | null>(null);
  useEffect(() => { if (lib.loaded && !lib.firmwares.length && tab === "Library") setTab("Get firmware"); }, [lib.loaded]);
  const open = (id: string) => { setOpenId(id); setTab("Library"); scrollTo(0, 0); };

  return (
    <>
      <header class="top">
        <div class="brand"><i aria-hidden="true" /><span>FM-1 Swapper</span></div>
        <nav class="tabs">
          {TABS.map((t) => <button key={t} aria-current={t === tab ? "page" : undefined} onClick={() => { setTab(t); if (t === "Library") setOpenId(null); }}>{t}</button>)}
        </nav>
      </header>
      <main class="shell">
        {tab === "Device" && <DeviceView lib={lib} open={open} />}
        {tab === "Library" && <LibraryView lib={lib} openId={openId} setOpenId={setOpenId} tryIt={(f, tut) => setEmu({ f, t: tut ? tutorialFor(f) : undefined })} />}
        {tab === "Get firmware" && <GetFirmware lib={lib} opened={open} />}
        {tab === "History" && <HistoryView lib={lib} open={open} />}
        <footer class="small faint" style={{ marginTop: 40 }}>
          Beta. Not affiliated with M-VAVE. Firmware is written at your own risk; the FM-1's update loader lets an interrupted install be finished.
          {" "}<a href="https://github.com/prone/fm1-swapper" target="_blank" rel="noopener noreferrer">Source (GPL-3.0)</a>
          {" · "}Emulator: <a href="https://github.com/joakimeriksson/fm1-emu" target="_blank" rel="noopener noreferrer">fm1-emu</a> (MIT)
        </footer>
      </main>
      {emu && <Emulator f={emu.f} tutorial={emu.t} close={() => setEmu(null)} />}
    </>
  );
}

render(<App />, document.getElementById("app")!);
