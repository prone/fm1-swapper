// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import SwiftData
import SwiftUI

enum ExportFiles {
    /// Writes files to a temporary folder for the share sheet.
    static func urls(_ files: [(name: String, data: Data)]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return files.compactMap { f in
            let u = dir.appendingPathComponent(f.name.replacingOccurrences(of: "/", with: "-"))
            return (try? f.data.write(to: u)) != nil ? u : nil
        }
    }

    static func files(for b: Backup) -> [(name: String, data: Data)] {
        guard let payload = b.payload else { return [] }
        if b.kindRaw == "file" { return [(b.fileName.isEmpty ? "backup.bin" : b.fileName, payload)] }
        let day = b.date.formatted(.iso8601.year().month().day())
        var out: [(String, Data)] = [("FM1-backup-\(b.identity)-\(day).fm1backup.json", payload)]
        if let a = b.archive, let extra = try? a.exportFiles() { out += extra }
        return out
    }
}

/// Files to share, written only when the user taps Share (never while a view renders).
struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
    init(files: [(name: String, data: Data)]) { urls = ExportFiles.urls(files) }
    init(text: String, name: String) { urls = ExportFiles.urls([(name, Data(text.utf8))]) }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension View {
    func shareSheet(_ item: Binding<ShareItems?>) -> some View {
        sheet(item: item) { ActivitySheet(items: $0.urls).presentationDetents([.medium, .large]) }
    }
}

extension Binding {
    /// For an alert or dialog shown while an optional is set: dismissing it clears the optional.
    func isPresent<T>() -> Binding<Bool> where Value == T? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}

extension View {
    /// An alert showing `text` with OK, while it's set.
    func messageAlert(_ title: String, _ text: Binding<String?>) -> some View {
        alert(title, isPresented: text.isPresent()) { Button("OK") { text.wrappedValue = nil } } message: { Text(text.wrappedValue ?? "") }
    }
}

/// A share button that prepares its files on tap.
struct ShareFilesButton<Label: View>: View {
    let files: () -> [(name: String, data: Data)]
    @ViewBuilder let label: () -> Label
    @State private var items: ShareItems?
    var body: some View {
        Button { items = ShareItems(files: files()) } label: { label() }
            .shareSheet($items)
    }
}

