// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import SwiftData
import SwiftUI

/// Reviews and edits a saved SLOOP song on the iPad: the song order (which section plays, for how many bars), the
/// loop and sections A–D (a piano roll per synth track, a grid for the drums), and bars copied, pasted, inserted or
/// taken out, within a section or from one section to another. Nothing reaches the FM-1 until "Send to FM-1".
struct SLOOPSongEditor: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let song: Backup

    @State private var doc: SLOOPSongDoc?
    @State private var saved: SLOOPSongDoc?
    @State private var loadError = ""
    @State private var undo: [SLOOPSongDoc] = []
    @State private var slot: SLOOPSongDoc.Slot = .loop
    @State private var track = 0
    @State private var bars: ClosedRange<Int>?
    @State private var allTracks = true
    @State private var clip: [Int: SLOOPClip] = [:]
    @State private var clipText = ""
    @State private var noteLength = 0
    @State private var octave: [Int: Int] = [:]
    @State private var sending = false
    @State private var closing = false
    @State private var copyName = ""
    @State private var namingCopy = false
    @State private var sharing: ShareItems?

    private var dirty: Bool { doc != saved }

    var body: some View {
        NavigationStack {
            Group {
                if let doc { editor(doc) } else { ContentUnavailableView("Can't open this song", systemImage: "music.note.list", description: Text(loadError)) }
            }
            .navigationTitle(song.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if dirty { closing = true } else { dismiss() } }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { if let last = undo.popLast() { doc = last } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(undo.isEmpty)
                    Menu {
                        Button { save() } label: { Label("Save changes", systemImage: "square.and.arrow.down") }.disabled(!dirty)
                        Button { copyName = "\(song.label) (edit)"; namingCopy = true } label: { Label("Save as a new song…", systemImage: "plus.square.on.square") }
                        Button {
                            if let d = doc, let f = try? SongFiles.file(d.archive(), name: song.label) { sharing = ShareItems(files: [f]) }
                        } label: { Label("Share song file…", systemImage: "square.and.arrow.up") }
                        Divider()
                        Button { sending = true } label: { Label("Send to FM-1…", systemImage: "arrow.up.to.line") }.disabled(device.busy)
                    } label: { Label("Song", systemImage: "ellipsis.circle") }
                    .disabled(doc == nil)
                }
            }
            .confirmationDialog("Save your changes?", isPresented: $closing, titleVisibility: .visible) {
                Button("Save changes") { save(); dismiss() }
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .confirmationDialog("Send \"\(song.label)\" to the FM-1?", isPresented: $sending, titleVisibility: .visible) {
                Button("Save and replace the song on the FM-1", role: .destructive) {
                    save()
                    Task { await device.loadSong(song) }
                }
            } message: {
                Text("Saves your changes, then replaces the loop, sections A–D and the song order on the FM-1 (stop playback first). Save the FM-1's current song first if you want to keep it."
                     + (doc?.emptyEntries.isEmpty == false ? " Some song-order entries point at empty sections: SLOOP won't play song mode until they're filled." : ""))
            }
            .alert("Save as a new song", isPresented: $namingCopy) {
                TextField("Name", text: $copyName)
                Button("Save") { saveCopy() }
                Button("Cancel", role: .cancel) {}
            }
            .shareSheet($sharing)
            .task { open() }
        }
    }

    // MARK: Layout

    @ViewBuilder private func editor(_ doc: SLOOPSongDoc) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if device.busy, case let .working(title, detail, _) = device.phase {
                    Label("\(title): \(detail)", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
                }
                orderCard(doc)
                Picker("Pattern", selection: $slot) {
                    ForEach(SLOOPSongDoc.Slot.allCases) { s in Text(doc.isEmpty(s) ? "\(s.name) (empty)" : s.name).tag(s) }
                }
                .pickerStyle(.segmented)
                .onChange(of: slot) { bars = nil }
                if doc.locked.contains(slot) {
                    note("This one was saved by an older SLOOP (before 2.6). It's kept as it is and can't be edited here.")
                } else if let p = doc.patterns[slot] {
                    patternCard(p)
                } else {
                    emptySlot(doc)
                }
            }
            .padding()
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Song order

    @ViewBuilder private func orderCard(_ doc: SLOOPSongDoc) -> some View {
        GroupBox {
            if let order = doc.order {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(order.entries.enumerated()), id: \.offset) { i, e in
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                            Picker("Section", selection: Binding(get: { e.section }, set: { v in edit { $0.order?.entries[i].section = v } })) {
                                ForEach(0..<4, id: \.self) { k in Text(["A", "B", "C", "D"][k] + (doc.isEmpty(.section(k)) ? " (empty)" : "")).tag(k) }
                            }
                            .labelsHidden()
                            .frame(minWidth: 110, alignment: .leading)
                            Stepper("\(e.bars) bar\(e.bars == 1 ? "" : "s")", value: Binding(get: { e.bars }, set: { v in edit { $0.order?.entries[i].bars = v } }), in: 1...64)
                                .font(.callout.monospacedDigit())
                                .fixedSize()
                            if doc.isEmpty(.section(e.section)) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            Spacer()
                            Button { edit { $0.order?.entries.swapAt(i, i - 1) } } label: { Image(systemName: "chevron.up") }
                                .disabled(i == 0)
                            Button { edit { $0.order?.entries.swapAt(i, i + 1) } } label: { Image(systemName: "chevron.down") }
                                .disabled(i == order.entries.count - 1)
                            Button(role: .destructive) { edit { $0.order?.entries.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                                .disabled(order.entries.count == 1)
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Button {
                            let k = slot.sectionIndex ?? 0
                            edit { $0.order?.entries.append(.init(section: k, bars: $0.patterns[.section(k)]?.bars ?? 4)) }
                        } label: { Label("Add \(["A", "B", "C", "D"][slot.sectionIndex ?? 0])", systemImage: "plus.circle") }
                        .disabled(order.entries.count >= SLOOPOrder.maxEntries)
                        Spacer()
                        Toggle("Loop the song", isOn: Binding(get: { order.loops }, set: { v in edit { $0.order?.loops = v } })).fixedSize()
                    }
                    .buttonStyle(.borderless)
                    note(summary(doc, order))
                }
            } else {
                note("This song has no song order (SLOOP 2.5 or later keeps one).")
            }
        } label: { Label("Song order", systemImage: "list.number") }
    }

    private func summary(_ doc: SLOOPSongDoc, _ o: SLOOPOrder) -> String {
        let bpm = doc.patterns[.loop]?.bpm ?? 120
        let secs = Int((Double(o.totalBars) * 4 * 60 / Double(max(40, bpm))).rounded())
        var s = "\(o.entries.count) of 16 entries · \(o.totalBars) bars · \(secs / 60):\(String(format: "%02d", secs % 60)) at \(bpm) BPM\(o.loops ? ", then again" : ""). "
        s += "Each entry plays its section for that many bars, repeating the section's loop. On the FM-1, play it in song mode (SONG screen, or SAVE + key 13)."
        if !doc.emptyEntries.isEmpty { s += " ⚠︎ Entries \(doc.emptyEntries.map { "\($0 + 1)" }.joined(separator: ", ")) point at empty sections." }
        return s
    }

    // MARK: A section

    @ViewBuilder private func emptySlot(_ doc: SLOOPSongDoc) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                note("Section \(slot.name) is empty. Start it as a copy of another pattern (sounds, notes and tempo), then change it.")
                HStack {
                    ForEach(SLOOPSongDoc.Slot.allCases.filter { $0 != slot && doc.patterns[$0] != nil }) { s in
                        Button("Copy \(s.name)") { edit { $0.copy(s, to: slot) } }.buttonStyle(.bordered)
                    }
                }
            }
        } label: { Text(slot == .loop ? "Loop" : "Section \(slot.name)") }
    }

    @ViewBuilder private func patternCard(_ p: SLOOPPattern) -> some View {
        let t = p[track: track]
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Track", selection: $track) {
                    ForEach(0..<4, id: \.self) { k in Text(k == SLOOPTrack.drumTrack ? "Drums" : "Track \(k + 1)").tag(k) }
                }
                .pickerStyle(.segmented)
                .onChange(of: track) { bars = nil }
                HStack(spacing: 16) {
                    Stepper("Length \(t.length) steps", value: Binding(get: { t.length }, set: { v in editTrack(track) { $0.length = v } }), in: 1...64)
                        .fixedSize()
                    Text("\(SLOOPTrack.divNames[t.div]) steps · \(formatBars(Double(t.length) / t.stepsPerBar)) bars").foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(SLOOPSongDoc.Slot.allCases.filter { $0 != slot }) { s in
                            Button("Copy \(slot.name) to \(s.name)\(doc?.isEmpty(s) == false ? " (replaces it)" : "")") { edit { $0.copy(slot, to: s) } }
                        }
                        if slot != .loop {
                            Divider()
                            Button("Erase section \(slot.name)", role: .destructive) { edit { $0.erase(slot) } }
                        }
                        Divider()
                        Button("Clear this track's notes", role: .destructive) { editTrack(track) { $0.clear() } }
                    } label: { Label("Section", systemImage: "square.on.square") }
                }
                .font(.callout)
                barBar(p, t)
                if t.isDrum { DrumGrid(track: t, selection: stepRange(t)) { lane, i in editTrack(track) { $0.toggleDrum(lane: lane, at: i) } } }
                else { roll(t) }
                note(t.isDrum
                     ? "Tap a square to add or remove a hit. Steps past the length are dimmed: SLOOP doesn't play them."
                     : "Tap to add a note of the chosen length (notes on the same step make a chord, 4 at most); tap a note to remove it. Steps past the length are dimmed.")
            }
        } label: { Text(slot == .loop ? "Loop in progress · \(p.bpm) BPM" : "Section \(slot.name) · \(p.bars) bar\(p.bars == 1 ? "" : "s") · \(p.bpm) BPM") }
    }

    private func formatBars(_ b: Double) -> String { b == b.rounded() ? "\(Int(b))" : String(format: "%.2g", b) }

    // MARK: Bars

    @ViewBuilder private func barBar(_ p: SLOOPPattern, _ t: SLOOPTrack) -> some View {
        if let per = t.barSteps {
            let shown = (SLOOPTrack.maxSteps + per - 1) / per, inLen = (t.length + per - 1) / per
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Bars").font(.caption).foregroundStyle(.secondary)
                        ForEach(0..<shown, id: \.self) { b in
                            Button { tapBar(b) } label: {
                                Text("\(b + 1)").font(.callout.monospacedDigit()).frame(minWidth: 30)
                            }
                            .buttonStyle(.bordered)
                            .tint(bars?.contains(b) == true ? .accentColor : (b < inLen ? .primary : .secondary))
                            .opacity(b < inLen ? 1 : 0.5)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Picker("Edit", selection: $allTracks) {
                        Text("All 4 tracks").tag(true)
                        Text("This track").tag(false)
                    }
                    .pickerStyle(.segmented).fixedSize()
                    if let r = bars {
                        Button("Copy") { copyBars(r) }
                        Button("Duplicate") { copyBars(r); pasteBars(at: r.upperBound + 1, insert: true) }
                        Button("Clear") { forTracks { t in t.barSteps.map { t.clear(($0 * r.lowerBound)..<($0 * (r.upperBound + 1))) } } }
                        Button("Delete", role: .destructive) { forTracks { t in t.barSteps.map { t.delete(($0 * r.lowerBound)..<($0 * (r.upperBound + 1))) } }; bars = nil }
                        if !clip.isEmpty {
                            Button("Paste over") { pasteBars(at: r.lowerBound, insert: false) }
                            Button("Insert before") { pasteBars(at: r.lowerBound, insert: true) }
                        }
                    } else {
                        Button("Add an empty bar") { forTracks { t in t.barSteps.map { t.extend(by: $0) } } }
                            .disabled(t.length >= SLOOPTrack.maxSteps)
                        if !clip.isEmpty { Button("Paste at the end") { pasteBars(at: nil, insert: false) } }
                    }
                }
                .buttonStyle(.bordered)
                .font(.callout)
                note((bars == nil ? "Tap a bar to select it, tap another to select a run of bars. " : "")
                     + (clipText.isEmpty ? "" : "Copied: \(clipText). ")
                     + "A pattern holds 64 steps at most (4 bars of 1/16): make the song longer with more sections in the song order.")
            }
        } else {
            note("Each step of this track is longer than a bar, so bar edits don't apply to it.")
        }
    }

    private func tapBar(_ b: Int) {
        if let r = bars, r == b...b { bars = nil } else if let r = bars, r.count == 1 { bars = min(r.lowerBound, b)...max(r.upperBound, b) } else { bars = b...b }
    }

    private func stepRange(_ t: SLOOPTrack) -> Range<Int>? {
        guard let r = bars, let per = t.barSteps else { return nil }
        return (per * r.lowerBound)..<min(SLOOPTrack.maxSteps, per * (r.upperBound + 1))
    }

    private var tracks: [Int] { allTracks ? [0, 1, 2, 3] : [track] }

    private func forTracks(_ f: (inout SLOOPTrack) -> Void) {
        edit { d in for k in tracks { d.patterns[slot]?[track: k].modify(f) } }
    }

    private func copyBars(_ r: ClosedRange<Int>) {
        guard let p = doc?.patterns[slot] else { return }
        var c: [Int: SLOOPClip] = [:]
        for k in tracks { let t = p[track: k]; if let per = t.barSteps { c[k] = t.copy((per * r.lowerBound)..<(per * (r.upperBound + 1))) } }
        clip = c
        clipText = "\(slot == .loop ? "the loop" : "section \(slot.name)"), bar\(r.count == 1 ? "" : "s") \(r.lowerBound + 1)\(r.count == 1 ? "" : "–\(r.upperBound + 1)"), \(c.count == 1 ? (track == SLOOPTrack.drumTrack ? "drums" : "track \(track + 1)") : "all tracks")"
    }

    /// Pastes the copied bars at bar `at` (nil: after each track's last step). A clip of one track pastes into the
    /// track shown; a clip of all four goes back to the same tracks.
    private func pasteBars(at bar: Int?, insert: Bool) {
        let one = clip.count == 1 ? clip.first?.value : nil
        edit { d in
            for k in (one == nil ? Array(clip.keys) : [track]) {
                guard let c = one ?? clip[k] else { continue }
                d.patterns[slot]?[track: k].modify { t in
                    guard let per = t.barSteps else { return }
                    let at = bar.map { $0 * per } ?? t.length
                    if insert { t.insert(c, at: min(at, t.length)) } else { t.paste(c, at: at) }
                }
            }
        }
    }

    // MARK: Piano roll

    private static let lengths: [(String, Double)] = [("1/16", 1 / 16), ("1/8", 1 / 8), ("1/4", 1 / 4), ("1/2", 1 / 2), ("1 bar", 1)]

    @ViewBuilder private func roll(_ t: SLOOPTrack) -> some View {
        let key = trackKey
        let low = octave[key] ?? defaultLow(t)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Note length", selection: $noteLength) {
                    ForEach(Self.lengths.indices, id: \.self) { Text(Self.lengths[$0].0).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Button { octave[key] = max(0, low - 12) } label: { Image(systemName: "chevron.down") }
                Text("\(PianoRoll.name(UInt8(low)))–\(PianoRoll.name(UInt8(min(127, low + 24))))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { octave[key] = min(103, low + 12) } label: { Image(systemName: "chevron.up") }
            }
            .buttonStyle(.bordered)
            PianoRoll(track: t, low: low, selection: stepRange(t)) { pitch, i in
                let steps = max(1, Int((t.stepsPerBar * Self.lengths[noteLength].1).rounded()))
                editTrack(track) { tr in
                    if let o = tr.owner(i), tr.step(o).notes.contains(pitch) { tr.remove(pitch, at: o) } else { tr.place(pitch, at: i, steps: steps) }
                }
            }
        }
    }

    private var trackKey: Int { (SLOOPSongDoc.Slot.allCases.firstIndex(of: slot) ?? 0) * 4 + track }

    private func defaultLow(_ t: SLOOPTrack) -> Int {
        guard let lowest = t.chords.flatMap(\.notes).min() else { return 48 }
        return min(103, Int(lowest) / 12 * 12)
    }

    // MARK: Changes

    private func edit(_ f: (inout SLOOPSongDoc) -> Void) {
        guard var d = doc else { return }
        f(&d)
        guard d != doc else { return }
        undo.append(doc!)
        if undo.count > 100 { undo.removeFirst() }
        doc = d
    }

    private func editTrack(_ k: Int, _ f: (inout SLOOPTrack) -> Void) {
        edit { d in d.patterns[slot]?[track: k].modify(f) }
    }

    private func open() {
        guard doc == nil else { return }
        do {
            guard let a = song.archive else { throw FM1Error.badPackage("The saved song can't be read.") }
            let d = try SLOOPSongDoc(a)
            doc = d; saved = d
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() {
        guard let d = doc, dirty else { return }
        do {
            try song.replace(with: d.archive())
            try context.save()
            saved = d
        } catch { loadError = error.localizedDescription }
    }

    private func saveCopy() {
        guard let d = doc else { return }
        let n = copyName.trimmingCharacters(in: .whitespaces)
        guard let b = try? Backup.from(d.archive(), label: n.isEmpty ? "\(song.label) (edit)" : n, kind: "song") else { return }
        b.firmware = song.firmware
        context.insert(b)
        try? context.save()
    }
}

private extension SLOOPTrack {
    mutating func modify(_ f: (inout SLOOPTrack) -> Void) { f(&self) }
}

// MARK: Grids

/// The notes of a synth track over two octaves: rows are pitches (high at the top), columns the 64 steps.
struct PianoRoll: View {
    let track: SLOOPTrack
    let low: Int
    let selection: Range<Int>?
    let tap: (UInt8, Int) -> Void
    static let cell = CGSize(width: 24, height: 18), label: CGFloat = 40
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func name(_ p: UInt8) -> String { "\(names[Int(p) % 12])\(Int(p) / 12 - 1)" }
    private var rows: Int { min(25, 128 - low) }

    var body: some View {
        let w = Self.label + Self.cell.width * 64, h = Self.cell.height * CGFloat(rows)
        ScrollView(.horizontal) {
            Canvas { ctx, _ in draw(ctx) }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    guard p.x >= Self.label else { return }
                    let i = Int((p.x - Self.label) / Self.cell.width), r = Int(p.y / Self.cell.height)
                    guard i < track.length, (0..<rows).contains(r) else { return }
                    tap(UInt8(low + rows - 1 - r), i)
                }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func draw(_ ctx: GraphicsContext) {
        let c = Self.cell, per = track.barSteps ?? 16
        for r in 0..<rows {
            let pitch = low + rows - 1 - r, y = CGFloat(r) * c.height
            let black = [1, 3, 6, 8, 10].contains(pitch % 12)
            ctx.fill(Path(CGRect(x: Self.label, y: y, width: c.width * 64, height: c.height)), with: .color(black ? .primary.opacity(0.06) : .clear))
            if pitch % 12 == 0 || r == rows - 1 {
                ctx.draw(Text(Self.name(UInt8(pitch))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: 4, y: y + c.height / 2), anchor: .leading)
            }
        }
        if let s = selection {
            ctx.fill(Path(CGRect(x: Self.label + CGFloat(s.lowerBound) * c.width, y: 0, width: CGFloat(s.count) * c.width, height: c.height * CGFloat(rows))), with: .color(.accentColor.opacity(0.12)))
        }
        for i in 0...64 {
            let x = Self.label + CGFloat(i) * c.width
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: c.height * CGFloat(rows))) },
                       with: .color(.primary.opacity(i % per == 0 ? 0.35 : 0.08)), lineWidth: i % per == 0 ? 1.5 : 0.5)
        }
        for ch in track.chords {
            for n in ch.notes where Int(n) >= low && Int(n) < low + rows {
                let y = CGFloat(low + rows - 1 - Int(n)) * c.height
                let rect = CGRect(x: Self.label + CGFloat(ch.at) * c.width + 1, y: y + 2, width: CGFloat(ch.length) * c.width - 2, height: c.height - 4)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.accentColor))
            }
        }
        if track.length < 64 {
            ctx.fill(Path(CGRect(x: Self.label + CGFloat(track.length) * c.width, y: 0, width: CGFloat(64 - track.length) * c.width, height: c.height * CGFloat(rows))),
                     with: .color(Color(.systemBackground).opacity(0.6)))
        }
    }
}

