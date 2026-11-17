// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import Foundation
import SwiftData

// SwiftData models. They follow CloudKit's rules (every property has a default, relationships
// are optional, no unique constraints) so the library can sync through the iCloud private
// database when sync is turned on (FM1_CLOUD_SYNC in project.yml; off by default).

enum TryStatus: String, CaseIterable, Codable, Identifiable {
    case notTried, tried, favorite, keeper, notForMe
    var id: String { rawValue }
    var label: String {
        switch self {
        case .notTried: "Not tried"
        case .tried: "Tried"
        case .favorite: "Favorite"
        case .keeper: "Daily driver"
        case .notForMe: "Not for me"
        }
    }
    var symbol: String {
        switch self {
        case .notTried: "circle.dashed"
        case .tried: "checkmark.circle"
        case .favorite: "star.fill"
        case .keeper: "heart.fill"
        case .notForMe: "hand.thumbsdown"
        }
    }
}

@Model
final class Firmware {
    var name: String = ""
    var author: String = ""
    var version: String = ""
    /// Identity the FM-1 reports with this firmware installed, e.g. "FM-1_918".
    var product: String = ""
    var sha256: String = ""
    var familyRaw: String = FirmwareFamily.unknown.rawValue
    var sourceURL: String = ""
    var repo: String = ""
    var notes: String = ""
    /// One- or two-sentence description (from the catalog or the GitHub repo, editable).
    var summary: String = ""
    var rating: Int = 0
    var statusRaw: String = TryStatus.notTried.rawValue
    var addedAt: Date = Date()
    var fileName: String = ""
    @Attribute(.externalStorage) var packageData: Data?
    /// Scalars kept beside the blob and relationships so lists never load the package or fault in history.
    var packageSize: Int = 0
    var lastInstalledAt: Date?
    var installCount: Int = 0
    @Relationship(deleteRule: .nullify, inverse: \InstallEvent.firmware) var installs: [InstallEvent]? = []
    @Relationship(deleteRule: .cascade, inverse: \Backup.firmware) var backups: [Backup]? = []
    @Relationship(deleteRule: .cascade, inverse: \EmulatorSave.firmware) var emulatorSaves: [EmulatorSave]? = []
    @Relationship(deleteRule: .cascade, inverse: \ControllerProfile.firmware) var controllerProfiles: [ControllerProfile]? = []

    init(name: String, product: String) {
        self.name = name
        self.product = product
        familyRaw = (DeviceIdentity(text: product)?.family ?? .unknown).rawValue
    }

    var family: FirmwareFamily { FirmwareFamily(rawValue: familyRaw) ?? .unknown }
    var status: TryStatus {
        get { TryStatus(rawValue: statusRaw) ?? .notTried }
        set { statusRaw = newValue.rawValue }
    }
    var hasPackage: Bool { packageSize > 0 }
    /// Decodes and hashes the whole file: only for installing, never in list rows.
    var package: FirmwarePackage? { packageData.flatMap { try? FirmwarePackage(data: $0) } }
    var isStock: Bool { StockFirmware.all.contains { $0.sha256 == sha256 } }
    /// The device model the package is for ("FM-1"), from its identity.
    var packageModel: String { String(product.split(separator: "_").first ?? "") }

    func setPackage(_ data: Data?) {
        packageData = data
        packageSize = data?.count ?? 0
    }

    func recordInstall(at date: Date = Date()) {
        lastInstalledAt = date
        installCount += 1
    }

    /// Fills the scalar fields for records made before they existed (runs once per record).
    func migrateScalars() {
        if packageSize == 0, let d = packageData { packageSize = d.count }
        if lastInstalledAt == nil, let last = (installs ?? []).filter(\.success).map(\.date).max() {
            lastInstalledAt = last
            installCount = (installs ?? []).filter(\.success).count
        }
    }

