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
                    if let n = hub.padName { LabeledContent("Pad firmware", value: n) }
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
                }

                Section {
                    Toggle("Light the pads in the layout's colours", isOn: $hub.lights)
                    if hub.lights && !hub.lightStatus.isEmpty { Text(hub.lightStatus).font(.caption).foregroundStyle(.secondary) }
                    if hub.lights { Toggle("Flash white while a pad is held", isOn: $hub.flashOnPress) }
                } header: { Text("Pad lights") } footer: {
                    Text("The SMC-PAD's lights don't follow MIDI: the app opens the pad's own light session (as M-VAVE's MIDI Suite does), over USB if the pad is plugged in, otherwise Bluetooth. Colours are saved into the pad's preset 1. Flashing on press rewrites a colour on every hit, so it is off by default. Verified on the full-size pad by others; the Pocket is untested.")
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
                    Toggle("PAD BANK B plays the same pads", isOn: Binding(get: { m.bankBMirrorsA }, set: { v in hub.update(model, context: context) { $0.bankBMirrorsA = v } }))
                    if let fw = currentFirmware, hub.active[model]?.firmware?.persistentModelID != fw.persistentModelID {
                        Button("Make a layout just for \(fw.name)") { hub.makeProfile(for: fw, model: model, context: context) }
                    }
                } header: { Text("Layout") } footer: {
                    Text(model == .smcPadPocket
                         ? "The Pocket has no knobs, and its SHIFT button sends nothing to apps, so pad 16 is a held Shift pad: hold it and pads 1–8 step CC 30–37 down, 9–15 step them up. Each pad's shift action is editable."
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
                #if DEBUG
                if let id = ProcessInfo.processInfo.environment["FM1_DEMO_EDIT"], editing == nil {
                    editing = hub.mapping(model).controls.first { $0.id == id }
                }
                #endif
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
        let knobs = m.controls.filter(\.isKnob)
        let buttons = m.controls.filter(\.isButton)
        VStack(spacing: 14) {
            if !knobs.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(knobs) { k in
                        Button { onTap(k) } label: { KnobCell(control: k, value: hub.value(model, k.id), learning: isLearning(k)) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(buttons) { b in
                        Button { onTap(b) } label: {
                            VStack(spacing: 1) {
                                Text(b.label).font(.caption2.weight(.semibold))
                                Text("CC \(b.number)").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(hub.value(model, b.id) > 0 ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isLearning(b) ? Color.accentColor : .clear, lineWidth: 3))
                        }
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
    if i == 0 { return .gray }
    let (r, g, b) = PadPalette.color(i)
    return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
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
                            Picker(selection: Binding(get: { Int(c.color) % PadPalette.names.count }, set: { v in
                                set { $0.color = UInt8(v) }
                                if hub.lightsReady, let n = c.input?.number {
                                    let (r, g, b) = PadPalette.color(UInt8(v))
                                    hub.testPaint(note: Int(n), r: r, g: g, b: b)
                                }
                            })) {
                                ForEach(PadPalette.names.indices, id: \.self) { i in
                                    Label { Text(PadPalette.names[i]) } icon: { Image(systemName: "circle.fill").foregroundStyle(padColor(UInt8(i))) }.tag(i)
                                }
                            } label: { HStack { Circle().fill(padColor(c.color)).frame(width: 16); Text("Colour") } }
                        }
                    }
                }
                .navigationTitle(c.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { hub.learning = nil; dismiss() } }
            }
        }
        .modifier(EditorSheetSize())
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

/// iPhone: a half-height sheet that drags to full. iPad: a large page sheet, so the whole form shows.
struct EditorSheetSize: ViewModifier {
    @Environment(\.horizontalSizeClass) private var size
    func body(content: Content) -> some View {
        if size == .regular {
            content.presentationDetents([.large]).presentationSizing(.page)
        } else {
            content.presentationDetents([.medium, .large])
        }
    }
}

/// Protocol discovery: identity request, a log of everything the pads send (SysEx included),
/// and a light test, to work out each model's real layout and M-VAVE's configuration messages.
struct PadLabView: View {
    @Environment(ControllerHub.self) private var hub
    let model: ControllerModel
    @State private var testNote = 36
    @State private var rgb: (Double, Double, Double) = (240, 0, 140)
    @State private var raw = ""

    var body: some View {
        List {
            Section {
                Button { hub.probe() } label: { Label("Ask the pad for its name and firmware", systemImage: "questionmark.circle") }
                if let n = hub.padName { LabeledContent("Reports", value: n) }
            } footer: { Text("Uses M-VAVE's service protocol (the same one the FM-1 uses). Over USB it goes to the pad's Private port; over Bluetooth the name arrives when the light session opens.") }

            Section {
                Text(hub.lights ? (hub.lightStatus.isEmpty ? "Starting…" : hub.lightStatus) : "Turn on pad lights on the Pads screen first.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Pad note \(ControllerHub.noteName(testNote))", value: $testNote, in: 36...67)
                ColorRow(label: "Red", value: $rgb.0)
                ColorRow(label: "Green", value: $rgb.1)
                ColorRow(label: "Blue", value: $rgb.2)
                HStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)).frame(width: 40, height: 24)
                    Spacer()
                    Button("Paint") { hub.testPaint(note: testNote, r: UInt8(rgb.0), g: UInt8(rgb.1), b: UInt8(rgb.2)) }
                    Button("Off") { hub.testPaint(note: testNote, r: 0, g: 0, b: 0) }
                    Button("Repaint layout") { hub.lightAll() }
                }.buttonStyle(.borderless).disabled(!hub.lightsReady)
            } header: { Text("Light test") } footer: { Text("Notes 36–51 are bank A, 52–67 bank B.") }

            Section("Send raw MIDI bytes to the \(model.displayName)") {
                TextField("e.g. B0 1E 40", text: $raw).font(.body.monospaced()).textInputAutocapitalization(.characters)
                Button("Send") {
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

struct ColorRow: View {
    let label: String
    @Binding var value: Double
    var body: some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading).font(.caption)
            Slider(value: $value, in: 0...255, step: 1)
            Text("\(Int(value))").font(.caption.monospacedDigit()).frame(width: 32)
        }
    }
}
