// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation
@testable import FM1Kit

/// A virtual FM-1 for tests: answers the handshake, runs both update steps the way the real
/// device does (it asks, the host answers), and implements the Felucca and FM1 Open archive
/// protocols on in-memory storage.
final class VirtualFM1: @unchecked Sendable {
    let lock = NSLock()
    var identity: String
    var loader = false
    var installed: [UInt8]?
    var attached = true
    let fromHost = SysExInbox()
    weak var link: SimLink?
    /// Fail (go silent) after this many write requests in step 2, to test resume.
    var dropAfter: Int?

    // Felucca storage
    var feluccaObjects: [UInt8: [UInt8]] = [:]
    var feluccaInfoSupported = true
    var pendingPut: (id: UInt8, size: Int, crc: UInt32, buf: [UInt8])?
    var sampleWrite: [UInt8] = []

    // FM1 Open storage
    var openProject = [UInt8](repeating: 0, count: 4264)
    var openTimbres = (0..<8).map { t in [UInt8](repeating: UInt8(t), count: 223) }
    var openDX7 = (0..<4).map { g in (0..<4096).map { UInt8(($0 + g) & 0x7F) } }
    var openSamples = (0..<300).map { UInt8($0 & 0xFF) }
    var transfer: (kind: UInt8, target: UInt8, size: Int, writing: Bool, buf: [UInt8])?
    var sampleIncoming: (size: Int, buf: [UInt8])?
    var lastRequest: [UInt8]?, lastReply: [UInt8]?

    init(identity: String) { self.identity = identity }

    var currentIdentity: String { loader ? "ota-" + identity.split(separator: "_")[0] + "_001" : identity }

    func reply(_ m: [UInt8]) { link?.toHost.push(m) }

    /// Called for every message the host sends.
    func handle(_ m: [UInt8]) {
        if m == OTAProtocol.handshakeQuery { reply(OTAProtocol.identityReply(currentIdentity)); return }
        if m == OTAProtocol.upgrade { Task { await self.runUpdate() }; return }
        if m.count >= 6, m[1] == 0x7D, m[2] == 0x46, m[3] == 0x4C { felucca(m[4], Array(m[5..<(m.count - 1)])); return }
        if m.count >= 10, m[1] == 0x7D, m[2] == 0x46, m[3] == 0x4D, m[4] == 2 { open(m); return }
        if OTAProtocol.parseRequest(m) == nil { fromHost.push(m) } // OTA responses
    }

    // MARK: update

    func fetch(_ addr: UInt32, _ len: Int) async -> [UInt8]? {
        reply(OTAProtocol.request(addr: addr, len: len))
        guard let r = await fromHost.pop(timeout: 2) else { return nil }
        let u = SysExCoding.unpack7(r[1..<(r.count - 1)])
        guard u.count == 15 + len, SysExCoding.le32(u, 7) == addr else { return nil }
        return Array(u[14..<(14 + len)])
    }

    func runUpdate() async {
        if !loader {
            // Step 1: read the header and a few blocks, then stage the loader.
            for a in stride(from: 0, to: 4096, by: 512) { guard await fetch(UInt32(a), 512) != nil else { return } }
            _ = await fetch(OTAProtocol.finishCheck, 8)
            loader = true
            await reattach()
        } else {
            var image: [UInt8] = []
            var count = 0
            let size = expectedSize
            while image.count < size {
                if let d = dropAfter, count >= d { dropAfter = nil; return }
                let n = min(512, size - image.count)
                guard let chunk = await fetch(UInt32(image.count), n) else { return }
                image += chunk
                count += 1
            }
            _ = await fetch(OTAProtocol.finishWrite, 8)
            installed = image
            loader = false
            identity = newIdentity ?? identity
            await reattach()
        }
    }

    var newIdentity: String?
    var expectedSize = 0

    func reattach() async {
        attached = false
        try? await Task.sleep(nanoseconds: 50_000_000)
        attached = true
    }

    // MARK: Felucca archive (web/fm1backup.js, device side)

    func felucca(_ cmd: UInt8, _ a: [UInt8]) {
        func send(_ payload: [UInt8]) { reply([0xF0, 0x7D, 0x46, 0x4C, cmd] + payload + [0xF7]) }
        switch cmd {
        case 1:
            var p = Array("FELUCCA 1.8.2".utf8) + [0]
            p += [1, 0, 0, 0, 0] + Array("FM6".utf8) + [0]
            p += [0] + (feluccaInfoSupported ? [16, 0x55, 1, 0, 0x4D, 1, 0, 0, 0x42, 1, 1] : [0])
            send(p)
        case 65:
            var p: [UInt8] = [1, 0, UInt8(FeluccaArchive.ids.count)]
            for id in FeluccaArchive.ids {
                let o = feluccaObjects[id] ?? []
                p += [id] + SysExCoding.u32To7(UInt32(o.count)) + SysExCoding.u32To7(o.isEmpty ? 0 : SysExCoding.crc32(o))
            }
            send(p)
        case 66:
            let id = a[0], off = Int(try! SysExCoding.u32From7(a, at: 1)), size = Int(a[6]) | Int(a[7]) << 7
            let o = feluccaObjects[id] ?? []
            send([id, 0] + SysExCoding.u32To7(UInt32(off)) + [UInt8(size & 127), UInt8(size >> 7)] + SysExCoding.maskPack(o[off..<(off + size)]))
        case 67:
            let op = a[0], id = a[1]
            switch op {
            case 0: pendingPut = (id, Int(try! SysExCoding.u32From7(a, at: 2)), try! SysExCoding.u32From7(a, at: 7), [])
            case 1:
                let off = Int(try! SysExCoding.u32From7(a, at: 2))
                let n = min(256, pendingPut!.size - off)
                pendingPut!.buf += try! SysExCoding.maskUnpack(Array(a[7...]), size: n)
            case 2:
                guard let p = pendingPut, SysExCoding.crc32(p.buf) == p.crc || p.size == 0 else { send([op, id, 2]); return }
                feluccaObjects[id] = p.buf
            default: pendingPut = nil
            }
            send([op, id, 0])
        case 11: sampleWrite = []; send([a[0], 0])
        case 12:
            let packed = a.count - 4
            sampleWrite += try! SysExCoding.maskUnpack(Array(a[4...]), size: packed - (packed + 7) / 8)
            send([a[0], 0])
        case 13:
            let header = try! SysExCoding.maskUnpack(Array(a[1...]), size: 480)
            feluccaObjects[32 + a[0]] = header + [UInt8](repeating: 0, count: 32) + sampleWrite
            send([a[0], 0])
        case 14: feluccaObjects[32 + a[0]] = []; send([a[0], 0])
        default: break
        }
    }