    var successfulInstalls: [InstallEvent] { (installs ?? []).filter(\.success).sorted { $0.date < $1.date } }
    var firstInstalled: Date? { successfulInstalls.first?.date }
    var lastInstalled: Date? { lastInstalledAt }
    var sortedBackups: [Backup] { (backups ?? []).sorted { $0.date > $1.date } }
    /// The latest full backup to write back after an install (saved SLOOP songs don't count).
    var latestRestorableBackup: Backup? { sortedBackups.first { $0.isRestorable && !$0.isSong } }
    /// Saved SLOOP songs, newest first.
    var songs: [Backup] { sortedBackups.filter(\.isSong) }
    /// The emulator treats a file named FM-1.fwsc as M-VAVE's own firmware.
    var emulatorFileName: String { isStock ? "FM-1.fwsc" : "\(name.replacingOccurrences(of: "/", with: "-")).fwsc" }
}

@Model
final class InstallEvent {
    var date: Date = Date()
    var fromIdentity: String = ""
    var toIdentity: String = ""
    var success: Bool = false
    var message: String = ""
    var duration: Double = 0
    var backupTaken: Bool = false
    var restored: Bool = false
    var deviceName: String = ""
    var firmware: Firmware?

    init(firmware: Firmware?, from: String, to: String) {
        self.firmware = firmware
        fromIdentity = from
        toIdentity = to
    }
}

@Model
final class Backup {
    var date: Date = Date()
    var identity: String = ""
    var familyRaw: String = FirmwareFamily.unknown.rawValue
    var label: String = ""
    var notes: String = ""
    /// "device" (read over MIDI), "file" (imported by the user), "auto" (taken before an install).
    var kindRaw: String = "device"
    var fileName: String = ""
    var sizeBytes: Int = 0
    var partsSummary: String = ""
    @Attribute(.externalStorage) var payload: Data?
    var firmware: Firmware?

    init(label: String, identity: String, family: FirmwareFamily, kind: String) {
        self.label = label
        self.identity = identity
        familyRaw = family.rawValue
        kindRaw = kind
    }

    var family: FirmwareFamily { FirmwareFamily(rawValue: familyRaw) ?? .unknown }
    /// Device and imported archives can be written back; attached files can't. (Cheap: no decoding.)
    var isRestorable: Bool { kindRaw != "file" }
    /// A saved SLOOP song (part of the SLOOP backup: the loop, the song order, sections A–D).
    var isSong: Bool { kindRaw == "song" }
    /// The device archive, when this backup can be written back over MIDI.
    var archive: DeviceArchive? {
        guard kindRaw != "file", let payload else { return nil }
        return try? DeviceArchive.decode(payload)
    }

    /// Puts an edited archive in place of this one (an edited SLOOP song), keeping its name and firmware.
    func replace(with archive: DeviceArchive) throws {
        payload = try archive.encoded()
        date = archive.created
        sizeBytes = archive.totalBytes
        partsSummary = archive.parts.filter { !$0.data.isEmpty }.map(\.label).joined(separator: ", ")
    }

    static func from(_ archive: DeviceArchive, label: String, kind: String) throws -> Backup {
        let b = Backup(label: label, identity: archive.info["identity"] ?? archive.firmware, family: archive.family, kind: kind)
        try b.replace(with: archive)
        return b
    }
}

/// A snapshot of the emulator's saved flash (settings, patches) for one firmware package:
/// fm1-emu's own .fm1save backup format, kept here so it syncs and survives reinstalls.
@Model
final class EmulatorSave {
    var date: Date = Date()
    var label: String = ""
    /// SHA-256 of the firmware package the save belongs to (fm1-emu keys saves by it).
    var packageSHA: String = ""
    var firmwareName: String = ""
    /// The latest automatic snapshot taken when closing the emulator (one per package).
    var isAuto: Bool = false
    @Attribute(.externalStorage) var payload: Data?
    var firmware: Firmware?

    init(label: String, packageSHA: String, firmwareName: String, payload: Data, isAuto: Bool) {
        self.label = label
        self.packageSHA = packageSHA
        self.firmwareName = firmwareName
        self.payload = payload
        self.isAuto = isAuto
    }

