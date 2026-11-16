// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let fwsc = UTType(importedAs: "com.example.fm1swapper.fwsc", conformingTo: .data)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, name, added, rating, status, installs, author
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: "Recently installed"
        case .name: "Name"
        case .added: "Date added"
        case .rating: "Rating"
        case .status: "Status"
        case .installs: "Most installed"
        case .author: "Author"
        }
    }
    var symbol: String {
        switch self {
        case .recent: "clock"
        case .name: "textformat"
        case .added: "calendar.badge.plus"
        case .rating: "star"
        case .status: "checkmark.circle"
        case .installs: "number"
        case .author: "person"
        }
    }
    /// The natural direction: newest, highest and A→Z first.
    func ordered(_ a: Firmware, _ b: Firmware) -> Bool {
        let tie = a.name.localizedStandardCompare(b.name) == .orderedAscending
        switch self {
        case .recent:
            let x = a.lastInstalled ?? a.addedAt, y = b.lastInstalled ?? b.addedAt
            return x == y ? tie : x > y
        case .name: return tie
        case .added: return a.addedAt == b.addedAt ? tie : a.addedAt > b.addedAt
        case .rating: return a.rating == b.rating ? tie : a.rating > b.rating
        case .status:
            let order: [TryStatus] = [.keeper, .favorite, .tried, .notTried, .notForMe]
            let x = order.firstIndex(of: a.status) ?? 9, y = order.firstIndex(of: b.status) ?? 9
            return x == y ? tie : x < y
        case .installs:
            let x = a.installCount, y = b.installCount
            return x == y ? tie : x > y
        case .author:
            let c = a.author.localizedStandardCompare(b.author)
            return c == .orderedSame ? tie : (a.author.isEmpty ? false : b.author.isEmpty ? true : c == .orderedAscending)
        }
    }
}

struct LibraryView: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Query(sort: \Firmware.addedAt, order: .reverse) private var firmwares: [Firmware]
    @State private var filter: TryStatus?
    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("librarySortReversed") private var reversed = false
    @State private var search = ""
    @State private var importing = false
    #if DEBUG
    @State private var showCatalog = ProcessInfo.processInfo.environment["FM1_DEMO_CATALOG"] != nil // simulator testing
    #else
    @State private var showCatalog = false
    #endif
    @State private var showURL = false
    @State private var urlText = ""
    @State private var message: String?
    @State private var working = false

    var filtered: [Firmware] {
        firmwares.filter { f in
            (filter == nil || f.status == filter) &&
                (search.isEmpty || f.name.localizedCaseInsensitiveContains(search) || f.product.localizedCaseInsensitiveContains(search)
                    || f.author.localizedCaseInsensitiveContains(search) || f.summary.localizedCaseInsensitiveContains(search))
        }
        .sorted { reversed ? sort.ordered($1, $0) : sort.ordered($0, $1) }
    }

    var body: some View {
        NavigationStack {
            List {
                if firmwares.isEmpty {
                    ContentUnavailableView {
                        Label("No firmware yet", systemImage: "square.stack.3d.up.slash")
                    } description: {
                        Text("Browse firmware to download Felucca, FM1 Open, the official V15 and hundreds of community firmwares, or import a .fwsc file.")
                    } actions: {
                        Button("Browse firmware") { showCatalog = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                chip(nil, "All \(firmwares.count)")
                                ForEach(TryStatus.allCases) { s in
                                    let n = firmwares.filter { $0.status == s }.count
                                    if n > 0 { chip(s, "\(s.label) \(n)") }
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                    Section {
                        ForEach(filtered) { f in
                            NavigationLink(value: f) { FirmwareRow(firmware: f, installedIdentity: device.identity?.text) }
                        }
                        .onDelete { idx in
                            for i in idx { context.delete(filtered[i]) }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .task(id: firmwares.count) { await DescriptionFiller.fill(firmwares, context: context) }
            .navigationDestination(for: Firmware.self) { FirmwareDetailView(firmware: $0) }
            .searchable(text: $search, prompt: "Name, description, author")
            .toolbar {
                if working { ProgressView() }
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    Divider()
                    Toggle(isOn: $reversed) { Label("Reverse order", systemImage: "arrow.up.arrow.down") }
                } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                Menu {
                    Button { showCatalog = true } label: { Label("Browse firmware", systemImage: "globe") }
                    Button { importing = true } label: { Label("Import .fwsc file", systemImage: "doc.badge.plus") }
                    Button { showURL = true } label: { Label("Download from a link", systemImage: "link") }
                } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showCatalog) { CatalogView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.fwsc, .data], allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                var lines: [String] = []
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let r = try LibraryImport.add(try readImport(url, maxBytes: ImportLimit.firmware), fileName: url.lastPathComponent, context: context)
                        lines.append((r.isNew ? "Added " : "Already have ") + r.firmware.name + (r.warning.map { " — \($0)" } ?? ""))
                    } catch {
                        lines.append("\(url.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                    }
                }
                message = lines.joined(separator: "\n")
            }
            .alert("Download firmware", isPresented: $showURL) {
                TextField("https://…/firmware.fwsc", text: $urlText).textInputAutocapitalization(.never).keyboardType(.URL)
                Button("Download") { download() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("A direct link to a .fwsc file.") }
            .alert("Library", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    func chip(_ s: TryStatus?, _ title: String) -> some View {
        Button(title) { filter = s }
            .buttonStyle(.bordered)
            .tint(filter == s ? .accentColor : .secondary)
            .controlSize(.small)
    }

    func download() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else {
            message = "That is not a web link."
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                let data = try await Catalog.download(url)
                let r = try LibraryImport.add(data, fileName: url.lastPathComponent, sourceURL: url.absoluteString, context: context)
                message = (r.isNew ? "Added " : "Already have ") + r.firmware.name + (r.warning.map { "\n\n\($0)" } ?? "")
                urlText = ""
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
