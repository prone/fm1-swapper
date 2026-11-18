// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import CoreMIDI
import AVFoundation
import FM1Kit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The slice sampler: a sample cut across the 16 pads, played from the SMC-PAD or the screen.
struct SamplerView: View {
    @Environment(ControllerHub.self) private var hub
    @Environment(\.modelContext) private var context
    @Query(sort: \SampleKit.createdAt, order: .reverse) private var kits: [SampleKit]
    @State private var kitID: PersistentIdentifier?
    @State private var loaded: LoadedKit?
    /// The edited kit's settings (normalised), mirrored here so SwiftUI redraws without decoding JSON.
    @State private var settings: KitSettings?
    @State private var saveTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var selectedPad = 0
    @State private var importing = false
    @State private var recording = false
    @State private var renaming = false
    @State private var newName = ""

    var kit: SampleKit? { kits.first { $0.persistentModelID == kitID } ?? kits.first }

    var body: some View {
        NavigationStack {
            List {
                if kits.isEmpty {
                    ContentUnavailableView {
                        Label("No samples yet", systemImage: "waveform")
                    } description: {
                        Text("Import a loop or a break, or record one with the mic. It's cut into 16 slices at its hits, one per pad.")
                    } actions: {
                        HStack {
                            Button("Import audio") { importing = true }.buttonStyle(.borderedProminent)
                            Button("Record") { recording = true }.buttonStyle(.bordered)
                        }
                    }
                } else if let kit {
                    Section {
                        Picker("Kit", selection: Binding(get: { kit.persistentModelID }, set: { kitID = $0 })) {
                            ForEach(kits) { Text($0.name).tag($0.persistentModelID) }
                        }
                        if let loaded, let settings {
                            WaveformSlices(settings: settings, loaded: loaded, selected: $selectedPad) { changed in
                                save(kit, changed)
                            } audition: { pad in hub.sampler.play(loaded, pad: pad, velocity: 110) }
                            .frame(height: 150)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                            HStack {
                                Button("Slice at hits") {
                                    var s = settings
                                    s.starts = SliceDetector.transients(loaded.mono, sampleRate: loaded.sampleRate); s.slicing = "transients"
                                    save(kit, s)
                                }
                                Spacer()
                                Button("Slice evenly") {
                                    var s = settings
                                    s.starts = SliceDetector.equal(frames: loaded.mono.count); s.slicing = "equal"
                                    save(kit, s)
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        } else if let loadError {
                            Text(loadError).foregroundStyle(.red)
                        } else {
                            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                        }
                    } header: { Text("Sample") } footer: {
                        Text("Drag a marker to move a slice. Tap the waveform or a pad to hear it.")
                    }

                    if let loaded, let settings {
                        Section("Pads") {
                            SamplerPadGrid(selected: $selectedPad, pads: settings.pads) { pad in
                                selectedPad = pad
                                hub.sampler.play(loaded, pad: pad, velocity: 110)
                            }
                            .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                            PadSettingsEditor(settings: Binding(get: { settings.pads[selectedPad] },
                                                                set: { v in var s = settings; s.pads[selectedPad] = v; save(kit, s) }),
                                              pad: selectedPad)
                        }
                    }

                    Section {
                        ForEach([ControllerModel.smcPad, .smcPadPocket]) { model in
                            PlayFromRow(model: model, kit: kit)
                        }
                    } header: { Text("Play from the SMC-PAD") } footer: {
                        Text("Pads 1–16 play slices 1–16 (pad 1 bottom left), through each layout's Learn and bank settings. On the Pocket, holding the Shift pad still sends its shift actions instead.")
                    }

                    Section {
                        Button("Rename…") { newName = kit.name; renaming = true }
                        Button("Delete kit", role: .destructive) {
                            for m in ControllerModel.allCases where hub.kit(for: m) == kit { hub.assign(nil, to: m, context: context) }
                            hub.forgetKit(kit); context.delete(kit); try? context.save(); kitID = nil
                        }
                    }
                }
            }
            .navigationTitle("Sampler")
            .toolbar {
                Menu {
                    Button { importing = true } label: { Label("Import audio file", systemImage: "doc.badge.plus") }
                    Button { recording = true } label: { Label("Record with the mic", systemImage: "mic") }
                } label: { Image(systemName: "plus") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { r in
                if case let .success(urls) = r, let u = urls.first { importAudio(u) }
            }
            .sheet(isPresented: $recording) { RecorderSheet { url in importAudio(url, name: "Recording \(Date().formatted(date: .abbreviated, time: .shortened))") } }
            .alert("Rename kit", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { kit?.name = newName; try? context.save() }
                Button("Cancel", role: .cancel) {}
            }
            .task(id: kit?.persistentModelID) { await load() }
            #if DEBUG
            .onAppear {
                // SIMCTL_CHILD_FM1_DEMO_SAMPLE=/path/loop.wav imports a sample on launch (simulator testing)
                if kits.isEmpty, let p = ProcessInfo.processInfo.environment["FM1_DEMO_SAMPLE"] { importAudio(URL(fileURLWithPath: p)) }
            }
            .task {
                // SIMCTL_CHILD_FM1_DEMO_PADS=1: a virtual "SMC-PAD" plays notes 36-43 through the router into the sampler
                guard ProcessInfo.processInfo.environment["FM1_DEMO_PADS"] != nil else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let kit else { NSLog("PADTEST no kit"); return }
                hub.assign(kit, to: .smcPad, context: context)
                hub.setPadTarget(.sampler, model: .smcPad, context: context)
                hub.sampler.onTrigger = { m, pad in NSLog("PADTEST trigger \(m.rawValue) pad \(pad + 1)") }
                var client = MIDIClientRef(), src = MIDIEndpointRef()
                MIDIClientCreateWithBlock("PadTest" as CFString, &client, nil)
                let st = MIDISourceCreateWithProtocol(client, "SMC-PAD Bluetooth" as CFString, ._1_0, &src)
                NSLog("PADTEST source status \(st)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                hub.refresh()
                NSLog("PADTEST connected: \(hub.connected.map(\.name))")
                for n in 36..<44 {
                    var w: UInt32 = 0x2099_0000 | UInt32(n) << 8 | 100
                    var list = MIDIEventList(); var pkt = MIDIEventListInit(&list, ._1_0)
                    pkt = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &w)
                    MIDIReceivedEventList(src, &list)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                NSLog("PADTEST done")
            }
            #endif
        }
    }

    func load() async {
        loaded = nil; settings = nil; loadError = nil
        guard let kit else { return }
        let id = kit.persistentModelID
        do {
            let l = try await hub.loadedKit(kit)
            guard !Task.isCancelled, self.kit?.persistentModelID == id else { return }   // switched kits meanwhile
            loaded = l
            settings = l.settings
            hub.sampler.start()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Applies new settings at once (the shared decoded kit plays them), and saves to the store a
    /// moment after the last change, so dragging a slider doesn't write on every tick.
    func save(_ kit: SampleKit, _ s: KitSettings) {
        settings = s
        if let loaded {
            if loaded.settings.starts == s.starts { loaded.update(s) }                  // cheap: no re-cut
            else { Task.detached(priority: .userInitiated) { loaded.update(s) } }       // re-cut off the main thread
        }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            kit.settings = s
            try? context.save()
        }
    }

    func importAudio(_ url: URL, name: String? = nil) {
        let data: Data
        do { data = try readImport(url, maxBytes: ImportLimit.audio) } catch { loadError = error.localizedDescription; return }
        let kit = SampleKit(name: name ?? url.deletingPathExtension().lastPathComponent, fileName: url.lastPathComponent, audio: data)
        context.insert(kit)
        try? context.save()
        kitID = kit.persistentModelID
        selectedPad = 0
    }
}

struct PlayFromRow: View {
    @Environment(ControllerHub.self) private var hub
    @Environment(\.modelContext) private var context
    let model: ControllerModel
    let kit: SampleKit

    var body: some View {
        let using = hub.kit(for: model) == kit
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { using }, set: { on in
                hub.assign(on ? kit : nil, to: model, context: context)
                if on, hub.mapping(model).padTarget == .instrument { hub.setPadTarget(.sampler, model: model, context: context) }
            })) {
                VStack(alignment: .leading) {
                    Text("\(model.displayName) plays this kit")
                    if let other = hub.kit(for: model), other != kit { Text("now: \(other.name)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if using {
                Picker("Pads go to", selection: Binding(get: { hub.mapping(model).padTarget },
                                                        set: { hub.setPadTarget($0, model: model, context: context) })) {
                    Text("Sampler").tag(ControllerMapping.PadTarget.sampler)
                    Text("Sampler + FM-1").tag(ControllerMapping.PadTarget.both)
                    Text("FM-1 only").tag(ControllerMapping.PadTarget.instrument)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

struct SamplerPadGrid: View {
    @Environment(ControllerHub.self) private var hub
    @Binding var selected: Int
    let pads: [PadSettings]
    let tap: (Int) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach([12, 8, 4, 0], id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row..<(row + 4), id: \.self) { pad in
                        let lit = hub.isFlashing(pad)
                        let ps = pads.indices.contains(pad) ? pads[pad] : PadSettings()
                        Button { tap(pad) } label: {
                            VStack(spacing: 2) {
                                Text("\(pad + 1)").font(.headline)
                                Text([ps.mode == .gate ? "gate" : nil, ps.choke ? nil : "poly", ps.pitch != 0 ? "\(ps.pitch > 0 ? "+" : "")\(ps.pitch)" : nil]
                                    .compactMap { $0 }.joined(separator: " "))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(RoundedRectangle(cornerRadius: 10).fill(lit ? Color.orange : sliceColor(pad).opacity(0.3)))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected == pad ? Color.accentColor : .clear, lineWidth: 3))
                            .animation(.easeOut(duration: 0.1), value: lit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

func sliceColor(_ i: Int) -> Color { Color(hue: Double(i) / 16, saturation: 0.6, brightness: 0.9) }

struct PadSettingsEditor: View {
    @Binding var settings: PadSettings
    let pad: Int
    var body: some View {
        Picker("Pad \(pad + 1) plays", selection: $settings.mode) {
            Text("Whole slice").tag(PadSettings.Mode.oneShot)
            Text("While held").tag(PadSettings.Mode.gate)
        }
        Toggle("Choke (cuts other choking pads)", isOn: $settings.choke)
        HStack {
            Text("Volume")
            Slider(value: $settings.volume, in: 0...1.5)
        }
        Stepper("Pitch \(settings.pitch > 0 ? "+" : "")\(settings.pitch) semitones", value: $settings.pitch, in: -24...24)
    }
}

/// Waveform with the 16 slice markers; drag a marker to move it, tap a slice to hear it.
struct WaveformSlices: View {
    let settings: KitSettings
    let loaded: LoadedKit
    @Binding var selected: Int
    let onChange: (KitSettings) -> Void
    let audition: (Int) -> Void
    @State private var drag: (index: Int, frame: Int)?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let frames = max(loaded.mono.count, 1)
            let starts = settings.starts.enumerated().map { i, f in drag?.index == i ? drag!.frame : f }
            let x = { (f: Int) -> CGFloat in CGFloat(f) / CGFloat(frames) * w }
            ZStack(alignment: .topLeading) {
                Canvas { g, size in
                    for i in starts.indices {
                        let a = x(starts[i]), b = i + 1 < starts.count ? x(starts[i + 1]) : size.width
                        g.fill(Path(CGRect(x: a, y: 0, width: max(0, b - a), height: size.height)),
                               with: .color(sliceColor(i).opacity(i == selected ? 0.35 : 0.12)))
                    }
                    let peaks = loaded.peaks(buckets: Int(size.width))
                    var p = Path()
                    for (i, pk) in peaks.enumerated() {
                        let xx = CGFloat(i) * size.width / CGFloat(max(peaks.count, 1))
                        p.move(to: CGPoint(x: xx, y: size.height / 2 - CGFloat(pk.max) * size.height / 2))
                        p.addLine(to: CGPoint(x: xx, y: size.height / 2 - CGFloat(pk.min) * size.height / 2))
                    }
                    g.stroke(p, with: .color(.primary.opacity(0.7)), lineWidth: 1)
                }
                ForEach(starts.indices, id: \.self) { i in
                    if i > 0 {
                        Rectangle().fill(Color.accentColor).frame(width: 2, height: h)
                            .overlay(alignment: .top) {
                                Text("\(i + 1)").font(.system(size: 9, weight: .bold)).padding(2)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                                    .offset(y: -2)
                            }
                            .contentShape(Rectangle().inset(by: -12))
                            .offset(x: x(starts[i]) - 1)
                            .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                                let lo = starts[i - 1] + 64, hi = (i + 1 < starts.count ? starts[i + 1] : frames) - 64
                                let f = Int((v.location.x + x(starts[i])) / w * CGFloat(frames))
                                drag = (i, min(max(f, lo), hi))
                            }.onEnded { _ in
                                if let d = drag { var s = settings; s.starts[d.index] = d.frame; drag = nil; onChange(s); selected = d.index; audition(d.index) }
                            })
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p in
                let f = Int(p.x / w * CGFloat(frames))
                let i = (starts.lastIndex { $0 <= f }) ?? 0
                selected = i
                audition(i)
            }
        }
    }
}

/// Records from the mic into a temporary file.
struct RecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    var hint = "Record a loop, a phrase or some hits. It is sliced at its hits when you stop."
    let done: (URL) -> Void
    @State private var recorder: AVAudioRecorder?
    @State private var start: Date?
    @State private var denied = false
    @State private var url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if denied {
                    Text("Microphone access is off. Turn it on in Settings › FM-1 Swapper.").multilineTextAlignment(.center)
                } else if let start {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        Text(Duration.seconds(Date().timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(size: 48, weight: .light).monospacedDigit())
                    }
                    Button { stop() } label: { Label("Stop", systemImage: "stop.circle.fill").font(.title2) }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Text(hint).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button { begin() } label: { Label("Record", systemImage: "record.circle").font(.title2) }.buttonStyle(.borderedProminent).tint(.red)
                }
            }
            .padding()
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { recorder?.stop(); SlicePlayer.configureSession(); dismiss() } }
        }
        .presentationDetents([.medium])
    }

    func begin() {
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                guard ok else { denied = true; return }
                SlicePlayer.configureSession(recording: true)
                let r = try? AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                  AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue])
                r?.record()
                recorder = r
                start = Date()
            }
        }
    }

    func stop() {
        recorder?.stop()
        SlicePlayer.configureSession()
        done(url)
        dismiss()
    }
}
