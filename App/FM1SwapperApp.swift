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
        let schema = Schema([Firmware.self, InstallEvent.self, Backup.self, EmulatorSave.self, ControllerProfile.self, SampleKit.self])
        // iCloud (CloudKit private database) keeps the iPhone and iPad in sync. If iCloud is
        // unavailable (signed out, simulator without an account), fall back to a local store.
        // Unsigned builds have no iCloud entitlement (CloudKit would trap): build them with FM1_CLOUD_SYNC=NO.
        let syncOn = (Bundle.main.object(forInfoDictionaryKey: "FM1CloudSync") as? String) == "YES"
        let cloudID = Bundle.main.object(forInfoDictionaryKey: "FM1CloudContainer") as? String ?? ""
        let cloud = ModelConfiguration("FM1Swapper", schema: schema, cloudKitDatabase: .private(cloudID))
        if syncOn, !cloudID.isEmpty, let c = try? ModelContainer(for: schema, configurations: cloud) {
            container = c
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
                .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                    Button("OK") { importMessage = nil }
                } message: { Text(importMessage ?? "") }
                .task { await device.refresh() }
        }
        .modelContainer(container)
    }

    /// A .fwsc shared from Files, Safari or AirDrop.
    @MainActor
    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
            let r = try LibraryImport.add(data, fileName: url.lastPathComponent, context: container.mainContext)
            importMessage = (r.isNew ? "Added \(r.firmware.name) to your library." : "\(r.firmware.name) is already in your library.")
                + (r.warning.map { "\n\n" + $0 } ?? "")
        } catch {
            importMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
    #endif

    var body: some View {
        tabs
            .modifier(CheckInDriver())
            .modifier(PadProfileDriver())
        #if DEBUG
            .fullScreenCover(isPresented: Binding(get: { demo != nil }, set: { if !$0 { demo = nil } })) {
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
            Tab("History", systemImage: "clock.arrow.circlepath", value: 3) { HistoryView() }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