struct FirmwareDetailView: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Bindable var firmware: Firmware
    @State private var showSwap = false
    @State private var showEmulator = false
    @State private var showTutorial = false
    @State private var importingBackup = false
    @State private var importingPackage = false
    @State private var message: String?
    @AppStorage("includeSamples") private var includeSamples = true

    var onDevice: Bool { device.identity?.text == firmware.product }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $firmware.name).font(.title2.weight(.semibold))
                        Text([firmware.author, firmware.family.displayName].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        TextField("Description", text: $firmware.summary, axis: .vertical)
                            .font(.callout).lineLimit(1...5)
                    }
                    Spacer()
                    if onDevice { Text("ON DEVICE").font(.caption.weight(.bold)).foregroundStyle(.green) }
                }
                Button {
                    showSwap = true
                } label: {
                    Label(onDevice ? "Reinstall on FM-1" : "Install on FM-1", systemImage: "arrow.down.to.line.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!firmware.hasPackage || device.busy)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                if firmware.hasPackage {
                    HStack {
                        Button { showEmulator = true } label: {
                            Label("Try it", systemImage: "play.rectangle").lineLimit(1).frame(maxWidth: .infinity)
                        }
                        if TutorialLibrary.tutorial(for: firmware) != nil {
                            Button { showTutorial = true } label: {
                                Label("Tutorial", systemImage: "graduationcap").lineLimit(1).frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityHint("Plays this firmware in the emulator")
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                }
                if !firmware.hasPackage {
                    Button("Add the .fwsc file for this firmware") { importingPackage = true }
                    if let u = URL(string: firmware.sourceURL), isWebLink(u) { Button("Open download page") { openURL(u) } }
                }
            }

            Section("My take") {
                Picker("Status", selection: Binding(get: { firmware.status }, set: { firmware.status = $0 })) {
                    ForEach(TryStatus.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                HStack {
                    Text("Rating")
                    Spacer()
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= firmware.rating ? "star.fill" : "star")
                            .foregroundStyle(.orange)
                            .onTapGesture { firmware.rating = firmware.rating == i ? 0 : i }
                    }
                }
                TextField("Notes: favorite engines, knob settings, what to try next…", text: $firmware.notes, axis: .vertical)
                    .lineLimit(3...12)
            }

            Section("Installs") {
                if let first = firmware.firstInstalled {
                    LabeledContent("First installed", value: first.formatted(date: .abbreviated, time: .shortened))
                    if let last = firmware.lastInstalled, last != first {
                        LabeledContent("Last installed", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Times installed", value: "\(firmware.successfulInstalls.count)")
                } else {
                    Text("Not installed with this app yet.").foregroundStyle(.secondary)
                }
                ForEach((firmware.installs ?? []).sorted { $0.date > $1.date }) { e in InstallRow(event: e, showFirmware: false) }
            }

            Section {
                ForEach(firmware.sortedBackups) { b in BackupRow(backup: b, onDevice: onDevice) }
                    .onDelete { idx in
                        let list = firmware.sortedBackups
                        for i in idx { context.delete(list[i]) }
                        try? context.save()
                    }
                if onDevice, firmware.family.supportsArchive || firmware.family == .unknown {
                    Button {
                        Task { await device.backup(context: context, includeSamples: includeSamples) }
                    } label: { Label("Back up from FM-1 now", systemImage: "externaldrive.badge.plus") }.disabled(device.busy)
                }
                Button { importingBackup = true } label: { Label("Attach a file (backup JSON, .syx, photo…)", systemImage: "paperclip") }
            } header: { Text("Saved settings & backups") } footer: {
                Text(firmware.family.supportsArchive
                     ? "Backups are kept \(CloudSync.isOn ? "in iCloud, on all your devices" : "on this device"). After installing this firmware, the newest backup is restored automatically (you can turn that off)."
                     : "This firmware has no backup protocol the app knows, so attach files or write notes to keep its settings.")
            }

            if !(firmware.emulatorSaves ?? []).isEmpty {
                Section {
                    ForEach((firmware.emulatorSaves ?? []).sorted { $0.date > $1.date }) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.isAuto ? "Last session" : s.label).font(.subheadline)
                                Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareFilesButton(files: { s.payload.map { [(s.fileName, $0)] } ?? [] }) { Image(systemName: "square.and.arrow.up") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { idx in
                        let list = (firmware.emulatorSaves ?? []).sorted { $0.date > $1.date }
                        for i in idx { context.delete(list[i]) }
                        try? context.save()
                    }
                } header: { Text("Emulator saves") } footer: {
                    Text("Settings and patches from the emulator, synced with your library. Restore them from the emulator's save menu.")
                }
            }

            Section("Package") {
                LabeledContent("Identity", value: firmware.product)
                if !firmware.version.isEmpty { LabeledContent("Version", value: firmware.version) }
                if firmware.hasPackage { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(firmware.packageSize), countStyle: .file)) }
                if !firmware.sha256.isEmpty {
                    LabeledContent("SHA-256") { Text(firmware.sha256.prefix(16) + "…").font(.caption.monospaced()).textSelection(.enabled) }
                }
                if firmware.isStock { Label("Unmodified official M-VAVE file", systemImage: "checkmark.seal").foregroundStyle(.green) }
                if firmware.hasPackage {
                    let chip = FirmwareHub.shared.chip(sha256: firmware.sha256)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Flash chip")
                            Spacer()
                            if let chip { Text(chip.badge).font(.caption.weight(.semibold)).foregroundStyle(chip.color) }
                        }
                        Text(chip?.explanation ?? FlashChipSupport.unknownExplanation).font(.caption).foregroundStyle(.secondary)
                    }
                    if !firmware.isStock {
                        LabeledContent("Checksum", value: FirmwareHub.shared.bySha[firmware.sha256] != nil ? "Matches The Firmware Hub" : "Not in The Firmware Hub's list")
                    }
                }
                LabeledContent("Added", value: firmware.addedAt.formatted(date: .abbreviated, time: .omitted))
                if let u = URL(string: firmware.sourceURL), isWebLink(u) { Button("Source") { openURL(u) } }
                if let (e, exact) = FirmwareHub.shared.entry(for: firmware) {
                    if let u = e.editor { Button("Editor") { openURL(u) } }
                    if let u = e.manual { Button("Manual") { openURL(u) } }
                    if let u = e.play { Button("Play in browser") { openURL(u) } }
                    if let u = e.talk { Button("Discussions") { openURL(u) } }
                    if !exact, e.editor ?? e.manual ?? e.play ?? e.talk != nil {
                        Text("Links for \(e.name) \(e.version), from The Firmware Hub").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if firmware.hasPackage {
                    ShareFilesButton(files: {
                        firmware.packageData.map { [(firmware.fileName.isEmpty ? "\(firmware.product).fwsc" : firmware.fileName, $0)] } ?? []
                    }) { Label("Share .fwsc", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle(firmware.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
        .task { await FirmwareHub.shared.load() }
        .sheet(isPresented: $showSwap) { SwapSheet(target: firmware) }
        .fullScreenCover(isPresented: $showEmulator) {
            if let p = firmware.packageData { EmulatorScreen(title: firmware.name, package: p, fileName: firmware.emulatorFileName, firmware: firmware) }
        }
        .fullScreenCover(isPresented: $showTutorial) {
            if let p = firmware.packageData, let t = TutorialLibrary.tutorial(for: firmware) {
                EmulatorScreen(title: t.title, package: p, fileName: firmware.emulatorFileName, firmware: firmware, tutorial: t)
            }
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.data, .json, .image], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { attach(urls) }
        }
        .fileImporter(isPresented: $importingPackage, allowedContentTypes: [.fwsc, .data]) { r in
            guard case let .success(url) = r else { return }
            do {
                let data = try readImport(url, maxBytes: ImportLimit.firmware)
                let pkg = try FirmwarePackage(data: data)
                guard pkg.product == firmware.product else {
                    message = "That file is \(pkg.product), but this firmware reports \(firmware.product). Import it from the Library instead."
                    return
                }
                firmware.setPackage(data)
                firmware.sha256 = pkg.sha256
                firmware.fileName = url.lastPathComponent
                try context.save()
            } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        .messageAlert("Firmware", $message)
    }

    func attach(_ urls: [URL]) {
        for url in urls {
            guard let data = try? readImport(url, maxBytes: ImportLimit.backup) else { continue }
            let b: Backup
            if let a = try? FeluccaArchive.fromNativeJSON(data), let made = try? Backup.from(a, label: url.deletingPathExtension().lastPathComponent, kind: "import") {
                b = made // Felucca's own backup file: restorable
            } else if let a = try? DeviceArchive.decode(data), let made = try? Backup.from(a, label: url.deletingPathExtension().lastPathComponent, kind: "import") {
                b = made // exported from this app
            } else {
                b = Backup(label: url.deletingPathExtension().lastPathComponent, identity: firmware.product, family: firmware.family, kind: "file")
                b.payload = data
                b.fileName = url.lastPathComponent
                b.sizeBytes = data.count
                b.partsSummary = url.pathExtension.uppercased() + " file"
            }
            b.firmware = firmware
            context.insert(b)
        }
        try? context.save()
    }
}

struct BackupRow: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Bindable var backup: Backup
    let onDevice: Bool
    @State private var confirmRestore = false
    @AppStorage("includeSamples") private var includeSamples = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: backup.kindRaw == "file" ? "doc" : backup.kindRaw == "auto" ? "clock.badge.checkmark" : "externaldrive")
                    .foregroundStyle(.secondary)
                TextField("Label", text: $backup.label).font(.subheadline.weight(.medium))
            }
            Text("\(backup.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file)) · \(backup.identity)")
                .font(.caption).foregroundStyle(.secondary)
            if !backup.partsSummary.isEmpty { Text(backup.partsSummary).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            HStack(spacing: 16) {
                if backup.isRestorable, onDevice {
                    Button("Restore to FM-1") { confirmRestore = true }.disabled(device.busy)
                }
                ShareFilesButton(files: { ExportFiles.files(for: backup) }) { Label("Export", systemImage: "square.and.arrow.up") }
            }
            .font(.caption).buttonStyle(.borderless)
        }
        .confirmationDialog("Restore this backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore", role: .destructive) { Task { await device.restore(backup, context: context, includeSamples: includeSamples) } }
        } message: { Text("This replaces the music and settings now on the FM-1 with the ones from \(backup.date.formatted(date: .abbreviated, time: .shortened)).") }
    }
}
