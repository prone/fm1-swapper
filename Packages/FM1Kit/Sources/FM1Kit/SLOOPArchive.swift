// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

/// SLOOP's backup protocol (isod89/sloop-fm1 `firmware/src/editor.c`, editor protocol v6+, SLOOP 2.3 and later; also its
/// forks: Clipper, winampFM, ORBIT…). Same frame as Felucca's archive (`F0 7D 46 4C cmd … F7`, objects by id, never flash
/// addresses), but its own commands: 34 LIST (snapshots the working project), 35 GET, 36 PUT (begin, data, commit;
/// each object is checked as a load would and written through SLOOP's A/B commit, so a cut-off restore never leaves
/// half an object).
///
/// Objects: 0 the loop in progress, 1 the settings (with the song order), 2–5 sections A–D, 6–7 the user preset
/// banks, 8 the FM6 patch bank, 9 the SYN drum kits, 10 MIDI learn, 11 the theme, 32–35 sample slots USR1–USR4.
/// The sample slots are read here but not written back: SLOOP restores them with its sample commands, which this
/// doesn't send yet, so a restore leaves the samples on the FM-1 as they are.
public struct SLOOPArchive: Sendable {
    public static let format = "sloop-backup"
    enum Cmd { static let info: UInt8 = 1, list: UInt8 = 34, get: UInt8 = 35, put: UInt8 = 36 }
    /// A SLOOP song: the loop in progress, the settings (they hold the song order) and sections A–D.
    public static let songIDs: Set<UInt8> = [0, 1, 2, 3, 4, 5]

    public static func label(_ id: UInt8) -> String {
        switch id {
        case 0: "Loop in progress"
        case 1: "Settings and song order"
        case 2...5: "Section \(["A", "B", "C", "D"][Int(id) - 2])"
        case 6: "User presets 1–16"
        case 7: "User presets 17–32"
        case 8: "FM6 patches"
        case 9: "SYN drum kits"
        case 10: "MIDI learn"
        case 11: "Theme"
        case 32...35: "Sample slot USR\(id - 31)"
        default: "Object \(id)"
        }
    }

    let felucca: FeluccaArchive
    public init(link: SysExLink) { felucca = FeluccaArchive(link: link) }

    /// The editor protocol version when the running firmware is SLOOP-style (INFO ends with the track count and the
    /// protocol version, and Felucca's archive extension is absent), else nil.
    public static func protocolVersion(info a: [UInt8]) -> Int? {
        guard var pos = a.firstIndex(of: 0) else { return nil }
        pos += 1
        guard pos < a.count else { return nil }
        let engines = Int(a[pos]); pos += 5
        for _ in 0..<engines {
            guard pos <= a.count, let end = a[pos...].firstIndex(of: 0) else { return nil }
            pos = end + 1
        }
        guard a.count - pos == 2, (1...8).contains(a[pos]) else { return nil }
        return Int(a[pos + 1])
    }

    /// Whether this firmware has SLOOP's backup commands (protocol 6 or later).
    public func supported() async -> Bool {
        guard let a = try? await felucca.request(Cmd.info, []), let v = Self.protocolVersion(info: a) else { return false }
        return v >= 6
    }

    static func manifest(_ a: [UInt8]) throws -> [FeluccaArchive.ManifestEntry] {
        guard a.count >= 2 else { throw FM1Error.protocolError("Short backup list") }
        try FeluccaArchive.check(a[0])
        let n = Int(a[1])
        guard a.count == 2 + n * 11 else { throw FM1Error.protocolError("Incomplete backup list") }
        return try (0..<n).map { i in
            let p = 2 + i * 11
            let size = Int(try SysExCoding.u32From7(a, at: p + 1)), crc = try SysExCoding.u32From7(a, at: p + 6)
            guard size <= 256 * 1024 else { throw FM1Error.protocolError("Backup object too large") }
            return .init(id: a[p], size: size, crc: crc)
        }
    }

