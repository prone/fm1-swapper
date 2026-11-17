// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

/// m-bootloader's MIDI mode (github.com/jvitkauskas/m-bootloader, MIT; docs/SPEC.md §11.6–11.7, src/midi_update.c):
/// the bootloader, or its RAM "stage" helper sent as a normal update, answers the update protocol as `ota-FM-1_900`
/// and also reports the flash chip and serves raw flash reads. Mirrors web/src/fm1kit/mboot.ts.
///
/// SAFETY: M-VAVE's stock update service uses the same frame, and on some versions its 0x21 erases a flash sector with
/// no check; 0x21 and 0x23 differ by one bit and the checksum doesn't cover the command. Reads are only possible
/// through an `MBoot`, and the only way to get one is `MBoot.probe`, which requires the `MBOOT` answer to 0x12.
public enum MBootProtocol {
    public static let version = "2.4-395e6cc"
    public static let restart: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7E, 0xF7]
    public static let downloadMode: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7D, 0xF7]
    public static let readMax = 512
    public static let oldChip: UInt32 = 0x856014, newChip: UInt32 = 0xB36014

    /// The helper packages we ship (App/MBoot, web/public/mboot), pinned to m-bootloader's release SHA256SUMS.
    public enum Helper: String, Sendable, CaseIterable {
        case stage = "fm1-stage", listed = "fm1-stage-listed"
        public var sha256: String {
            switch self {
            case .stage: "e861ad2ec1a7fe0088e8281d566442acb93a8b7e2dba41437e4edaa16ff25a6c"
            case .listed: "7c14b0cd3159c1c1ef6e93d3f3394a572ab03ad66093a3f561166b6792ed3606"
            }
        }
    }

    /// Which helper a running firmware accepts, or nil when it isn't known to accept one (spec §11.7): M-VAVE's firmware
    /// takes the plain one; Felucca-family firmware only the "listed" one. Community firmware outside the number ranges
    /// (Melodee `FM-1_91061`, AMB-1 `FM-1_7010302`, X0X `FM-1_9010202`) is almost all Felucca-based, so it gets the
    /// listed one too; firmware with M-VAVE's update service refuses that package without writing anything. FM1 Open
    /// isn't sent the message until tested.
    public static func helper(for family: FirmwareFamily) -> Helper? {
        switch family {
        case .official: .stage
        case .felucca, .unknown: .listed
        default: nil
        }
    }

    public static func frame(_ cmd: UInt8, _ body: [UInt8] = []) -> [UInt8] {
        let n = body.count
        var sum = 0
        for b in body { sum += Int(b) }
        var unpacked: [UInt8] = [0, 0x59, cmd, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), 0]
        unpacked += body
        unpacked.append(UInt8(~sum & 0xFF))
        var out: [UInt8] = [0xF0]
        out += SysExCoding.pack7(unpacked)
        out.append(0xF7)
        return out
    }

    public static func parseFrame(_ pkt: [UInt8]) -> (cmd: UInt8, body: [UInt8])? {
        guard pkt.count >= 3, pkt.first == 0xF0, pkt.last == 0xF7 else { return nil }
        let d = SysExCoding.unpack7(pkt[1..<(pkt.count - 1)])
        guard d.count >= 7, d[0] == 0, d[1] == 0x59, d[5] == 0 else { return nil }
        let length = Int(d[3]) | (Int(d[4]) << 8)
        guard length == d.count - 7 else { return nil }
        var sum = 0
        for b in d[6...] { sum += Int(b) }
        guard sum & 0xFF == 0xFF else { return nil }
        return (d[2], Array(d[6..<(d.count - 1)]))
    }

    public static func chip(_ jedec: UInt32) -> String {
        jedec == oldChip ? "older unit" : jedec == newChip ? "newer unit" : "unknown kind"
    }
}

public struct MBootInfo: Sendable, Hashable, Codable {
    public var protocolVersion: Int
    public var isStage: Bool
    public var flags: Int
    public var chipKey: UInt16
    public var capacity: Int
    public var jedec: UInt32
    public var unitID: String
    public var version: String

