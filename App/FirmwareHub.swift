// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import Foundation
import Observation
import SwiftData
import SwiftUI

/// The Firmware Hub's firmware list (https://thefirmwarehub.com/catalog.json, CC BY 4.0: credit "The Firmware Hub" with
/// a link, read at most once a day; card texts belong to each firmware's maker). Per package it gives the SHA-256 to
/// check downloads against, which FM-1 flash chips the firmware supports, its kind and its links. Mirrors web/src/hub.ts;
/// see docs/flash-chips.md.
struct HubFirmware: Identifiable, Hashable {
    let id, name, author, repo, what, version, date, lic, pkg, sha256, product: String
    let kind: [String]
    let stars, size: Int
    let chip: FlashChipSupport
    let beta, linkOnly: Bool
    let editor, play, manual, site, talk: URL?
    var packageURL: URL { FirmwareHub.base.appending(path: pkg) }
    var dateValue: Date? { FirmwareHub.day.date(from: date) }
}

/// Which FM-1 flash chips a firmware works with.
enum FlashChipSupport: String {
    /// Both chips (or M-VAVE's own firmware).
    case both = "new"
    /// Doesn't check the chip; should work on both.
    case unchecked = "any"
    /// Only the first FM-1s' chip (0x856014): on a newer FM-1 it keeps saves in RAM and can't update itself.
    case olderOnly = "old"

    var badge: String {
        switch self {
        case .both: "All FM-1s"
        case .unchecked: "No chip check"
        case .olderOnly: "Older FM-1s only"
        }
    }
    var color: Color { self == .olderOnly ? .red : self == .both ? .green : .secondary }
    var explanation: String {
        switch self {
        case .both: "Works on every FM-1, including newer units (flash chip 0xB36014)."
        case .unchecked: "Doesn't check the flash chip: should work on every FM-1 (not confirmed on the newer chip)."
        case .olderOnly: "Only for the first FM-1s. On a newer FM-1 (flash chip 0xB36014) it keeps saves in RAM only, and it can't update itself afterwards."
        }
    }
    static let unknownExplanation = "Flash chip support unknown: this exact package isn't in The Firmware Hub's list."
}

/// The user's own FM-1. The chip can't be read over USB MIDI (only in download mode, e.g. M-Flasher), so they tell us.
enum MyFlashChip: String, CaseIterable, Identifiable {
    case unknown, older, newer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unknown: "I don't know"
        case .older: "Older unit (0x856014)"
        case .newer: "Newer unit (0xB36014)"
        }
    }
}

@MainActor @Observable
final class FirmwareHub {
    static let shared = FirmwareHub()
    static let base = URL(string: "https://thefirmwarehub.com/")!
    static let rescueURL = URL(string: FM1Error.rescueURL)!
    static let attribution = "Firmware list: The Firmware Hub – thefirmwarehub.com (CC BY 4.0). Descriptions belong to each firmware's maker."
    static let kinds: [(String, String)] = [("synth", "Synths"), ("groove", "Grooveboxes"), ("drums", "Drums & samplers"), ("chords", "Chords"),
                                            ("tracker", "Trackers"), ("dev", "For devs"), ("other", "Other")]
    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()

    private(set) var list: [HubFirmware] = []
    private(set) var bySha: [String: HubFirmware] = [:]
    private(set) var byRepo: [String: HubFirmware] = [:]
    private(set) var stockURL = base.appending(path: "fw/mvave/FM-1_015.fwsc")
    private(set) var loaded = false
    private var loading: Task<Void, Never>?

    private var cacheFile: URL { URL.cachesDirectory.appending(path: "thefirmwarehub-catalog.json") }

    /// Loads the list, from a copy less than a day old when there is one (the hub asks for at most one read a day).
    func load() async {
        if loaded { return }
        if let loading { return await loading.value }
        let t = Task { @MainActor in
            let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path)
            let age = (attrs?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? .infinity
            if age < 86_400, let d = try? Data(contentsOf: cacheFile), apply(d) { return }
            if let d = try? await Catalog.download(Self.base.appending(path: "catalog.json"), maxBytes: 8 << 20), apply(d) {
                try? d.write(to: cacheFile, options: .atomic)
            } else if let d = try? Data(contentsOf: cacheFile) {
                _ = apply(d)                       // offline: an older copy is better than none
            }
        }
        loading = t
        await t.value
        loading = nil
    }

