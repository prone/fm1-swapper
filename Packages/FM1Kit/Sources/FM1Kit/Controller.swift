import CoreMIDI
import Foundation

// MARK: - Mapping

/// What a physical control sends: a note or a CC on a channel (0-15).
public struct MIDIInputKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case note, cc }
    public var kind: Kind
    public var channel: UInt8
    public var number: UInt8
    public init(kind: Kind, channel: UInt8, number: UInt8) { self.kind = kind; self.channel = channel; self.number = number }
    public var description: String { "\(kind == .note ? "Note" : "CC") \(number) ch\(channel + 1)" }

    /// The control a channel message comes from (note on/off or CC), if any.
    public static func of(_ m: [UInt8]) -> MIDIInputKey? {
        guard m.count >= 2 else { return nil }
        let hi = m[0] & 0xF0, ch = m[0] & 0x0F
        switch hi {
        case 0x80, 0x90, 0xA0: return .init(kind: .note, channel: ch, number: m[1])
        case 0xB0: return .init(kind: .cc, channel: ch, number: m[1])
        default: return nil
        }
    }
}

/// The controllers this app knows. Layouts differ, so each has its own mapping profiles.
public enum ControllerModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case smcPad, smcPadPocket, generic
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .smcPad: "SMC-PAD"
        case .smcPadPocket: "SMC-PAD Pocket"
        case .generic: "MIDI controller"
        }
    }
    public var padCount: Int { 16 }
    public var knobCount: Int { self == .smcPadPocket ? 0 : 8 }

    /// Best guess from the CoreMIDI port name (USB product name or Bluetooth name).
    public static func detect(portName: String) -> ControllerModel {
        let n = portName.lowercased()
        guard n.contains("smc") || (n.contains("vave") && n.contains("pad")) else { return .generic }
        return n.contains("pocket") ? .smcPadPocket : .smcPad
    }

    /// Refines the guess with a MIDI identity reply (F0 7E id 06 02 manufacturer family model version F7).
    /// The product codes are filled in once both pads have answered; until then the name decides.
    public static func detect(portName: String, identity: [UInt8]?) -> ControllerModel {
        detect(portName: portName)
    }
}

/// One pad or knob: what it sends and what the app turns it into.
public struct ControlMap: Codable, Hashable, Sendable, Identifiable {
    public enum Output: String, Codable, Sendable, CaseIterable {
        case note, cc, program, off
        /// Pads standing in for knobs (the Pocket has none): step a CC up or down by `step`.
        case ccUp, ccDown
        /// Held, switches every other pad to its shift output.
        case shift
    }
    public enum KnobMode: String, Codable, Sendable, CaseIterable { case absolute, relative64, relativeTwos }

    public var id: String
    public var label: String
    public var input: MIDIInputKey?
    public var output: Output
    public var number: UInt8
    /// nil: the mapping's output channel.
    public var channel: UInt8?
    public var knobMode: KnobMode
    /// Pad light colour (velocity sent back to the pad), 0 = off.
    public var color: UInt8
    /// What a pad does while the shift pad is held.
    public var shiftOutput: Output
    public var shiftNumber: UInt8
    public var step: UInt8

    public init(id: String, label: String, input: MIDIInputKey? = nil, output: Output, number: UInt8,
                channel: UInt8? = nil, knobMode: KnobMode = .absolute, color: UInt8 = 0,
                shiftOutput: Output = .off, shiftNumber: UInt8 = 0, step: UInt8 = 8) {
        self.id = id; self.label = label; self.input = input; self.output = output; self.number = number
        self.channel = channel; self.knobMode = knobMode; self.color = color
        self.shiftOutput = shiftOutput; self.shiftNumber = shiftNumber; self.step = step
    }

    public var isPad: Bool { id.hasPrefix("pad") }
}

/// A layout for one controller model and where its messages go.
public struct ControllerMapping: Codable, Hashable, Sendable {
    public var name: String
    public var model: ControllerModel
    /// Output channel 0-15.
    public var channel: UInt8
    public var controls: [ControlMap]
    /// Send messages from controls that have no mapping unchanged (keyboards, wheels...).
    public var passThroughUnmapped: Bool
    /// Pad lights: channel the pad listens on for LED notes.
    public var lightChannel: UInt8

    public init(name: String, model: ControllerModel, channel: UInt8, controls: [ControlMap],
                passThroughUnmapped: Bool = true, lightChannel: UInt8 = 9) {
        self.name = name; self.model = model; self.channel = channel; self.controls = controls
        self.passThroughUnmapped = passThroughUnmapped; self.lightChannel = lightChannel
    }

