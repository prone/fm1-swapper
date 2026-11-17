// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import Foundation
import SwiftData

/// Where firmware comes from. The community catalog is 2bbb/fm1-firmware-collection,
/// which indexes every public FM-1 firmware repository and its release packages.
struct CatalogEntry: Decodable, Identifiable, Hashable {
    struct Release: Decodable, Hashable {
        var tag: String?
        var name: String?
        var url: String?
        var size: Int?
        var prerelease: Bool?
        var published: String?
    }

    var id: String
    var repo: String?
    var url: String?
    var description: String?
    var license: String?
    var stars: Int?
    var pushed: String?
    var archived: Bool?
    var fork_of: String?
    var upstream_releases: [Release]?

    var title: String { repo?.split(separator: "/").last.map(String.init) ?? id }
    var owner: String { repo?.split(separator: "/").first.map(String.init) ?? "" }
    var packages: [Release] { (upstream_releases ?? []).filter { ($0.name ?? "").lowercased().hasSuffix(".fwsc") && $0.url != nil } }
    /// Packages that look like they are for the FM-1 (not the SMK-37 or Pocket amps).
    var fm1Packages: [Release] { packages.filter { !($0.name ?? "").lowercased().contains("smk") } }
    var pushedDate: Date? { pushed.flatMap { Self.iso.date(from: $0) } }
    private static let iso = ISO8601DateFormatter()
}

struct FeaturedFirmware: Identifiable {
    let id: String
    let name: String
    let author: String
    let blurb: String
    let repo: String?
    let website: String
    let howToGet: String
}

enum Catalog {
    /// M-VAVE's own download of the current official firmware (linked from their site and fm1-emu).
    static let officialFWSC = "https://yms-file-store.oss-cn-hongkong.aliyuncs.com/software/firmware/FM-1.fwsc"
    static let communityURL = URL(string: "https://raw.githubusercontent.com/2bbb/fm1-firmware-collection/main/catalog/firmwares.json")!

    static let featured: [FeaturedFirmware] = [
        .init(id: "official", name: "M-VAVE official", author: "M-VAVE", blurb: "The stock DX7-style FM firmware (V15, V16 adds stereo FX and presets). Keep a copy so you can always go back.",
              repo: nil, website: "https://www.m-vave.com/download", howToGet: "Download it right here from M-VAVE's server, or share FM-1.fwsc to this app."),
        .init(id: "fm1open", name: "FM1 Open", author: "M-VAVE", blurb: "M-VAVE's open-source branch: 8-track 64-step sequencer, six engines with samples, DX7 library.",
              repo: "m-vave/fm1_open", website: "https://open.m-vave.com/fm1-workbench", howToGet: "Fetched from the Workbench file in M-VAVE's GitHub release (it also contains the original official V15)."),
        .init(id: "felucca", name: "Felucca", author: "Hügelton Instruments", blurb: "Multi-engine synth firmware (13+ engines, FM6, samples). The base for many community firmwares.",
              repo: "hugelton/Felucca", website: "https://github.com/hugelton/Felucca/wiki", howToGet: "Download from GitHub releases right here."),
        .init(id: "fm1dock", name: "fm1-dock", author: "joakimeriksson", blurb: "One firmware with synths as modules in flash slots, deployed over MIDI.",
              repo: "joakimeriksson/fm1-dock", website: "https://github.com/joakimeriksson/fm1-dock", howToGet: "Download from GitHub releases right here (pick a package without “smk37” in its name)."),
        .init(id: "groove", name: "Groove OS", author: "Groove OS", blurb: "8-track groovebox firmware (paid).",
              repo: nil, website: "https://synthanatomy.com/2026/10/groove-os-turns-the-m-vave-fm-1-into-an-8-track-groovebox.html", howToGet: "Buy it from the developer, then import the .fwsc."),
        .init(id: "baudgirl", name: "Baud Girl FM-1+VA", author: "Baud Girl", blurb: "Adds a VA engine (303-style, supersaw) and a better sequencer.",
              repo: nil, website: "https://synthanatomy.com/2026/09/baud-girl-fm-1-va-custom-m-vave-fm-1-firmware.html", howToGet: "Download from the developer's page, then import the .fwsc."),
    ]

