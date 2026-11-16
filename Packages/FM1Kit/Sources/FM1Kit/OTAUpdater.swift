// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments (Felucca web/fm1ota.js and tools/fm1_install.py)
// Copyright (C) 2026 FM-1 Swapper contributors (Swift port, modified)
import Foundation

/// The FM-1 USB-MIDI update protocol (after Felucca's tools/fm1_install.py and web/fm1ota.js,
/// which reproduce M-VAVE's updater). Step 1: the running firmware reads parts of the
/// package and starts the update loader. Step 2: the loader reads the whole image and
/// writes it. In both steps the device asks (cmd 0x30 read requests) and we answer.
public enum OTAProtocol {
    public static let handshakeQuery: [UInt8] = [0xF0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7F, 0xF7]
    public static let upgrade: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7F, 0xF7]
    public static let finishCheck: UInt32 = 0xE000_0000
    public static let finishWrite: UInt32 = 0xF000_0000
    public static let maxData = 512

    public struct ReadRequest: Equatable, Sendable { public let flags: UInt8; public let addr: UInt32; public let len: Int }

    public static func response(addr: UInt32, data: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        let n = data.count
        var body: [UInt8] = [0x00, 0x59, 0x30, UInt8((n + 8) & 0xFF), UInt8(((n + 8) >> 8) & 0xFF), 0, flags]
        body += SysExCoding.le32Bytes(addr)
        body += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), 0]
        body += data
        var s = 0
        for b in body[6...] { s += Int(b) }
        body.append(UInt8(~s & 0xFF))
        return [0xF0] + SysExCoding.pack7(body) + [0xF7]
    }

    public static func parseRequest(_ pkt: [UInt8]) -> ReadRequest? {
        guard pkt.count >= 2, pkt.first == 0xF0, pkt.last == 0xF7 else { return nil }
        let u = SysExCoding.unpack7(pkt[1..<(pkt.count - 1)])
        guard u.count == 15, u[0] == 0, u[1] == 0x59, u[2] == 0x30 else { return nil }
        var s = 0
        for b in u[6..<14] { s += Int(b) }
        guard UInt8(~s & 0xFF) == u[14] else { return nil }
        return ReadRequest(flags: u[6], addr: SysExCoding.le32(u, 7), len: Int(u[11]) | Int(u[12]) << 8 | Int(u[13]) << 16)
    }

    public static func request(addr: UInt32, len: Int, flags: UInt8 = 0) -> [UInt8] {
        var u: [UInt8] = [0, 0x59, 0x30, 0, 0, 0, flags]
        u += SysExCoding.le32Bytes(addr)
        u += [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), UInt8((len >> 16) & 0xFF)]
        var s = 0
        for b in u[6...] { s += Int(b) }
        u.append(UInt8(~s & 0xFF))
        return [0xF0] + SysExCoding.pack7(u) + [0xF7]
    }

    public static func parseIdentity(_ pkt: [UInt8]) -> DeviceIdentity? {
        guard pkt.count >= 2, pkt.first == 0xF0, pkt.last == 0xF7 else { return nil }
        let d = SysExCoding.unpack7(pkt[1..<(pkt.count - 1)])
        guard d.count == 34, d[0] == 0, d[1] == 0x59, d[2] == 0x11 else { return nil }
        var txt = d[6..<33].map { (32..<127).contains($0) ? Character(Unicode.Scalar($0)) : $0 == 0 ? "\0" : "?" }
        while txt.last == "\0" { txt.removeLast() }
        return DeviceIdentity(text: String(txt))
    }

    public static func identityReply(_ text: String) -> [UInt8] {
        var d: [UInt8] = [0, 0x59, 0x11, 0, 0, 0]
        var t = Array(text.utf8.prefix(27))
        t += [UInt8](repeating: 0, count: 27 - t.count)
        d += t
        d.append(0)
        return [0xF0] + SysExCoding.pack7(d) + [0xF7]
    }
}

/// A connected FM-1 (or its update loader) that answered the handshake.
public struct ConnectedDevice: Sendable {
    public let link: SysExLink
    public let identity: DeviceIdentity
    public let portName: String
}

public enum UpdateStep: Sendable, Equatable {
    case start(String), verify(Int), loader, write(Int), reboot, done(String)

