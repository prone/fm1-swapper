// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import SwiftData
import SwiftUI

/// Pre-flight, progress and result for installing a firmware.
struct SwapSheet: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var firmwares: [Firmware]
    let target: Firmware
    @State private var options = DeviceController.SwapOptions()
    @State private var started = false
    @AppStorage("includeSamples") private var includeSamples = true
    @AppStorage("myFlashChip") private var myChip: MyFlashChip = .unknown
    @State private var chipAck = false
    @State private var viaV15 = true
    @State private var preparing: String?
    @Environment(\.openURL) private var openURL
    private var hub: FirmwareHub { .shared }

    var hasV15: Bool { firmwares.contains { f in f.hasPackage && StockFirmware.v15.sha256 == f.sha256 } }
    var chip: FlashChipSupport? { hub.chip(sha256: target.sha256) }
    /// Installing a package that may not know this FM-1's flash chip (docs/flash-chips.md).
    var chipRisky: Bool { chip == .olderOnly ? myChip != .older : (chip == nil && myChip == .newer) }

    var current: DeviceIdentity? { if case let .connected(id, _) = device.connection { id } else { nil } }
    var currentName: String {
        guard let id = current else { return "" }
        return firmwares.first { $0.product == id.text }?.name ?? id.family.displayName
    }
    var canBackUp: Bool { current.map { $0.family.supportsArchive || $0.family == .unknown } ?? false }
    var needsAck: Bool { current.map { !$0.family.supportsArchive } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if started {
                    PhaseSection()
                    if case .working = device.phase {} else {
                        Section { Button("Done") { device.clearResult(); dismiss() }.frame(maxWidth: .infinity) }
                    }
                } else {
                    Section("From → to") {
                        LabeledContent("On the FM-1", value: current.map { "\(currentName) (\($0.text))" } ?? "Not connected")
                        LabeledContent("Installing", value: "\(target.name) (\(target.product))")
                    }
                    if current == nil {
                        Section {
                            Label("Connect the FM-1 by USB to continue.", systemImage: "cable.connector.slash")
                            Button("Look again") { Task { await device.refresh() } }
                        }
                    }
                    if let id = current {
                        Section {
                            if canBackUp {
                                Label("\(currentName)'s work is backed up first (\(CloudSync.whereKept)).", systemImage: "externaldrive.badge.checkmark")
                                Toggle("Include sample banks", isOn: $includeSamples)
                            }
                            if needsAck {
                                Label(id.family == .official
                                      ? "The official firmware can't be backed up over MIDI. Its patterns and settings will probably be erased."
                                      : "\(currentName) may not support backups.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            Toggle("Continue without a backup if it fails", isOn: $options.continueWithoutBackup)
                        } header: { Text("Before") }
                        if chipRisky {
                            Section {
                                Label(chip == .olderOnly ? "This firmware only knows the first FM-1s' flash chip." : "Flash chip support for this package is unknown.",
                                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text("Newer FM-1s (sold since autumn 2026, flash chip 0xB36014) keep its saves in RAM only, and it can't update itself afterwards: getting off it then needs download mode and M-Flasher.")
                                    .font(.callout)
                                Picker("Your FM-1", selection: $myChip) { ForEach(MyFlashChip.allCases) { Text($0.label).tag($0) } }
                                if myChip != .older { Toggle("I understand, install anyway", isOn: $chipAck) }
                                Button("Rescue guide") { openURL(FirmwareHub.rescueURL) }
                            } header: { Text("Flash chip") } footer: {
                                Text("The chip can't be read over USB; M-Flasher shows it in download mode. A unit bought before autumn 2026 has the older chip.")
                            }
                        } else if chip == nil {
                            Section { Text(FlashChipSupport.unknownExplanation).font(.footnote).foregroundStyle(.secondary) }
                        }
                        if DeviceController.viaV15Recommended(from: id, target: target) {
                            Section {
                                Toggle(isOn: $viaV15) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Go via official V15 (recommended)")
                                        Text(hasV15 ? "Installs M-VAVE's V15 first, then \(target.name)." : "Downloads M-VAVE's V15 (about 700 KB, checked), installs it, then \(target.name).")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } header: { Text("Route") } footer: {
                                Text("Most community firmware expects to be installed over official V15, and installs from one community firmware straight to another fail most often. It adds about two minutes.")
                            }
                        }
                        Section {
                            if let b = target.latestRestorableBackup {
                                Toggle(isOn: $options.restoreAfter) {
                                    VStack(alignment: .leading) {
                                        Text("Restore my \(target.name) settings")
                                        Text("\(b.label) · \(b.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("No saved \(target.name) settings yet, so it starts fresh.").foregroundStyle(.secondary)
                            }
                        } header: { Text("After") }
                        Section {
                            Label("A data USB cable, straight into the \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") (no hub)", systemImage: "cable.connector")
                            Label("The FM-1 charged, or on power", systemImage: "battery.75percent")
                            Label("Other music and MIDI apps closed", systemImage: "xmark.app")
                            Label("Keep this app open until it's done; the screen stays on", systemImage: "iphone")
                        } header: { Text("Before you start") }
                        Section {
                            if let preparing { Text(preparing).font(.footnote).foregroundStyle(.orange) }
                            Button {
                                options.includeSamples = includeSamples
                                Task {
                                    if viaV15 && DeviceController.viaV15Recommended(from: id, target: target) {
                                        preparing = "Getting official V15…"
                                        do { options.viaV15 = try await FirmwareHub.shared.stockV15(in: firmwares, context: context) }
                                        catch { preparing = error.localizedDescription; return }
                                        preparing = nil
                                    } else { options.viaV15 = nil }
                                    started = true
                                    await device.swap(to: target, context: context, options: options)
                                }
                            } label: {
                                Text("Install \(target.name)").frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(device.busy || preparing == "Getting official V15…" || (needsAck && !options.continueWithoutBackup) || id.model != target.packageModel || (chipRisky && !chipAck))
                        } footer: {
                            Text(id.model != target.packageModel
                                 ? "This package is for \(target.packageModel.isEmpty ? "another device" : target.packageModel), not \(id.model)."
                                 : "Takes about two minutes. Keep the app open and the cable connected. If it is interrupted, the FM-1 waits in update mode and you can resume from the Device tab. Installing firmware is at your own risk.")
                        }
                    }
                }
            }
            .navigationTitle(started ? "Installing" : "Install firmware")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !started || !device.busy { Button("Close") { dismiss() } }
            }
            .interactiveDismissDisabled(device.busy)
            .task { if !started { await hub.load(); await device.refresh() } }
        }
    }
}
