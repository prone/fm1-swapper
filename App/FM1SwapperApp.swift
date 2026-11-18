// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@main
struct FM1SwapperApp: App {
    let container: ModelContainer
    @State private var device = DeviceController()
    @State private var pads = ControllerHub()
    @State private var importMessage: String?

    init() {
        let schema = Schema([Firmware.self, InstallEvent.self, Backup.self, EmulatorSave.self, ControllerProfile.self, SampleKit.self, FlashImage.self])
        // iCloud (CloudKit private database) keeps the iPhone and iPad in sync. If iCloud is
        // unavailable (signed out, simulator without an account), fall back to a local store.
        // Unsigned builds have no iCloud entitlement (CloudKit would trap): build them with FM1_CLOUD_SYNC=NO.
        let syncOn = (Bundle.main.object(forInfoDictionaryKey: "FM1CloudSync") as? String) == "YES"
        let cloudID = Bundle.main.object(forInfoDictionaryKey: "FM1CloudContainer") as? String ?? ""
        let cloud = ModelConfiguration("FM1Swapper", schema: schema, cloudKitDatabase: .private(cloudID))
        if syncOn, !cloudID.isEmpty, let c = try? ModelContainer(for: schema, configurations: cloud) {
            container = c
            CloudSync.isOn = true
        } else {
            let local = ModelConfiguration("FM1Swapper", schema: schema, cloudKitDatabase: .none)
            container = try! ModelContainer(for: schema, configurations: local)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(device)
                .environment(pads)
                .onAppear { let hub = pads; device.onBusyChange = { busy in hub.setDeviceBusy(busy) } }
                .onOpenURL { url in importFile(url) }
                .messageAlert("Import", $importMessage)
                .task { importWaitingFiles(); await device.refresh() }
        }
        .modelContainer(container)
    }

    /// Files left in Documents/Inbox (delivered by "Open in" or AirDrop while the app wasn't there to take them, or
    /// copied in from a Mac) are imported at launch, as if just opened; each is removed once imported.
    @MainActor
    func importWaitingFiles() {
        let inbox = URL.documentsDirectory.appending(path: "Inbox")
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { importFile(url) }
    }

    /// A .fwsc shared from Files, Safari or AirDrop.
    @MainActor
    func importFile(_ url: URL) {
        // files shared into the app land in Documents/Inbox: remove our copy once imported
        defer { if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) } }
        do {
            let isAudio = UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
            let data = try readImport(url, maxBytes: isAudio ? ImportLimit.audio : ImportLimit.firmware)
            if isAudio {
                let kit = SampleKit(name: url.deletingPathExtension().lastPathComponent, fileName: url.lastPathComponent, audio: data)
                container.mainContext.insert(kit)
                try container.mainContext.save()
                importMessage = "Added “\(kit.name)” to the Sampler."
                return
            }
            if SongFiles.isSong(data, fileName: url.lastPathComponent) {
                importMessage = try SongFiles.add(data, fileName: url.lastPathComponent, context: container.mainContext)
                return
            }
            let r = try LibraryImport.add(data, fileName: url.lastPathComponent, context: container.mainContext)
            importMessage = (r.isNew ? "Added \(r.firmware.name) to your library." : "\(r.firmware.name) is already in your library.")
                + (r.warning.map { "\n\n" + $0 } ?? "")
        } catch {
            importMessage = error.localizedDescription
        }
    }
}

/// Keeps this install's check-in current: on launch, when the FM-1 or pads change, after an install.
struct CheckInDriver: ViewModifier {
    @Environment(DeviceController.self) private var device
    @Environment(ControllerHub.self) private var pads
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .task { CheckInService.shared.start(); schedule() }
            .onChange(of: phase) { if phase == .active { schedule() } }
            .onChange(of: device.identity?.text) { send() }
            .onChange(of: device.busy) { if !device.busy { send() } }
            .onChange(of: pads.connected) { send() }
            .onChange(of: pads.padName) { send() }
    }

    func schedule() {
        guard CheckInService.shared.enabled else { return }
        let ctx = context, dev = device, hub = pads
        CheckInService.shared.schedule { CheckInReport.make(context: ctx, device: dev, pads: hub) }
    }

    func send() {
        guard CheckInService.shared.enabled else { return }
        let r = CheckInReport.make(context: context, device: device, pads: pads)
        Task { await CheckInService.shared.send(r) }
    }
}

