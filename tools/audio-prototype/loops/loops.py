# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Repetition in a song: every bar described (drum attacks per 16th, bass and chord pitch classes per beat), bars
# compared with each other, the pattern length of each part (1, 2 or 4 bars), where 4-bar phrases start, the song's
# distinct 4-bar loops, and each loop's drums from all its repeats (the consensus).
import sys, os, json, numpy as np, librosa
sys.path.insert(0, sys.argv[1]); from a2s import Analysis
SR = 22050; L = {0: "kick", 2: "snare", 4: "hat", 5: "open hat"}

def analyse(path):
    y, _ = librosa.load(path, sr=SR, mono=True); a = Analysis(y, SR)
    b = a.beats; steps = np.concatenate([np.linspace(t0, t1, 4, endpoint=False) for t0, t1 in zip(b[:-1], b[1:])])
    R, tone, ring = a.rises(steps)
    hits = a.drums(steps); o = a.bar_start(hits)                     # (bar 1 from the kicks and snares, song-wide)
    steps, tone, ring = steps[o:], tone[o:], ring[o:]; R = {k: v[o:] for k, v in R.items()}
    nb = len(steps) // 16
    harm, _ = librosa.effects.hpss(y)
    hop = 512; fr = lambda t: np.clip(np.round(np.asarray(t) * SR / hop).astype(int), 0, None)
    chroma = librosa.feature.chroma_cqt(y=harm, sr=SR, hop_length=hop)
    C = np.abs(librosa.cqt(harm, sr=SR, hop_length=hop, fmin=librosa.note_to_hz("C1"), n_bins=36))
    bass = np.stack([C[i::12].sum(0) for i in range(12)])           # (C1-B3 folded to pitch classes)
    def per_beat(X, bar):
        out = []
        for q in range(4):
            i0, i1 = fr(steps[bar * 16 + q * 4]), fr(steps[min(len(steps) - 1, bar * 16 + q * 4 + 3)]) + 1
            v = X[:, i0:min(i1, X.shape[1])].mean(1) if i1 > i0 else np.zeros(12); out.append(v / (np.linalg.norm(v) + 1e-9))
        return np.concatenate(out)
    F = {"drums": np.array([np.concatenate([np.clip(R[k][i * 16:(i + 1) * 16], 0, None) for k in ("low", "mid", "high")]) for i in range(nb)]),
         "bass": np.array([per_beat(bass, i) for i in range(nb)]), "chords": np.array([per_beat(chroma, i) for i in range(nb)])}
    for k in F: F[k] = F[k] / (np.linalg.norm(F[k], axis=1, keepdims=True) + 1e-9)
    loud = np.array([np.abs(y[int(steps[i * 16] * SR):int(steps[min(len(steps) - 1, i * 16 + 15)] * SR)]).mean() for i in range(nb)])
    return dict(y=y, a=a, steps=steps, R=R, tone=tone, ring=ring, F=F, nb=nb, loud=loud / loud.max())

def period(F, live):
    """The smallest of 1, 2, 4 bars at which the part repeats about as well as at its best lag."""
    sc = {}
    for lag in (1, 2, 4, 8):
        i = np.array([b for b in range(len(F) - lag) if live[b] and live[b + lag]])
        sc[lag] = float((F[i] * F[i + lag]).sum(1).mean()) if len(i) else 0
    best = max(sc.values()); return next(l for l in (1, 2, 4, 8) if sc[l] >= best - 0.03), sc