    public var label: String {
        switch self {
        case .start: "Starting the update"
        case .verify: "Device checking the package"
        case .loader: "Waiting for the update loader"
        case .write: "Writing firmware"
        case .reboot: "Restarting the FM-1"
        case .done: "Done"
        }
    }
}

public struct UpdateTiming: Sendable {
    public var replyDelay: TimeInterval = 0.010
    public var afterUpgrade: TimeInterval = 2.0
    public var beforeLoader: TimeInterval = 3.0
    public var beforeReboot: TimeInterval = 3.0
    public var idleCheck: TimeInterval = 8.0
    public var idleWrite: TimeInterval = 180.0
    public var waitLoader: TimeInterval = 30.0
    public var waitReboot: TimeInterval = 40.0
    public var poll: TimeInterval = 1.0
    public var handshake: TimeInterval = 1.0
    public init() {}
    public static let fast: UpdateTiming = {
        var t = UpdateTiming()
        t.replyDelay = 0; t.afterUpgrade = 0.01; t.beforeLoader = 0.01; t.beforeReboot = 0.01
        t.idleCheck = 1; t.idleWrite = 2; t.waitLoader = 2; t.waitReboot = 2; t.poll = 0.05; t.handshake = 0.2
        return t
    }()
}

public final class OTAUpdater: @unchecked Sendable {
    public let provider: MIDIPortProvider
    public var timing: UpdateTiming
    /// Probe every port, not only ones whose names look like an FM-1.
    public var probeAllPorts = false
    public var log: @Sendable (String) -> Void

    /// Expected total device read requests in a step for a given image (for progress bars).
    public static func expectedRequests(imageSize: Int) -> Int { (imageSize + OTAProtocol.maxData - 1) / OTAProtocol.maxData }

    public init(provider: MIDIPortProvider, timing: UpdateTiming = .init(), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.provider = provider; self.timing = timing; self.log = log
    }

