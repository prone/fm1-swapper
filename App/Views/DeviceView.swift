// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import SwiftData
import SwiftUI

struct DeviceView: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Query(sort: \Firmware.name) private var firmwares: [Firmware]
    @AppStorage("includeSamples") private var includeSamples = true
    @State private var showLog = false
    @State private var restoring: Backup?
    @State private var resumeTarget: Firmware?
    @State private var official: Firmware?
    @State private var gettingOfficial = false
    @State private var officialError: String?
    @AppStorage("myFlashChip") private var myChip: MyFlashChip = .unknown
    @Environment(\.openURL) private var openURL

    private var currentFirmware: Firmware? {
        guard let id = device.identity, !id.isLoader else { return nil }
        return firmwares.filter { $0.product == id.text }.max { ($0.lastInstalled ?? .distantPast) < ($1.lastInstalled ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionCard() }
                PhaseSection()

                if case let .connected(id, _) = device.connection {
                    Section("Installed now") {
                        if let fw = currentFirmware {
                            NavigationLink { FirmwareDetailView(firmware: fw) } label: { FirmwareRow(firmware: fw, installedIdentity: id.text) }
                        } else {
                            LabeledContent("Firmware", value: "\(id.family.displayName)")
                            Text("Not in your library yet. A backup (or importing its .fwsc) adds it.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button {
                            Task { await device.backup(context: context, includeSamples: includeSamples) }
                        } label: { Label("Back up now", systemImage: "externaldrive.badge.plus") }
                            .disabled(device.busy || !id.family.supportsArchive && id.family != .unknown)
                        if let fw = currentFirmware, fw.latestRestorableBackup != nil {
                            Menu {
                                ForEach(fw.sortedBackups.filter { $0.isRestorable && !$0.isSong }) { b in
                                    Button("\(b.label) · \(b.date.formatted(date: .abbreviated, time: .shortened))") { restoring = b }
                                }
                            } label: { Label("Restore a backup…", systemImage: "arrow.counterclockwise") }
                                .disabled(device.busy)
                        }
                        Toggle("Include sample banks", isOn: $includeSamples)
                    } header: { Text("Saved work") } footer: {
                        Text(id.family.supportsArchive
                             ? "Reads everything \(id.family.displayName) can export (projects, voices, settings\(includeSamples ? ", samples" : "")) and saves it \(CloudSync.whereKept)."
                             : id.family == .official
                             ? "M-VAVE's official firmware has no backup protocol, so its patterns can't be read out. Note anything you want to keep in the firmware's notes."
                             : "This firmware may not have a backup protocol. Back up now will try Felucca's and SLOOP's.")
                    }
                    if id.family == .felucca || id.family == .unknown {
                        SLOOPSongsSection(firmware: currentFirmware)
                    }
                }

                if case .loader = device.connection, let m = device.mboot {
                    MBootSection(info: m, firmwares: firmwares)
                } else if case let .loader(id, _) = device.connection {
                    Section {
                        Text("The FM-1 is waiting in update mode (\(id.text)). An install was interrupted. Pick the firmware you were installing to finish writing it.")
                        Picker("Firmware", selection: $resumeTarget) {
                            Text("Choose…").tag(Firmware?.none)
                            ForEach(firmwares.filter(\.hasPackage)) { Text($0.name).tag(Optional($0)) }
                        }
                        Button("Resume install") {
                            if let t = resumeTarget { Task { await device.resume(t, context: context) } }
                        }.disabled(resumeTarget == nil || device.busy)
                    } header: { Label("Update mode", systemImage: "exclamationmark.triangle") }
                }

                if case let .connected(id, _) = device.connection, MBootProtocol.helper(for: id.family) != nil {
                    Section {
                        Button { Task { await device.startHelper() } } label: { Label("Check this FM-1", systemImage: "stethoscope") }
                            .disabled(device.busy)
                    } header: { Text("Flash chip and whole-flash backup") } footer: {
                        Text("Reads which flash chip this FM-1 has, and can back up its whole flash (1 MB), using m-bootloader's helper. The helper is sent like a firmware update but only runs from memory: nothing is installed. The firmware uses about 20 KB of free space to hold it. Afterwards the FM-1 restarts into its firmware as before.")
                    }
                }

                FlashImagesSection()

                if case let .connected(id, _) = device.connection, id.family != .official {
                    Section {
                        Button {
                            Task {
                                gettingOfficial = true
                                defer { gettingOfficial = false }
                                do { official = try await FirmwareHub.shared.officialFirmware(in: firmwares, context: context); officialError = nil }
                                catch { officialError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                            }
                        } label: {
                            HStack { Label("Back to official firmware…", systemImage: "arrow.uturn.backward.circle"); if gettingOfficial { Spacer(); ProgressView() } }
                        }
                        .disabled(device.busy || gettingOfficial)
                        if let officialError { Text(officialError).font(.footnote).foregroundStyle(.red) }
                    } footer: { Text("Puts M-VAVE's own firmware back (V15 unless your library has V16), checked against its known checksum. It works on every FM-1.") }
                }

                Section {
                    Picker("This FM-1's flash chip", selection: $myChip) { ForEach(MyFlashChip.allCases) { Text($0.label).tag($0) } }
                    Button("About the two chips, and the rescue guide") { openURL(FirmwareHub.rescueURL) }
                } header: { Text("Flash chip") } footer: {
                    Text("FM-1s sold since autumn 2026 have a different flash chip. Some firmware only knows the older one: on a newer FM-1 it loses saves at power-off and can't update itself. The chip can't be read over USB, so tell the app which you have (M-Flasher shows it in download mode); installs of firmware that don't support it will warn you.")
                }

                InstallsSection()

                Section {
                    DisclosureGroup("Connection log", isExpanded: $showLog) {
                        if device.log.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                        ForEach(Array(device.log.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("Connect the FM-1 with a USB-C cable (iPhone 15 or later, USB-C iPad) or a Lightning-to-USB camera adapter. Close other MIDI apps while installing.")
                }
            }
            .navigationTitle("FM-1")
            .confirmationDialog(restoring.map { "Restore \"\($0.label)\"?" } ?? "", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                                titleVisibility: .visible, presenting: restoring) { b in
                Button("Restore", role: .destructive) { Task { await device.restore(b, context: context, includeSamples: includeSamples) } }
            } message: { b in
                Text("Replaces the saved work on the FM-1 with this backup from \(b.date.formatted(date: .abbreviated, time: .shortened))\(includeSamples ? ", samples included" : "").")
            }
            .sheet(item: $official) { SwapSheet(target: $0) }
            .refreshable { await device.refresh() }
            .toolbar {
                Button { Task { await device.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(device.busy)
            }
        }
    }
}

struct ConnectionCard: View {
    @Environment(DeviceController.self) private var device

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 46, height: 46)
                Image(systemName: symbol).font(.title3).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if device.connection == .searching { ProgressView() }
        }
        .padding(.vertical, 4)
    }

    var title: String {
        switch device.connection {
        case .searching: "Looking for the FM-1…"
        case .none: "No FM-1 connected"
        case let .connected(id, _): id.text
        case .loader: "FM-1 in update mode"
        }
    }

    var subtitle: String {
        switch device.connection {
        case .searching: "Probing MIDI ports"
        case .none: "Plug it in by USB, then pull to refresh"
        case let .connected(id, port): "\(id.family.displayName) · \(port)"
        case let .loader(id, port): "\(id.text) · \(port)"
        }
    }

    var symbol: String {
        switch device.connection {
        case .connected: "cable.connector"
        case .loader: "exclamationmark.triangle.fill"
        default: "cable.connector.slash"
        }
    }

    var color: Color {
        switch device.connection {
        case .connected: .green
        case .loader: .orange
        default: .secondary
        }
    }
}

/// Progress or the result of the last operation.
struct PhaseSection: View {
    @Environment(DeviceController.self) private var device

    var body: some View {
        switch device.phase {
        case .idle: EmptyView()
        case let .working(title, detail, progress):
            Section(title) {
                VStack(alignment: .leading, spacing: 8) {
                    if let progress { ProgressView(value: progress) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    Text(detail).font(.subheadline)
                    Text("Keep this screen open and the cable connected.").font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .finished(title, detail):
            Section {
                Label { Text(detail) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Button("Dismiss") { device.clearResult() }
            } header: { Text(title) }
        case let .failed(title, detail):
            Section {
                Label { Text(detail) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
                Button("Dismiss") { device.clearResult() }
            } header: { Text(title) }
        }
    }
}

struct FirmwareRow: View {
    let firmware: Firmware
    var installedIdentity: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: firmware.status.symbol)
                .foregroundStyle(firmware.status == .notTried ? Color.secondary : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(firmware.name).font(.body.weight(.medium))
                    if installedIdentity == firmware.product {
                        Text("ON DEVICE").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.2), in: Capsule()).foregroundStyle(.green)
                    }
                }
                if !firmware.summary.isEmpty {
                    Text(firmware.summary).font(.caption).foregroundStyle(.primary.opacity(0.8)).lineLimit(2)
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if TutorialLibrary.tutorial(for: firmware) != nil {
                Image(systemName: "graduationcap").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Has a tutorial")
            }
            if firmware.rating > 0 {
                Text(String(repeating: "★", count: firmware.rating)).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    var detail: String {
        var bits: [String] = [firmware.product]
        if let d = firmware.lastInstalled { bits.append("installed \(d.formatted(.relative(presentation: .named)))") } else { bits.append(firmware.status.label.lowercased()) }
        let n = firmware.backups?.count ?? 0
        if n > 0 { bits.append("\(n) backup\(n == 1 ? "" : "s")") }
        if !firmware.hasPackage { bits.append("no file") }
        return bits.joined(separator: " · ")
    }
}

/// What the other installs of the app (iPad, iPhone) have, from their check-ins on the Mac.
struct InstallsSection: View {
    @State private var svc = CheckInService.shared
    @State private var editing = false

    var body: some View {
        Section {
            Toggle("Share with my other installs", isOn: Binding(get: { svc.enabled }, set: { svc.enabled = $0 }))
            if svc.enabled {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This \(UIDevice.current.model): \(svc.deviceLabel)").font(.subheadline)
                    Text(svc.lastCheckIn.map { "\(svc.status) · \($0.formatted(.relative(presentation: .named)))" } ?? svc.status)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = true } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless)
            }
            ForEach(svc.others) { r in
                NavigationLink { InstallDetail(report: r) } label: { CheckInRow(report: r) }
            }
            }
        } header: { Text("Installs") } footer: {
            Text("Off by default. When on, this install reports its FM-1 firmware and library to a check-in server on your Mac (tools/checkin_server.py, same Wi-Fi) and shows your other installs here. Read-only: no install changes another.")
        }
        .sheet(isPresented: $editing) { CheckInSettings() }
    }
}

struct CheckInRow: View {
    let report: CheckInReport
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: report.install.deviceModel?.lowercased().contains("ipad") == true ? "ipad" : "iphone")
                Text(report.install.deviceName).font(.subheadline.weight(.medium))
                Spacer()
                if let d = report.checkedIn { Text(d.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary) }
            }
            if let f = report.fm1, let id = f.identity {
                Text("FM-1: \(f.firmwareName ?? id) (\(id))\(f.connected == true ? " · connected" : "")").font(.caption)
            } else {
                Text("No FM-1 seen yet").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(report.library?.count ?? 0) firmwares · app \(report.install.appVersion ?? "?") (\(report.install.build ?? "?"))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct InstallDetail: View {
    let report: CheckInReport
    @Query private var mine: [Firmware]

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: report.install.deviceModel ?? "?")
                if let s = report.install.system { LabeledContent("System", value: s) }
                LabeledContent("App", value: "\(report.install.appVersion ?? "?") (\(report.install.build ?? "?"))")
                if let d = report.checkedIn { LabeledContent("Checked in", value: d.formatted(date: .abbreviated, time: .shortened)) }
            }
            if let f = report.fm1, let id = f.identity {
                Section("FM-1") {
                    LabeledContent("Firmware", value: f.firmwareName ?? id)
                    LabeledContent("Identity", value: id)
                    LabeledContent("State", value: f.connected == true ? "connected" : "last seen \(f.lastSeen.flatMap { ISO8601DateFormatter.full.date(from: $0) }?.formatted(.relative(presentation: .named)) ?? "?")")
                }
            }
            if let l = report.lastInstall {
                Section("Last install") {
                    LabeledContent(l.firmware ?? "?", value: l.success == true ? "ok" : "failed")
                    if let m = l.message { Text(m).font(.caption).foregroundStyle(.red) }
                }
            }
            Section {
                ForEach(report.library ?? []) { item in
                    let have = mine.contains { !$0.sha256.isEmpty && $0.sha256 == item.sha256 }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.name ?? "?").font(.subheadline)
                            Spacer()
                            Image(systemName: have ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(have ? .green : .secondary)
                        }
                        Text([item.version ?? item.product, item.status, item.lastInstalled.map { "installed " + $0.prefix(10) }]
                            .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Library") } footer: { Text("✓ means this device has the same file (same SHA-256).") }
        }
        .navigationTitle(report.install.deviceName)
    }
}

struct CheckInSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = CheckInService.shared.deviceLabel
    @State private var server = CheckInService.shared.manualServer
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) } header: { Text("This install's name") }
                Section {
                    TextField("Found automatically", text: $server).textInputAutocapitalization(.never).keyboardType(.URL)
                } header: { Text("Mac address (host:port)") } footer: {
                    Text("Leave empty to find the Mac over Bonjour. Start the server on the Mac with: python3 tools/checkin_server.py")
                }
            }
            .navigationTitle("Check-ins")
            .toolbar {
                Button("Done") {
                    CheckInService.shared.deviceLabel = name.isEmpty ? CheckInService.defaultLabel : name
                    if server != CheckInService.shared.manualServer { CheckInService.shared.manualServer = server }
                    dismiss()
                }
            }
        }
    }
}

