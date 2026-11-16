// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

/// Byte codecs used by the FM-1 SysEx protocols.
public enum SysExCoding {
    /// LSB-first bit stream of 8-bit bytes packed into 7-bit MIDI data
    /// (the update protocol and the FM1 Open transfer protocol).
    public static func pack7(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 8 / 7 + 1)
        var acc: UInt32 = 0, nb: UInt32 = 0
        for b in data {
            acc |= UInt32(b) << nb
            nb += 8
            while nb >= 7 {
                out.append(UInt8(acc & 0x7F))
                acc >>= 7
                nb -= 7
            }
        }
        if nb > 0 { out.append(UInt8(acc & 0x7F)) }
        return out
    }

    /// Inverse of `pack7`. Trailing partial bits are dropped.
    public static func unpack7(_ data: some Sequence<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var acc: UInt32 = 0, nb: UInt32 = 0
        for b in data {
            acc |= UInt32(b & 0x7F) << nb
            nb += 7
            while nb >= 8 {
                out.append(UInt8(acc & 0xFF))
                acc >>= 8
                nb -= 8
            }
        }
        return out
    }

    /// Strict `unpack7`: nil when leftover bits are non-zero or a full 7-bit group is left over.
    public static func unpack7Strict(_ data: some Sequence<UInt8>) -> [UInt8]? {
        var out: [UInt8] = []
        var acc: UInt32 = 0, nb: UInt32 = 0
        for b in data {
            if b > 0x7F { return nil }
            acc |= UInt32(b) << nb
            nb += 7
            if nb >= 8 {
                out.append(UInt8(acc & 0xFF))
                acc >>= 8
                nb -= 8
            }
        }
        if acc != 0 || nb >= 7 { return nil }
        return out
    }

    /// Felucca archive packing: groups of 7 bytes, each preceded by a mask of their high bits.
    public static func maskPack(_ bytes: some Collection<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        let a = Array(bytes)
        var off = 0
        while off < a.count {
            let chunk = a[off..<min(off + 7, a.count)]
            var mask: UInt8 = 0
            for (i, b) in chunk.enumerated() { mask |= (b >> 7) << UInt8(i) }
            out.append(mask)
            out.append(contentsOf: chunk.map { $0 & 0x7F })
            off += 7
        }
        return out
    }

    public static func maskUnpack(_ a: [UInt8], size: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        var i = 0, j = 0
        while j < size {
            let n = min(7, size - j)
            guard i < a.count else { throw FM1Error.protocolError("Invalid archive bytes") }
            let mask = a[i]; i += 1
            if mask >> UInt8(n) != 0 { throw FM1Error.protocolError("Invalid archive bytes") }
            for k in 0..<n {
                guard i < a.count, a[i] <= 127 else { throw FM1Error.protocolError("Short archive chunk") }
                out[j] = a[i] | (((mask >> UInt8(k)) & 1) << 7)
                j += 1; i += 1
            }
        }
        if i != a.count { throw FM1Error.protocolError("Trailing archive bytes") }
        return out
    }

    /// 32-bit number as five 7-bit groups (Felucca archive).
    public static func u32To7(_ n: UInt32) -> [UInt8] {
        (0..<5).map { i in UInt8((n >> (UInt32(i) * 7)) & (i == 4 ? 15 : 127)) }
    }

    public static func u32From7(_ a: [UInt8], at off: Int = 0) throws -> UInt32 {
        guard a.count >= off + 5, a[off + 4] <= 15 else { throw FM1Error.protocolError("Invalid archive number") }
        return UInt32(a[off]) | UInt32(a[off + 1]) << 7 | UInt32(a[off + 2]) << 14 | UInt32(a[off + 3]) << 21 | UInt32(a[off + 4]) << 28
    }

    /// Standard CRC-32 (IEEE, reflected 0xEDB88320). Matches Felucca's bkCrc and FM1 Open's ~groove_crc32(~0, ...).
    public static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return ~c
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    static func le32(_ a: [UInt8], _ o: Int) -> UInt32 {
        UInt32(a[o]) | UInt32(a[o + 1]) << 8 | UInt32(a[o + 2]) << 16 | UInt32(a[o + 3]) << 24
    }

    static func le32Bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}

public enum FM1Error: LocalizedError, Equatable {
    case notFound
    case wrongModel(device: String, package: String)
    case stopped(String)
    case lost(String)
    case noLoader
    case noReturn
    case mismatch(String)
    case badRequest(String)
    case badPackage(String)
    case timeout(String)
    case protocolError(String)
    case unsupported(String)
    case device(String)
    /// The firmware or its update loader answered nothing: most often a firmware that doesn't know the newer
    /// FM-1 flash chip (0xB36014). `inLoader`: the FM-1 is in update mode. See docs/flash-chips.md.
    case refused(inLoader: Bool)

    public static let rescueURL = "https://thefirmwarehub.com/tools/rescue/#chip"

    public var errorDescription: String? {
        switch self {
        case .refused(false): "The FM-1's current firmware didn't start the update. Nothing was written. On a newer FM-1 (flash chip 0xB36014), a firmware that only knows the older chip can't update itself, and trying again won't help: the way out is download mode and M-Flasher (\(FM1Error.rescueURL)). Otherwise, check that this firmware supports updates over USB."
        case .refused(true): "The update loader didn't start writing. The FM-1 is in update mode and nothing new was written. On a newer FM-1 (flash chip 0xB36014), this package's loader may not support the chip; installing it again won't help. Power-cycle the FM-1, then follow the rescue guide (download mode and M-Flasher): \(FM1Error.rescueURL)"
        case .notFound: "FM-1 not found. Check the USB cable, and close any other app using the FM-1."
        case let .wrongModel(d, p): "The device is \(d), but the package is for \(p)."
        case let .stopped(m), let .lost(m), let .badRequest(m), let .badPackage(m), let .timeout(m),
             let .protocolError(m), let .unsupported(m), let .device(m): m
        case .noLoader: "The update loader did not appear. Replug the USB cable and press Install again: the FM-1 stays in update mode until the write finishes."
        case .noReturn: "The FM-1 did not come back after the update. Power-cycle it."
        case let .mismatch(id): "Installed, but the FM-1 now reports \(id)."
        }
    }
}
