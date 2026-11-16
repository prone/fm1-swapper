import FM1Kit
import Foundation
import Observation
import SwiftData

/// Thread-safe slot for the emulator's MIDI input (the router calls it on a CoreMIDI thread).
final class MIDISink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([UInt8]) -> Void)?
    func set(_ h: (@Sendable ([UInt8]) -> Void)?) { lock.withLock { handler = h } }
    func callAsFunction(_ m: [UInt8]) { lock.withLock { handler }?(m) }
}

/// The SMC-PAD (and SMC-PAD Pocket) side of the app: which pads are connected, the mapping
/// profile each one uses (per model, optionally per firmware), where mapped messages go
/// (the real FM-1 and/or the emulator), Learn, pad lights and the protocol-discovery log.
@MainActor @Observable
final class ControllerHub {
    struct Connected: Identifiable, Hashable { let name: String; let model: ControllerModel; var id: String { name } }
    struct LogLine: Identifiable { let id = UUID(); let date: Date; let source: String; let text: String; let sysex: Bool }

    private(set) var connected: [Connected] = []
    /// Live values per "model/control" for the on-screen pads.
    private(set) var activity: [String: UInt8] = [:]
    private(set) var log: [LogLine] = []
    /// While set, the next pad/knob touched on that model becomes this control's input.
    var learning: (model: ControllerModel, control: String)?
    private(set) var lastLearned: String?

    var sendToFM1: Bool { didSet { UserDefaults.standard.set(sendToFM1, forKey: "pad.toFM1"); updateOutputs() } }
    var sendToEmulator: Bool { didSet { UserDefaults.standard.set(sendToEmulator, forKey: "pad.toEmu") } }
    /// Paint the pads with each layout's colours (needs the pad's light session: Bluetooth or USB).
    var lights: Bool { didSet { UserDefaults.standard.set(lights, forKey: "pad.lights"); lights ? startLights() : stopLights() } }
    /// Flash a pad white while it is held (writes the pad's settings on every press: experimental).
    var flashOnPress: Bool { didSet { UserDefaults.standard.set(flashOnPress, forKey: "pad.flash") } }
    private(set) var lightStatus = ""
    /// The pad's own name and firmware ("SMC-PAD_004"), from the service protocol.
    private(set) var padName: String?
    private var lightSession: SMCPadLightSession?
    private(set) var fm1Port: String?
    private var deviceBusy = false

    /// Active profile per model (nil: the built-in default).
    private(set) var active: [ControllerModel: ControllerProfile] = [:]
    let router: ControllerRouter
    let emulatorSink = MIDISink()
    /// The in-app slice sampler the pads can play (per layout: Pads target).
    let sampler = SlicePlayer()
    /// Pads lit on screen by the sampler, "model/pad-n" -> time.
    private(set) var samplerFlash: [String: Date] = [:]
    /// Kits being decoded, by model.
    private(set) var loadingKit: Set<ControllerModel> = []

    init() {
        let d = UserDefaults.standard
        sendToFM1 = d.object(forKey: "pad.toFM1") as? Bool ?? true
        sendToEmulator = d.object(forKey: "pad.toEmu") as? Bool ?? true
        lights = d.object(forKey: "pad.lights") as? Bool ?? false
        flashOnPress = d.object(forKey: "pad.flash") as? Bool ?? false
        router = ControllerRouter(mappings: ControllerModel.allCases.map { ControllerMapping.defaultLayout(for: $0) })
        let sink = emulatorSink
        router.onOutput = { [weak self] m in
            sink(m)
            _ = self
        }
        router.onInput = { [weak self] source, raw, result in
            Task { @MainActor in self?.received(source: source, raw: raw, result: result) }
        }
        router.onSysEx = { [weak self] source, m in
            Task { @MainActor in
                guard let self else { return }
                var text = m.map { String(format: "%02X", $0) }.joined(separator: " ")
                if var u = Sinco.fromSysex(m) {
                    for f in Sinco.frames(&u) {
                        if let n = SMCPadProtocol.name(fromReply: f) { self.padName = n; text = "Pad reports \(n)" }
                    }
                }
                self.addLog(source, text, sysex: true)
            }
        }
        router.onSetupChanged = { [weak self] in Task { @MainActor in self?.refresh() } }
        let player = sampler
        router.onPad = { model, pad, velocity in player.trigger(model: model, pad: pad, velocity: velocity) }
        sampler.onTrigger = { [weak self] model, pad in
            Task { @MainActor in self?.samplerFlash["\(model.rawValue)/pad-\(pad)"] = Date() }
        }
        refresh()
        if lights { startLights() }
    }

