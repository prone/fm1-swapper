import FM1Kit
import SwiftData
import SwiftUI

struct DeviceView: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.modelContext) private var context
    @Query(sort: \Firmware.name) private var firmwares: [Firmware]
    @AppStorage("includeSamples") private var includeSamples = true
    @State private var showLog = false
    @State private var resumeTarget: Firmware?

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
                        if let fw = currentFirmware, !fw.sortedBackups.filter({ $0.archive != nil }).isEmpty {
                            Menu {
                                ForEach(fw.sortedBackups.filter { $0.archive != nil }) { b in
                                    Button("\(b.label) · \(b.date.formatted(date: .abbreviated, time: .shortened))") {
                                        Task { await device.restore(b, context: context, includeSamples: includeSamples) }
                                    }
                                }
                            } label: { Label("Restore a backup…", systemImage: "arrow.counterclockwise") }
                                .disabled(device.busy)
                        }
                        Toggle("Include sample banks", isOn: $includeSamples)
                    } header: { Text("Saved work") } footer: {
                        Text(id.family.supportsArchive
                             ? "Reads everything \(id.family.displayName) can export (projects, voices, settings\(includeSamples ? ", samples" : "")) and saves it to iCloud."
                             : id.family == .official
                             ? "M-VAVE's official firmware has no backup protocol, so its patterns can't be read out. Note anything you want to keep in the firmware's notes."
                             : "This firmware may not have a backup protocol. Back up now will try Felucca's.")
                    }
                }

                if case let .loader(id, _) = device.connection {
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