/// Loads the SMC-PAD layouts and sampler kits at launch (not only when the Pads tab opens), switches
/// to a firmware's own layout when that firmware is on the FM-1, and rests the sampler in the background.
struct PadProfileDriver: ViewModifier {
    @Environment(DeviceController.self) private var device
    @Environment(ControllerHub.self) private var pads
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .task {
                // one-time fill of scalar fields added for performance
                for f in (try? context.fetch(FetchDescriptor<Firmware>())) ?? [] { f.migrateScalars() }
                try? context.save()
                pads.contextForLearn = context
                select()
                // share files from earlier sessions
                let tmp = FileManager.default.temporaryDirectory
                for u in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent.hasPrefix("export-") {
                    try? FileManager.default.removeItem(at: u)
                }
            }
            .onChange(of: device.identity?.text) { select() }
            .onChange(of: phase) {
                if phase == .background, pads.connected.isEmpty { pads.sampler.pause() }
            }
    }

    func select() {
        var firmware: Firmware?
        if let id = device.identity, !id.isLoader {
            let text = id.text
            firmware = (try? context.fetch(FetchDescriptor<Firmware>(predicate: #Predicate { $0.product == text })))?
                .max { ($0.lastInstalledAt ?? .distantPast) < ($1.lastInstalledAt ?? .distantPast) }
        }
        pads.selectProfiles(context: context, firmware: firmware)
    }
}

struct RootView: View {
    #if DEBUG
    /// Simulator testing: SIMCTL_CHILD_FM1_DEMO_EMULATOR=/path/to/x.fwsc opens the emulator on launch.
    @State private var demo: Data? = ProcessInfo.processInfo.environment["FM1_DEMO_EMULATOR"].flatMap { FileManager.default.contents(atPath: $0) }
    /// SIMCTL_CHILD_FM1_DEMO_AUDIO=/path/to/audio analyses it with the audio import on launch and logs "AUDIOTEST …".
    @State private var audioTest = AudioAnalyser()
    #endif

    var body: some View {
        tabs
            .modifier(CheckInDriver())
            .modifier(PadProfileDriver())
        #if DEBUG
            .background {
                if let path = ProcessInfo.processInfo.environment["FM1_DEMO_AUDIO"], let data = FileManager.default.contents(atPath: path) {
                    AudioAnalyserView(analyser: audioTest).frame(width: 1, height: 1).opacity(0).task {
                        let t0 = Date()
                        do {
                            let r = try await audioTest.analyse(data)
                            NSLog("AUDIOTEST ok %.1f BPM, %d sections in %.1f s: %@", r.bpm, r.sections.count, Date().timeIntervalSince(t0),
                                  r.sections.map { "\(String(format: "%.1f", $0.start))s bass \($0.bass.count) keys \($0.keys.count) lead \($0.lead.count) drums \($0.drums.count)" }.joined(separator: "; "))
                        } catch { NSLog("AUDIOTEST failed: %@", "\(error)") }
                    }
                }
            }
            .fullScreenCover(isPresented: $demo.isPresent()) {
                if let d = demo {
                    let tut = ProcessInfo.processInfo.environment["FM1_DEMO_TUTORIAL"].flatMap(TutorialLibrary.byID)
                    let name = ProcessInfo.processInfo.environment["FM1_DEMO_NAME"] ?? "demo.fwsc"
                    EmulatorScreen(title: tut?.title ?? "Demo", package: d, fileName: name, tutorial: tut)
                }
            }
        #endif
    }

    #if DEBUG
    // simulator testing: SIMCTL_CHILD_FM1_DEMO_TAB=2 opens on that tab
    @State private var tab = Int(ProcessInfo.processInfo.environment["FM1_DEMO_TAB"] ?? "") ?? 0
    #else
    @State private var tab = 0
    #endif

    var tabs: some View {
        TabView(selection: $tab) {
            Tab("Device", systemImage: "pianokeys", value: 0) { DeviceView() }
            Tab("Library", systemImage: "square.stack.3d.up", value: 1) { LibraryView() }
            Tab("Pads", systemImage: "square.grid.4x3.fill", value: 2) { PadsView() }
            Tab("Sampler", systemImage: "waveform", value: 4) { SamplerView() }
            Tab("Firmware Editor", systemImage: "slider.horizontal.below.square.and.square.filled", value: 5) { FirmwareEditorView() }
            Tab("History", systemImage: "clock.arrow.circlepath", value: 3) { HistoryView() }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

/// Whether the library is syncing through iCloud in this run (off in unsigned/sideloaded builds), for wording in the UI.
enum CloudSync {
    nonisolated(unsafe) static var isOn = false
    /// "in iCloud" or "on this device", for sentences about where backups are kept.
    static var whereKept: String { isOn ? "in iCloud" : "on this device" }
}