    static func loadCommunity() async throws -> [CatalogEntry] {
        struct Root: Decodable { var firmwares: [CatalogEntry] }
        let data = try await download(communityURL, maxBytes: 8 << 20)
        // ISO 8601 timestamps sort as text: no date parsing per comparison
        return try JSONDecoder().decode(Root.self, from: data).firmwares
            .filter { !$0.packages.isEmpty }
            .sorted { ($0.pushed ?? "") > ($1.pushed ?? "") }
    }

    struct GitHubRelease: Decodable, Identifiable {
        struct Asset: Decodable, Hashable { var name: String; var browser_download_url: String; var size: Int }
        var id: Int
        var tag_name: String
        var name: String?
        var published_at: String?
        var prerelease: Bool
        var assets: [Asset]
        var packages: [Asset] { assets.filter { $0.name.lowercased().hasSuffix(".fwsc") } }
    }

    static func releases(repo: String) async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=15")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([GitHubRelease].self, from: data).filter { !$0.packages.isEmpty }
    }

    /// FM1 Open and the original official V15, pulled out of M-VAVE's latest Workbench release.
    static func fm1OpenWorkbench() async throws -> (tag: String, packages: [WorkbenchExtractor.Embedded]) {
        let url = URL(string: "https://api.github.com/repos/m-vave/fm1_open/releases?per_page=5")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        for r in releases where !r.prerelease {
            guard let a = r.assets.first(where: { $0.name.hasSuffix("Workbench.html") }), let u = URL(string: a.browser_download_url) else { continue }
            let found = WorkbenchExtractor.packages(inHTML: try await download(u, maxBytes: 32 << 20))
            if !found.isEmpty { return (r.tag_name, found) }
        }
        throw FM1Error.badPackage("No FM1 Open Workbench with firmware packages was found in M-VAVE's releases.")
    }

    /// Downloads over https only, refusing anything larger than `maxBytes` (firmware is ~0.5-1 MB).
    static func download(_ url: URL, maxBytes: Int = 16 << 20) async throws -> Data {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        if resp.expectedContentLength > Int64(maxBytes) { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        data.reserveCapacity(max(0, min(Int(resp.expectedContentLength), maxBytes)))
        for try await chunk in bytes.chunked() {
            data.append(contentsOf: chunk)
            if data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }
}

enum LibraryImport {
    struct Result { let firmware: Firmware; let isNew: Bool; let warning: String? }

    /// Adds a package to the library (or fills in the file of an existing entry with the same identity).
    @MainActor
    static func add(_ data: Data, fileName: String, name: String? = nil, author: String = "", version: String = "",
                    sourceURL: String = "", repo: String = "", context: ModelContext) throws -> Result {
        let pkg = try FirmwarePackage(data: data)
        let sha = pkg.sha256
        if let existing = try context.fetch(FetchDescriptor<Firmware>(predicate: #Predicate { $0.sha256 == sha })).first {
            if !existing.hasPackage { existing.setPackage(data) }
            return Result(firmware: existing, isNew: false, warning: nil)
        }
        let product = pkg.product
        // A placeholder created when the device reported this identity, waiting for its file.
        let placeholder = try context.fetch(FetchDescriptor<Firmware>(predicate: #Predicate { $0.product == product && $0.sha256 == "" })).first
        let f = placeholder ?? Firmware(name: name ?? defaultName(fileName: fileName, pkg: pkg), product: product)
        if placeholder == nil { context.insert(f) }
        if let stock = pkg.stock {
            f.name = "M-VAVE official \(stock.version)"
            f.author = "M-VAVE"
            f.version = stock.version
        } else {
            if let name { f.name = name }
            if !author.isEmpty { f.author = author }
            if !version.isEmpty { f.version = version }
        }
        f.sha256 = sha
        f.setPackage(data)
        f.fileName = fileName
        if !sourceURL.isEmpty { f.sourceURL = sourceURL }
        if !repo.isEmpty { f.repo = repo }
        try context.save()
        let warning = pkg.model == "FM-1" ? nil : "This package is for \(pkg.model), not the FM-1. It will be refused at install time."
        return Result(firmware: f, isNew: placeholder == nil, warning: warning)
    }

    static func defaultName(fileName: String, pkg: FirmwarePackage) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty || base == "FM-1" ? "Firmware \(pkg.product)" : base
    }
}

/// Fills in missing firmware descriptions: the featured list first, then the community
/// catalog (matched by repo or download URL), then the GitHub repo's own description.
@MainActor
enum DescriptionFiller {
    private static var community: [CatalogEntry]?
    private static var running = false

    static func featured(for f: Firmware) -> FeaturedFirmware? {
        let repo = f.repo.lowercased(), src = f.sourceURL.lowercased()
        if f.isStock || f.family == .official { return Catalog.featured.first { $0.id == "official" } }
        if f.family == .fm1Open || repo == "m-vave/fm1_open" { return Catalog.featured.first { $0.id == "fm1open" } }
        return Catalog.featured.first { item in
            guard let r = item.repo?.lowercased() else { return false }
            return repo == r || src.contains("github.com/\(r)/")
        }
    }

    /// "owner/name" from a GitHub URL.
    static func repo(fromURL s: String) -> String? {
        guard let u = URL(string: s), u.host?.hasSuffix("github.com") == true else { return nil }
        let parts = u.path.split(separator: "/")
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    static func fill(_ firmwares: [Firmware], context: ModelContext) async {
        let missing = firmwares.filter { $0.summary.isEmpty }
        guard !missing.isEmpty, !running else { return }
        running = true
        defer { running = false }
        for f in missing {
            if f.repo.isEmpty, let r = repo(fromURL: f.sourceURL) { f.repo = r }
            if let item = featured(for: f) { f.summary = item.blurb; continue }
            if f.family == .felucca, f.repo.isEmpty { f.summary = Catalog.featured.first { $0.id == "felucca" }?.blurb ?? ""; continue }
        }
        var rest = missing.filter { $0.summary.isEmpty }
        if !rest.isEmpty {
            if community == nil { community = try? await Catalog.loadCommunity() }
            for f in rest {
                let repo = f.repo.lowercased()
                let entry = community?.first { e in
                    (!repo.isEmpty && e.repo?.lowercased() == repo) ||
                        (!f.sourceURL.isEmpty && (e.upstream_releases ?? []).contains { $0.url == f.sourceURL })
                }
                if let e = entry {
                    if f.repo.isEmpty, let r = e.repo { f.repo = r }
                    if f.author.isEmpty { f.author = e.owner }
                    if let d = e.description, !d.isEmpty { f.summary = d }
                }
            }
            rest = rest.filter { $0.summary.isEmpty && !$0.repo.isEmpty }
            for f in rest {
                if let d = await githubDescription(f.repo) { f.summary = d }
            }
        }
        try? context.save()
    }

    static func githubDescription(_ repo: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = j["description"] as? String,
              !d.isEmpty else { return nil }
        return d
    }
}

extension URLSession.AsyncBytes {
    /// The stream in 64 KB pieces (byte-by-byte appends are slow).
    func chunked(size: Int = 64 << 10) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var buf: [UInt8] = []
                buf.reserveCapacity(size)
                do {
                    for try await b in self {
                        buf.append(b)
                        if buf.count == size { cont.yield(buf); buf.removeAll(keepingCapacity: true) }
                    }
                    if !buf.isEmpty { cont.yield(buf) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Opens only web links from catalog data (other schemes could launch other apps).
func isWebLink(_ url: URL) -> Bool { ["https", "http"].contains(url.scheme?.lowercased() ?? "") }

enum ImportLimit {
    static let firmware = 16 << 20
    static let audio = 100 << 20
    static let backup = 32 << 20
    static let emulatorSave = 8 << 20
}

/// Reads an imported file, refusing it before loading when it is larger than `maxBytes`.
func readImport(_ url: URL, maxBytes: Int) throws -> Data {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= maxBytes else {
        throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "\(url.lastPathComponent) is too large (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."])
    }
    // (the size above can be missing: read at most one byte past the limit to be sure)
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    let data = try h.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else {
        throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) is too large."])
    }
    return data
}