    static func pad(_ i: Int) -> ControlMap {
        let input = MIDIInputKey(kind: .note, channel: 9, number: UInt8(36 + i))
        return ControlMap(id: "pad-\(i)", label: "Pad \(i + 1)", input: input, output: .note,
                          number: UInt8(48 + i), color: UInt8(1 + i % 7))
    }

    static func knob(_ i: Int) -> ControlMap {
        let input = MIDIInputKey(kind: .cc, channel: 0, number: UInt8(70 + i))
        return ControlMap(id: "knob-\(i)", label: "Knob \(i + 1)", input: input, output: .cc, number: UInt8(70 + i))
    }

    /// Starting layout for a model: pads play a chromatic run from note 48 (C2), knobs send CC 70-77, channel 1.
    /// Inputs are guesses until learned. On the Pocket, pad 16 is shift: held, pads 1-8 step CC 70-77
    /// down and pads 9-15 step CC 70-76 up, standing in for the knobs it lacks.
    public static func defaultLayout(for model: ControllerModel, name: String = "Default") -> ControllerMapping {
        var pads: [ControlMap] = (0..<model.padCount).map { pad($0) }
        let knobs: [ControlMap] = (0..<model.knobCount).map { knob($0) }
        if model == .smcPadPocket {
            pads[15].output = .shift
            pads[15].label = "Shift"
            for i in 0..<15 {
                pads[i].shiftOutput = i < 8 ? .ccDown : .ccUp
                pads[i].shiftNumber = UInt8(70 + i % 8)
            }
        }
        return ControllerMapping(name: name, model: model, channel: 0, controls: pads + knobs)
    }

    public static func smcPadDefault(name: String = "Default") -> ControllerMapping { defaultLayout(for: .smcPad, name: name) }

    public func control(for key: MIDIInputKey) -> ControlMap? { controls.first { $0.input == key } }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ d: Data) -> ControllerMapping? { try? JSONDecoder().decode(ControllerMapping.self, from: d) }
}

/// Turns controller messages into output messages. Keeps the state relative knobs, stepped
/// CCs and the shift pad need.
public struct MappingEngine: Sendable {
    public var mapping: ControllerMapping
    private var values: [String: Int] = [:]
    private var shiftHeld = false

    public init(mapping: ControllerMapping) { self.mapping = mapping }

    public struct Result: Equatable, Sendable {
        public var messages: [[UInt8]]
        /// Which control it came from (for the on-screen pads and Learn).
        public var control: String?
        public var value: UInt8?
    }

    private mutating func stepped(_ cc: UInt8, _ delta: Int) -> UInt8 {
        let key = "cc-\(cc)"
        let v = max(0, min(127, (values[key] ?? 64) + delta))
        values[key] = v
        return UInt8(v)
    }

    public mutating func transform(_ m: [UInt8]) -> Result {
        guard let key = MIDIInputKey.of(m), let c = mapping.control(for: key) else {
            let realtime = m.first.map { $0 >= 0xF0 } ?? true
            let pass = mapping.passThroughUnmapped && !realtime ? [m] : []
            return Result(messages: pass, control: nil, value: nil)
        }
        let ch = c.channel ?? mapping.channel
        let hi = m[0] & 0xF0
        let raw: UInt8 = m.count > 2 ? m[2] : 0
        let isOff = hi == 0x80 || (hi == 0x90 && raw == 0)

        if hi == 0xA0 { // aftertouch on a pad
            switch c.output {
            case .note: return Result(messages: [[0xA0 | ch, c.number, raw]], control: c.id, value: raw)
            case .cc: return Result(messages: [[0xB0 | ch, c.number, raw]], control: c.id, value: raw)
            default: return Result(messages: [], control: c.id, value: raw)
            }
        }

        if c.output == .shift {
            shiftHeld = key.kind == .note ? !isOff : raw >= 64
            return Result(messages: [], control: c.id, value: shiftHeld ? 127 : 0)
        }

        // the value this control now has (0-127)
        var value: UInt8 = key.kind == .note ? (isOff ? 0 : raw) : raw
        if key.kind == .cc, c.knobMode != .absolute {
            let delta = c.knobMode == .relative64 ? Int(raw) - 64 : (raw < 64 ? Int(raw) : Int(raw) - 128)
            value = stepped(c.number, delta)
        }

        let useShift = shiftHeld && c.isPad && c.shiftOutput != .off
        let output = useShift ? c.shiftOutput : c.output
        let number = useShift ? c.shiftNumber : c.number
        var out: [[UInt8]] = []
        switch output {
        case .off, .shift: break
        case .note:
            if key.kind == .note {
                out = [isOff ? [0x80 | ch, number, 0] : [0x90 | ch, number, value]]
            } else {
                out = [value > 0 ? [0x90 | ch, number, value] : [0x80 | ch, number, 0]] // knob as a gate
            }
        case .cc:
            out = [[0xB0 | ch, number, value]]
        case .program:
            if !(key.kind == .note && isOff) { out = [[0xC0 | ch, key.kind == .note ? number : value]] }
        case .ccUp, .ccDown:
            if !isOff {
                let v = stepped(number, (output == .ccUp ? 1 : -1) * Int(c.step))
                out = [[0xB0 | ch, number, v]]
                value = v
            }
        }
        return Result(messages: out, control: c.id, value: value)
    }
}

