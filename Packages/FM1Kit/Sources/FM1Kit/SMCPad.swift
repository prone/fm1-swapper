// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import CoreBluetooth
import Foundation

/// The SINCO / M-VAVE service protocol that the SMC-PAD shares with the FM-1 (same JieLi SDK):
/// logical packets `00 59 <cmd> <len24-le> <payload> <~sum(payload)>`, sent raw over Bluetooth
/// (GATT AE41, replies on AE42) or 7-bit packed in `F0 … F7` over USB (the "SMC-PAD-Private" port).
/// Reverse-engineered by github.com/fedepaj/open-smc-pad (docs/sinco-protocol.md) and
/// github.com/spectalive/smc-pad (LED colours, session unlock). Verified there on the full-size
/// SMC-PAD; the Pocket is unconfirmed.
public enum Sinco {
    public static func packet(_ cmd: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        let sum = payload.reduce(0) { $0 &+ Int($1) }
        return [0x00, 0x59, cmd, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF)] + payload + [UInt8(~sum & 0xFF)]
    }

    /// USB form: the whole logical packet packed LSB-first into 7-bit bytes.
    public static func sysex(_ logical: [UInt8]) -> [UInt8] { [0xF0] + SysExCoding.pack7(logical) + [0xF7] }

    public static func fromSysex(_ m: [UInt8]) -> [UInt8]? {
        guard let u = SysExCoding.unwrap(m) else { return nil }
        return u.count >= 7 && u[0] == 0 && u[1] == 0x59 ? u : nil
    }

    public struct Frame: Equatable, Sendable { public let cmd: UInt8; public let payload: [UInt8] }

    /// Splits a byte stream (BLE notifications may cut or join packets) into frames; returns leftovers.
    public static func frames(_ buffer: inout [UInt8]) -> [Frame] {
        var out: [Frame] = []
        while buffer.count >= 7 {
            guard buffer[0] == 0x00, buffer[1] == 0x59 else { buffer.removeFirst(); continue }
            let n = Int(buffer[3]) | Int(buffer[4]) << 8 | Int(buffer[5]) << 16
            guard n < 65536 else { buffer.removeFirst(); continue }
            guard buffer.count >= 7 + n else { break }
            let payload = Array(buffer[6..<(6 + n)])
            out.append(Frame(cmd: buffer[2], payload: payload))
            buffer.removeFirst(7 + n)
        }
        return out
    }

    static func le(_ v: Int, _ width: Int) -> [UInt8] { (0..<width).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    public static let queryName = packet(0x11, [])
    public static func flashRead(region: UInt8, address: Int, length: Int) -> [UInt8] {
        packet(0x23, [region] + le(address, 4) + le(length, 3))
    }
    public static func flashWrite(region: UInt8, address: Int, data: [UInt8]) -> [UInt8] {
        packet(0x22, [region] + le(address, 4) + le(data.count, 3) + data)
    }
}

public enum SMCPadProtocol {
    public static let presetSize = 3539
    public static let presetCount = 8
    static let padArray = 211, padRecord = 26, rgbOffset = 5, firstSlotNote = 4

    /// Flash (settings region 5) address of a pad note's RGB in a preset. Note 36 in preset 1 = 0x418.
    public static func colorAddress(note: Int, preset: Int = 0) -> Int {
        preset * presetSize + padArray + (note - firstSlotNote) * padRecord + rgbOffset
    }

    public static func colorWrite(note: Int, r: UInt8, g: UInt8, b: UInt8, preset: Int = 0) -> [UInt8] {
        Sinco.flashWrite(region: 5, address: colorAddress(note: note, preset: preset), data: [r, g, b])
    }

    /// The editor's connect handshake: name query, then reading the whole settings area, then polls.
    /// Colour writes are ignored until a client has done this on the same connection.
    public static var unlock: [[UInt8]] {
        var p: [[UInt8]] = [Sinco.queryName, keepAlive]
        let total = presetSize * presetCount, chunk = 0x3F1
        var at = 0
        while at < total {
            p.append(Sinco.flashRead(region: 5, address: at, length: min(chunk, total - at)))
            at += chunk
        }
        p += Array(repeating: keepAlive, count: 10)
        return p
    }

    /// Sent about twice a second to hold the session open.
    public static let keepAlive = Sinco.flashRead(region: 4, address: 0, length: 12)