    // MARK: devices

    func refresh() {
        connected = router.controllers().filter { ControllerModel.isPlayPort($0.name) }
            .map { Connected(name: $0.name, model: ControllerModel.detect(portName: $0.name, deviceName: padName)) }
        updateOutputs()
    }

    /// The FM-1's MIDI destination gets mapped messages (paused while installing or backing up).
    private func updateOutputs() {
        let fm1 = router.endpoints().first { looksLikeFM1($0.name) && !$0.name.lowercased().contains("ota") && $0.destinationUID != nil }
        fm1Port = fm1?.name
        router.outputUIDs = (sendToFM1 && !deviceBusy) ? Set([fm1?.destinationUID].compactMap { $0 }) : []
        router.enabled = true
    }

    func setDeviceBusy(_ busy: Bool) {
        deviceBusy = busy
        updateOutputs()
    }

    /// The models to show: connected ones, else both SMC-PADs.
    var models: [ControllerModel] {
        let c = Array(Set(connected.map(\.model))).sorted { $0.rawValue < $1.rawValue }
        return c.isEmpty ? [.smcPad, .smcPadPocket] : c
    }

    // MARK: profiles

    func mapping(_ model: ControllerModel) -> ControllerMapping { router.mapping(for: model) }

    /// Picks each model's profile: the one for the firmware on the FM-1, else the model's default.
    func selectProfiles(context: ModelContext, firmware: Firmware?) {
        let all = (try? context.fetch(FetchDescriptor<ControllerProfile>())) ?? []
        for model in ControllerModel.allCases {
            let mine = all.filter { $0.model == model }
            let pick = mine.first { $0.firmware != nil && $0.firmware?.persistentModelID == firmware?.persistentModelID }
                ?? mine.filter { $0.firmware == nil }.max { $0.updatedAt < $1.updatedAt }
            use(pick, model: model)
        }
    }

    func use(_ profile: ControllerProfile?, model: ControllerModel) {
        active[model] = profile
        router.setMapping(profile?.mapping ?? .defaultLayout(for: model))
        if lights { lightAll() }
        loadKit(profile?.kit, for: model)
    }

    // MARK: sampler

    func kit(for model: ControllerModel) -> SampleKit? { active[model]?.kit }

