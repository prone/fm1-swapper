// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments (Felucca web/fm1pkg.js and tools/fm1_install.py)
// Copyright (C) 2026 FM-1 Swapper contributors (Swift port, modified)
import CryptoKit
import Foundation

/// An FM-1 firmware package (.fwsc). Every FM-1 firmware (official, FM1 Open,
/// Felucca, and the community firmwares) ships in this container and installs
/// through the same update protocol.
public struct FirmwarePackage: Sendable, Equatable {
    static let blocks = 20, blockSize = 0x30, keep = 0x2F

    public let raw: Data
    /// Identity the device reports once this package is installed, e.g. "FM-1_918".
    public let product: String
    public let sha256: String

    public init(data: Data) throws {
        guard data.count >= Self.blocks * Self.blockSize + 1024 else {
            throw FM1Error.badPackage("This is not an FM-1 firmware package (.fwsc): the file is too short.")
        }
        raw = data
        product = Self.productOf(data)
        guard Self.identityPattern.firstMatch(in: product, range: NSRange(product.startIndex..., in: product)) != nil else {
            throw FM1Error.badPackage("This is not an FM-1 firmware package (.fwsc): no package identity found.")
        }
        sha256 = sha256Hex(data)
    }

    static let identityPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9\-]+_\d+$"#)

    public var model: String { String(product.split(separator: "_").first ?? "") }
    public var identity: DeviceIdentity? { DeviceIdentity(text: product) }
    public var stock: StockFirmware? { StockFirmware.all.first { $0.sha256 == sha256 } }

    /// The package identity: one marker byte after each of the first 20 blocks.
    public static func productOf(_ d: Data) -> String {
        let b = [UInt8](d.prefix(blocks * blockSize))
        var s = ""
        for i in 0..<blocks {
            let m = b[i * blockSize + keep]
            if m != 0x7D { s.unicodeScalars.append(Unicode.Scalar((Int(m) - i - 1) & 0xFF)!) }
        }
        return s
    }

    /// The image the device addresses during an update: the package without the 20 marker bytes.
    public var logicalImage: [UInt8] {
        let b = [UInt8](raw)
        var out: [UInt8] = []
        out.reserveCapacity(b.count - Self.blocks)
        for i in 0..<Self.blocks { out.append(contentsOf: b[(i * Self.blockSize)..<(i * Self.blockSize + Self.keep)]) }
        out.append(contentsOf: b[(Self.blocks * Self.blockSize)...])
        return out
    }
}

/// The unmodified official M-VAVE releases (FM-1.fwsc), pinned by digest.
public struct StockFirmware: Sendable, Equatable {
    public let version: String
    public let size: Int
    public let sha256: String
    public let product: String

    /// Official V15, the version the app installs as a clean base.
    public static var v15: StockFirmware { all.first { $0.version == "V15" }! }

    public static let all: [StockFirmware] = [
        .init(version: "V15", size: 699_956, sha256: "db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a", product: "FM-1_015"),
        .init(version: "V16", size: 718_196, sha256: "d017fb65e70aca97ee29d944470c3515a74581df5c0576bf70de917c7b2b61d5", product: "FM-1_016"),
    ]
}

/// The identity string an FM-1 answers the handshake with: "<model>_<number>".
public struct DeviceIdentity: Sendable, Hashable, Codable, CustomStringConvertible {
    public let text: String
    public let model: String
    public let number: Int

    public init?(text: String) {
        let parts = text.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let n = Int(parts[1]), parts[1].allSatisfy(\.isNumber) else { return nil }
        self.text = text
        model = String(parts[0])
        number = n
    }

    public var description: String { text }
    /// The update loader announces itself as "ota-<model>_<n>".
    public var isLoader: Bool { model.lowercased().hasPrefix("ota-") }
    public var baseModel: String { isLoader ? String(model.dropFirst(4)) : model }

    /// Best guess at which firmware family this is, from the number ranges the projects use.
    public var family: FirmwareFamily {
        guard !isLoader else { return .updateLoader }
        switch number {
        case 1..<100: return .official
        case 900..<1000: return .felucca
        case 8_000_000..<9_000_000: return .fm1Open
        default: return .unknown
        }
    }
}

public enum FirmwareFamily: String, Sendable, Codable, CaseIterable {
    case official, fm1Open, felucca, updateLoader, unknown

    public var displayName: String {
        switch self {
        case .official: "M-VAVE official"
        case .fm1Open: "FM1 Open (official open-source)"
        case .felucca: "Felucca (or a Felucca fork)"
        case .updateLoader: "Update loader (mid-install)"
        case .unknown: "Community firmware"
        }
    }

    /// Whether this app can read the firmware's saved work over MIDI.
    public var supportsArchive: Bool { self == .felucca || self == .fm1Open }
}

public extension Sequence<UInt8> {
    /// Lower-case hex, two digits a byte (checksums, ids).
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    /// Upper-case hex bytes with spaces between, as MIDI monitors show them.
    var spacedHex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// A file's SHA-256 in hex (the way packages are named and checked everywhere in the app).
public func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).hex }