    /// "SMC-PAD_004" style name from a 0x11 reply.
    public static func name(fromReply f: Sinco.Frame) -> String? {
        guard f.cmd == 0x11 else { return nil }
        let s = String(decoding: f.payload.prefix { $0 != 0 }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}

/// How a session reaches the pad: Bluetooth GATT or the USB "Private" MIDI port.
public protocol SincoChannel: AnyObject {
    var isOpen: Bool { get }
    var onFrame: ((Sinco.Frame) -> Void)? { get set }
    var onStateChange: ((String) -> Void)? { get set }
    func start()
    func stop()
    func write(_ logical: [UInt8])
}

/// Bluetooth: the pad's service AE40 (write AE41 without response, notify AE42), found among the
/// peripherals already connected for Bluetooth MIDI, or by scanning while the pad is in pairing mode.
public final class SMCPadBLEChannel: NSObject, SincoChannel, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "AE40"), writeChar = CBUUID(string: "AE41"), notifyChar = CBUUID(string: "AE42")
    static let bleMIDI = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var buffer: [UInt8] = []
    public var onFrame: ((Sinco.Frame) -> Void)?
    public var onStateChange: ((String) -> Void)?
    public var isOpen: Bool { writer != nil }

    public func start() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) } else { connectKnown() }
    }

    public func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        writer = nil
        peripheral = nil
    }

    public func write(_ logical: [UInt8]) {
        guard let p = peripheral, let c = writer else { return }
        p.writeValue(Data(logical), for: c, type: .withoutResponse)
    }

    /// Only peripherals named like an SMC-PAD ("SMC-PAD", "SMC-PAD Pocket"…). Many unrelated devices
    /// use the same JieLi AE40 service, so the name is the first filter and the session then checks
    /// the device's own identity before touching its flash.
    static func isSMCPadName(_ name: String?) -> Bool {
        (name ?? "").lowercased().replacingOccurrences(of: " ", with: "-").hasPrefix("smc-pad")
    }

    private func wanted(_ p: CBPeripheral) -> Bool { Self.isSMCPadName(p.name) }

    private func connectKnown() {
        guard let c = central, c.state == .poweredOn else { return }
        let known = c.retrieveConnectedPeripherals(withServices: [Self.service, Self.bleMIDI]).filter(wanted)
        if let p = known.first {
            attach(p)
        } else {
            onStateChange?("Looking for the pad over Bluetooth…")
            c.scanForPeripherals(withServices: nil)
        }
    }

    private func attach(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        onStateChange?("Connecting to \(p.name ?? "pad")…")
        central?.connect(p)
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: connectKnown()
        case .unauthorized: onStateChange?("Bluetooth permission is off for this app (Settings › FM-1 Swapper).")
        case .poweredOff: onStateChange?("Bluetooth is off.")
        default: break
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if wanted(p) { attach(p) }
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.service])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        onStateChange?("Could not connect: \(error?.localizedDescription ?? "unknown error")")
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        writer = nil
        onStateChange?("The pad disconnected.")
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
            onStateChange?("This pad has no light service (AE40).")
            return
        }
        p.discoverCharacteristics([Self.writeChar, Self.notifyChar], for: s)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == Self.notifyChar { p.setNotifyValue(true, for: c) }
            if c.uuid == Self.writeChar { writer = c }
        }
        if writer != nil { onStateChange?("open") }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        buffer += v
        for f in Sinco.frames(&buffer) { onFrame?(f) }
    }
}

/// USB: the pad's "SMC-PAD-Private" CoreMIDI port, packets 7-bit packed in SysEx.
/// Used from the main thread only (its reader task hops back to the main actor for every callback).
public final class SMCPadUSBChannel: SincoChannel, @unchecked Sendable {
    private let provider: MIDIPortProvider
    private var link: SysExLink?
    private var reader: Task<Void, Never>?
    public var onFrame: ((Sinco.Frame) -> Void)?
    public var onStateChange: ((String) -> Void)?
    public var isOpen: Bool { link.map { !$0.isLost } ?? false }

    public init(provider: MIDIPortProvider = CoreMIDIProvider.shared) { self.provider = provider }

    public static func privatePort(in provider: MIDIPortProvider) -> PortCandidate? {
        provider.candidates().first { $0.name.lowercased().contains("smc") && $0.name.lowercased().contains("private") }
    }

    public func start() {
        guard link == nil, reader == nil, let c = Self.privatePort(in: provider) else {
            if link == nil { onStateChange?("No SMC-PAD-Private USB port.") }
            return
        }
        // opening a CoreMIDI port waits briefly for it to settle: do it off the main thread
        let provider = self.provider
        reader = Task { @MainActor [weak self] in
            guard let l = await Task.detached(operation: { try? provider.open(c) }).value else {
                self?.reader = nil
                self?.onStateChange?("Couldn't open the SMC-PAD-Private USB port.")
                return
            }
            self?.link = l
            self?.onStateChange?("open")
            while !Task.isCancelled {
                if let m = await l.read(timeout: 1), let u = Sinco.fromSysex(m) {
                    var b = u
                    for f in Sinco.frames(&b) { self?.onFrame?(f) }
                }
                if l.isLost { self?.onStateChange?("The pad's USB port went away."); return }
                if self == nil { return }
            }
        }
    }

