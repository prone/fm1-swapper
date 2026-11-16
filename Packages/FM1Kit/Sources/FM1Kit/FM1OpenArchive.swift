// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

/// M-VAVE's open-source FM1 Open firmware: the project transfer protocol in app/transfer.c.
/// F0 7D 'F' 'M' 02 cmd token-lo token-hi <packed data> checksum F7. Packing is the LSB-first
/// 8-in-7 stream; the checksum makes the sum from 7D through the checksum zero mod 128.
/// Replies set bit 6 of cmd and start with a status byte. Exact retries get the cached reply.
public final class FM1OpenArchive: @unchecked Sendable {
    public static let tracks = 8
    public static let timbreBytes = 223
    public static let dx7GroupBytes = 4096
    static let readChunk = 64
    static let writeChunk = 64
    static let sampleWriteChunk = 128

    enum Kind: UInt8 { case project = 0, fmPatch = 1, timbre = 2, tunedProject = 3, dx7Group = 4 }

    let link: SysExLink
    private var token: UInt16 = 1
    public init(link: SysExLink) { self.link = link }

    static func message(cmd: UInt8, token: UInt16, data: [UInt8]) -> [UInt8] {
        var m: [UInt8] = [0xF0, 0x7D, 0x46, 0x4D, 0x02, cmd, UInt8(token & 0x7F), UInt8((token >> 7) & 0x7F)]
        m += SysExCoding.pack7(data)
        let sum = m.dropFirst().reduce(0) { $0 + Int($1) }
        m.append(UInt8((128 - sum % 128) % 128))
        m.append(0xF7)
        return m
    }

    /// Reply payload (status, data...) if `m` is the reply to (cmd, token).
    static func parseReply(_ m: [UInt8], cmd: UInt8, token: UInt16) -> [UInt8]? {
        guard m.count >= 10, m[0] == 0xF0, m.last == 0xF7, m[1] == 0x7D, m[2] == 0x46, m[3] == 0x4D, m[4] == 2,
              m[5] == cmd | 64, m[6] == UInt8(token & 0x7F), m[7] == UInt8((token >> 7) & 0x7F) else { return nil }
        guard m[1..<(m.count - 1)].reduce(0, { $0 + Int($1) }) % 128 == 0 else { return nil }
        guard let d = SysExCoding.unpack7Strict(m[8..<(m.count - 2)]), !d.isEmpty else { return nil }
        return d
    }

    struct Status: Error { let code: UInt8 }

