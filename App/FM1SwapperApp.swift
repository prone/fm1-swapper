import FM1Kit
import SwiftData
import SwiftUI

@main
struct FM1SwapperApp: App {
    let container: ModelContainer
    @State private var device = DeviceController()
    @State private var importMessage: String?

    init() {
        let schema = Schema([Firmware.self, InstallEvent.self, Backup.self, EmulatorSave.self])
        // iCloud (CloudKit private database) keeps the iPhone and iPad in sync. If iCloud is
        // unavailable (signed out, simulator without an account), fall back to a local store.
        // Unsigned builds have no iCloud entitlement (CloudKit would trap): build them with FM1_CLOUD_SYNC=NO.
        let syncOn = (Bundle.main.object(forInfoDictionaryKey: "FM1CloudSync") as? String) == "YES"
        let cloud = ModelConfiguration("FM1Swapper", schema: schema, cloudKitDatabase: .private("iCloud.com.example.fm1swapper"))
        if syncOn, let c = try? ModelContainer(for: schema, configurations: cloud) {
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
        do {
            let data = try Data(contentsOf: url)
            let r = try LibraryImport.add(data, fileName: url.lastPathComponent, context: container.mainContext)
            importMessage = (r.isNew ? "Added \(r.firmware.name) to your library." : "\(r.firmware.name) is already in your library.")
                + (r.warning.map { "\n\n" + $0 } ?? "")
        } catch {
            importMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct RootView: View {
    #if DEBUG
    /// Simulator testing: SIMCTL_CHILD_FM1_DEMO_EMULATOR=/path/to/x.fwsc opens the emulator on launch.
    @State private var demo: Data? = ProcessInfo.processInfo.environment["FM1_DEMO_EMULATOR"].flatMap { FileManager.default.contents(atPath: $0) }
    #endif

    var body: some View {
        tabs
        #if DEBUG
            .fullScreenCover(isPresented: Binding(get: { demo != nil }, set: { if !$0 { demo = nil } })) {
                if let d = demo { EmulatorScreen(title: "Demo", package: d, fileName: "demo.fwsc") }
            }
        #endif
    }

    var tabs: some View {
        TabView {
            Tab("Device", systemImage: "pianokeys") { DeviceView() }
            Tab("Library", systemImage: "square.stack.3d.up") { LibraryView() }
            Tab("History", systemImage: "clock.arrow.circlepath") { HistoryView() }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
