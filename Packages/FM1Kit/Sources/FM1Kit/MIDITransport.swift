import CoreMIDI
import Foundation

/// A MIDI in/out pair that carries SysEx messages (each message F0 ... F7).
public protocol SysExLink: AnyObject, Sendable {
    var name: String { get }
    /// false when the port is gone (unplugged).
    @discardableResult func send(_ bytes: [UInt8]) -> Bool
    /// Next received SysEx message, or nil after `timeout` seconds.
    func read(timeout: TimeInterval) async -> [UInt8]?
    func drain()
    var isLost: Bool { get }
    func close()
}

public struct PortCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Lists and opens MIDI port pairs. `CoreMIDIProvider` is the real one; tests use a simulator.
public protocol MIDIPortProvider: AnyObject, Sendable {
    func candidates() -> [PortCandidate]
    func open(_ candidate: PortCandidate) throws -> SysExLink
}

/// Ports the FM-1 (or its update loader) shows up as. Other gear is never probed.
public let fm1PortPattern = try! NSRegularExpression(pattern: "fm-1|fm1|felucca|ota|composite|sinco|usb-midi", options: .caseInsensitive)

public func looksLikeFM1(_ name: String) -> Bool {
    fm1PortPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
}

/// Thread-safe queue of received SysEx messages with an async, timed read.
public final class SysExInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[UInt8]] = []
    private var waiter: (id: UInt64, cont: CheckedContinuation<[UInt8]?, Never>)?
    private var nextID: UInt64 = 0

    public init() {}

    public func push(_ message: [UInt8]) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.cont.resume(returning: message)
        } else {
            queue.append(message)
            lock.unlock()
        }
    }

    public func drain() {
        lock.withLock { queue.removeAll() }
    }

    /// Takes a queued message, or registers the continuation as the waiter (one reader at a time).
    private func takeOrWait(_ cont: CheckedContinuation<[UInt8]?, Never>) -> (message: [UInt8]?, id: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if !queue.isEmpty { return (queue.removeFirst(), 0) }
        nextID &+= 1
        waiter = (nextID, cont)
        return (nil, nextID)
    }

    private func expire(_ id: UInt64) {
        lock.lock()
        guard let w = waiter, w.id == id else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        w.cont.resume(returning: nil)
    }

    public func pop(timeout: TimeInterval) async -> [UInt8]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            let r = takeOrWait(cont)
            if let m = r.message { cont.resume(returning: m); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 0)) { [weak self] in self?.expire(r.id) }
        }
    }
}

/// Reassembles UMP SysEx7 packets into complete F0...F7 messages.
struct SysEx7Assembler {
    private var buffer: [UInt8] = []
    private var active = false

    /// Feed UMP words; returns completed messages.
    mutating func feed(_ words: UnsafeBufferPointer<UInt32>) -> [[UInt8]] {
        var done: [[UInt8]] = []
        var i = 0
        while i < words.count {
            let w0 = words[i]
            let type = Int(w0 >> 28)
            let size = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][type]
            if type == 3, i + 1 < words.count {
                let w1 = words[i + 1]
                let status = (w0 >> 20) & 0xF
                let n = min(Int((w0 >> 16) & 0xF), 6)
                let all: [UInt8] = [UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF),
                                    UInt8(w1 >> 24), UInt8((w1 >> 16) & 0xFF), UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF)]
                let bytes = all.prefix(n)
                switch status {
                case 0: done.append([0xF0] + bytes + [0xF7]); active = false; buffer.removeAll()
                case 1: buffer = Array(bytes); active = true
                case 2: if active { buffer.append(contentsOf: bytes) }
                case 3:
                    if active { done.append([0xF0] + buffer + bytes + [0xF7]) }
                    active = false; buffer.removeAll()
                default: break
                }
            }
            i += size
        }
        return done
    }

    /// UMP SysEx7 words for one F0...F7 message.
    static func words(for message: [UInt8]) -> [UInt32] {
        var payload = message
        if payload.first == 0xF0 { payload.removeFirst() }
        if payload.last == 0xF7 { payload.removeLast() }
        let chunks = stride(from: 0, to: max(payload.count, 1), by: 6).map { Array(payload[$0..<min($0 + 6, payload.count)]) }
        var words: [UInt32] = []
        for (i, c) in chunks.enumerated() {
            let status: UInt32 = chunks.count == 1 ? 0 : i == 0 ? 1 : i == chunks.count - 1 ? 3 : 2
            let b = c + [UInt8](repeating: 0, count: 6 - c.count)
            words.append(0x3000_0000 | status << 20 | UInt32(c.count) << 16 | UInt32(b[0]) << 8 | UInt32(b[1]))
            words.append(UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5]))
        }
        return words
    }
}

