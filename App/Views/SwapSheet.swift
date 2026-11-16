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
                                Label("\(currentName)'s work is backed up to iCloud first.", systemImage: "externaldrive.badge.checkmark")
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
                            Button {
                                options.includeSamples = includeSamples
                                started = true
                                Task { await device.swap(to: target, context: context, options: options) }
                            } label: {
                                Text("Install \(target.name)").frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(device.busy || (needsAck && !options.continueWithoutBackup) || id.model != target.packageModel)
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
            .task { if !started { await device.refresh() } }
        }
    }
}
