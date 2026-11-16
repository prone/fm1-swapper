import CoreAudioKit
import FM1Kit
import SwiftData
import SwiftUI

/// Apple's Bluetooth MIDI pairing screen (finds and connects BLE MIDI devices like the SMC-PADs).
struct BluetoothMIDIPairing: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CABTMIDICentralViewController())
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

struct PadsView: View {
    @Environment(ControllerHub.self) private var hub
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Query(sort: \ControllerProfile.name) private var profiles: [ControllerProfile]
    @Query private var firmwares: [Firmware]
    @State private var model: ControllerModel = .smcPad
    @State private var pairing = false
    @State private var editing: ControlMap?

    var currentFirmware: Firmware? {
        guard let id = device.identity, !id.isLoader else { return nil }
        return firmwares.filter { $0.product == id.text }.max { ($0.lastInstalled ?? .distantPast) < ($1.lastInstalled ?? .distantPast) }
    }

    var body: some View {
        @Bindable var hub = hub
        NavigationStack {
            List {
                Section {
                    if hub.connected.isEmpty {
                        Label("No SMC-PAD connected", systemImage: "square.grid.4x3.fill").foregroundStyle(.secondary)
                    }
                    ForEach(hub.connected) { c in
                        LabeledContent { Text(c.model.displayName) } label: { Label(c.name, systemImage: "dot.radiowaves.left.and.right") }
                    }
                    Button { pairing = true } label: { Label("Pair over Bluetooth…", systemImage: "antenna.radiowaves.left.and.right") }
                } header: { Text("Controllers") } footer: {
                    Text("Turn the pad on and pair it here (Bluetooth leaves the USB port for the FM-1). It reconnects by itself after that. A USB hub works too.")
                }

                Section("Send pads to") {
                    Toggle(isOn: $hub.sendToFM1) {
                        VStack(alignment: .leading) {
                            Text("The FM-1")
                            Text(hub.fm1Port.map { "via \($0)" } ?? "not connected").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("The emulator (when open)", isOn: $hub.sendToEmulator)
                    Toggle("Pad lights (experimental)", isOn: $hub.lights)
                }

                Section {
                    Picker("Model", selection: $model) {
                        ForEach([ControllerModel.smcPad, .smcPadPocket]) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    profilePicker
                    let m = hub.mapping(model)
                    Stepper("Output channel \(m.channel + 1)", value: Binding(get: { Int(m.channel) }, set: { v in hub.update(model, context: context) { $0.channel = UInt8(v) } }), in: 0...15)
                    Toggle("Pass other messages through", isOn: Binding(get: { m.passThroughUnmapped }, set: { v in hub.update(model, context: context) { $0.passThroughUnmapped = v } }))
                    if let fw = currentFirmware, hub.active[model]?.firmware?.persistentModelID != fw.persistentModelID {
                        Button("Make a layout just for \(fw.name)") { hub.makeProfile(for: fw, model: model, context: context) }
                    }
                } header: { Text("Layout") } footer: {
                    Text(model == .smcPadPocket
                         ? "The Pocket has no knobs: hold the Shift pad (pad 16 by default) and the other pads step CCs down (1–8) and up (9–15). Each pad's shift action is editable."
                         : "Layouts are kept per model. A layout made for a firmware is picked automatically whenever that firmware is on the FM-1.")
                }

                Section {
                    PadGrid(model: model) { editing = $0 }
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    if let l = hub.lastLearned { Text("Learned \(l)").font(.caption).foregroundStyle(.green) }
                } header: { Text("Pads & knobs") } footer: { Text("Tap a pad or knob to change what it sends, or to learn which physical control it is.") }

                Section {
                    NavigationLink { PadLabView(model: model) } label: { Label("Lab: identify, MIDI log, light test", systemImage: "testtube.2") }
                    Button("Reset this layout", role: .destructive) { hub.resetLayout(model, context: context) }
                }
            }
            .navigationTitle("Pads")
            .sheet(isPresented: $pairing, onDismiss: { hub.refresh() }) { BluetoothMIDIPairing().ignoresSafeArea() }
            .sheet(item: $editing) { c in ControlEditor(model: model, controlID: c.id) }
            .onAppear {
                hub.contextForLearn = context
                if let m = hub.connected.first?.model, m != .generic { model = m }
                hub.selectProfiles(context: context, firmware: currentFirmware)
            }
            .onChange(of: device.identity?.text) { hub.selectProfiles(context: context, firmware: currentFirmware) }
            .onChange(of: hub.connected) { if let m = hub.connected.first?.model, m != .generic { model = m } }
        }
    }

    private var profilePicker: some View {
        let mine = profiles.filter { $0.model == model }
        return Picker("Profile", selection: Binding(get: { hub.active[model]?.persistentModelID },
                                                     set: { id in hub.use(mine.first { $0.persistentModelID == id }, model: model) })) {
            Text("Built-in default").tag(PersistentIdentifier?.none)
            ForEach(mine) { p in Text(p.firmware.map { "\(p.name) (for \($0.name))" } ?? p.name).tag(Optional(p.persistentModelID)) }
        }
    }
}

struct PadGrid: View {
    @Environment(ControllerHub.self) private var hub
    let model: ControllerModel
    let onTap: (ControlMap) -> Void

    var body: some View {
        let m = hub.mapping(model)
        let pads = m.controls.filter(\.isPad)
        let knobs = m.controls.filter { !$0.isPad }
        VStack(spacing: 14) {
            if !knobs.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(knobs) { k in
                        Button { onTap(k) } label: { KnobCell(control: k, value: hub.value(model, k.id), learning: isLearning(k)) }
                            .buttonStyle(.plain)
                    }
                }
            }
            // SMC-PAD pad 1 is bottom left, like most pad controllers: show rows top to bottom as 13-16 ... 1-4
            let rows = stride(from: max(pads.count - 4, 0), through: 0, by: -4).map { Array(pads[$0..<min($0 + 4, pads.count)]) }
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 8) {
                        ForEach(rows[r]) { p in
                            Button { onTap(p) } label: { PadCell(control: p, value: hub.value(model, p.id), learning: isLearning(p)) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    func isLearning(_ c: ControlMap) -> Bool { hub.learning?.model == model && hub.learning?.control == c.id }
}

/// The colour a pad shows on screen, from the light colour index.
func padColor(_ i: UInt8) -> Color {
    let palette: [Color] = [.gray, .red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]
    return palette[Int(i) % palette.count]
}

struct PadCell: View {
    let control: ControlMap
    let value: UInt8
    let learning: Bool

    var body: some View {
        let on = value > 0
        VStack(spacing: 2) {
            Text(control.label).font(.caption2.weight(.semibold))
            Text(summary).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(RoundedRectangle(cornerRadius: 10).fill(padColor(control.color).opacity(on ? 0.85 : 0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(learning ? Color.accentColor : .clear, lineWidth: 3))
        .animation(.easeOut(duration: 0.12), value: on)
    }

    var summary: String {
        switch control.output {
        case .note: ControllerHub.noteName(Int(control.number)).components(separatedBy: " ").first ?? ""
        case .cc: "CC \(control.number)"
        case .program: "PC \(control.number)"
        case .ccUp: "CC \(control.number) +"
        case .ccDown: "CC \(control.number) −"
        case .shift: "SHIFT"
        case .off: "off"
        }
    }
}

struct KnobCell: View {
    let control: ControlMap
    let value: UInt8
    let learning: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 4)
                Circle().trim(from: 0, to: CGFloat(value) / 127).stroke(Color.accentColor, style: .init(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(value)").font(.system(size: 9).monospacedDigit())
            }
            .frame(width: 34, height: 34)
            .overlay(Circle().strokeBorder(learning ? Color.accentColor : .clear, lineWidth: 3).padding(-4))
            Text(control.output == .cc ? "CC\(control.number)" : control.label).font(.system(size: 9)).lineLimit(1)
        }
    }
}

struct ControlEditor: View {
    @Environment(ControllerHub.self) private var hub
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let model: ControllerModel
    let controlID: String

    var control: ControlMap? { hub.mapping(model).controls.first { $0.id == controlID } }

    func set(_ change: @escaping (inout ControlMap) -> Void) {
        hub.update(model, context: context) { m in
            if let i = m.controls.firstIndex(where: { $0.id == controlID }) { change(&m.controls[i]) }
        }
    }

    var body: some View {
        NavigationStack {
            if let c = control {
                Form {
                    Section {
                        LabeledContent("Sends", value: c.input?.description ?? "not learned")
                        if hub.learning?.control == controlID {
                            HStack { ProgressView(); Text("Press or turn it on the \(model.displayName) now…") }
                            Button("Cancel") { hub.learning = nil }
                        } else {
                            Button { hub.learning = (model, controlID) } label: { Label("Learn from the pad", systemImage: "hand.tap") }
                        }
                        TextField("Name", text: Binding(get: { c.label }, set: { v in set { $0.label = v } }))
                    } header: { Text("Input") }

                    Section("Does") {
                        outputPicker(c.output) { v in set { $0.output = v } }
                        numberRow(c.output, c.number) { v in set { $0.number = v } }
                        if c.output == .ccUp || c.output == .ccDown || c.shiftOutput == .ccUp || c.shiftOutput == .ccDown {
                            Stepper("Step \(c.step)", value: Binding(get: { Int(c.step) }, set: { v in set { $0.step = UInt8(v) } }), in: 1...64)
                        }
                        Picker("Channel", selection: Binding(get: { c.channel.map(Int.init) ?? -1 }, set: { v in set { $0.channel = v < 0 ? nil : UInt8(v) } })) {
                            Text("Layout's (\(hub.mapping(model).channel + 1))").tag(-1)
                            ForEach(0..<16, id: \.self) { Text("\($0 + 1)").tag($0) }
                        }
                        if !c.isPad {
                            Picker("Knob sends", selection: Binding(get: { c.knobMode }, set: { v in set { $0.knobMode = v } })) {
                                Text("Absolute 0–127").tag(ControlMap.KnobMode.absolute)
                                Text("Relative (64 ± n)").tag(ControlMap.KnobMode.relative64)
                                Text("Relative (1 / 127)").tag(ControlMap.KnobMode.relativeTwos)
                            }
                        }
                    }

                    if c.isPad, c.output != .shift {
                        Section {
                            outputPicker(c.shiftOutput, allowShift: false) { v in set { $0.shiftOutput = v } }
                            if c.shiftOutput != .off { numberRow(c.shiftOutput, c.shiftNumber) { v in set { $0.shiftNumber = v } } }
                        } header: { Text("While Shift is held") } footer: {
                            Text("Set one pad to “Shift” to use these. Handy on the Pocket, which has no knobs.")
                        }
                        Section("Light") {
                            Stepper(value: Binding(get: { Int(c.color) }, set: { v in set { $0.color = UInt8(v) }; hub.router.light(c, model: model, color: UInt8(v)) }), in: 0...127) {
                                HStack { Circle().fill(padColor(c.color)).frame(width: 16); Text("Colour \(c.color)") }
                            }
                        }
                    }
                }
                .navigationTitle(c.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { hub.learning = nil; dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    func outputPicker(_ value: ControlMap.Output, allowShift: Bool = true, _ set: @escaping (ControlMap.Output) -> Void) -> some View {
        Picker("Action", selection: Binding(get: { value }, set: set)) {
            Text("Play a note").tag(ControlMap.Output.note)
            Text("Send a CC").tag(ControlMap.Output.cc)
            Text("Program change").tag(ControlMap.Output.program)
            Text("Step a CC up").tag(ControlMap.Output.ccUp)
            Text("Step a CC down").tag(ControlMap.Output.ccDown)
            if allowShift { Text("Shift").tag(ControlMap.Output.shift) }
            Text("Nothing").tag(ControlMap.Output.off)
        }
    }

    @ViewBuilder
    func numberRow(_ output: ControlMap.Output, _ n: UInt8, _ set: @escaping (UInt8) -> Void) -> some View {
        if output != .off && output != .shift {
            Stepper(value: Binding(get: { Int(n) }, set: { set(UInt8($0)) }), in: 0...127) {
                Text(output == .note ? "Note \(ControllerHub.noteName(Int(n)))" : output == .program ? "Program \(n)" : "CC \(n)")
            }
        }
    }
}

/// Protocol discovery: identity request, a log of everything the pads send (SysEx included),
/// and a light test, to work out each model's real layout and M-VAVE's configuration messages.
struct PadLabView: View {
    @Environment(ControllerHub.self) private var hub
    let model: ControllerModel
    @State private var testNote = 36
    @State private var testVelocity = 1
    @State private var testChannel = 9
    @State private var raw = ""

    var body: some View {
        List {
            Section {
                Button { hub.probe() } label: { Label("Ask the pads to identify themselves", systemImage: "questionmark.circle") }
            } footer: { Text("Sends the standard MIDI identity request. Replies (manufacturer, model, firmware version) appear in the log as SysEx.") }

            Section {
                Stepper("Note \(ControllerHub.noteName(testNote))", value: $testNote, in: 0...127)
                Stepper("Velocity (colour) \(testVelocity)", value: $testVelocity, in: 0...127)
                Stepper("Channel \(testChannel + 1)", value: $testChannel, in: 0...15)
                HStack {
                    Button("Light it") { hub.sendRaw([0x90 | UInt8(testChannel), UInt8(testNote), UInt8(testVelocity)], model: model) }
                    Spacer()
                    Button("Off") { hub.sendRaw([0x80 | UInt8(testChannel), UInt8(testNote), 0], model: model) }
                }.buttonStyle(.borderless)
            } header: { Text("Light test (\(model.displayName))") } footer: {
                Text("Many pad controllers light a pad when sent its own note; velocity picks the colour. Find a channel and velocities that work, and the layout's pad lights will use them.")
            }

            Section("Send raw bytes") {
                TextField("e.g. F0 7E 7F 06 01 F7", text: $raw).font(.body.monospaced()).textInputAutocapitalization(.characters)
                Button("Send to \(model.displayName)") {
                    let bytes = raw.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { UInt8($0, radix: 16) }
                    if !bytes.isEmpty { hub.sendRaw(bytes, model: model) }
                }
            }

            Section {
                if hub.log.isEmpty { Text("Press pads and turn knobs to see what they send.").foregroundStyle(.secondary) }
                ForEach(hub.log.reversed()) { l in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.text).font(.caption.monospaced()).foregroundStyle(l.sysex ? Color.orange : Color.primary).textSelection(.enabled)
                        Text("\(l.source) · \(l.date.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                HStack {
                    Text("MIDI log")
                    Spacer()
                    ShareLink(item: hub.logText) { Image(systemName: "square.and.arrow.up") }
                    Button("Clear") { hub.clearLog() }.font(.caption)
                }
            }
        }
        .navigationTitle("Pad lab")
    }
}