/// CoreMIDI (iOS / iPadOS / macOS). The FM-1 is class-compliant USB-MIDI, so a
/// USB-C cable (or Lightning camera adapter) is all an iPhone or iPad needs.
public final class CoreMIDIProvider: MIDIPortProvider, @unchecked Sendable {
    public static let shared = CoreMIDIProvider()

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private let lock = NSLock()
    private var links: [Int: CoreMIDILink] = [:]
    private var nextLinkID = 1
    private var observers: [UUID: @Sendable () -> Void] = [:]
    public private(set) var setupError: OSStatus = noErr

    private init() {
        var status = MIDIClientCreateWithBlock("FM1Kit" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged { self?.notifyChange() }
        }
        if status == noErr {
            status = MIDIInputPortCreateWithProtocol(client, "FM1Kit In" as CFString, ._1_0, &inPort) { [weak self] list, refCon in
                guard let self, let refCon else { return }
                let id = Int(bitPattern: refCon)
                self.lock.lock()
                let link = self.links[id]
                self.lock.unlock()
                link?.receive(list)
            }
        }
        if status == noErr { status = MIDIOutputPortCreate(client, "FM1Kit Out" as CFString, &outPort) }
        setupError = status
    }

    /// Called (on a CoreMIDI thread) whenever devices are plugged or unplugged.
    @discardableResult
    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = handler; lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }

    private func notifyChange() {
        lock.lock(); let hs = Array(observers.values); lock.unlock()
        hs.forEach { $0() }
    }

    static func name(of obj: MIDIObjectRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &s) == noErr, let v = s?.takeRetainedValue() { return v as String }
        if MIDIObjectGetStringProperty(obj, kMIDIPropertyName, &s) == noErr, let v = s?.takeRetainedValue() { return v as String }
        return "?"
    }

    static func uid(of obj: MIDIObjectRef) -> MIDIUniqueID {
        var v: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(obj, kMIDIPropertyUniqueID, &v)
        return v
    }

    static func exists(_ uid: MIDIUniqueID) -> Bool {
        var obj = MIDIObjectRef(), type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(uid, &obj, &type) == noErr else { return false }
        var offline: Int32 = 0
        MIDIObjectGetIntegerProperty(obj, kMIDIPropertyOffline, &offline)
        return offline == 0
    }

    /// Every source paired with a destination of the same entity (or, failing that, the same name).
    public func candidates() -> [PortCandidate] {
        var out: [PortCandidate] = []
        let dests = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var srcEntity = MIDIEntityRef()
            MIDIEndpointGetEntity(src, &srcEntity)
            let name = Self.name(of: src)
            let dest = dests.first { d in
                var e = MIDIEntityRef()
                return srcEntity != 0 && MIDIEndpointGetEntity(d, &e) == noErr && e == srcEntity
            } ?? dests.first { Self.name(of: $0) == name }
            guard let dest else { continue }
            out.append(PortCandidate(id: "\(Self.uid(of: src)):\(Self.uid(of: dest))", name: name))
        }
        return out
    }

    public func open(_ candidate: PortCandidate) throws -> SysExLink {
        let parts = candidate.id.split(separator: ":").compactMap { Int32($0) }
        guard parts.count == 2, setupError == noErr else { throw FM1Error.device("MIDI is unavailable (\(setupError)).") }
        var srcObj = MIDIObjectRef(), dstObj = MIDIObjectRef(), t = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(parts[0], &srcObj, &t) == noErr,
              MIDIObjectFindByUniqueID(parts[1], &dstObj, &t) == noErr else { throw FM1Error.notFound }
        lock.lock()
        let id = nextLinkID
        nextLinkID += 1
        let link = CoreMIDILink(provider: self, id: id, name: candidate.name, source: srcObj, destination: dstObj,
                                sourceUID: parts[0], destinationUID: parts[1])
        links[id] = link
        lock.unlock()
        let status = MIDIPortConnectSource(inPort, srcObj, UnsafeMutableRawPointer(bitPattern: id))
        guard status == noErr else { detach(link); throw FM1Error.device("Could not open \(candidate.name) (\(status)).") }
        // CoreMIDI may drop a message sent right after connecting.
        Thread.sleep(forTimeInterval: 0.3)
        return link
    }

    fileprivate func detach(_ link: CoreMIDILink) {
        MIDIPortDisconnectSource(inPort, link.source)
        lock.lock(); links[link.id] = nil; lock.unlock()
    }

    fileprivate func send(_ words: [UInt32], to dest: MIDIEndpointRef) -> Bool {
        let size = 256 + words.count * 8
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        let list = buf.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
        var ok = true
        words.withUnsafeBufferPointer { w in
            var i = 0
            while i + 1 < w.count, ok {
                packet = MIDIEventListAdd(list, size, packet!, 0, 2, w.baseAddress! + i)
                if packet == nil { ok = false }
                i += 2
            }
        }
        guard ok else { return false }
        return MIDISendEventList(outPort, dest, list) == noErr
    }
}