    /// Decodes a kit off the main thread and hands it to the sampler for this model.
    func loadKit(_ kit: SampleKit?, for model: ControllerModel) {
        guard let kit, let data = kit.audio else { sampler.setKit(nil, for: model); return }
        let name = kit.fileName, settings = kit.settingsData == nil ? nil : kit.settings, format = sampler.format
        loadingKit.insert(model)
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = try? LoadedKit(data: data, fileName: name, settings: settings, engineFormat: format)
            await MainActor.run {
                guard let self else { return }
                self.loadingKit.remove(model)
                if let loaded, kit.settingsData == nil {
                    kit.frames = loaded.mono.count
                    kit.sampleRate = loaded.sampleRate
                    kit.settings = loaded.settings
                }
                self.sampler.setKit(loaded, for: model)
            }
        }
    }

    /// Plays this kit from a model's pads (creating its editable layout if needed).
    func assign(_ kit: SampleKit?, to model: ControllerModel, context: ModelContext) {
        let p = editableProfile(model, context: context)
        p.kit = kit
        try? context.save()
        loadKit(kit, for: model)
    }

    func setPadTarget(_ t: ControllerMapping.PadTarget, model: ControllerModel, context: ModelContext) {
        update(model, context: context) { $0.padTarget = t }
    }

    func flashed(_ model: ControllerModel, _ pad: Int) -> Bool {
        guard let d = samplerFlash["\(model.rawValue)/pad-\(pad)"] else { return false }
        return Date().timeIntervalSince(d) < 0.15
    }

    /// The profile being edited for a model, created on first edit.
    func editableProfile(_ model: ControllerModel, context: ModelContext) -> ControllerProfile {
        if let p = active[model] { return p }
        let p = ControllerProfile(name: "\(model.displayName) default", mapping: .defaultLayout(for: model), firmware: nil)
        context.insert(p)
        try? context.save()
        active[model] = p
        return p
    }

    func update(_ model: ControllerModel, context: ModelContext, _ change: (inout ControllerMapping) -> Void) {
        let p = editableProfile(model, context: context)
        var m = p.mapping
        change(&m)
        p.mapping = m
        try? context.save()
        router.setMapping(m)
    }

    /// Copies the current layout into a profile used only while `firmware` is on the FM-1.
    func makeProfile(for firmware: Firmware, model: ControllerModel, context: ModelContext) {
        var m = mapping(model)
        m.name = "\(firmware.name)"
        let p = ControllerProfile(name: firmware.name, mapping: m, firmware: firmware)
        context.insert(p)
        try? context.save()
        use(p, model: model)
    }

    func resetLayout(_ model: ControllerModel, context: ModelContext) {
        update(model, context: context) { m in
            let name = m.name
            m = .defaultLayout(for: model, name: name)
        }
    }

    // MARK: input

    private func received(source: String, raw: [UInt8], result: MappingEngine.Result) {
        let model = ControllerModel.detect(portName: source)
        if let l = learning, l.model == model, let key = MIDIInputKey.of(raw), raw[0] & 0xF0 != 0x80, !(raw.count > 2 && raw[2] == 0 && key.kind == .note) {
            learnInput(key, model: model, control: l.control)
            learning = nil
        }
        if let c = result.control {
            activity["\(model.rawValue)/\(c)"] = result.value ?? 0
            if let nav = tutorialNav, (result.value ?? 0) > 0, c == "btn-1" || c == "btn-0" { nav(c == "btn-1" ? 1 : -1) }
            if flashOnPress, let s = lightSession, s.isReady, raw[0] & 0xF0 == 0x80 || raw[0] & 0xF0 == 0x90, raw.count > 2,
               let ctl = mapping(model).controls.first(where: { $0.id == c }) {
                let on = raw[0] & 0xF0 == 0x90 && raw[2] > 0
                let (r, g, b) = on ? (UInt8(240), UInt8(240), UInt8(240)) : PadPalette.color(ctl.color)
                s.paint(note: Int(raw[1]), r: r, g: g, b: b)
            }
        }
        addLog(source, describe(raw) + (result.messages.isEmpty ? "" : "  →  " + result.messages.map(describe).joined(separator: ", ")), sysex: false)
    }

    var contextForLearn: ModelContext?
    /// While a tutorial is open: the SMC-PAD's > (next) and < (back) buttons step through it.
    var tutorialNav: ((Int) -> Void)?

    private func learnInput(_ key: MIDIInputKey, model: ControllerModel, control: String) {
        guard let context = contextForLearn else { return }
        update(model, context: context) { m in
            for i in m.controls.indices where m.controls[i].input == key { m.controls[i].input = nil }
            if let i = m.controls.firstIndex(where: { $0.id == control }) { m.controls[i].input = key }
        }
        lastLearned = "\(control) ← \(key)"
    }

    func value(_ model: ControllerModel, _ control: String) -> UInt8 { activity["\(model.rawValue)/\(control)"] ?? 0 }

    private func addLog(_ source: String, _ text: String, sysex: Bool) {
        log.append(LogLine(date: Date(), source: source, text: text, sysex: sysex))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log.removeAll() }

    func describe(_ m: [UInt8]) -> String {
        guard let s = m.first else { return "" }
        let ch = Int(s & 0x0F) + 1
        let d1 = m.count > 1 ? Int(m[1]) : 0, d2 = m.count > 2 ? Int(m[2]) : 0
        switch s & 0xF0 {
        case 0x80: return "Note off \(Self.noteName(d1)) ch\(ch)"
        case 0x90: return d2 == 0 ? "Note off \(Self.noteName(d1)) ch\(ch)" : "Note \(Self.noteName(d1)) vel \(d2) ch\(ch)"
        case 0xA0: return "Pressure \(Self.noteName(d1)) \(d2) ch\(ch)"
        case 0xB0: return "CC \(d1) = \(d2) ch\(ch)"
        case 0xC0: return "Program \(d1) ch\(ch)"
        case 0xD0: return "Ch pressure \(d1) ch\(ch)"
        case 0xE0: return "Pitch bend \(((d2 << 7) | d1) - 8192) ch\(ch)"
        default: return m.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    static func noteName(_ n: Int) -> String {
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][n % 12] + "\(n / 12 - 2)" + " (\(n))"
    }

    // MARK: lights and probes

    private func startLights() {
        stopLights()
        // USB when the pad's configuration port is there (no pairing needed), else Bluetooth.
        let usb = SMCPadUSBChannel.privatePort(in: CoreMIDIProvider.shared) != nil
        let channel: SincoChannel = usb ? SMCPadUSBChannel() : SMCPadBLEChannel()
        let session = SMCPadLightSession(channel: channel)
        session.onState = { [weak self] st in
            guard let self else { return }
            switch st {
            case .idle: self.lightStatus = ""
            case let .connecting(m): self.lightStatus = m
            case let .unlocking(n, t): self.lightStatus = "Opening the light session (\(n)/\(t))…"
            case .ready: self.lightStatus = "Lights on (\(usb ? "USB" : "Bluetooth"))"; self.lightAll()
            case let .failed(m): self.lightStatus = m
            }
        }
        session.onName = { [weak self] n in self?.padName = n; self?.addLog("pad", "Pad reports \(n)", sysex: true); self?.refresh() }
        lightSession = session
        session.start()
    }

    private func stopLights() {
        lightSession?.stop()
        lightSession = nil
        lightStatus = ""
    }

    var lightsReady: Bool { lightSession?.isReady ?? false }

    /// Paints every pad with its layout colour (bank B too when it mirrors bank A).
    func lightAll() {
        guard let s = lightSession, s.isReady else { return }
        let model = connected.first?.model ?? .smcPad
        let m = mapping(model)
        for c in m.controls where c.isPad {
            guard let input = c.input, input.kind == .note else { continue }
            let (r, g, b) = PadPalette.color(c.color)
            s.paint(note: Int(input.number), r: r, g: g, b: b)
            if m.bankBMirrorsA, input.number < 112 { s.paint(note: Int(input.number) + 16, r: r, g: g, b: b) }
        }
    }

    func testPaint(note: Int, r: UInt8, g: UInt8, b: UInt8) {
        guard let s = lightSession, s.isReady else { addLog("app", "Turn on pad lights first", sysex: false); return }
        s.paint(note: note, r: r, g: g, b: b)
        addLog("app", "Paint note \(note) → \(r),\(g),\(b)", sysex: false)
    }

    func probe() {
        addLog("app", "Asked the pad for its name and version", sysex: true)
        router.probeIdentity()
        if lightSession == nil { addLog("app", "Over Bluetooth the name arrives when the light session opens", sysex: false) }
    }

    func sendRaw(_ bytes: [UInt8], model: ControllerModel) {
        addLog("app → \(model.displayName)", bytes.map { String(format: "%02X", $0) }.joined(separator: " "), sysex: bytes.first == 0xF0)
        router.sendToController(bytes, model: model)
    }

    var logText: String {
        let f = ISO8601DateFormatter()
        return log.map { "\(f.string(from: $0.date))\t\($0.source)\t\($0.text)" }.joined(separator: "\n")
    }
}