/// The drum track: 16 lanes by 64 steps.
struct DrumGrid: View {
    let track: SLOOPTrack
    let selection: Range<Int>?
    let tap: (Int, Int) -> Void
    static let cell = CGSize(width: 24, height: 20), label: CGFloat = 76

    var body: some View {
        ScrollView(.horizontal) {
            Canvas { ctx, _ in draw(ctx) }
                .frame(width: Self.label + Self.cell.width * 64, height: Self.cell.height * 16)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    guard p.x >= Self.label else { return }
                    let i = Int((p.x - Self.label) / Self.cell.width), lane = Int(p.y / Self.cell.height)
                    guard i < track.length, (0..<16).contains(lane) else { return }
                    tap(lane, i)
                }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func draw(_ ctx: GraphicsContext) {
        let c = Self.cell, per = track.barSteps ?? 16
        if let s = selection {
            ctx.fill(Path(CGRect(x: Self.label + CGFloat(s.lowerBound) * c.width, y: 0, width: CGFloat(s.count) * c.width, height: c.height * 16)), with: .color(.accentColor.opacity(0.12)))
        }
        for lane in 0..<16 {
            let y = CGFloat(lane) * c.height
            ctx.draw(Text(SLOOPTrack.drumLanes[lane]).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 4, y: y + c.height / 2), anchor: .leading)
            for i in 0..<64 {
                let r = CGRect(x: Self.label + CGFloat(i) * c.width + 2, y: y + 2, width: c.width - 4, height: c.height - 4)
                let on = track.step(i).drum(lane)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3),
                         with: .color(on ? .accentColor : .primary.opacity((i / per) % 2 == 0 ? 0.08 : 0.04)))
            }
        }
        if track.length < 64 {
            ctx.fill(Path(CGRect(x: Self.label + CGFloat(track.length) * c.width, y: 0, width: CGFloat(64 - track.length) * c.width, height: c.height * 16)),
                     with: .color(Color(.systemBackground).opacity(0.6)))
        }
    }
}