/// SLOOP keeps one song on the FM-1. This keeps as many as you like in the app: save the one on the FM-1 under a name,
/// load another back (the loop, the song order and sections A–D; presets, kits and samples stay as they are).
struct SLOOPSongsSection: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    let firmware: Firmware?
    @State private var naming = false
    @State private var name = ""
    @State private var checking = false
    @State private var clearCheck: DeviceController.SongCheck?
    /// Every saved song (the clear check compares the FM-1 with all of them, imported ones included).
    @Query(filter: #Predicate<Backup> { $0.kindRaw == "song" }) private var allSongs: [Backup]

    var body: some View {
        Section {
            Button {
                name = "Song \((firmware?.songs.count ?? 0) + 1)"
                naming = true
            } label: { Label("Save the song on the FM-1…", systemImage: "square.and.arrow.down") }
                .disabled(device.busy)
            Button(role: .destructive) {
                checking = true
                Task { clearCheck = await device.checkSongSaved(allSongs); checking = false }
            } label: {
                HStack { Label("Clear the song on the FM-1…", systemImage: "eraser"); if checking { Spacer(); ProgressView() } }
            }
            .disabled(device.busy || checking)
            let saved = firmware?.songs.count ?? 0
            LabeledContent("Saved songs", value: saved == 0 ? "none yet" : "\(saved), in Firmware Editor")
        } header: { Text("SLOOP songs") } footer: {
            Text("SLOOP holds one song: the loop, sections A–D and their order. Save it here under a name; review, edit and load saved songs in the Firmware Editor tab (no FM-1 needed to edit). Clear empties the FM-1 for a new song and offers to save first; it needs SLOOP 2.7 or later. Saving and loading work with SLOOP 2.3 or later and firmware built on it.")
        }
        .alert("Save the song", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { let n = name.trimmingCharacters(in: .whitespaces); Task { await device.saveSong(n.isEmpty ? "Song" : n, context: context) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saves the loop, sections A–D and the song order from the FM-1.") }
        .confirmationDialog(clearTitle, isPresented: Binding(get: { clearCheck != nil }, set: { if !$0 { clearCheck = nil } }),
                            titleVisibility: .visible, presenting: clearCheck) { check in
            if case .saved = check {
                Button("Clear", role: .destructive) { Task { await device.clearSong(saveFirstAs: nil, context: context) } }
            } else {
                Button("Save, then clear") { Task { await device.clearSong(saveFirstAs: autoName, context: context) } }
                Button("Clear without saving", role: .destructive) { Task { await device.clearSong(saveFirstAs: nil, context: context) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { check in
            switch check {
            case let .saved(n): Text("It's saved as \"\(n)\". This erases every note in the loop and empties sections A–D. Sounds, presets, kits, samples and the song order stay.")
            case .unsaved: Text("This song isn't saved in the app. Save it first (as \"\(autoName)\", rename it later), or clear it for good: every note in the loop and sections A–D.")
            case let .failed(m): Text("Couldn't check whether it's saved (\(m)). Save it first to be safe. Clearing erases every note in the loop and sections A–D.")
            }
        }
    }

    private var clearTitle: String {
        if case .saved = clearCheck { return "Clear the song on the FM-1?" }
        return "The song on the FM-1 isn't saved"
    }
    private var autoName: String { "Song \((firmware?.songs.count ?? 0) + 1) · \(Date().formatted(date: .abbreviated, time: .shortened))" }
}

/// m-bootloader (or its helper) in MIDI mode: the flash chip, a whole-flash backup, installs through it, restart.
struct MBootSection: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    let info: MBootInfo
    let firmwares: [Firmware]
    @State private var target: Firmware?
    @State private var confirming = false

    /// Firmware that only knows the older flash chip isn't installed on a newer unit, through m-bootloader either.
    private func refused(_ f: Firmware) -> Bool { info.isNewerChip == true && FirmwareHub.shared.chip(sha256: f.sha256) == .olderOnly }

    var body: some View {
        Section {
            Text("The FM-1 is in m-bootloader's MIDI mode (\(info.isStage ? "its helper, running from memory" : "the installed bootloader"), \(info.version)).")
            LabeledContent("Flash chip", value: "\(info.jedecHex) · \(MBootProtocol.chip(info.jedec)) · \(ByteCountFormatter.string(fromByteCount: Int64(info.capacity), countStyle: .memory))")
            LabeledContent("Unit ID") { Text(info.unitID).font(.caption.monospaced()).textSelection(.enabled) }
            Button { Task { await device.backupFlash(context: context, firmwareName: "") } } label: {
                Label("Back up the whole flash", systemImage: "externaldrive.badge.plus")
            }.disabled(device.busy)
            Picker("Install firmware through it", selection: $target) {
                Text("Choose…").tag(Firmware?.none)
                ForEach(firmwares.filter { $0.hasPackage && $0.packageModel == "FM-1" }) { Text($0.name).tag(Optional($0)) }
            }
            if let t = target {
                if refused(t) {
                    Text("\(t.name) only works on older FM-1s, and this one has the newer flash chip (\(info.jedecHex)).").foregroundStyle(.orange)
                } else {
                    Button("Install \(t.name)…") { confirming = true }.disabled(device.busy)
                }
            }
            Button { Task { await device.restartFromMBoot() } } label: { Label("Restart the FM-1", systemImage: "arrow.clockwise.circle") }
                .disabled(device.busy)
        } header: { Label("m-bootloader", systemImage: "cpu") } footer: {
            Text((info.isNewerChip.map { "The app's flash chip setting now says \($0 ? "newer" : "older") unit. " } ?? "")
                 + "Its installer writes only the firmware area, checks the package against this unit, skips unchanged parts and writes the first part last.")
        }
        .confirmationDialog(target.map { "Install \($0.name) through m-bootloader?" } ?? "", isPresented: $confirming, titleVisibility: .visible) {
            if let t = target { Button("Install") { Task { await device.resume(t, context: context) } } }
        } message: { Text("The FM-1's saved work stays; restore a backup afterwards if you need to.") }
    }
}

/// Whole-flash images read through m-bootloader, newest first.
struct FlashImagesSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \FlashImage.date, order: .reverse) private var images: [FlashImage]

    var body: some View {
        if !images.isEmpty {
            Section {
                ForEach(images) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.medium))
                        Text("unit \(f.unitID.prefix(8))… · chip \(String(format: "0x%06X", f.jedec)) · \(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .memory))")
                            .font(.caption).foregroundStyle(.secondary)
                        ShareFilesButton(files: { f.data.map { [(f.fileName, $0)] } ?? [] }) { Label("Share .bin", systemImage: "square.and.arrow.up") }
                            .font(.caption)
                    }
                }
                .onDelete { idx in
                    for i in idx { context.delete(images[i]) }
                    try? context.save()
                }
            } header: { Text("Whole-flash backups") } footer: {
                Text("Raw images read through m-bootloader and checked against the chip's own CRC-32. M-Flasher can restore them from a computer.")
            }
        }
    }
}
