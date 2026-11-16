// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
// Firmware to add: The Firmware Hub's list (checked downloads, flash chip support, kinds, links), then community
// firmware that is only on GitHub (2bbb/fm1-firmware-collection), which opens as a normal download to drop in.
import { useEffect, useMemo, useState } from "preact/hooks";
import { CatalogEntry, FEATURED, addFromHub, entryOwner, entryTitle, importFile, loadCommunity, officialFirmware, packagesOf, tryDownload, addPackage } from "../catalog";
import { ATTRIBUTION, Chip, HUB, HubFirmware, KIND_LABEL, myChip, useHub } from "../hub";
import { FileDrop, Library, ago } from "./common";

type Sort = "recent" | "stars" | "name";

export const ChipBadge = ({ chip }: { chip: Chip | undefined }) =>
  chip === "old" ? <span class="badge" style={{ background: "rgba(255,69,58,.16)", color: "#ff8a80" }} title="Only the first FM-1s' flash chip">Older FM-1s only</span>
    : chip === "new" ? <span class="badge green" title="Works with both FM-1 flash chips">All FM-1s</span>
      : chip === "any" ? <span class="badge" title="Doesn't check the flash chip">No chip check</span> : null;

export function GetFirmware({ lib, opened }: { lib: Library; opened: (id: string, swap?: boolean) => void }) {
  const hub = useHub();
  const [community, setCommunity] = useState<CatalogEntry[] | null>(null);
  const [sort, setSort] = useState<Sort>("recent");
  const [kind, setKind] = useState<string | null>(null);
  const [newChipOnly, setNewChipOnly] = useState(myChip() === "new");
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ text: string; tone: "ok" | "warn" | "err" } | null>(null);
  useEffect(() => { loadCommunity().then(setCommunity).catch(() => setCommunity([])); }, []);

  const haveSha = (sha: string) => lib.firmwares.some((f) => f.sha256 === sha);
  const haveRepo = (repo?: string) => !!repo && lib.firmwares.some((f) => f.repo.toLowerCase() === repo.toLowerCase() && f.sha256);
  const match = (s: string) => !q || s.toLowerCase().includes(q.toLowerCase());
  const list = useMemo(() => (hub?.list ?? [])
    .filter((f) => !f.linkOnly && (!kind || f.kind.includes(kind)) && (!newChipOnly || f.chip !== "old") && match(`${f.name} ${f.author} ${f.what}`))
    .sort((a, b) => sort === "stars" ? b.stars - a.stars : sort === "name" ? a.name.localeCompare(b.name) : b.date.localeCompare(a.date)),
  [hub, kind, newChipOnly, q, sort]);
  const githubOnly = useMemo(() => (community ?? [])
    .filter((e) => e.repo && !hub?.byRepo.has(e.repo.toLowerCase()) && match(`${e.repo} ${e.description}`))
    .sort((a, b) => sort === "stars" ? (b.stars ?? 0) - (a.stars ?? 0) : sort === "name" ? entryTitle(a).localeCompare(entryTitle(b)) : (b.pushed ?? "").localeCompare(a.pushed ?? "")),
  [community, hub, q, sort]);

  async function act(key: string, f: () => Promise<void>) {
    setBusy(key); setMsg(null);
    try { await f(); } catch (e) { setMsg({ tone: "err", text: (e as Error).message }); } finally { setBusy(null); }
  }
  const getHub = (e: HubFirmware) => act(e.id, async () => {
    const r = await addFromHub(e);
    setMsg({ tone: r.warning ? "warn" : "ok", text: `${r.isNew ? "Added" : "Already in your library:"} ${r.firmware.name} (checked against The Firmware Hub)${r.warning ? ` — ${r.warning}` : ""}` });
    if (r.isNew) opened(r.firmware.id);
  });
  const getGitHub = (e: CatalogEntry, url: string) => act(e.id, async () => {
    const bytes = await tryDownload(url);
    if (!bytes) {
      window.open(url, "_blank", "noopener");
      setMsg({ tone: "warn", text: `GitHub doesn't let web pages download release files, so ${entryTitle(e)} opened as a normal download. Drop the .fwsc into the box above when it finishes.` });
      return;
    }
    const r = await addPackage(bytes, { fileName: url.split("/").pop() || "firmware.fwsc", name: entryTitle(e), author: entryOwner(e), repo: e.repo ?? "", sourceURL: url, summary: e.description ?? "" });
    if (r.isNew) opened(r.firmware.id);
  });
  const drop = async (files: File[]) => {
    const out: string[] = [];
    for (const f of files) try { out.push(...(await importFile(f))); } catch (e) { out.push(`${f.name}: ${(e as Error).message}`); }
    setMsg({ tone: "ok", text: out.join("\n") });
  };

  return (
    <>
      <h1>Get firmware</h1>
      <FileDrop accept=".fwsc,.html,.htm" multiple onFiles={drop}>Downloaded a <b>.fwsc</b> or M-VAVE's Workbench <b>.html</b>? Drop it here.</FileDrop>
      {msg && <div class={"banner " + msg.tone} style={{ whiteSpace: "pre-line" }}>{msg.text}</div>}

      <h2>Featured</h2>
      <div class="grid">
        {FEATURED.map((f) => {
          const h = f.repo ? hub?.byRepo.get(f.repo.toLowerCase()) : undefined;
          const official = f.id === "official";
          return (
            <div class="card" key={f.id} style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              <b>{f.name}</b>
              <div class="small dim">{f.author}</div>
              <div class="small" style={{ flex: 1 }}>{f.blurb}</div>
              {official ? <button class="btn primary" disabled={!!busy} onClick={() => act("official", async () => { const fw = await officialFirmware(); opened(fw.id); })}>{busy === "official" ? "Downloading…" : "Get V15"}</button>
                : h && !h.linkOnly ? (haveSha(h.sha256) ? <span class="badge green">In your library</span>
                  : <button class="btn primary" disabled={!!busy} onClick={() => getHub(h)}>{busy === h.id ? "Downloading…" : `Get ${h.version}`}</button>)
                  : <div class="small faint">{f.howToGet}</div>}
              <a class="small" href={f.website} target="_blank" rel="noopener noreferrer">Website ↗</a>
            </div>
          );
        })}
      </div>

      <h2>All firmware {hub ? `(${list.length})` : ""}</h2>
      <div class="chips">
        <button class={"chip" + (kind ? "" : " on")} onClick={() => setKind(null)}>All</button>
        {Object.entries(KIND_LABEL).map(([k, l]) => <button key={k} class={"chip" + (kind === k ? " on" : "")} onClick={() => setKind(kind === k ? null : k)}>{l}</button>)}
      </div>
      <div style={{ display: "flex", gap: 8, marginBottom: 6, flexWrap: "wrap" }}>
        <input type="search" placeholder="Search firmware" value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} style={{ flex: 1, minWidth: 180 }} />
        <select value={sort} onChange={(e) => setSort((e.target as HTMLSelectElement).value as Sort)} aria-label="Sort by">
          <option value="recent">Recently updated</option><option value="stars">Most stars</option><option value="name">Name</option>
        </select>
      </div>
      <label class="check small"><input type="checkbox" checked={newChipOnly} onChange={(e) => setNewChipOnly((e.target as HTMLInputElement).checked)} />
        Only firmware that works on newer FM-1s (flash chip 0xB36014)</label>
      {!hub && <div class="dim">Loading The Firmware Hub's list…</div>}
      <div class="rows">
        {list.map((f) => (
          <div key={f.id} style={{ alignItems: "flex-start" }}>
            <span class="row-main">
              <div style={{ display: "flex", gap: 6, alignItems: "center", flexWrap: "wrap" }}>
                <b>{f.name}</b> <span class="small dim">{f.version} · {f.author}</span> <ChipBadge chip={f.chip} />{f.beta && <span class="badge">beta</span>}
              </div>
              {f.what && <div class="small dim">{f.what}</div>}
              <div class="small faint">
                {f.stars ? `★ ${f.stars} · ` : ""}{f.lic ? `${f.lic} · ` : ""}{f.date ? `updated ${ago(Date.parse(f.date))}` : ""}
                {f.play && <> · <a href={f.play} target="_blank" rel="noopener noreferrer">Play in browser ↗</a></>}
                {f.editor && <> · <a href={f.editor} target="_blank" rel="noopener noreferrer">Editor ↗</a></>}
                {f.repo && <> · <a href={`https://github.com/${f.repo}`} target="_blank" rel="noopener noreferrer">GitHub ↗</a></>}
              </div>
            </span>
            {haveSha(f.sha256) ? <span class="badge green">Have it</span>
              : <button class="btn" disabled={!!busy} onClick={() => getHub(f)}>{busy === f.id ? "…" : "Get"}</button>}
          </div>
        ))}
      </div>
      <p class="small faint">{ATTRIBUTION} – <a href={HUB} target="_blank" rel="noopener noreferrer">thefirmwarehub.com</a> (CC BY 4.0). Descriptions belong to each firmware's maker.
        Downloads are checked against the SHA-256 the hub publishes before they are added.</p>

      {githubOnly.length > 0 && (
        <>
          <h2>More on GitHub ({githubOnly.length})</h2>
          <p class="small dim" style={{ margin: "0 4px 8px" }}>Not in The Firmware Hub's list, so not checked and with no flash chip information. These open as a normal download (↗) for you to drop in above.</p>
          <div class="rows">
            {githubOnly.map((e) => {
              const pkg = packagesOf(e)[0];
              return (
                <div key={e.id}>
                  <span class="row-main">
                    <b>{entryTitle(e)}</b> <span class="small dim">{entryOwner(e)}</span>
                    {e.description && <div class="small dim">{e.description}</div>}
                    <div class="small faint">{e.stars ? `★ ${e.stars} · ` : ""}{e.pushed ? `updated ${ago(Date.parse(e.pushed))}` : ""} · <a href={`https://github.com/${e.repo}`} target="_blank" rel="noopener noreferrer">GitHub ↗</a></div>
                  </span>
                  {haveRepo(e.repo) ? <span class="badge green">Have it</span> : pkg?.url && <button class="btn" disabled={!!busy} onClick={() => getGitHub(e, pkg.url!)}>Get ↗</button>}
                </div>
              );
            })}
          </div>
          <p class="small faint">List from 2bbb/fm1-firmware-collection.</p>
        </>
      )}
    </>
  );
}
