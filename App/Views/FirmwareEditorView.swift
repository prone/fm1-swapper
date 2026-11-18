// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import SwiftData
import SwiftUI

/// Editors for work saved from each firmware, used without the FM-1: one entry per firmware (SLOOP for now; add a
/// row to `body` for each new one). Saving from the FM-1 stays on the Device tab, since it needs the FM-1.
struct FirmwareEditorView: View {
    @Query(filter: #Predicate<Backup> { $0.kindRaw == "song" }) private var sloopSongs: [Backup]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { SLOOPSongsView() } label: {
                        LabeledContent {
                            Text(sloopSongs.isEmpty ? "No songs yet" : "\(sloopSongs.count) song\(sloopSongs.count == 1 ? "" : "s")")
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("SLOOP")
                                    Text("Songs: the song order, sections A–D, notes, drums, bars").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "music.note.list") }
                        }
                    }
                } footer: {
                    Text("Edit what you've saved from each firmware, without the FM-1 connected. Send it back to the FM-1 when you're done.")
                }
            }
            .navigationTitle("Firmware Editor")
        }
    }
}

/// SLOOP's entry: every saved SLOOP song, to open in the song editor, load, duplicate, rename or delete.
struct SLOOPSongsView: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Backup> { $0.kindRaw == "song" }, sort: \Backup.date, order: .reverse) private var songs: [Backup]
    @State private var editing: Backup?
    @State private var loading: Backup?
    @State private var renaming: Backup?
    @State private var deleting: Backup?
    @State private var newName = ""
    @State private var search = ""
    @State private var sharing: ShareItems?
    @State private var importing = false
    @State private var message: String?

    private var shown: [Backup] {
        search.isEmpty ? songs : songs.filter { $0.label.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                if songs.isEmpty {
                    ContentUnavailableView("No SLOOP songs yet", systemImage: "music.note.list",
                                           description: Text("With SLOOP on the FM-1, use Device → SLOOP songs → Save the song on the FM-1. Saved songs appear here, and you can edit them without the FM-1."))
                }
                ForEach(shown) { s in
                    Button { editing = s } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.label).foregroundStyle(.primary)
                            Text(detail(s)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { deleting = s } label: { Label("Delete", systemImage: "trash") }
                        Button { newName = s.label; renaming = s } label: { Label("Rename", systemImage: "pencil") }
                        Button { loading = s } label: { Label("Load", systemImage: "arrow.up.to.line") }.tint(.blue)
                        Button { share(s) } label: { Label("Share", systemImage: "square.and.arrow.up") }.tint(.indigo)
                    }
                    .contextMenu {
                        Button { editing = s } label: { Label("Open and edit", systemImage: "pianokeys") }
                        DeviceIdleButton("Load onto the FM-1…", systemImage: "arrow.up.to.line") { loading = s }
                        Button { share(s) } label: { Label("Share song file…", systemImage: "square.and.arrow.up") }
                        Button { duplicate(s) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { newName = s.label; renaming = s } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = s } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } header: { Text("SLOOP songs") } footer: {
                if !songs.isEmpty {
                    Text("Tap a song to review and edit it: the song order, the loop and sections A–D, notes, drums and bars. Changes stay \(CloudSync.whereKept) until you send the song to the FM-1 (from the editor, or swipe → Load, with SLOOP stopped). To use a song on another iPhone or iPad, or in the web app, share it as a file (AirDrop, Files, iCloud Drive) and open it there.")
                }
            }
        }
        .navigationTitle("SLOOP songs")
        .toolbar {
            Button { importing = true } label: { Label("Import song files", systemImage: "square.and.arrow.down") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.fm1song, .json], allowsMultipleSelection: true) { r in
            guard case let .success(urls) = r else { return }
            message = urls.map(importOne).joined(separator: "\n\n")
        }
        .shareSheet($sharing)
        .messageAlert("Song files", $message)
        .searchable(text: $search, prompt: "Songs")
        .fullScreenCover(item: $editing) { SLOOPSongEditor(song: $0) }
        .alert("Rename", isPresented: $renaming.isPresent()) {
            TextField("Name", text: $newName)
            Button("Rename") { let n = newName.trimmingCharacters(in: .whitespaces); if let r = renaming, !n.isEmpty { r.label = n; try? context.save() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleting.map { "Delete \"\($0.label)\"?" } ?? "", isPresented: $deleting.isPresent(),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = deleting { context.delete(d); try? context.save() } }
        } message: { Text("The saved song is removed from the app. The FM-1 isn't changed.") }
        .confirmationDialog(loading.map { "Load \"\($0.label)\"?" } ?? "", isPresented: $loading.isPresent(),
                            titleVisibility: .visible) {
            Button("Save the FM-1's song, then load") { if let l = loading { Task { await device.loadSong(l, saveFirstAs: DeviceController.autoSongName(), context: context) } } }
            Button("Replace without saving", role: .destructive) { if let l = loading { Task { await device.loadSong(l) } } }
        } message: {
            Text("Needs the FM-1 connected with SLOOP. The loop, sections A–D and the song order on the FM-1 are replaced; save its song first to keep it (as “\(DeviceController.autoSongName())”, rename it later).")
        }
        .safeAreaInset(edge: .bottom) { LoadStatus() }
    }

    /// The row's second line, from stored fields only (decoding each song's payload per row is slow).
    private func detail(_ s: Backup) -> String {
        let used = ["A", "B", "C", "D"].filter { s.partsSummary.contains("Section \($0)") }
        return ([s.date.formatted(date: .abbreviated, time: .shortened), s.firmware?.name].compactMap { $0 }
                + [used.isEmpty ? "no sections" : "sections " + used.joined(separator: " ")]).joined(separator: " · ")
    }

    private func share(_ s: Backup) {
        do { sharing = ShareItems(files: [try SongFiles.file(s)]) } catch { message = error.localizedDescription }
    }

    private func importOne(_ url: URL) -> String {
        do {
            return try SongFiles.add(try readImport(url, maxBytes: ImportLimit.backup), fileName: url.lastPathComponent, context: context)
        } catch {
            return "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func duplicate(_ s: Backup) {
        guard let a = s.archive, let b = try? Backup.from(a, label: "\(s.label) copy", kind: "song") else { return }
        b.firmware = s.firmware
        b.date = Date()
        context.insert(b)
        try? context.save()
    }
}

/// What the FM-1 is doing, on its own: only this view redraws on each progress tick.
struct DeviceProgressLabel: View {
    @Environment(DeviceController.self) private var device
    var body: some View {
        if case let .working(title, detail, _) = device.phase {
            Label("\(title): \(detail)", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// A button that's off while the FM-1 is busy (reads the device itself, so the view around it doesn't redraw).
struct DeviceIdleButton: View {
    @Environment(DeviceController.self) private var device
    let title: String, systemImage: String, action: () -> Void
    init(_ title: String, systemImage: String, action: @escaping () -> Void) { self.title = title; self.systemImage = systemImage; self.action = action }
    var body: some View { Button(action: action) { Label(title, systemImage: systemImage) }.disabled(device.busy) }
}

/// The result of a song load, at the bottom of the songs list.
private struct LoadStatus: View {
    @Environment(DeviceController.self) private var device
    var body: some View {
        switch device.phase {
        case let .working(title, detail, _) where title == "Load song":
            Label(detail, systemImage: "hourglass").banner()
        case let .finished(title, detail) where title == "Load song":
            Label(detail, systemImage: "checkmark.circle").banner()
        case let .failed(title, detail) where title == "Load song":
            Label(detail, systemImage: "exclamationmark.triangle").foregroundStyle(.red).banner()
        default:
            EmptyView()
        }
    }
}

private extension View {
    func banner() -> some View {
        font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal).padding(.bottom, 6)
    }
}