final class CoreMIDILink: SysExLink, @unchecked Sendable {
    weak var provider: CoreMIDIProvider?
    let id: Int
    let name: String
    let source: MIDIEndpointRef
    let destination: MIDIEndpointRef
    let sourceUID: MIDIUniqueID
    let destinationUID: MIDIUniqueID
    private let inbox = SysExInbox()
    private var assembler = SysEx7Assembler()
    private var closed = false

    init(provider: CoreMIDIProvider, id: Int, name: String, source: MIDIEndpointRef, destination: MIDIEndpointRef,
         sourceUID: MIDIUniqueID, destinationUID: MIDIUniqueID) {
        self.provider = provider; self.id = id; self.name = name
        self.source = source; self.destination = destination
        self.sourceUID = sourceUID; self.destinationUID = destinationUID
    }

    // CoreMIDI delivers on a single high-priority thread per port, so the assembler needs no lock.
    func receive(_ list: UnsafePointer<MIDIEventList>) {
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
            let base = (UnsafeRawPointer(packet) + wordsOffset).assumingMemoryBound(to: UInt32.self)
            for m in assembler.feed(UnsafeBufferPointer(start: base, count: count)) { inbox.push(m) }
        }
    }

    var isLost: Bool { closed || !CoreMIDIProvider.exists(sourceUID) || !CoreMIDIProvider.exists(destinationUID) }

    func send(_ bytes: [UInt8]) -> Bool {
        guard !isLost, let provider else { return false }
        return provider.send(SysEx7Assembler.words(for: bytes), to: destination)
    }

    func read(timeout: TimeInterval) async -> [UInt8]? { await inbox.pop(timeout: timeout) }
    func drain() { inbox.drain() }

    func close() {
        guard !closed else { return }
        closed = true
        provider?.detach(self)
    }
}

/// Converts UMP words (MIDI 1.0 protocol) into plain MIDI 1.0 messages, skipping SysEx.
enum UMPToMIDI1 {
    static func messages(_ words: UnsafeBufferPointer<UInt32>) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let type = Int(w >> 28)
            let size = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][type]
            let status = UInt8((w >> 16) & 0xFF), d1 = UInt8((w >> 8) & 0x7F), d2 = UInt8(w & 0x7F)
            if type == 2 {
                let hi = status & 0xF0
                out.append(hi == 0xC0 || hi == 0xD0 ? [status, d1] : [status, d1, d2])
            } else if type == 1 {
                switch status {
                case 0xF1, 0xF3: out.append([status, d1])
                case 0xF2: out.append([status, d1, d2])
                default: out.append([status])
                }
            }
            i += size
        }
        return out
    }
}

/// Listens to every MIDI source (keyboards, controllers, the FM-1 itself) and reports
/// channel and system messages. Used to play the emulator from real hardware.
public final class MIDIInputMonitor: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []
    private let lock = NSLock()
    public var onMessage: (@Sendable ([UInt8]) -> Void)?

    public init() {
        MIDIClientCreateWithBlock("FM1Kit Monitor" as CFString, &client) { [weak self] n in
            if n.pointee.messageID == .msgSetupChanged { self?.connectAll() }
        }
        MIDIInputPortCreateWithProtocol(client, "FM1Kit Monitor In" as CFString, ._1_0, &port) { [weak self] list, _ in
            guard let self, let handler = self.onMessage else { return }
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let off = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
                let base = (UnsafeRawPointer(packet) + off).assumingMemoryBound(to: UInt32.self)
                for m in UMPToMIDI1.messages(UnsafeBufferPointer(start: base, count: count)) { handler(m) }
            }
        }
        connectAll()
    }

    /// Names of the sources currently listened to.
    public var sourceNames: [String] {
        (0..<MIDIGetNumberOfSources()).map { CoreMIDIProvider.name(of: MIDIGetSource($0)) }
    }

    public func connectAll() {
        lock.lock(); defer { lock.unlock() }
        let now = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) })
        for s in now.subtracting(connected) { MIDIPortConnectSource(port, s, nil) }
        for s in connected.subtracting(now) { MIDIPortDisconnectSource(port, s) }
        connected = now
    }

    public func stop() {
        onMessage = nil
        lock.lock(); defer { lock.unlock() }
        for s in connected { MIDIPortDisconnectSource(port, s) }
        connected = []
    }

    deinit {
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }
}