    func sleep(_ s: TimeInterval) async { if s > 0 { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) } }

    func handshake(_ link: SysExLink, tries: Int = 3) async -> DeviceIdentity? {
        link.drain()
        for _ in 0..<tries {
            guard link.send(OTAProtocol.handshakeQuery) else { return nil }
            let end = Date().addingTimeInterval(timing.handshake)
            while Date() < end {
                guard let p = await link.read(timeout: end.timeIntervalSinceNow) else { break }
                if let id = OTAProtocol.parseIdentity(p) { return id }
            }
        }
        return nil
    }

    /// The first port pair that answers the handshake (and passes `filter`). The link is left open.
    public func find(where filter: (DeviceIdentity) -> Bool = { _ in true }) async -> ConnectedDevice? {
        for c in provider.candidates() where probeAllPorts || looksLikeFM1(c.name) {
            guard let link = try? provider.open(c) else { continue }
            if let id = await handshake(link, tries: 2), filter(id) {
                log("found \(id.text) on \(c.name)")
                return ConnectedDevice(link: link, identity: id, portName: c.name)
            }
            link.close()
        }
        return nil
    }

    /// Identity of whatever FM-1 is connected, closing the link afterwards.
    public func identify() async -> (identity: DeviceIdentity, port: String)? {
        guard let d = await find() else { return nil }
        d.link.close()
        return (d.identity, d.portName)
    }

    func waitFor(_ filter: (DeviceIdentity) -> Bool, seconds: TimeInterval) async -> ConnectedDevice? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if Task.isCancelled { return nil }
            if let d = await find(where: filter) { return d }
            await sleep(timing.poll)
        }
        return nil
    }

    struct ServeResult { var served: Int; var finished: Bool; var lost: Bool }

    func serve(_ link: SysExLink, image: [UInt8], finish: UInt32, idle: TimeInterval,
               progress: (Int) -> Void) async throws -> ServeResult {
        var served = 0
        var last = Date()
        while true {
            guard let pkt = await link.read(timeout: 1.0) else {
                if link.isLost { return .init(served: served, finished: false, lost: true) }
                if Date().timeIntervalSince(last) > idle { return .init(served: served, finished: false, lost: false) }
                continue
            }
            guard let r = OTAProtocol.parseRequest(pkt) else { continue }
            last = Date()
            if r.addr == OTAProtocol.finishCheck || r.addr == OTAProtocol.finishWrite {
                link.send(OTAProtocol.response(addr: r.addr, data: Array("success".utf8) + [0]))
                if r.addr == finish { return .init(served: served, finished: true, lost: false) }
                continue
            }
            guard r.len <= OTAProtocol.maxData, Int(r.addr) + r.len <= image.count else {
                throw FM1Error.badRequest("The FM-1 asked for bytes outside the package (\(String(r.addr, radix: 16))+\(r.len)).")
            }
            await sleep(timing.replyDelay)
            let a = Int(r.addr)
            guard link.send(OTAProtocol.response(addr: r.addr, data: Array(image[a..<(a + r.len)]), flags: r.flags)) else {
                return .init(served: served, finished: false, lost: true)
            }
            served += 1
            progress(served)
        }
    }

    /// Full install: running firmware -> update loader -> new firmware. Returns the identity the device reports afterwards.
    public func install(_ package: FirmwarePackage, onStep: @escaping @Sendable (UpdateStep) -> Void = { _ in }) async throws -> DeviceIdentity {
        let image = package.logicalImage
        guard let dev = await find(where: { !$0.isLoader }) else { throw FM1Error.notFound }
        guard dev.identity.model == package.model else {
            dev.link.close()
            throw FM1Error.wrongModel(device: dev.identity.text, package: package.product)
        }
        onStep(.start(dev.identity.text))
        dev.link.send(OTAProtocol.upgrade)
        await sleep(timing.afterUpgrade)
        let s1 = try await serve(dev.link, image: image, finish: OTAProtocol.finishCheck, idle: timing.idleCheck) { onStep(.verify($0)) }
        dev.link.close()
        if !s1.finished, !s1.lost, s1.served == 0 { throw FM1Error.refused(inLoader: false) }
        guard s1.finished else {
            let why = s1.lost ? "was disconnected" : "stopped"
            throw s1.lost ? FM1Error.lost("The FM-1 \(why) after \(s1.served) requests. Nothing was written.")
                : FM1Error.stopped("The FM-1 \(why) after \(s1.served) requests. Nothing was written.")
        }
        onStep(.loader)
        await sleep(timing.beforeLoader)
        guard let ota = await waitFor({ $0.model == "ota-" + package.model }, seconds: timing.waitLoader) else { throw FM1Error.noLoader }
        return try await finishWrite(ota, package: package, image: image, onStep: onStep)
    }

    /// The device is already in update mode (an earlier install was cut off): finish the write.
    /// Returns nil when no update loader is connected.
    public func resume(_ package: FirmwarePackage, onStep: @escaping @Sendable (UpdateStep) -> Void = { _ in }) async throws -> DeviceIdentity? {
        guard let ota = await find(where: { $0.model == "ota-" + package.model }) else { return nil }
        return try await finishWrite(ota, package: package, image: package.logicalImage, onStep: onStep)
    }

    private func finishWrite(_ ota: ConnectedDevice, package: FirmwarePackage, image: [UInt8],
                             onStep: @escaping @Sendable (UpdateStep) -> Void) async throws -> DeviceIdentity {
        ota.link.send(OTAProtocol.upgrade)
        await sleep(timing.afterUpgrade)
        let s2 = try await serve(ota.link, image: image, finish: OTAProtocol.finishWrite, idle: timing.idleWrite) { onStep(.write($0)) }
        ota.link.close()
        if !s2.finished, !s2.lost, s2.served == 0 { throw FM1Error.refused(inLoader: true) }
        guard s2.finished else {
            let msg = "The update loader \(s2.lost ? "was disconnected" : "stopped") after \(s2.served) requests. Replug the FM-1 and choose Resume to finish."
            throw s2.lost ? FM1Error.lost(msg) : FM1Error.stopped(msg)
        }
        onStep(.reboot)
        await sleep(timing.beforeReboot)
        guard let back = await waitFor({ !$0.isLoader }, seconds: timing.waitReboot) else { throw FM1Error.noReturn }
        back.link.close()
        guard back.identity.text == package.product else { throw FM1Error.mismatch(back.identity.text) }
        onStep(.done(back.identity.text))
        return back.identity
    }
}