    var fileName: String { "\(firmwareName.replacingOccurrences(of: "/", with: "-")) \(date.formatted(.iso8601.year().month().day())).fm1save" }
}

/// A pad/knob mapping for one controller model, either the model's default (firmware nil)
/// or the one used while a particular firmware is on the FM-1.
@Model
final class ControllerProfile {
    var name: String = ""
    var modelRaw: String = ControllerModel.smcPad.rawValue
    var updatedAt: Date = Date()
    var mappingData: Data?
    var firmware: Firmware?
    /// The slice-sampler kit the pads play with this layout.
    var kit: SampleKit?

    init(name: String, mapping: ControllerMapping, firmware: Firmware?) {
        self.name = name
        modelRaw = mapping.model.rawValue
        mappingData = mapping.encoded()
        self.firmware = firmware
    }

    var model: ControllerModel { ControllerModel(rawValue: modelRaw) ?? .generic }
    var mapping: ControllerMapping {
        get { mappingData.flatMap(ControllerMapping.decode) ?? .defaultLayout(for: model, name: name) }
        set { mappingData = newValue.encoded(); updatedAt = Date() }
    }
}

extension [Firmware] {
    /// The library entry for the firmware the FM-1 runs now (the most recently installed one with its identity).
    func installed(_ id: DeviceIdentity?) -> Firmware? {
        guard let id, !id.isLoader else { return nil }
        return filter { $0.product == id.text }.max { ($0.lastInstalled ?? .distantPast) < ($1.lastInstalled ?? .distantPast) }
    }
}

extension ModelContext {
    /// The library entry for whatever the device reports, creating a placeholder if needed.
    /// Keeps an archive as a backup of `firmware` (a song, a device backup, one taken before an install) and saves.
    @discardableResult
    func addBackup(_ archive: DeviceArchive, label: String, kind: String, firmware: Firmware?) throws -> Backup {
        let b = try Backup.from(archive, label: label, kind: kind)
        b.firmware = firmware
        insert(b)
        try save()
        return b
    }

    func firmware(forIdentity id: DeviceIdentity) -> Firmware {
        let text = id.text
        let all = (try? fetch(FetchDescriptor<Firmware>(predicate: #Predicate { $0.product == text }))) ?? []
        if let f = all.max(by: { ($0.lastInstalled ?? $0.addedAt) < ($1.lastInstalled ?? $1.addedAt) }) { return f }
        let name: String = switch id.family {
        case .official: "M-VAVE official V\(id.number)"
        case .felucca: "Felucca \(id.number / 10 % 10).\(id.number % 10)"
        case .fm1Open: "FM1 Open V\(id.number % 1000)"
        default: "Firmware \(id.text)"
        }
        let f = Firmware(name: name, product: text)
        f.notes = "Added automatically when the FM-1 reported \(text)."
        if id.family == .official { f.author = "M-VAVE"; f.sourceURL = "https://www.m-vave.com/download" }
        insert(f)
        return f
    }
}

/// A whole-flash image (1 MB on the FM-1) read through m-bootloader's MIDI mode, checked against the chip's CRC-32.
/// M-Flasher can restore it from a computer. CloudKit-compatible: every property has a default.
@Model
final class FlashImage {
    var id: UUID = UUID()
    var date: Date = Date()
    var unitID: String = ""
    var jedec: Int = 0
    var chipKey: Int = 0
    var firmware: String = ""
    var mbootVersion: String = ""
    var size: Int = 0
    var crc: Int = 0
    @Attribute(.externalStorage) var data: Data?

    init(info: MBootInfo, firmware: String, data: Data) {
        unitID = info.unitID; jedec = Int(info.jedec); chipKey = Int(info.chipKey); mbootVersion = info.version
        self.firmware = firmware; self.data = data; size = data.count; crc = Int(SysExCoding.crc32(data))
    }

    var fileName: String { "fm1-flash-\(unitID.prefix(8))-\(date.formatted(.iso8601.year().month().day())).bin" }
}
