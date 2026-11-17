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
                            Button { loading = s } label: { Label("Load onto the FM-1…", systemImage: "arrow.up.to.line") }.disabled(device.busy)
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
            .alert("Song files", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .searchable(text: $search, prompt: "Songs")
            .fullScreenCover(item: $editing) { SLOOPSongEditor(song: $0) }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let r = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty { r.label = newName; try? context.save() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleting.map { "Delete \"\($0.label)\"?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let d = deleting { context.delete(d); try? context.save() } }
            } message: { Text("The saved song is removed from the app. The FM-1 isn't changed.") }
            .confirmationDialog(loading.map { "Load \"\($0.label)\"?" } ?? "", isPresented: Binding(get: { loading != nil }, set: { if !$0 { loading = nil } }),
                                titleVisibility: .visible) {
                Button("Replace the song on the FM-1", role: .destructive) { if let l = loading { Task { await device.loadSong(l) } } }
            } message: {
                Text("Needs the FM-1 connected with SLOOP, stopped. The loop, sections A–D and the song order on the FM-1 are replaced: save its current song first (Device tab) if you want to keep it.")
            }
            .safeAreaInset(edge: .bottom) { status }
    }

    /// The result of a load, shown here too so it isn't only on the Device tab.
    @ViewBuilder private var status: some View {
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

    private func detail(_ s: Backup) -> String {
        var parts = [s.date.formatted(date: .abbreviated, time: .shortened)]
        if let fw = s.firmware?.name { parts.append(fw) }
        if let a = s.archive {
            let used = ["2": "A", "3": "B", "4": "C", "5": "D"].filter { a.part($0.key).map { !$0.data.isEmpty } ?? false }.values.sorted()
            parts.append(used.isEmpty ? "no sections" : "sections " + used.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }

    private func share(_ s: Backup) {
        do { sharing = ShareItems(files: [try SongFiles.file(s)]) } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func importOne(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try SongFiles.add(try readImport(url, maxBytes: ImportLimit.backup), fileName: url.lastPathComponent, context: context)
        } catch {
            return "\(url.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func duplicate(_ s: Backup) {
        guard let a = s.archive, let b = try? Backup.from(a, label: "\(s.label) copy", kind: "song") else { return }
        b.firmware = s.firmware
        context.insert(b)
        try? context.save()
    }
}

private extension View {
    func banner() -> some View {
        font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal).padding(.bottom, 6)
    }
}
