import FM1Kit
import SwiftData
import SwiftUI

struct HistoryView: View {
    @Query(sort: \InstallEvent.date, order: .reverse) private var events: [InstallEvent]
    @Query private var firmwares: [Firmware]

    var tried: [Firmware] { firmwares.filter { $0.firstInstalled != nil } }

    /// Time each firmware stayed on the device: from its install until the next successful one.
    var timeOn: [(Firmware, TimeInterval)] {
        let ok = events.filter(\.success).sorted { $0.date < $1.date }
        var totals: [PersistentIdentifier: (Firmware, TimeInterval)] = [:]
        for (i, e) in ok.enumerated() {
            guard let f = e.firmware else { continue }
            let end = i + 1 < ok.count ? ok[i + 1].date : Date()
            totals[f.persistentModelID, default: (f, 0)].1 += end.timeIntervalSince(e.date)
        }
        return totals.values.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    ContentUnavailableView("No installs yet", systemImage: "clock",
                                           description: Text("Every firmware you install is logged here with dates, backups and restores."))
                } else {
                    Section {
                        HStack {
                            stat("\(tried.count)", "tried")
                            stat("\(firmwares.count - tried.count)", "waiting")
                            stat("\(events.filter(\.success).count)", "installs")
                        }
                    }
                    if !timeOn.isEmpty {
                        Section("Time on the FM-1") {
                            ForEach(timeOn.prefix(8), id: \.0.persistentModelID) { f, t in
                                LabeledContent(f.name, value: Duration.seconds(t).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))
                            }
                        }
                    }
                    Section("Installs") {
                        ForEach(events) { e in InstallRow(event: e, showFirmware: true) }
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    func stat(_ v: String, _ l: String) -> some View {
        VStack { Text(v).font(.title2.weight(.semibold).monospacedDigit()); Text(l).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }
}

struct InstallRow: View {
    let event: InstallEvent
    let showFirmware: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(event.success ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                if showFirmware { Text(event.firmware?.name ?? event.toIdentity).font(.subheadline.weight(.medium)) }
                Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(showFirmware ? .caption : .subheadline)
                Text("\(event.fromIdentity) → \(event.toIdentity)").font(.caption.monospaced()).foregroundStyle(.secondary)
                let flags = [event.backupTaken ? "backed up" : nil, event.restored ? "settings restored" : nil,
                             event.deviceName.isEmpty ? nil : "from \(event.deviceName)",
                             event.duration > 0 ? "\(Int(event.duration))s" : nil].compactMap { $0 }
                if !flags.isEmpty { Text(flags.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary) }
                if !event.success, !event.message.isEmpty { Text(event.message).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}
