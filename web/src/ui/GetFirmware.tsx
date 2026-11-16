// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import { useEffect, useMemo, useState } from "preact/hooks";
import { CatalogEntry, FEATURED, HubPackage, addPackage, entryOwner, entryTitle, hubPackages, loadCommunity, packagesOf, tryDownload } from "../catalog";
import { FileDrop, Library, ago } from "./common";
import { importFile } from "../catalog";

type Sort = "recent" | "stars" | "name";

export function GetFirmware({ lib, opened }: { lib: Library; opened: (id: string) => void }) {
  const [entries, setEntries] = useState<CatalogEntry[] | null>(null);
  const [hub, setHub] = useState<Map<string, HubPackage>>(new Map());
  const [err, setErr] = useState<string | null>(null);
  const [sort, setSort] = useState<Sort>("recent");
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ text: string; tone: "ok" | "warn" | "err" } | null>(null);

  useEffect(() => {
    loadCommunity().then(setEntries).catch((e) => setErr((e as Error).message));
    hubPackages().then(setHub);
  }, []);

  const have = (repo?: string) => !!repo && lib.firmwares.some((f) => f.repo.toLowerCase() === repo.toLowerCase() && f.sha256);
  const list = useMemo(() => (entries ?? [])
    .filter((e) => !q || `${e.repo} ${e.description}`.toLowerCase().includes(q.toLowerCase()))
    .sort((a, b) => sort === "stars" ? (b.stars ?? 0) - (a.stars ?? 0) : sort === "name" ? entryTitle(a).localeCompare(entryTitle(b)) : (b.pushed ?? "").localeCompare(a.pushed ?? "")),
  [entries, sort, q]);

  /** One click when the server allows browser downloads; otherwise the file downloads normally and the user drops it in. */
  async function get(repo: string | undefined, url: string, meta: { name: string; author: string; version?: string; summary?: string }) {
    setBusy(repo ?? url); setMsg(null);
    try {
      const hubPkg = repo ? hub.get(repo.toLowerCase()) : undefined;
      const bytes = await tryDownload(hubPkg?.url ?? url);
      if (!bytes) {
        window.open(url, "_blank", "noopener");
        setMsg({ tone: "warn", text: `${meta.name}'s host doesn't allow downloads from web pages, so it was opened as a normal download. Drop the .fwsc into the box below when it finishes.` });
        return;
      }
      const r = await addPackage(bytes, { fileName: url.split("/").pop() || "firmware.fwsc", name: meta.name, author: meta.author,
        version: meta.version ?? hubPkg?.version ?? "", repo: repo ?? "", sourceURL: url, summary: meta.summary ?? hubPkg?.about ?? "" });
      setMsg({ tone: r.warning ? "warn" : "ok", text: `${r.isNew ? "Added" : "Already in your library:"} ${r.firmware.name}${r.warning ? ` — ${r.warning}` : ""}` });
      if (r.isNew) opened(r.firmware.id);
    } catch (e) { setMsg({ tone: "err", text: (e as Error).message }); }
    finally { setBusy(null); }
  }

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
          const hubPkg = f.repo ? hub.get(f.repo.toLowerCase()) : undefined;
          return (
            <div class="card" key={f.id} style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              <b>{f.name}</b>
              <div class="small dim">{f.author}</div>
              <div class="small" style={{ flex: 1 }}>{f.blurb}</div>
              {hubPkg ? (
                have(f.repo) ? <span class="badge green">In your library</span>
                  : <button class="btn primary" disabled={!!busy} onClick={() => get(f.repo, hubPkg.url, { name: `${f.name} ${hubPkg.version}`.trim(), author: f.author, version: hubPkg.version, summary: f.blurb })}>
                    {busy === f.repo ? "Downloading…" : `Get ${hubPkg.version}`}</button>
              ) : <div class="small faint">{f.howToGet}</div>}
              <a class="small" href={f.website} target="_blank" rel="noopener noreferrer">Website ↗</a>
            </div>
          );
        })}
      </div>

      <h2>Community {entries ? `(${list.length})` : ""}</h2>
      <div style={{ display: "flex", gap: 8, marginBottom: 10 }}>
        <input type="search" placeholder="Search firmwares" value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} />
        <select value={sort} onChange={(e) => setSort((e.target as HTMLSelectElement).value as Sort)} aria-label="Sort by">
          <option value="recent">Recently updated</option><option value="stars">Most stars</option><option value="name">Name</option>
        </select>
      </div>
      {err && <div class="banner err">Couldn't load the community catalog: {err}</div>}
      {!entries && !err && <div class="dim">Loading the community catalog…</div>}
      <div class="rows">
        {list.map((e) => {
          const pkg = packagesOf(e)[0];
          const direct = e.repo && hub.has(e.repo.toLowerCase());
          return (
            <div key={e.id}>
              <span class="row-main">
                <b>{entryTitle(e)}</b> <span class="small dim">{entryOwner(e)}</span>
                {e.description && <div class="small dim">{e.description}</div>}
                <div class="small faint">{e.stars ? `★ ${e.stars} · ` : ""}{e.license ? `${e.license} · ` : ""}{e.pushed ? `updated ${ago(Date.parse(e.pushed))}` : ""}
                  {e.repo && <> · <a href={`https://github.com/${e.repo}`} target="_blank" rel="noopener noreferrer">GitHub ↗</a></>}</div>
              </span>
              {have(e.repo) ? <span class="badge green">Have it</span> : pkg?.url && (
                <button class="btn" disabled={!!busy} title={direct ? "" : "Opens as a normal download"} onClick={() => get(e.repo, pkg.url!, { name: entryTitle(e), author: entryOwner(e), version: pkg.tag, summary: e.description })}>
                  {busy === e.repo ? "…" : direct ? "Get" : "Get ↗"}
                </button>
              )}
            </div>
          );
        })}
      </div>
      <p class="small faint">Community list from 2bbb/fm1-firmware-collection. One-click downloads come from The Firmware Hub; firmware hosted only on GitHub releases opens as a normal download (↗), which you then drop in above.</p>
    </>
  );
}