// MARK: - Router

/// Listens to a MIDI controller (the SMC-PAD, over Bluetooth or USB), maps its messages and sends them
/// to the FM-1 (a CoreMIDI destination) and to any in-app listener (the emulator). Also talks back to
/// the controller: pad lights and SysEx probes.
public final class ControllerRouter: @unchecked Sendable {
    public struct Endpoint: Hashable, Sendable, Identifiable {
        public let name: String
        public let sourceUID: MIDIUniqueID?
        public let destinationUID: MIDIUniqueID?
        public var id: String { name }
    }

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private let lock = NSLock()
    private var engines: [ControllerModel: MappingEngine] = [:]
    private var connectedSources: Set<MIDIEndpointRef> = []
    private var sysexAssembler = SysEx7Assembler()

    /// Controller sources whose names match this are routed.
    public var controllerPattern: NSRegularExpression
    /// Where mapped messages go on CoreMIDI (the FM-1), by destination unique ID.
    public var outputUIDs: Set<MIDIUniqueID> = []
    public var enabled = true

    /// Mapped output, for in-app instruments (the emulator). Called on a CoreMIDI thread.
    public var onOutput: (@Sendable ([UInt8]) -> Void)?
    /// Every raw controller message with its mapping result. Called on a CoreMIDI thread.
    public var onInput: (@Sendable (_ source: String, _ message: [UInt8], _ result: MappingEngine.Result) -> Void)?
    public var onSysEx: (@Sendable (_ source: String, _ message: [UInt8]) -> Void)?
    public var onSetupChanged: (@Sendable () -> Void)?

    public static let smcPadPattern = try! NSRegularExpression(pattern: "smc|m-?vave.*pad", options: .caseInsensitive)