    /// Sends a command; returns the reply data after the status byte. Status 1 ("empty") throws `Status`.
    func command(_ cmd: UInt8, _ data: [UInt8] = [], timeout: TimeInterval = 1.0, retries: Int = 3) async throws -> [UInt8] {
        token = token >= 16383 ? 1 : token + 1
        let t = token
        let msg = Self.message(cmd: cmd, token: t, data: data)
        for _ in 0...retries {
            guard link.send(msg) else { throw FM1Error.lost("The FM-1 was disconnected.") }
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                guard let r = await link.read(timeout: end.timeIntervalSinceNow) else { break }
                guard let d = Self.parseReply(r, cmd: cmd, token: t) else { continue }
                if d[0] == 0 { return Array(d.dropFirst()) }
                if d[0] == 1 { throw Status(code: 1) }
                throw FM1Error.device(Self.describe(d[0]))
            }
        }
        throw FM1Error.timeout("The FM-1 did not answer (FM1 Open command \(cmd)). Keep it connected and stopped.")
    }

    static func describe(_ status: UInt8) -> String {
        let r = 64 - Int(status)
        return r == -7 ? "The FM-1 rejected the data (invalid)." : "FM1 Open error \(r)."
    }

    func read(kind: Kind, target: UInt8) async throws -> [UInt8]? {
        let r: [UInt8]
        do { r = try await command(1, [kind.rawValue, target]) } catch is Status { return nil }
        guard r.count >= 2 else { throw FM1Error.protocolError("Short FM1 Open reply") }
        let size = Int(r[0]) | Int(r[1]) << 8
        var out: [UInt8] = []
        out.reserveCapacity(size)
        while out.count < size {
            let n = min(Self.readChunk, size - out.count)
            let d = try await command(2, [UInt8(out.count & 0xFF), UInt8(out.count >> 8), UInt8(n)])
            guard d.count == n else { throw FM1Error.protocolError("Short FM1 Open chunk") }
            out += d
        }
        return out
    }

    func write(kind: Kind, target: UInt8, bytes: [UInt8]) async throws {
        guard bytes.count <= 0xFFFF else { throw FM1Error.badPackage("A backup part is too large.") }
        _ = try await command(3, [kind.rawValue, target, UInt8(bytes.count & 0xFF), UInt8(bytes.count >> 8)])
        do {
            var at = 0
            while at < bytes.count {
                let c = bytes[at..<min(at + Self.writeChunk, bytes.count)]
                _ = try await command(4, [UInt8(at & 0xFF), UInt8(at >> 8)] + c)
                at += c.count
            }
            _ = try await command(5, SysExCoding.le32Bytes(SysExCoding.crc32(bytes)), timeout: 4)
        } catch {
            _ = try? await command(6)
            throw error
        }
    }

    public func capture(firmware: String, includeSamples: Bool = true,
                        progress: @escaping ArchiveProgress = { _, _ in }) async throws -> DeviceArchive {
        var parts: [DeviceArchive.Part] = []
        var info: [String: String] = ["identity": firmware]

        let status = try await command(0)
        guard status.count >= 3 else { throw FM1Error.protocolError("Short FM1 Open status") }
        let slots = Int(status[1])
        info["currentSlot"] = "\(status[2])"
        let caps = try? await command(22)
        let hasLibrary = (caps?.count ?? 0) >= 4 && caps![3] != 0
        let tuning = (try? await command(21))?.first == 1

        let sampleInfo = includeSamples ? try? await command(11) : nil
        let sampleSize = min(sampleInfo.map { $0.count >= 5 && $0[0] == 2 ? Int(SysExCoding.le32($0, 1)) : 0 } ?? 0, Self.maxSampleBank)
        let total = 4300 + Self.tracks * Self.timbreBytes + (hasLibrary ? 4 * Self.dx7GroupBytes : 0) + sampleSize
        var done = 0
        func step(_ n: Int) { done += n; progress(done, total) }

        var project = tuning ? try await read(kind: .tunedProject, target: 0) : nil
        if project == nil { project = try await read(kind: .project, target: 0) }
        guard let project else { throw FM1Error.device("The FM-1 did not export its current project.") }
        parts.append(.init(id: "project", label: "Current project", data: Data(project)))
        step(4300)

        for t in 0..<Self.tracks {
            if let d = try await read(kind: .timbre, target: UInt8(t)) {
                parts.append(.init(id: "timbre-\(t)", label: "Track \(t + 1) timbre", data: Data(d)))
            }
            step(Self.timbreBytes)
        }
        if hasLibrary {
            for g in 0..<4 {
                if let d = try await read(kind: .dx7Group, target: UInt8(g)) {
                    parts.append(.init(id: "dx7-\(g)", label: "DX7 library group \(["A", "B", "C", "D"][g])", data: Data(d)))
                }
                step(Self.dx7GroupBytes)
            }
        }
        var names: [String] = []
        for s in 0..<min(slots, 32) {
            if let n = try? await command(9, [UInt8(s)]) {
                names.append(String(decoding: n.prefix(12), as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters)))
            } else { names.append("") }
        }
        info["slotNames"] = names.joined(separator: "|")

        if sampleSize > 0 {
            var bank: [UInt8] = []
            bank.reserveCapacity(sampleSize)
            while bank.count < sampleSize {
                let n = min(Self.readChunk, sampleSize - bank.count)
                let d = try await command(15, SysExCoding.le32Bytes(UInt32(bank.count)) + [UInt8(n)])
                guard d.count == n else { throw FM1Error.protocolError("Short sample chunk") }
                bank += d
                step(n)
            }
            parts.append(.init(id: "samples", label: "Sample bank", data: Data(bank)))
        }
        return DeviceArchive(format: "fm1open-backup", family: .fm1Open, firmware: firmware, parts: parts, info: info)
    }

    /// Largest sample bank this app reads or writes (the FM1 Open sample region is about 1 MB).
    static let maxSampleBank = 4 << 20

    /// Every part is known, the right size for its kind and matches its checksum. Imported files are
    /// untrusted, and the sample bank is written first, so nothing is sent until all of it passes.
    public static func validate(_ archive: DeviceArchive) throws {
        guard archive.format == "fm1open-backup" else { throw FM1Error.badPackage("Not an FM1 Open backup.") }
        for p in archive.parts {
            let n = p.data.count
            let ok: Bool
            switch p.id {
            case "project": ok = [4048, 4064, 4264].contains(n)
            case "samples": ok = n > 0 && n <= maxSampleBank
            default:
                if p.id.hasPrefix("timbre-"), let t = Int(p.id.dropFirst(7)), (0..<tracks).contains(t) { ok = n == timbreBytes }
                else if p.id.hasPrefix("dx7-"), let g = Int(p.id.dropFirst(4)), (0..<4).contains(g) { ok = n == dx7GroupBytes }
                else { ok = false }
            }
            guard ok else { throw FM1Error.badPackage("Unexpected part \(p.id) (\(n) bytes) in the backup.") }
            guard SysExCoding.crc32(p.data) == p.crc else { throw FM1Error.badPackage("Backup checksum mismatch.") }
        }
    }

    public func restore(_ archive: DeviceArchive, includeSamples: Bool = true, progress: @escaping ArchiveProgress = { _, _ in }) async throws {
        try Self.validate(archive)
        let total = archive.parts.filter { includeSamples || $0.id != "samples" }.reduce(0) { $0 + $1.data.count }
        var done = 0
        func step(_ n: Int) { done += n; progress(done, total) }

        if includeSamples, let s = archive.part("samples") {
            let bytes = [UInt8](s.data)
            _ = try await command(12, SysExCoding.le32Bytes(UInt32(bytes.count)), timeout: 6)
            do {
                var off = 0
                while off < bytes.count {
                    let c = bytes[off..<min(off + Self.sampleWriteChunk, bytes.count)]
                    _ = try await command(13, SysExCoding.le32Bytes(UInt32(off)) + c, timeout: 3)
                    off += c.count
                    step(c.count)
                }
                _ = try await command(14, timeout: 6)
            } catch {
                _ = try? await command(16)
                throw error
            }
        }
        for g in 0..<4 {
            if let p = archive.part("dx7-\(g)") { try await write(kind: .dx7Group, target: UInt8(g), bytes: [UInt8](p.data)); step(p.data.count) }
        }
        for t in 0..<Self.tracks {
            if let p = archive.part("timbre-\(t)") { try await write(kind: .timbre, target: UInt8(t), bytes: [UInt8](p.data)); step(p.data.count) }
        }
        // The current project last; kind 0 accepts the plain, legacy and tuned sizes.
        if let p = archive.part("project") { try await write(kind: .project, target: 0, bytes: [UInt8](p.data)); step(p.data.count) }
    }

    /// DX7 library groups as standard 32-voice bank SysEx (Dexed, DX7 librarians, FM1 Open's own import).
    static func exportFiles(_ a: DeviceArchive) -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        for g in 0..<4 {
            guard let p = a.part("dx7-\(g)"), p.data.count == dx7GroupBytes else { continue }
            out.append(("FM1-DX7-\(["A", "B", "C", "D"][g])-\(DeviceArchive.day(a.created)).syx", Data(dx7BankSysEx(p.data))))
        }
        return out
    }

    public static func dx7BankSysEx(_ packed: Data) -> [UInt8] {
        let body = [UInt8](packed)
        let sum = body.reduce(0) { $0 + Int($1) }
        return [0xF0, 0x43, 0x00, 0x09, 0x20, 0x00] + body + [UInt8((128 - sum % 128) % 128), 0xF7]
    }
}