    public init?(body b: [UInt8]) {
        guard b.count >= 29, String(decoding: b[0..<5], as: UTF8.self) == "MBOOT" else { return nil }
        protocolVersion = Int(b[5]); isStage = b[6] == 2; flags = Int(b[7]); chipKey = UInt16(b[8]) | UInt16(b[9]) << 8
        capacity = Int(SysExCoding.le32(b, 10)); jedec = SysExCoding.le32(b, 14)
        unitID = b[18..<26].map { String(format: "%02x", $0) }.joined()
        let end = b[28...].firstIndex(of: 0) ?? b.count
        version = String(decoding: b[28..<end], as: UTF8.self)
    }
    public var jedecHex: String { String(format: "0x%06X", jedec) }
    public var isNewerChip: Bool? { jedec == MBootProtocol.newChip ? true : jedec == MBootProtocol.oldChip ? false : nil }
}

public final class MBoot: @unchecked Sendable {
    public let link: SysExLink
    public let info: MBootInfo
    private init(link: SysExLink, info: MBootInfo) { self.link = link; self.info = info }

    /// Asks what's answering. Only m-bootloader (or its helper) answers `MBOOT`; anything else gives nil.
    public static func probe(_ link: SysExLink, timeout: TimeInterval = 1.5) async -> MBoot? {
        link.drain()
        guard link.send(MBootProtocol.frame(0x12)) else { return nil }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            guard let p = await link.read(timeout: end.timeIntervalSinceNow) else { break }
            guard let f = MBootProtocol.parseFrame(p) else { continue }
            if f.cmd == 0x12 { return MBootInfo(body: f.body).map { MBoot(link: link, info: $0) } }
            if f.cmd == 0 { return nil }                  // a refusal: not ours
        }
        return nil
    }

    private func ask(_ cmd: UInt8, _ addr: Int, _ count: Int) async throws -> [UInt8] {
        guard count >= 1, addr >= 0, addr + count <= info.capacity, cmd != 0x23 || count <= MBootProtocol.readMax else {
            throw FM1Error.protocolError("Read outside the flash.")
        }
        var body: [UInt8] = [0]
        body += SysExCoding.le32Bytes(UInt32(addr))
        body += [UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF), UInt8((count >> 16) & 0xFF)]
        for _ in 0..<3 {
            link.drain()
            guard link.send(MBootProtocol.frame(cmd, body)) else { throw FM1Error.lost("The FM-1 was disconnected.") }
            let end = Date().addingTimeInterval(cmd == 0x24 ? 8 : 1.5)
            while Date() < end {
                guard let p = await link.read(timeout: end.timeIntervalSinceNow) else { break }
                guard let f = MBootProtocol.parseFrame(p) else { continue }
                if f.cmd == 0 { throw FM1Error.device("The FM-1 refused the read.") }
                if f.cmd == cmd, f.body.count >= 8, Array(f.body[0..<8]) == body { return Array(f.body[8...]) }
            }
        }
        throw FM1Error.timeout("The FM-1 stopped answering. Keep it connected and try again.")
    }

    public func read(_ addr: Int, _ count: Int) async throws -> [UInt8] {
        let d = try await ask(0x23, addr, count)
        guard d.count == count else { throw FM1Error.protocolError("Short read from the FM-1.") }
        return d
    }

    /// The CRC-32 the chip computes of a range.
    public func crc(_ addr: Int, _ count: Int) async throws -> UInt32 {
        let d = try await ask(0x24, addr, count)
        guard d.count == 4 else { throw FM1Error.protocolError("Bad checksum answer.") }
        return SysExCoding.le32(d, 0)
    }

    /// The whole flash, each 64 KB block checked against the chip's own CRC-32 (read again once on a mismatch).
    public func backup(progress: (Int, Int) -> Void = { _, _ in }) async throws -> Data {
        let total = info.capacity, block = 0x10000
        guard total >= 0x1000, total <= 16 << 20, total % 0x1000 == 0 else { throw FM1Error.protocolError("Unexpected flash size \(total).") }
        var out = [UInt8](repeating: 0, count: total)
        for at in stride(from: 0, to: total, by: block) {
            let size = min(block, total - at)
            let want = try await crc(at, size)
            for attempt in 0..<2 {
                for o in stride(from: 0, to: size, by: MBootProtocol.readMax) {
                    let n = min(MBootProtocol.readMax, size - o)
                    out.replaceSubrange((at + o)..<(at + o + n), with: try await read(at + o, n))
                    progress(at + o + n, total)
                }
                if SysExCoding.crc32(out[at..<(at + size)]) == want { break }
                if attempt == 1 { throw FM1Error.device(String(format: "The flash at 0x%06X read differently twice. Nothing was changed; try again.", at)) }
            }
        }
        return Data(out)
    }

    /// Leaves MIDI mode: the unit restarts into its firmware.
    public func restart() { link.send(MBootProtocol.restart) }
}