    public func stop() {
        reader?.cancel()
        reader = nil
        link?.close()
        link = nil
    }

    public func write(_ logical: [UInt8]) { link?.send(Sinco.sysex(logical)) }
}

/// Holds an SMC-PAD light session: replays the unlock, keeps it alive, and paints pads.
/// Colours are written into the pad's settings (preset 1 by default), so they persist like the
/// colours MIDI Suite sets. Writes are coalesced per note and paced.
@MainActor
public final class SMCPadLightSession {
    public enum State: Equatable { case idle, connecting(String), unlocking(Int, Int), ready, failed(String) }

    public private(set) var state: State = .idle { didSet { onState?(state) } }
    public var onState: ((State) -> Void)?
    public var onName: ((String) -> Void)?
    public var preset = 0

    private let channel: SincoChannel
    private var queue: [[UInt8]] = []
    private var pending: [Int: [UInt8]] = [:]
    private var pump: Timer?
    private var keepAlive: Timer?
    private var unlocked = false
    private var lastWrite: [Int: [UInt8]] = [:]

    public init(channel: SincoChannel) {
        self.channel = channel
        channel.onStateChange = { [weak self] s in
            guard let self else { return }
            if s == "open" { self.beginUnlock() } else if self.state != .ready { self.state = .connecting(s) }
            if s.contains("disconnect") || s.contains("went away") { self.reset(); self.state = .failed(s) }
        }
        channel.onFrame = { [weak self] f in
            guard let self, let n = SMCPadProtocol.name(fromReply: f) else { return }
            self.onName?(n)
            self.identity(n)
        }
    }

    public func start() {
        state = .connecting("Connecting…")
        channel.start()
        if channel.isOpen { beginUnlock() }
    }

    public func stop() {
        reset()
        channel.stop()
        state = .idle
    }

    private func reset() {
        identityTimeout?.invalidate()
        pump?.invalidate(); keepAlive?.invalidate()
        pump = nil; keepAlive = nil
        unlocked = false
        queue.removeAll()
        lastWrite.removeAll()
    }

    private var identified = false
    private var identityTimeout: Timer?

    /// Asks the device for its name first; the settings reads and colour writes only start once it
    /// answers as an SMC-PAD, so the session never writes to another device's flash.
    private func beginUnlock() {
        reset()
        identified = false
        state = .connecting("Checking the device…")
        channel.write(Sinco.queryName)
        identityTimeout?.invalidate()
        identityTimeout = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.identified else { return }
                self.channel.stop()
                self.state = .failed("That device didn't answer as an SMC-PAD, so nothing was sent to it.")
            }
        }
    }

    private func identity(_ name: String) {
        guard !identified else { return }
        identityTimeout?.invalidate()
        guard name.uppercased().hasPrefix("SMC-PAD") else {
            channel.stop()
            state = .failed("The device says it is \(name), not an SMC-PAD, so nothing was sent to it.")
            return
        }
        identified = true
        let steps = Array(SMCPadProtocol.unlock.dropFirst())   // the name query is already done
        queue = steps
        state = .unlocking(0, steps.count)
        startPump()
    }

    private func startPump() {
        pump?.invalidate()
        pump = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard channel.isOpen else { return }
        if !queue.isEmpty {
            channel.write(queue.removeFirst())
            if !unlocked {
                let total = SMCPadProtocol.unlock.count - 1
                state = .unlocking(total - queue.count, total)
                if queue.isEmpty { finishUnlock() }
            }
            return
        }
        if unlocked, let note = pending.keys.sorted().first, let rgb = pending.removeValue(forKey: note) {
            channel.write(SMCPadProtocol.colorWrite(note: note, r: rgb[0], g: rgb[1], b: rgb[2], preset: preset))
            lastWrite[note] = rgb
        }
    }

    private func finishUnlock() {
        unlocked = true
        state = .ready
        keepAlive = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.channel.isOpen, self.pending.isEmpty else { return }
                self.channel.write(SMCPadProtocol.keepAlive)
            }
        }
    }

    /// Paints a pad (by its stock note, 36-67; bank B notes 52-67 are their own slots).
    public func paint(note: Int, r: UInt8, g: UInt8, b: UInt8) {
        guard (SMCPadProtocol.firstSlotNote...127).contains(note) else { return }
        let rgb = [r, g, b]
        if lastWrite[note] == rgb, pending[note] == nil { return }
        pending[note] = rgb
    }

    public var isReady: Bool { state == .ready }
}
