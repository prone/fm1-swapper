import Foundation

/// Felucca's complete musical archive (after Felucca web/fm1backup.js): current music,
/// settings, saved music, FM6 banks and sample slots. Requests name whitelisted objects,
/// never flash addresses. Messages: F0 7D 46 4C <cmd> <args...> F7, the reply echoes <cmd>.
public struct FeluccaArchive: Sendable {
    public static let ids: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 32, 33, 34]
    static let idsV2 = ids.filter { $0 != 9 }      // 1.0 ... 1.0.2
    static let idsV1 = idsV2.filter { $0 != 8 }    // before FM6
    static func ids(count: Int) -> [UInt8]? { [ids, idsV2, idsV1].first { $0.count == count } }
    static let chunk = 256
    enum Cmd { static let info: UInt8 = 1, list: UInt8 = 65, get: UInt8 = 66, put: UInt8 = 67 }

    static let labels: [UInt8: String] = [0: "Current music", 1: "Settings", 8: "FM6 patch bank (old)", 9: "FM6 user patches",
                                          32: "Sample slot 1", 33: "Sample slot 2", 34: "Sample slot 3"]
    static func label(_ id: UInt8) -> String { labels[id] ?? "Saved music \(id - 1)" }

    let link: SysExLink
    public init(link: SysExLink) { self.link = link }

    func request(_ cmd: UInt8, _ args: [UInt8], timeout: TimeInterval = 1.2, retries: Int = 0) async throws -> [UInt8] {
        for attempt in 0...retries {
            link.drain()
            guard link.send([0xF0, 0x7D, 0x46, 0x4C, cmd] + args + [0xF7]) else { throw FM1Error.lost("The FM-1 was disconnected.") }
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                guard let d = await link.read(timeout: end.timeIntervalSinceNow) else { break }
                if d.count >= 6, d[1] == 0x7D, d[2] == 0x46, d[3] == 0x4C, d[4] == cmd, d.last == 0xF7 { return Array(d[5..<(d.count - 1)]) }
            }
            if attempt == retries { break }
        }
        throw FM1Error.timeout("Backup timed out. Keep the FM-1 connected and stopped.")
    }

    static func check(_ rc: UInt8) throws {
        guard rc != 0 else { return }
        let m: [UInt8: String] = [1: "Invalid archive object", 2: "Archive data failed validation", 3: "Stop playback first",
                                  4: "Flash write failed", 5: "Start a fresh backup"]
        throw FM1Error.device(m[rc] ?? "Archive error \(rc)")
    }

    /// INFO: whether this Felucca supports complete archives.
    public func supportsArchive() async throws -> (version: String, supported: Bool) {
        let a = try await request(Cmd.info, [])
        guard var pos = a.firstIndex(of: 0) else { throw FM1Error.protocolError("Invalid INFO") }
        let version = String(decoding: a[0..<pos], as: UTF8.self)
        pos += 1
        guard pos < a.count else { return (version, false) }
        let engines = Int(a[pos]); pos += 5
        for _ in 0..<engines {
            guard pos <= a.count, let end = a[pos...].firstIndex(of: 0) else { throw FM1Error.protocolError("Invalid INFO") }
            pos = end + 1
        }
        let ext = pos + 1 < a.count ? Array(a[(pos + 1)...]) : []
        let supported = version.uppercased().hasPrefix("FELUCCA ") && ext.count > 10 && ext[0] == 16 && ext[1] == 0x55 && ext[2] == 1 &&
            ext[4] == 0x4D && ext[5] == 1 && ext[8] == 0x42 && ext[9] == 1 && (ext[10] & 1) != 0
        return (version, supported)
    }

    struct ManifestEntry { let id: UInt8; let size: Int; let crc: UInt32 }

    static func manifest(_ a: [UInt8]) throws -> [ManifestEntry] {
        guard a.count >= 3, a[0] == 1 else { throw FM1Error.protocolError("Unsupported archive protocol") }
        try check(a[1])
        guard let ids = ids(count: Int(a[2])), a.count == 3 + Int(a[2]) * 11 else { throw FM1Error.protocolError("Incomplete archive manifest") }
        return try ids.enumerated().map { i, id in
            let p = 3 + i * 11
            guard a[p] == id else { throw FM1Error.protocolError("Unexpected archive object") }
            let size = Int(try SysExCoding.u32From7(a, at: p + 1)), crc = try SysExCoding.u32From7(a, at: p + 6)
            guard size <= (id >= 32 ? 81920 : 3840), size > 0 || crc == 0 else { throw FM1Error.protocolError("Archive object too large") }
            return ManifestEntry(id: id, size: size, crc: crc)
        }
    }

    public func capture(firmware: String, progress: @escaping ArchiveProgress = { _, _ in }) async throws -> DeviceArchive {
        let info = try await supportsArchive()
        guard info.supported else {
            throw FM1Error.unsupported("This Felucca (\(info.version)) does not support complete backups. Update Felucca first.")
        }
        let manifest = try Self.manifest(try await request(Cmd.list, [], timeout: 3))
        let total = manifest.reduce(0) { $0 + $1.size }
        var done = 0
        var parts: [DeviceArchive.Part] = []
        for o in manifest {
            var bytes = [UInt8](repeating: 0, count: o.size)
            var off = 0
            while off < o.size {
                let size = min(Self.chunk, o.size - off)
                let a = try await request(Cmd.get, [o.id] + SysExCoding.u32To7(UInt32(off)) + [UInt8(size & 127), UInt8(size >> 7)], timeout: 1, retries: 1)
                guard a.count >= 9 else { throw FM1Error.protocolError("Short backup reply") }
                try Self.check(a[1])
                guard a[0] == o.id, try SysExCoding.u32From7(a, at: 2) == off, Int(a[7]) | Int(a[8]) << 7 == size else {
                    throw FM1Error.protocolError("Unexpected backup reply")
                }
                bytes.replaceSubrange(off..<(off + size), with: try SysExCoding.maskUnpack(Array(a[9...]), size: size))
                off += size
                done += size
                progress(done, total)
            }
            guard SysExCoding.crc32(bytes) == o.crc else { throw FM1Error.device("The FM-1 changed during the backup. Stop playback and try again.") }
            parts.append(.init(id: "\(o.id)", label: Self.label(o.id), data: Data(bytes)))
        }
        guard parts.count >= 2, !parts[0].data.isEmpty, !parts[1].data.isEmpty else {
            throw FM1Error.device("The backup is missing the current music or settings.")
        }
        return DeviceArchive(format: "felucca-backup", family: .felucca, firmware: info.version, parts: parts,
                             info: ["identity": firmware])
    }

    public func restore(_ archive: DeviceArchive, progress: @escaping ArchiveProgress = { _, _ in }) async throws {
        // Validate everything before the first destructive request.
        guard archive.format == "felucca-backup", Self.ids(count: archive.parts.count) != nil else {
            throw FM1Error.badPackage("Not a complete Felucca backup.")
        }
        for p in archive.parts where SysExCoding.crc32(p.data) != p.crc { throw FM1Error.badPackage("Backup checksum mismatch.") }
        let info = try await supportsArchive()
        guard info.supported else { throw FM1Error.unsupported("This Felucca (\(info.version)) cannot restore complete backups. Update Felucca first.") }

        let total = archive.totalBytes
        var done = 0
        func ask(_ cmd: UInt8, _ args: [UInt8]) async throws -> [UInt8] { try await request(cmd, args, timeout: 4) }
        func put(_ args: [UInt8]) async throws -> [UInt8] {
            let a = try await ask(Cmd.put, args)
            guard a.count >= 3 else { throw FM1Error.protocolError("Short restore reply") }
            try Self.check(a[2])
            return a
        }
        // Live music last. Other objects commit individually; a disconnect can leave a partial restore.
        let order = Array(archive.parts.dropFirst(2)) + [archive.parts[1], archive.parts[0]]
        for o in order {
            guard let id = UInt8(o.id) else { continue }
            let bytes = [UInt8](o.data)
            if id >= 32 {
                let slot = id - 32
                func checkSample(_ a: [UInt8]) throws {
                    guard a.first == slot, let rc = a.last else { throw FM1Error.protocolError("Unexpected sample reply") }
                    try Self.check(rc)
                }
                if bytes.isEmpty {
                    try checkSample(try await ask(14, [slot]))
                } else {
                    guard bytes.count >= 512 else { throw FM1Error.badPackage("Short sample backup") }
                    try checkSample(try await ask(11, [slot]))
                    var off = 512
                    while off < bytes.count {
                        let c = bytes[off..<min(off + Self.chunk, bytes.count)]
                        try checkSample(try await ask(12, [slot, UInt8(off & 127), UInt8(off >> 7 & 127), UInt8(off >> 14 & 127)] + SysExCoding.maskPack(c)))
                        off += c.count; done += c.count; progress(done, total)
                    }
                    try checkSample(try await ask(13, [slot] + SysExCoding.maskPack(bytes[0..<480])))
                    done += 512; progress(done, total)
                }
                continue
            }
            let begin: [UInt8] = [0, id] + SysExCoding.u32To7(UInt32(bytes.count)) + SysExCoding.u32To7(o.crc)
            if id == 9 {
                // Firmware before 1.0.3 does not take id 9 (rc 1 at begin, nothing written): skip it.
                let a = try await ask(Cmd.put, begin)
                if a.count >= 3, a[2] == 1 { done += bytes.count; progress(done, total); continue }
                guard a.count >= 3 else { throw FM1Error.protocolError("Short restore reply") }
                try Self.check(a[2])
            } else {
                _ = try await put(begin)
            }
            do {
                var off = 0
                while off < bytes.count {
                    let c = bytes[off..<min(off + Self.chunk, bytes.count)]
                    _ = try await put([1, id] + SysExCoding.u32To7(UInt32(off)) + SysExCoding.maskPack(c))
                    off += c.count; done += c.count; progress(done, total)
                }
                _ = try await put([2, id])
            } catch {
                _ = try? await put([3, id])
                throw error
            }
        }
    }

    /// The archive in Felucca's own file format, readable by Felucca's web editor.
    public static func nativeJSON(_ a: DeviceArchive) throws -> Data {
        let objects: [[String: Any]] = a.parts.map { p in
            ["id": Int(p.id) ?? 0, "size": p.data.count, "crc": Int(p.crc), "data": p.data.base64EncodedString()]
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let file: [String: Any] = ["format": "felucca-backup", "version": 1, "firmware": a.firmware,
                                   "created": f.string(from: a.created), "objects": objects]
        return try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])
    }

    /// Import a file saved by Felucca's own installer or editor.
    public static func fromNativeJSON(_ data: Data) throws -> DeviceArchive {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], j["format"] as? String == "felucca-backup",
              let objs = j["objects"] as? [[String: Any]], ids(count: objs.count) != nil else {
            throw FM1Error.badPackage("Not a complete Felucca backup.")
        }
        let parts: [DeviceArchive.Part] = try objs.map { o in
            guard let id = o["id"] as? Int, let s = o["data"] as? String, let d = Data(base64Encoded: s),
                  let crc = o["crc"] as? Int, SysExCoding.crc32(d) == UInt32(crc) else { throw FM1Error.badPackage("Backup checksum mismatch.") }
            return .init(id: "\(id)", label: label(UInt8(id)), data: d)
        }
        let created = (j["created"] as? String).flatMap { s -> Date? in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        } ?? Date()
        return DeviceArchive(format: "felucca-backup", family: .felucca, firmware: j["firmware"] as? String ?? "Felucca",
                             created: created, parts: parts)
    }
}
