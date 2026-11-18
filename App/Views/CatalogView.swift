// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import SwiftData
import SwiftUI

struct CatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query private var firmwares: [Firmware]
    @State private var community: [CatalogEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @AppStorage("catalogSort") private var sort: CatalogSort = .updated
    @State private var kind: String?
    @State private var newChipOnly = UserDefaults.standard.string(forKey: "myFlashChip") == MyFlashChip.newer.rawValue
    private var hub: FirmwareHub { .shared }

    /// Community firmware that isn't in The Firmware Hub's list (unchecked, no chip information).
    var results: [CatalogEntry] {
        let sorted = sort.apply(community.filter { e in e.repo.map { hub.byRepo[$0.lowercased()] == nil } ?? true })
        guard !search.isEmpty else { return sorted }
        return sorted.filter { e in
            [e.repo, e.description].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var hubResults: [HubFirmware] {
        let l = hub.list.filter { f in
            !f.linkOnly && (kind.map { f.kind.contains($0) } ?? true) && (!newChipOnly || f.chip != .olderOnly)
                && (search.isEmpty || [f.name, f.author, f.what].contains { $0.localizedCaseInsensitiveContains(search) })
        }
        return sort.apply(l)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Sort", selection: $sort) {
                        ForEach(CatalogSort.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                }
                if search.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Catalog.featured) { f in
                                    NavigationLink { FeaturedDetail(item: f) } label: { FeaturedCard(item: f, have: firmwares.contains { $0.name.localizedCaseInsensitiveContains(f.name) }) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    } header: { Text("Featured").padding(.leading, 4) }
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            kindChip(nil, "All")
                            ForEach(FirmwareHub.kinds, id: \.0) { kindChip($0.0, $0.1) }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    Toggle("Only firmware that works on newer FM-1s", isOn: $newChipOnly)
                    if !hub.loaded { HStack { ProgressView(); Text("Loading The Firmware Hub's list…").foregroundStyle(.secondary) } }
                    ForEach(hubResults) { f in
                        NavigationLink { HubDetail(entry: f) } label: { HubRow(entry: f, have: firmwares.contains { $0.sha256 == f.sha256 }) }
                    }
                } header: {
                    Text("All firmware (\(hubResults.count)) · \(sort.label.lowercased())")
                } footer: {
                    Text("\(FirmwareHub.attribution) Downloads are checked against the SHA-256 the hub publishes. Community firmware is unofficial: you install it at your own risk.")
                }
                Section {
                    if loading { HStack { ProgressView(); Text("Loading the GitHub list…").foregroundStyle(.secondary) } }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    ForEach(results) { e in
                        NavigationLink { CommunityDetail(entry: e) } label: { CommunityRow(entry: e) }
                    }
                } header: {
                    Text("More on GitHub (\(results.count))")
                } footer: {
                    Text("Not in The Firmware Hub's list, so not checked and with no flash chip information. From github.com/2bbb/fm1-firmware-collection. Packages for other devices (SMK-37, Pocket amps) are refused at install time.")
                }
            }
            .navigationTitle("Get firmware")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search \(hub.list.count + results.count) firmwares")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await hub.load() }
            .task { await load() }
            .refreshable { await load() }
        }
        .presentationSizing(.page)
    }

    func kindChip(_ k: String?, _ label: String) -> some View {
        Button(label) { kind = (kind == k ? nil : k) }
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(kind == k ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(kind == k ? .white : .primary)
            .buttonStyle(.plain)
    }

    func load() async {
        loading = true
        defer { loading = false }
        do { community = try await Catalog.loadCommunity(); error = nil } catch { self.error = "Could not load the catalog: \(error.localizedDescription)" }
    }
}