def song(path):
    d = analyse(path); F, nb = d["F"], d["nb"]; live = d["loud"] > 0.15
    per = {k: period(F[k], live) for k in F}
    allF = np.concatenate([F[k] for k in F], 1) / np.sqrt(len(F))
    # phrases: 4 bars, starting where the music changes most (the bar phase whose boundaries are the most novel)
    nov = np.array([0] + [1 - float(allF[b - 1] @ allF[b]) for b in range(1, nb)])
    phase = max(range(4), key=lambda p: np.sort(nov[p::4])[-max(1, nb // 16):].mean())
    starts = [b for b in range(phase, nb - 3, 4)]
    W = np.array([allF[s:s + 4].ravel() / 2 for s in starts])
    # distinct loops: phrases grouped by similarity (each joins the first earlier group it matches)
    groups, label = [], []
    for i in range(len(starts)):
        g = next((j for j, m in enumerate(groups) if float(W[i] @ W[m[0]]) >= 0.85), None)
        if g is None: groups.append([i]); g = len(groups) - 1
        else: groups[g].append(i)
        label.append(g)
    return d, per, phase, starts, groups, label

def consensus(d, occ, drum_period):
    """A loop's drums from all its repeats: each 16th's attack per band, the median over the repeats (and over the
    bars a shorter drum pattern repeats in), then the same rules as one section's."""
    R, tone, ring = d["R"], d["tone"], d["ring"]; ps = drum_period * 16
    idx = lambda pos: [s * 16 + q for s in occ for q in range(pos % ps, 64, ps)]
    M = {k: np.array([np.median(R[k][idx(p)]) for p in range(64)]) for k in R}
    T = np.array([np.median(tone[idx(p)]) for p in range(64)]); G = np.array([np.median(ring[idx(p)]) for p in range(64)])
    out = []
    for n in range(64):
        if M["low"][n] >= 6 and M["low"][n] >= M["mid"][n] - 2 and T[n] < 12: out.append((n, 0))
        sn = M["mid"][n] >= 7.5 and M["mid"][n] - M["low"][n] >= 2.5
        if sn: out.append((n, 2))
        if M["high"][n] >= 6 and (not sn or M["high"][n] - M["mid"][n] >= 3.5): out.append((n, 5 if G[n] > 0.15 else 4))
    return out

def grid(h):
    H = set(h); return "\n".join(f"      {L[l]:8s} " + " ".join("".join("x" if (b * 16 + s, l) in H else "." for s in range(16)) for b in range(4)) for l in L)

if __name__ == "__main__":
    for path in sys.argv[2:]:
        d, per, phase, starts, groups, label = song(path); st = d["steps"]
        print(f"\n== {os.path.basename(path)}: {d['a'].bpm:.1f} BPM, {d['nb']} bars; phrases start on bar {phase + 1} of 4")
        print("   pattern length (bars): " + ", ".join(f"{k} {p} (repeat at 1/2/4/8 bars: " + "/".join(f"{v:.2f}" for v in sc.values()) + ")" for k, (p, sc) in per.items()))
        print("   phrases: " + "".join(chr(65 + g) if g < 26 else "?" for g in label))
        for g, occ in sorted(enumerate(groups), key=lambda x: -len(x[1]))[:4]:
            s = [starts[i] for i in occ]; t = st[s[0] * 16]
            print(f"   loop {chr(65 + g)}: {len(occ)}x, first at {int(t) // 60}:{t % 60:04.1f}")
            print(grid(consensus(d, s, per['drums'][0])))

def refine(d, starts, groups, changes=(), gain=0.04):
    """Per loop: its own phrase start, and the repeat to take it from. A loop shouldn't cross a point where the song
    changes (an instrument comes in, a new section): the start moves by up to 3 bars to cross the fewest; otherwise
    it moves by half a phrase (2 bars) only when its end then leads into its start clearly better. The repeat used
    is the most typical of those at full volume that cross no change."""
    F = d["F"]; nb = d["nb"]; allF = np.concatenate([F[k] for k in F], 1) / np.sqrt(len(F)); S = allF @ allF.T
    # changes: bars a new sound starts at; `inside`: bars it starts part way into (a lead-in: the loop can't hold them)
    inside = set(changes[1]) if isinstance(changes, tuple) else set()
    changes = set(changes[0]) if isinstance(changes, tuple) else set(changes)
    cross = lambda b: any(b < c < b + 4 for c in changes) or any(b <= c < b + 4 for c in inside)
    def seam(o): v = [S[b + 4, b] for b in o if b + 4 < nb] + [S[b - 1, b + 3] for b in o if b >= 1]; return np.mean(v) if v else 0
    out = []
    for occ in groups:
        bars = [starts[i] for i in occ]
        ok = {sh: [b + sh for b in bars] for sh in (0, -2, 2, -1, 1, -3, 3) if all(0 <= b + sh and b + sh + 4 <= nb for b in bars)}
        # (a start that has a clean full-volume repeat is fine: the loop is played from that one)
        def clean(o):
            loud = np.array([d["loud"][b:b + 4].mean() for b in o]); return any(l >= 0.85 * loud.max() and not cross(b) for b, l in zip(o, loud))
        n = {sh: 0 if clean(o) else 1 for sh, o in ok.items()}; least = min(n.values())
        cands = [sh for sh in ok if n[sh] == least]
        if 0 in cands:
            best = max((sh for sh in cands if sh in (-2, 2) and seam(ok[sh]) >= seam(ok[0]) + gain), key=lambda sh: seam(ok[sh]), default=0)
        else:
            best = max(cands, key=lambda sh: (seam(ok[sh]), -abs(sh)))
        bars = ok[best]
        loud = np.array([d["loud"][b:b + 4].mean() for b in bars])
        pool = [b for b, l in zip(bars, loud) if l >= 0.85 * loud.max() and not cross(b)] or [b for b, l in zip(bars, loud) if l >= 0.85 * loud.max()]
        W = {b: allF[b:b + 4].ravel() for b in bars}
        rep = max(pool, key=lambda b: sum(float(W[b] @ W[c]) for c in bars))
        out.append({"bars": bars, "rep": rep, "shift": best, "crosses": cross(rep)})
    return out
