// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

/// Puts a SLOOP song into an emulator save (fm1-emu's "fm1-emulator-save": the firmware package and the 4 KB flash
/// sectors that differ from it), so the song plays in the emulator as it would on the FM-1.
///
/// The song is written the way SLOOP writes it (isod89/sloop-fm1 `firmware/src/storage.c`): each object has an A/B
/// pair of sectors; a copy is the payload at +256 and a 32-byte commit header at +0 (magic "FELU", type, copy, seq,
/// length, CRC-32 of the payload, CRC-32 of the header); the valid copy with the highest seq wins. A save writes the
/// other copy with seq + 1, as SLOOP's own save does, so the copy it had stays as it was. Sections A–D are objects
/// 1–4 (0x97000…), the loop in progress object 7 (0x9F000 / 0xFE000), the settings object 0 (0xFC000 / 0xFD000):
/// only the song order bytes of the emulator's settings change, its drum kits and MIDI learn stay.
public enum SLOOPFlash {
    public static let sectorSize = 4096
    static let magic: UInt32 = 0x554C_4546, payloadAt = 256, sideAt = 64
    static let settings = 0, project0 = 1, autosave = 7

    static func sector(_ obj: Int, _ copy: Int) -> Int {
        switch obj {
        case settings: 0xFC000 + copy * sectorSize
        case autosave: copy == 1 ? 0xFE000 : 0x9F000
        default: 0x97000 + (obj - project0) * 2 * sectorSize + copy * sectorSize
        }
    }

    public typealias Sectors = [Int: [UInt8]]

    struct Header { let seq: UInt32, len: Int }

    static func header(_ s: Sectors, _ obj: Int, _ copy: Int) -> Header? {
        guard let b = s[sector(obj, copy)] else { return nil }                 // not in the save: erased
        let u32 = { (at: Int) in UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24 }
        let type = Int(b[4]) | Int(b[5]) << 8, slot = Int(b[6]) | Int(b[7]) << 8, len = Int(u32(12))
        guard u32(0) == magic, type == obj, slot == copy, len <= sectorSize - payloadAt,
              u32(28) == SysExCoding.crc32(b[0..<28]),
              u32(16) == SysExCoding.crc32(b[payloadAt..<payloadAt + len]) else { return nil }
        return Header(seq: u32(8), len: len)
    }

    /// The copy SLOOP would load (st_current): the valid one with the highest seq, A on a tie.
    static func current(_ s: Sectors, _ obj: Int) -> (copy: Int, h: Header)? {
        let a = header(s, obj, 0), b = header(s, obj, 1)
        if let b, a == nil || b.seq > a!.seq { return (1, b) }
        if let a { return (0, a) }
        return nil
    }

    /// The object's payload as SLOOP would load it, or nil.
    public static func read(_ s: Sectors, _ obj: Int) -> [UInt8]? {
        guard let c = current(s, obj), let b = s[sector(obj, c.copy)] else { return nil }
        return Array(b[payloadAt..<payloadAt + c.h.len])
    }

    /// Saves an object as SLOOP's st_save does: the other copy, seq + 1; the side record (bytes 64–255) kept from the
    /// copy it had when `keepSide`.
    static func write(_ s: inout Sectors, _ obj: Int, _ payload: [UInt8], keepSide: Bool = false) throws {
        guard payload.count <= sectorSize - payloadAt else { throw FM1Error.badPackage("A song part is too large for SLOOP's flash.") }
        let cur = current(s, obj)
        let copy = cur?.copy == 0 ? 1 : 0
        var b = [UInt8](repeating: 0xFF, count: sectorSize)
        b.replaceSubrange(payloadAt..<payloadAt + payload.count, with: payload)
        if keepSide, let c = cur, let old = s[sector(obj, c.copy)] { b.replaceSubrange(sideAt..<payloadAt, with: old[sideAt..<payloadAt]) }
        var h: [UInt8] = []
        func put32(_ v: UInt32) { for i in 0..<4 { h.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        put32(magic)
        h += [UInt8(obj & 255), UInt8(obj >> 8), UInt8(copy), 0]
        put32((cur?.h.seq ?? 0) &+ 1)
        put32(UInt32(payload.count))
        put32(SysExCoding.crc32(payload))
        put32(0xFFFF_FFFF); put32(0xFFFF_FFFF)
        put32(SysExCoding.crc32(h))
        b.replaceSubrange(0..<32, with: h)
        s[sector(obj, copy)] = b
    }

    /// The song's objects written over the emulator's flash sectors: the loop, sections A–D (an empty one: a record
    /// of length 0, as SLOOP's restore writes it) and the song order.
    public static func put(_ song: DeviceArchive, into s: inout Sectors) throws {
        guard song.format == SLOOPArchive.format else { throw FM1Error.badPackage("This isn't a SLOOP song.") }
        _ = try SLOOPArchive.restoreOrder(song)                                 // checked as a load would
        if let loop = song.part("0"), !loop.data.isEmpty { try write(&s, autosave, [UInt8](loop.data)) }
        for i in 0..<4 { try write(&s, project0 + i, [UInt8](song.part("\(i + 2)")?.data ?? Data())) }
        guard let settingsPart = song.part("1"), let order = SLOOPOrder(settings: settingsPart.data) else { return }
        if let mine = read(s, settings), mine.count >= SLOOPOrder.at + 36, SLOOPOrder(settings: Data(mine)) != nil {
            try write(&s, settings, [UInt8](order.written(into: Data(mine))), keepSide: true)
        } else {
            try write(&s, settings, [UInt8](settingsPart.data))
        }
    }

    // MARK: fm1-emu's save file

    /// The sectors of an emulator save (fm1-emu persistence.js exportSave), checked as fm1-emu checks them.
    public static func sectors(ofSave text: String) throws -> Sectors {
        guard let j = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], j["format"] as? String == "fm1-emulator-save",
              let list = j["sectors"] as? [[String: Any]], list.count <= 256 else { throw FM1Error.badPackage("Not an emulator save.") }
        var s: Sectors = [:]
        for x in list {
            guard let at = x["at"] as? Int, at >= 0, at < 1 << 20, at % sectorSize == 0, s[at] == nil,
                  let d = (x["data"] as? String).flatMap({ Data(base64Encoded: $0) }), d.count == sectorSize else {
                throw FM1Error.badPackage("The emulator save is damaged.")
            }
            s[at] = [UInt8](d)
        }
        return s
    }

    /// An emulator save for `package` with these sectors (the package inside, so it imports on its own).
    public static func save(package: Data, sha256: String, name: String, sectors: Sectors) throws -> String {
        guard sectors.count <= 256 else { throw FM1Error.badPackage("Too many flash sectors for an emulator save.") }
        let list = sectors.keys.sorted().map { ["at": $0, "data": Data(sectors[$0]!).base64EncodedString()] as [String: Any] }
        let j: [String: Any] = ["format": "fm1-emulator-save", "version": 1, "hash": sha256, "name": name,
                                "package": package.base64EncodedString(), "sectors": list]
        return String(decoding: try JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]), as: UTF8.self)
    }

    /// The song in an emulator save for SLOOP: over `base` (the emulator's own save for that package, if any).
    public static func emulatorSave(song: DeviceArchive, package: Data, sha256: String, name: String, base: String?) throws -> String {
        var s = try base.map(sectors(ofSave:)) ?? [:]
        try put(song, into: &s)
        return try save(package: package, sha256: sha256, name: name, sectors: s)
    }
}