    public init(mappings: [ControllerMapping], pattern: NSRegularExpression = ControllerRouter.smcPadPattern) {
        for m in mappings { engines[m.model] = MappingEngine(mapping: m) }
        controllerPattern = pattern
        MIDIClientCreateWithBlock("FM1Kit Controller" as CFString, &client) { [weak self] n in
            if n.pointee.messageID == .msgSetupChanged { self?.reconnect(); self?.onSetupChanged?() }
        }
        MIDIInputPortCreateWithProtocol(client, "FM1Kit Controller In" as CFString, ._1_0, &inPort) { [weak self] list, refCon in
            guard let self else { return }
            let src = refCon.map { MIDIEndpointRef(UInt32(Int(bitPattern: $0))) }
            let name = src.map { CoreMIDIProvider.name(of: $0) } ?? "?"
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let off = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
                let words = UnsafeBufferPointer(start: (UnsafeRawPointer(packet) + off).assumingMemoryBound(to: UInt32.self), count: count)
                for s in self.sysexAssembler.feed(words) { self.onSysEx?(name, s) }
                for m in UMPToMIDI1.messages(words) { self.handle(m, from: name) }
            }
        }
        MIDIOutputPortCreate(client, "FM1Kit Controller Out" as CFString, &outPort)
        reconnect()
    }

    deinit {
        MIDIPortDispose(inPort); MIDIPortDispose(outPort); MIDIClientDispose(client)
    }

    /// The active mapping for a model (one per model: both pads can be connected at once).
    public func mapping(for model: ControllerModel) -> ControllerMapping {
        lock.withLock { engines[model]?.mapping } ?? .defaultLayout(for: model)
    }

    public func setMapping(_ m: ControllerMapping) {
        lock.withLock {
            if engines[m.model] != nil { engines[m.model]!.mapping = m } else { engines[m.model] = MappingEngine(mapping: m) }
        }
    }

    private func matches(_ name: String) -> Bool {
        controllerPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Controllers currently visible to CoreMIDI.
    public func controllers() -> [Endpoint] {
        endpoints().filter { matches($0.name) }
    }

    /// All MIDI ports (for picking the FM-1 output).
    public func endpoints() -> [Endpoint] {
        var byName: [String: (MIDIUniqueID?, MIDIUniqueID?)] = [:]
        for i in 0..<MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            byName[CoreMIDIProvider.name(of: s), default: (nil, nil)].0 = CoreMIDIProvider.uid(of: s)
        }
        for i in 0..<MIDIGetNumberOfDestinations() {
            let d = MIDIGetDestination(i)
            byName[CoreMIDIProvider.name(of: d), default: (nil, nil)].1 = CoreMIDIProvider.uid(of: d)
        }
        return byName.map { Endpoint(name: $0.key, sourceUID: $0.value.0, destinationUID: $0.value.1) }.sorted { $0.name < $1.name }
    }

    public func reconnect() {
        lock.lock(); defer { lock.unlock() }
        var want: Set<MIDIEndpointRef> = []
        for i in 0..<MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            if matches(CoreMIDIProvider.name(of: s)) { want.insert(s) }
        }
        for s in want.subtracting(connectedSources) {
            MIDIPortConnectSource(inPort, s, UnsafeMutableRawPointer(bitPattern: Int(s)))
        }
        for s in connectedSources.subtracting(want) { MIDIPortDisconnectSource(inPort, s) }
        connectedSources = want
    }

    private func handle(_ m: [UInt8], from source: String) {
        guard let first = m.first, first < 0xF8 || first == 0xFA || first == 0xFC else { return } // drop clock/active sensing
        let model = ControllerModel.detect(portName: source)
        let result: MappingEngine.Result = lock.withLock {
            if engines[model] == nil { engines[model] = MappingEngine(mapping: .defaultLayout(for: model)) }
            return engines[model]!.transform(m)
        }
        onInput?(source, m, result)
        guard enabled else { return }
        for out in result.messages {
            onOutput?(out)
            for uid in outputUIDs { send(out, toUID: uid) }
        }
    }

    // MARK: sending

    public func send(_ m: [UInt8], toUID uid: MIDIUniqueID) {
        var obj = MIDIObjectRef(), t = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(uid, &obj, &t) == noErr else { return }
        let words: [UInt32] = m.first == 0xF0 ? SysEx7Assembler.words(for: m) : [Self.ump(m)]
        let size = 256 + words.count * 8
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        let list = buf.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
        let step = m.first == 0xF0 ? 2 : 1
        words.withUnsafeBufferPointer { w in
            var i = 0
            while i < w.count, let p = packet {
                packet = MIDIEventListAdd(list, size, p, 0, step, w.baseAddress! + i)
                i += step
            }
        }
        MIDISendEventList(outPort, MIDIEndpointRef(obj), list)
    }

    static func ump(_ m: [UInt8]) -> UInt32 {
        let s = UInt32(m[0]), d1 = m.count > 1 ? UInt32(m[1]) : 0, d2 = m.count > 2 ? UInt32(m[2]) : 0
        return (s >= 0xF0 ? 0x1000_0000 : 0x2000_0000) | s << 16 | d1 << 8 | d2
    }

    /// Sends to connected controllers (all, or one model) on their matching destinations.
    public func sendToController(_ m: [UInt8], model: ControllerModel? = nil) {
        for c in controllers() where model == nil || ControllerModel.detect(portName: c.name) == model {
            if let d = c.destinationUID { send(m, toUID: d) }
        }
    }

    /// Lights a pad the way many pad controllers do: a note-on to the pad's own note, velocity = colour.
    /// Unconfirmed for the SMC-PADs: the Lab screen tests it.
    public func light(_ control: ControlMap, model: ControllerModel, color: UInt8? = nil) {
        guard let input = control.input, input.kind == .note else { return }
        let ch = mapping(for: model).lightChannel
        let v = color ?? control.color
        sendToController(v == 0 ? [0x80 | ch, input.number, 0] : [0x90 | ch, input.number, v & 0x7F], model: model)
    }

    /// MIDI universal identity request (answers with manufacturer, family and firmware version).
    public func probeIdentity(model: ControllerModel? = nil) { sendToController([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], model: model) }
}