    // MARK: FM1 Open transfer protocol (app/transfer.c, device side)

    func open(_ m: [UInt8]) {
        if m == lastRequest, let r = lastReply { reply(r); return }
        let cmd = m[5]
        guard let data = SysExCoding.unpack7Strict(m[8..<(m.count - 2)]) else { return }
        var out: [UInt8] = []
        var status: UInt8 = 0
        func size(_ kind: UInt8) -> Int { [4064, 156, 223, 4264, 4096][Int(kind)] }
        switch cmd {
        case 0: out = [4, 16, 3, 0xE0, 0x0F, 0] + [UInt8](repeating: 1, count: 8)
        case 9: out = Array("SLOT \(data[0])".utf8) + [UInt8](repeating: 32, count: 12 - "SLOT \(data[0])".count)
        case 11: out = [2] + SysExCoding.le32Bytes(UInt32(openSamples.count)) + SysExCoding.le32Bytes(1 << 20)
        case 12: sampleIncoming = (Int(SysExCoding.le32(data, 0)), [])
        case 13: sampleIncoming!.buf += data[4...]
        case 14: openSamples = sampleIncoming!.buf
        case 15:
            let at = Int(SysExCoding.le32(data, 0))
            out = Array(openSamples[at..<(at + Int(data[4]))])
        case 21: out = [1, 0xA8, 0x10, 0, 0, 0, 0]
        case 22: out = [1, 128, 4, 1, 0, 0, 0, 0, 3]
        case 1:
            let kind = data[0], target = data[1]
            let buf: [UInt8] = switch kind {
            case 0: Array(openProject.prefix(4064))
            case 3: openProject
            case 2: openTimbres[Int(target)]
            case 4: openDX7[Int(target)]
            default: []
            }
            transfer = (kind, target, buf.count, false, buf)
            out = [UInt8(buf.count & 0xFF), UInt8(buf.count >> 8)]
        case 2:
            let at = Int(data[0]) | Int(data[1]) << 8
            out = Array(transfer!.buf[at..<(at + Int(data[2]))])
        case 3: transfer = (data[0], data[1], Int(data[2]) | Int(data[3]) << 8, true, [])
        case 4: transfer!.buf += data[2...]
        case 5:
            guard let t = transfer, SysExCoding.le32(data, 0) == SysExCoding.crc32(t.buf) else { status = 71; break }
            switch t.kind {
            case 0: openProject = t.buf
            case 2: openTimbres[Int(t.target)] = t.buf
            case 4: openDX7[Int(t.target)] = t.buf
            default: break
            }
            transfer = nil
        case 6: transfer = nil
        default: status = 71
        }
        var r: [UInt8] = Array(m[0..<8])
        r[5] |= 64
        r += SysExCoding.pack7([status] + out)
        let sum = r.dropFirst().reduce(0) { $0 + Int($1) }
        r += [UInt8((128 - sum % 128) % 128), 0xF7]
        lastRequest = m
        lastReply = r
        reply(r)
    }
}

final class SimLink: SysExLink, @unchecked Sendable {
    let name: String
    let device: VirtualFM1
    let toHost = SysExInbox()
    var closed = false
    init(name: String, device: VirtualFM1) { self.name = name; self.device = device }
    func send(_ bytes: [UInt8]) -> Bool {
        guard !isLost else { return false }
        device.handle(bytes)
        return true
    }
    func read(timeout: TimeInterval) async -> [UInt8]? { await toHost.pop(timeout: timeout) }
    func drain() { toHost.drain() }
    var isLost: Bool { closed || !device.attached }
    func close() { closed = true }
}

final class SimProvider: MIDIPortProvider, @unchecked Sendable {
    let device: VirtualFM1
    var otherPorts = ["IAC Driver Bus 1"]
    init(device: VirtualFM1) { self.device = device }
    func candidates() -> [PortCandidate] {
        otherPorts.map { PortCandidate(id: $0, name: $0) } +
            (device.attached ? [PortCandidate(id: "fm1", name: device.loader ? "OTA Composite Device" : "FM-1")] : [])
    }
    func open(_ c: PortCandidate) throws -> SysExLink {
        guard c.id == "fm1", device.attached else { throw FM1Error.notFound }
        let l = SimLink(name: c.name, device: device)
        device.link = l
        return l
    }
}