    /// Reads the objects (all of them, or only `only`), each checked against SLOOP's CRC-32.
    public func capture(firmware: String, only: Set<UInt8>? = nil, progress: @escaping ArchiveProgress = { _, _ in }) async throws -> DeviceArchive {
        guard await supported() else { throw FM1Error.unsupported("This firmware doesn't have SLOOP's backup (SLOOP 2.3 or later).") }
        let all = try Self.manifest(try await felucca.request(Cmd.list, [], timeout: 5))
        let manifest = all.filter { only?.contains($0.id) ?? true }
        let parts = try await felucca.readObjects(manifest, get: Cmd.get, label: Self.label, progress: progress)
        guard parts.contains(where: { $0.id == "0" && !$0.data.isEmpty }), parts.contains(where: { $0.id == "1" && !$0.data.isEmpty }) else {
            throw FM1Error.device("The backup is missing the loop in progress or the settings.")
        }
        return DeviceArchive(format: Self.format, family: .felucca, firmware: firmware, parts: parts,
                             info: ["identity": firmware, "contents": only == Self.songIDs ? "song" : "all"])
    }

    // MARK: Clearing the song

    /// The size and CRC-32 of each object as the FM-1 has it now (LIST: checksums only, nothing is read out).
    public func checksums() async throws -> [UInt8: (size: Int, crc: UInt32)] {
        guard await supported() else { throw FM1Error.unsupported("This firmware doesn't have SLOOP's song backup (SLOOP 2.3 or later).") }
        var out: [UInt8: (size: Int, crc: UInt32)] = [:]
        for e in try Self.manifest(try await felucca.request(Cmd.list, [], timeout: 5)) { out[e.id] = (e.size, e.crc) }
        return out
    }

    /// Whether a saved song holds what the FM-1 has now: the loop and sections A–D (the settings change too often to count).
    public static func matches(_ song: DeviceArchive, _ now: [UInt8: (size: Int, crc: UInt32)]) -> Bool {
        guard song.format == format else { return false }
        for id: UInt8 in [0, 2, 3, 4, 5] {
            let p = song.part("\(id)"), have = now[id] ?? (0, 0)          // an empty object's CRC-32 is 0
            guard (p?.data.count ?? 0) == have.size, (p?.crc ?? 0) == have.crc else { return false }
        }
        return true
    }

    static let live: UInt8 = 77

    /// The editor protocol version of the running SLOOP, or nil.
    func protocolVersion() async -> Int? {
        guard let a = try? await felucca.request(Cmd.info, []) else { return nil }
        return Self.protocolVersion(info: a)
    }

    private func liveState(_ args: [UInt8]) async throws -> [UInt8] {
        let r = try await felucca.request(Self.live, args, timeout: 1, retries: 1)
        guard r.count >= 3, r[0] == args[0] else { throw FM1Error.protocolError("Unexpected reply from SLOOP") }
        return r
    }

    /// Stops playback and waits until the transport has really stopped (LIVE, protocol 12): SLOOP refuses a restore
    /// while playing, and erases the whole pattern only when stopped.
    func stopPlayback() async throws {
        var state = try await liveState([1, 0])
        let end = Date().addingTimeInterval(3)
        while state[1] & 3 != 0 {
            guard Date() < end else { throw FM1Error.device("SLOOP didn't stop playing. Stop it on the FM-1 and try again.") }
            try await Task.sleep(nanoseconds: 50_000_000)
            state = try await liveState([0, 0])
        }
    }

