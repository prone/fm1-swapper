// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

/// A firmware's saved work, read from the device over MIDI. Each firmware family
/// has its own format; this container holds the raw parts so they can be stored,
/// synced and written back to the same family later.
public struct DeviceArchive: Codable, Sendable, Equatable {
    public struct Part: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var data: Data
        public var crc: UInt32
        public init(id: String, label: String, data: Data) {
            self.id = id; self.label = label; self.data = data
            crc = SysExCoding.crc32(data)
        }
    }

    public var format: String
    public var family: FirmwareFamily
    public var firmware: String
    public var created: Date
    public var parts: [Part]
    public var info: [String: String]

    public init(format: String, family: FirmwareFamily, firmware: String, created: Date = Date(), parts: [Part], info: [String: String] = [:]) {
        self.format = format; self.family = family; self.firmware = firmware
        self.created = created; self.parts = parts; self.info = info
    }

    public var totalBytes: Int { parts.reduce(0) { $0 + $1.data.count } }
    public func part(_ id: String) -> Part? { parts.first { $0.id == id } }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> DeviceArchive {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(DeviceArchive.self, from: data)
    }

    /// Files to hand to other tools (e.g. Felucca's editor JSON, DX7 banks as .syx).
    public func exportFiles() throws -> [(name: String, data: Data)] {
        if format == SLOOPArchive.format { return [] }
        switch family {
        case .felucca: return [("Felucca-backup-\(Self.day(created)).json", try FeluccaArchive.nativeJSON(self))]
        case .fm1Open: return FM1OpenArchive.exportFiles(self)
        default: return []
        }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

public typealias ArchiveProgress = @Sendable (_ done: Int, _ total: Int) -> Void

/// Reads and writes saved work for the firmware families that expose it over MIDI.
public enum Archives {
    /// Capture everything the connected firmware can export. Throws `.unsupported` for other firmwares.
    public static func capture(_ device: ConnectedDevice, includeSamples: Bool = true,
                               progress: @escaping ArchiveProgress = { _, _ in }) async throws -> DeviceArchive {
        switch device.identity.family {
        case .felucca:
            // SLOOP and its forks answer as Felucca but have their own backup commands.
            let s = SLOOPArchive(link: device.link)
            if await s.supported() { return try await s.capture(firmware: device.identity.text, progress: progress) }
            return try await FeluccaArchive(link: device.link).capture(firmware: device.identity.text, progress: progress)
        case .fm1Open: return try await FM1OpenArchive(link: device.link).capture(firmware: device.identity.text, includeSamples: includeSamples, progress: progress)
        case .updateLoader: throw FM1Error.unsupported("The FM-1 is in update mode, so nothing can be backed up. Finish the install first.")
        case .official:
            throw FM1Error.unsupported("M-VAVE's official firmware has no backup protocol. Its patterns and settings stay on the device, and are usually erased when other firmware is installed.")
        case .unknown:
            // Unknown numbers can still be Felucca forks: ask.
            if let a = try? await FeluccaArchive(link: device.link).capture(firmware: device.identity.text, progress: progress) { return a }
            let s = SLOOPArchive(link: device.link)
            if await s.supported() { return try await s.capture(firmware: device.identity.text, progress: progress) }
            throw FM1Error.unsupported("\(device.identity.text) has no backup protocol this app knows. Save anything important on the device, or use the firmware's own editor.")
        }
    }

    public static func restore(_ archive: DeviceArchive, to device: ConnectedDevice, includeSamples: Bool = true,
                               progress: @escaping ArchiveProgress = { _, _ in }) async throws {
        if archive.format == SLOOPArchive.format {
            return try await SLOOPArchive(link: device.link).restore(archive, progress: progress)
        }
        switch archive.family {
        case .felucca:
            try await FeluccaArchive(link: device.link).restore(archive, includeSamples: includeSamples, progress: progress)
        case .fm1Open:
            guard device.identity.family == .fm1Open else {
                throw FM1Error.unsupported("This backup is for FM1 Open; the FM-1 is running \(device.identity.text).")
            }
            try await FM1OpenArchive(link: device.link).restore(archive, includeSamples: includeSamples, progress: progress)
        default:
            throw FM1Error.unsupported("Backups of this kind cannot be written back.")
        }
    }
}