    /// Parses the list, keeping only entries with a well-formed digest and a package path on the hub itself.
    @discardableResult
    func apply(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["firmwares"] as? [[String: Any]] else { return false }
        func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
        func link(_ d: [String: Any], _ k: String) -> URL? { (d[k] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil } }
        var out: [HubFirmware] = []
        for f in items {
            let sha = str(f, "sha256"), pkg = str(f, "pkg")
            guard !str(f, "id").isEmpty, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, Self.safePath(pkg) else { continue }
            let kind = (f["kind"] as? [String]) ?? (f["kind"] as? String).map { [$0] } ?? []
            out.append(HubFirmware(id: str(f, "id"), name: str(f, "name").isEmpty ? str(f, "id") : str(f, "name"), author: str(f, "author"),
                                   repo: str(f, "repo"), what: str(f, "what"), version: str(f, "version"), date: str(f, "date"), lic: str(f, "lic"),
                                   pkg: pkg, sha256: sha, product: str(f, "product"), kind: kind, stars: f["stars"] as? Int ?? 0,
                                   size: f["size"] as? Int ?? 0, chip: FlashChipSupport(rawValue: str(f, "chip")) ?? .olderOnly,
                                   beta: f["beta"] as? Bool ?? false, linkOnly: f["linkOnly"] as? Bool ?? false,
                                   editor: link(f, "editor"), play: link(f, "play"), manual: link(f, "cheat"), site: link(f, "site"), talk: link(f, "talk")))
        }
        guard !out.isEmpty else { return false }
        list = out
        bySha = Dictionary(out.map { ($0.sha256, $0) }, uniquingKeysWith: { a, _ in a })
        byRepo = Dictionary(out.filter { !$0.repo.isEmpty }.map { ($0.repo.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        if let s = (root["stock"] as? [String: Any])?["pkg"] as? String, Self.safePath(s) { stockURL = Self.base.appending(path: s) }
        loaded = true
        return true
    }

    /// A package path on the hub: no scheme, no leading slash, no "." or ".." segments.
    nonisolated static func safePath(_ p: String) -> Bool {
        p.range(of: #"^[\w-]+(/[\w.-]+)*\.fwsc$"#, options: .regularExpression) != nil && !p.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    /// Flash chip support of an exact package. M-VAVE's own firmware works on both; nil when unknown.
    func chip(sha256: String) -> FlashChipSupport? {
        if StockFirmware.all.contains(where: { $0.sha256 == sha256 }) { return .both }
        return bySha[sha256]?.chip
    }

    /// The hub's entry for a library firmware: the exact package, else the same project (links only).
    func entry(for f: Firmware) -> (entry: HubFirmware, exact: Bool)? {
        if let e = bySha[f.sha256] { return (e, true) }
        if !f.repo.isEmpty, let e = byRepo[f.repo.lowercased()] { return (e, false) }
        return nil
    }

    /// Downloads a package from the hub and checks it against the SHA-256 the hub publishes before returning it.
    func download(_ e: HubFirmware) async throws -> Data {
        let data = try await Catalog.download(e.packageURL)
        guard try FirmwarePackage(data: data).sha256 == e.sha256 else {
            throw FM1Error.badPackage("The download doesn't match the checksum The Firmware Hub publishes for \(e.name) \(e.version), so it wasn't added.")
        }
        return data
    }

    /// Official V15 exactly: the copy in the library, or downloaded from the hub and checked against its digest.
    func stockV15(in firmwares: [Firmware], context: ModelContext) async throws -> Firmware {
        let v15 = StockFirmware.all.first { $0.version == "V15" }!
        if let f = firmwares.first(where: { $0.sha256 == v15.sha256 && $0.hasPackage }) { return f }
        await load()
        let data = try await Catalog.download(stockURL)
        guard try FirmwarePackage(data: data).stock?.version == "V15" else {
            throw FM1Error.badPackage("The downloaded file isn't M-VAVE's official V15 (its checksum doesn't match), so it wasn't used.")
        }
        return try LibraryImport.add(data, fileName: "FM-1_015.fwsc", sourceURL: stockURL.absoluteString, context: context).firmware
    }

    /// M-VAVE's official firmware: the copy in the library, or V15 from the hub, checked against its known digest.
    func officialFirmware(in firmwares: [Firmware], context: ModelContext) async throws -> Firmware {
        for s in StockFirmware.all.reversed() { if let f = firmwares.first(where: { $0.sha256 == s.sha256 && $0.hasPackage }) { return f } }
        await load()
        let data = try await Catalog.download(stockURL)
        guard try FirmwarePackage(data: data).stock != nil else {
            throw FM1Error.badPackage("The downloaded file isn't M-VAVE's official firmware (its checksum doesn't match), so it wasn't added.")
        }
        return try LibraryImport.add(data, fileName: "FM-1.fwsc", sourceURL: stockURL.absoluteString, context: context).firmware
    }
}