    /// Clears the song on the FM-1, as SLOOP's own controls would: stops playback, erases every note of the four tracks
    /// (LIVE ERASE, as EDIT + a key; sounds, presets and tempo stay) and empties sections A–D. Needs SLOOP 2.7 or later
    /// (editor protocol 12). With `unchangedSince`, it first checks the song is still the one checked then (so a song
    /// played or recorded since the "it's saved" check isn't erased).
    public func clearSong(unchangedSince checked: [UInt8: (size: Int, crc: UInt32)]? = nil,
                          progress: @escaping ArchiveProgress = { _, _ in }) async throws {
        guard let v = await protocolVersion(), v >= 12 else {
            throw FM1Error.unsupported("Clearing from the app needs SLOOP 2.7 or later. On the FM-1: SAVE → TOOLS → NEW, then SECTION → ERASE for A–D.")
        }
        try await stopPlayback()
        if let checked {
            let now = try await checksums()
            for id: UInt8 in [0, 2, 3, 4, 5] where (now[id]?.size ?? 0, now[id]?.crc ?? 0) != (checked[id]?.size ?? 0, checked[id]?.crc ?? 0) {
                throw FM1Error.device("The song on the FM-1 changed since it was checked. Nothing was cleared: try Clear again.")
            }
        }
        let steps = 4 * 128 * 2 + 4
        var done = 0
        for track: UInt8 in 0..<4 {
            for note: UInt8 in 0..<128 { _ = try await liveState([7, track, note, 1]); done += 1; progress(done, steps) }
            for note: UInt8 in 0..<128 { _ = try await liveState([7, track, note, 0]); done += 1; progress(done, steps) }
        }
        for id: UInt8 in 2...5 {
            for args: [UInt8] in [[0, id] + SysExCoding.u32To7(0) + SysExCoding.u32To7(0), [2, id]] {
                let r = try await felucca.request(Cmd.put, args, timeout: 5)
                guard r.count >= 3, r[0] == args[0], r[1] == id else { throw FM1Error.protocolError("Unexpected reply from SLOOP") }
                try FeluccaArchive.check(r[2])
            }
            done += 1; progress(done, steps)
        }
    }

    /// The objects a restore writes, in order: everything else first, then the settings, the loop in progress last.
    public static func restoreOrder(_ archive: DeviceArchive) throws -> [(id: UInt8, data: [UInt8], crc: UInt32)] {
        guard archive.format == format else { throw FM1Error.badPackage("This isn't a SLOOP backup.") }
        var out: [(id: UInt8, data: [UInt8], crc: UInt32)] = []
        for p in archive.parts {
            guard let id = UInt8(p.id) else { throw FM1Error.badPackage("Damaged backup.") }
            guard id <= 11 else { continue }                                      // sample slots: left as they are
            guard SysExCoding.crc32(p.data) == p.crc else { throw FM1Error.badPackage("The backup is damaged (\(p.label)).") }
            guard id >= 2 || !p.data.isEmpty else { throw FM1Error.badPackage("The backup is missing \(p.label).") }
            out.append((id, [UInt8](p.data), p.crc))
        }
        guard out.contains(where: { $0.id == 0 }) else { throw FM1Error.badPackage("The backup is missing the loop in progress.") }
        func rank(_ id: UInt8) -> Int { id == 0 ? 2 : id == 1 ? 1 : 0 }
        return out.sorted { rank($0.id) < rank($1.id) }
    }

    public func restore(_ archive: DeviceArchive, progress: @escaping ArchiveProgress = { _, _ in }) async throws {
        let order = try Self.restoreOrder(archive)                             // checked before anything is sent
        guard let v = await protocolVersion(), v >= 6 else { throw FM1Error.unsupported("This firmware can't restore a SLOOP backup (SLOOP 2.3 or later).") }
        if v >= 12 { try await stopPlayback() }                                // (older: SLOOP says to stop it)
        let total = order.reduce(0) { $0 + $1.data.count }
        var done = 0
        func put(_ args: [UInt8]) async throws {
            let a = try await felucca.request(Cmd.put, args, timeout: 5)
            guard a.count >= 3, a[0] == args[0], a[1] == args[1] else { throw FM1Error.protocolError("Unexpected restore reply") }
            try FeluccaArchive.check(a[2])
        }
        for o in order {
            let begin = [0, o.id] + SysExCoding.u32To7(UInt32(o.data.count)) + SysExCoding.u32To7(o.crc)
            if o.id >= 6 {
                // presets, kits, MIDI learn, theme: an older SLOOP that doesn't know the object says "invalid" (1); skip it
                let a = try await felucca.request(Cmd.put, begin, timeout: 5)
                guard a.count >= 3, a[0] == 0, a[1] == o.id else { throw FM1Error.protocolError("Unexpected restore reply") }
                if a[2] == 1 { done += o.data.count; progress(done, total); continue }
                try FeluccaArchive.check(a[2])
            } else {
                try await put(begin)
            }
            try await FeluccaArchive.sendObject(o.id, o.data, put: put) { done += $0; progress(done, total) }
        }
    }
}