struct FeaturedCard: View {
    let item: FeaturedFirmware
    let have: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if have { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
            }
            Text(item.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 180, height: 92, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CommunityRow: View {
    let entry: CatalogEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.title).font(.body.weight(.medium))
                Spacer()
                if let s = entry.stars, s > 0 { Label("\(s)", systemImage: "star").font(.caption).foregroundStyle(.secondary) }
            }
            if let d = entry.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Text([entry.owner, entry.license, entry.pushedDate.map { "updated \($0.formatted(.relative(presentation: .named)))" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Download buttons shared by the catalog pages.
struct PackageDownloadRow: View {
    @Environment(\.modelContext) private var context
    @Query private var firmwares: [Firmware]
    let title: String
    let subtitle: String
    let url: URL
    let name: String
    let author: String
    let version: String
    let repo: String
    /// Refuse the download unless it has this SHA-256 (The Firmware Hub's published digest).
    var expectedSHA: String? = nil
    /// Refuse the download unless it is one of M-VAVE's official releases.
    var requireStock = false
    var summary: String = ""
    @State private var state: String?
    @State private var busy = false
    @State private var trying: Data?

    var have: Bool { firmwares.contains { $0.sourceURL == url.absoluteString && $0.hasPackage } }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(state ?? subtitle).font(.caption).foregroundStyle(state == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            if busy { ProgressView() } else {
                Button { Task { await tryIt() } } label: { Text("Try").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.bordered).controlSize(.small)
                if have { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else {
                    Button { Task { await get() } } label: { Image(systemName: "icloud.and.arrow.down").font(.title3) }
                        .buttonStyle(.borderless)
                }
            }
        }
        .fullScreenCover(isPresented: $trying.isPresent()) {
            if let d = trying { EmulatorScreen(title: name, package: d, fileName: "\(name.replacingOccurrences(of: "/", with: "-")).fwsc") }
        }
    }

    private func check(_ p: FirmwarePackage) throws {
        if let e = expectedSHA, p.sha256 != e {
            throw FM1Error.badPackage("The download doesn't match the checksum The Firmware Hub publishes, so it wasn't used.")
        }
        if requireStock, p.stock == nil {
            throw FM1Error.badPackage("The downloaded file isn't an official M-VAVE release (its checksum doesn't match), so it wasn't used.")
        }
    }

    /// Plays the package in the emulator without adding it to the library.
    func tryIt() async {
        if let f = firmwares.first(where: { $0.sourceURL == url.absoluteString }), let d = f.packageData { trying = d; return }
        busy = true
        defer { busy = false }
        do {
            let data = try await Catalog.download(url)
            try check(FirmwarePackage(data: data))
            trying = data
        } catch {
            state = error.localizedDescription
        }
    }

    func get() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await Catalog.download(url)
            try check(FirmwarePackage(data: data))
            let r = try LibraryImport.add(data, fileName: url.lastPathComponent, name: name, author: author, version: version,
                                          sourceURL: url.absoluteString, repo: repo, context: context)
            if r.isNew, r.firmware.summary.isEmpty, !summary.isEmpty { r.firmware.summary = summary }
            state = r.warning ?? (r.isNew ? (expectedSHA != nil ? "Added (checksum matches The Firmware Hub)" : "Added to your library") : "Already in your library")
        } catch {
            state = error.localizedDescription
        }
    }
}

struct CommunityDetail: View {
    @Environment(\.openURL) private var openURL
    let entry: CatalogEntry

    var body: some View {
        List {
            Section {
                if let d = entry.description { Text(d) }
                LabeledContent("Author", value: entry.owner)
                if let l = entry.license { LabeledContent("License", value: l) }
                if let f = entry.fork_of { LabeledContent("Fork of", value: f) }
                if let u = entry.url.flatMap(URL.init(string:)), isWebLink(u) { Button("Open on GitHub") { openURL(u) } }
            }
            Section("Packages") {
                ForEach(entry.packages, id: \.self) { r in
                    if let u = r.url.flatMap(URL.init(string:)) {
                        PackageDownloadRow(title: r.name ?? "package", subtitle: [r.tag, r.prerelease == true ? "pre-release" : nil,
                                                                                    r.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                                                                                    .compactMap { $0 }.joined(separator: " · "),
                                           url: u, name: "\(entry.title) \(r.tag ?? "")".trimmingCharacters(in: .whitespaces),
                                           author: entry.owner, version: r.tag ?? "", repo: entry.repo ?? "")
                    }
                }
            }
        }
        .navigationTitle(entry.title)
    }
}

struct FeaturedDetail: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    let item: FeaturedFirmware
    @State private var releases: [Catalog.GitHubRelease] = []
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text(item.blurb)
                LabeledContent("By", value: item.author)
                Text(item.howToGet).font(.footnote).foregroundStyle(.secondary)
                if let u = URL(string: item.website), isWebLink(u) { Button("Open website") { openURL(u) } }
            }
            if item.id == "official", let u = URL(string: Catalog.officialFWSC) {
                Section {
                    PackageDownloadRow(title: "FM-1.fwsc", subtitle: "Latest official firmware from M-VAVE's server", url: u,
                                       name: "M-VAVE official", author: "M-VAVE", version: "", repo: "", requireStock: true)
                    PackageDownloadRow(title: "FM-1_015.fwsc (V15)", subtitle: "Official V15, from The Firmware Hub", url: FirmwareHub.shared.stockURL,
                                       name: "M-VAVE official", author: "M-VAVE", version: "V15", repo: "", requireStock: true)
                } footer: { Text("Only accepted if its SHA-256 matches a known official release (V15 or V16). Official firmware works on every FM-1.") }
            }
            if item.id == "fm1open" {
                Section {
                    Button { Task { await fetchWorkbench() } } label: {
                        HStack { Label("Get FM1 Open + official V15", systemImage: "icloud.and.arrow.down"); if loading { Spacer(); ProgressView() } }
                    }.disabled(loading)
                    if let message { Text(message).font(.footnote) }
                } footer: { Text("Downloads M-VAVE's Workbench from GitHub and adds the two firmware packages inside it, after checking their SHA-256 digests.") }
            } else if let repo = item.repo {
                Section("Releases") {
                    if loading { ProgressView() }
                    ForEach(releases) { r in
                        ForEach(r.packages, id: \.self) { a in
                            if let u = URL(string: a.browser_download_url) {
                                PackageDownloadRow(title: a.name, subtitle: [r.tag_name, r.prerelease ? "pre-release" : nil,
                                                                             r.published_at.flatMap { ISO8601DateFormatter().date(from: $0)?.formatted(date: .abbreviated, time: .omitted) }]
                                                                             .compactMap { $0 }.joined(separator: " · "),
                                                   url: u, name: "\(item.name) \(r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))",
                                                   author: item.author, version: r.tag_name, repo: repo)
                            }
                        }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle(item.name)
        .task {
            guard let repo = item.repo, item.id != "fm1open", releases.isEmpty else { return }
            loading = true
            defer { loading = false }
            do { releases = try await Catalog.releases(repo: repo) } catch { message = "Could not load releases: \(error.localizedDescription)" }
        }
    }

    func fetchWorkbench() async {
        loading = true
        defer { loading = false }
        do {
            let (tag, found) = try await Catalog.fm1OpenWorkbench()
            var lines: [String] = []
            for e in found {
                let name = e.isStock ? nil : "FM1 Open \(e.releaseVersion)"
                let r = try LibraryImport.add(e.package.raw, fileName: "\(e.product).fwsc", name: name, author: "M-VAVE",
                                              version: e.releaseVersion, sourceURL: "https://github.com/m-vave/fm1_open/releases/tag/\(tag)",
                                              repo: "m-vave/fm1_open", context: context)
                if e.hardwareValidated == false, r.isNew {
                    r.firmware.notes = "M-VAVE marks this \(e.releaseVersion) build as not yet hardware-validated.\n\n" + r.firmware.notes
                }
                lines.append((r.isNew ? "Added " : "Already have ") + r.firmware.name)
            }
            message = lines.joined(separator: "\n")
        } catch {
            message = error.localizedDescription
        }
    }
}

struct HubRow: View {
    let entry: HubFirmware
    let have: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.name).font(.body.weight(.medium))
                Text(entry.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if have { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                if entry.stars > 0 { Label("\(entry.stars)", systemImage: "star").font(.caption).foregroundStyle(.secondary) }
            }
            if !entry.what.isEmpty { Text(entry.what).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 6) {
                Text(entry.chip.badge).font(.caption2.weight(.semibold)).foregroundStyle(entry.chip.color)
                if entry.beta { Text("beta").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                Text([entry.author, entry.lic, entry.dateValue.map { "updated \($0.formatted(date: .abbreviated, time: .omitted))" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct HubDetail: View {
    @Environment(\.openURL) private var openURL
    let entry: HubFirmware

    var body: some View {
        List {
            Section {
                if !entry.what.isEmpty { Text(entry.what) }
                LabeledContent("By", value: entry.author)
                if !entry.version.isEmpty { LabeledContent("Version", value: entry.version) }
                if !entry.lic.isEmpty { LabeledContent("Licence", value: entry.lic) }
                ChipRow(chip: entry.chip)
            }
            Section {
                PackageDownloadRow(title: entry.pkg.split(separator: "/").last.map(String.init) ?? "package",
                                   subtitle: [entry.version, entry.beta ? "beta" : nil, entry.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file) : nil]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   url: entry.packageURL, name: "\(entry.name) \(entry.version)".trimmingCharacters(in: .whitespaces),
                                   author: entry.author, version: entry.version, repo: entry.repo, expectedSHA: entry.sha256, summary: entry.what)
            } header: { Text("Package") } footer: { Text("Checked against the SHA-256 The Firmware Hub publishes before it's used.") }
            Section("Links") {
                HubLinks(entry: entry)
                if !entry.repo.isEmpty, let u = URL(string: "https://github.com/\(entry.repo)") { Button("Source on GitHub") { openURL(u) } }
                Button("The Firmware Hub") { openURL(FirmwareHub.base) }
            }
        }
        .navigationTitle(entry.name)
    }
}

enum CatalogSort: String, CaseIterable, Identifiable {
    case updated, stars, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .updated: "Recently updated"
        case .stars: "Most stars"
        case .name: "Name"
        }
    }
    var symbol: String {
        switch self {
        case .updated: "clock"
        case .stars: "star"
        case .name: "textformat"
        }
    }
    func apply(_ list: [HubFirmware]) -> [HubFirmware] {
        switch self {
        case .updated: list.sorted { $0.date > $1.date }      // yyyy-MM-dd sorts as text
        case .stars: list.sorted { $0.stars == $1.stars ? $0.date > $1.date : $0.stars > $1.stars }
        case .name: list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    func apply(_ list: [CatalogEntry]) -> [CatalogEntry] {
        switch self {
        case .updated: list.sorted { ($0.pushedDate ?? .distantPast) > ($1.pushedDate ?? .distantPast) }
        case .stars: list.sorted { ($0.stars ?? 0) == ($1.stars ?? 0) ? ($0.pushedDate ?? .distantPast) > ($1.pushedDate ?? .distantPast) : ($0.stars ?? 0) > ($1.stars ?? 0) }
        case .name: list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}
