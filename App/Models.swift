import FM1Kit
import Foundation
import SwiftData

// SwiftData models, synced through the iCloud private database (CloudKit) so the
// iPhone and iPad share one library. CloudKit rules: every property has a default,
// relationships are optional, no unique constraints.

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
    var hasPackage: Bool { packageData != nil }
    var package: FirmwarePackage? { packageData.flatMap { try? FirmwarePackage(data: $0) } }

    var successfulInstalls: [InstallEvent] { (installs ?? []).filter(\.success).sorted { $0.date < $1.date } }
    var firstInstalled: Date? { successfulInstalls.first?.date }
    var lastInstalled: Date? { successfulInstalls.last?.date }
    var sortedBackups: [Backup] { (backups ?? []).sorted { $0.date > $1.date } }
    var latestRestorableBackup: Backup? { sortedBackups.first { $0.archive != nil } }
    var displayVersion: String { version.isEmpty ? product : version }
    /// The emulator treats a file named FM-1.fwsc as M-VAVE's own firmware.
    var emulatorFileName: String { package?.stock != nil ? "FM-1.fwsc" : "\(name.replacingOccurrences(of: "/", with: "-")).fwsc" }
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
    /// The device archive, when this backup can be written back over MIDI.
    var archive: DeviceArchive? {
        guard kindRaw != "file", let payload else { return nil }
        return try? DeviceArchive.decode(payload)
    }

    static func from(_ archive: DeviceArchive, label: String, kind: String) throws -> Backup {
        let b = Backup(label: label, identity: archive.info["identity"] ?? archive.firmware, family: archive.family, kind: kind)
        b.date = archive.created
        b.payload = try archive.encoded()
        b.sizeBytes = archive.totalBytes
        b.partsSummary = archive.parts.filter { !$0.data.isEmpty }.map(\.label).joined(separator: ", ")
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

extension ModelContext {
    /// The library entry for whatever the device reports, creating a placeholder if needed.
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
