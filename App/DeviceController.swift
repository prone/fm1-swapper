import FM1Kit
import Foundation
import Observation
import SwiftData
import UIKit

/// Owns the connection to the FM-1 and runs one operation at a time:
/// identify, back up, restore, and the full swap (back up -> install -> restore).
@MainActor @Observable
final class DeviceController {
    enum Connection: Equatable {
        case searching, none, connected(DeviceIdentity, port: String), loader(DeviceIdentity, port: String)
    }

    enum Phase: Equatable {
        case idle
        case working(title: String, detail: String, progress: Double?)
        case finished(title: String, detail: String)
        case failed(title: String, detail: String)
    }

    private(set) var connection: Connection = .none
    private(set) var phase: Phase = .idle { didSet { if busy != wasBusy { wasBusy = busy; onBusyChange?(busy) } } }
    private var wasBusy = false
    /// Tells the pad router to stop sending to the FM-1 while it is being written.
    var onBusyChange: ((Bool) -> Void)?
    private(set) var log: [String] = []
    var busy: Bool { if case .working = phase { true } else { false } }

    let updater: OTAUpdater
    private var refreshTask: Task<Void, Never>?

    init(provider: MIDIPortProvider = CoreMIDIProvider.shared) {
        updater = OTAUpdater(provider: provider)
        updater.log = { [weak self] line in Task { @MainActor in self?.append(line) } }
        if let core = provider as? CoreMIDIProvider {
            core.observeChanges { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
    }

    func append(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func clearResult() { if !busy { phase = .idle } }

    // MARK: identify

    func scheduleRefresh() {
        guard !busy else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func refresh() async {
        guard !busy else { return }
        connection = .searching
        if let found = await updater.identify() {
            connection = found.identity.isLoader ? .loader(found.identity, port: found.port) : .connected(found.identity, port: found.port)
        } else {
            connection = .none
        }
    }

    var identity: DeviceIdentity? {
        switch connection {
        case let .connected(id, _), let .loader(id, _): id
        default: nil
        }
    }

    // MARK: operations

    private func run(_ title: String, _ body: () async throws -> String) async {
        guard !busy else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        phase = .working(title: title, detail: "Connecting…", progress: nil)
        append("— \(title)")
        do {
            let done = try await body()
            phase = .finished(title: title, detail: done)
            append("✓ \(done)")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(title: title, detail: msg)
            append("✗ \(msg)")
        }
        UIApplication.shared.isIdleTimerDisabled = false
        await refresh()
    }

    private func progress(_ title: String, _ detail: String, _ value: Double?) {
        phase = .working(title: title, detail: detail, progress: value)
    }

    private func connect() async throws -> ConnectedDevice {
        guard let d = await updater.find(where: { !$0.isLoader }) else {
            if await updater.find(where: \.isLoader).map({ $0.link.close(); return true }) == true {
                throw FM1Error.device("The FM-1 is in update mode (an install was interrupted). Use Resume install first.")
            }
            throw FM1Error.notFound
        }
        connection = .connected(d.identity, port: d.portName)
        return d
    }

    private func archiveProgress(_ title: String, _ verb: String) -> ArchiveProgress {
        { [weak self] done, total in
            Task { @MainActor in
                self?.progress(title, "\(verb) \(ByteCountFormatter.string(fromByteCount: Int64(done), countStyle: .file))",
                               total > 0 ? Double(done) / Double(total) : nil)
            }
        }
    }

    /// Reads the firmware's saved work into a new Backup.
    func backup(context: ModelContext, includeSamples: Bool, label: String? = nil) async {
        await run("Back up") {
            let dev = try await connect()
            defer { dev.link.close() }
            let archive = try await Archives.capture(dev, includeSamples: includeSamples, progress: archiveProgress("Back up", "Reading"))
            let fw = context.firmware(forIdentity: dev.identity)
            let b = try Backup.from(archive, label: label ?? "Backup", kind: "device")
            b.firmware = fw
            context.insert(b)
            try context.save()
            return "Saved \(b.partsSummary.isEmpty ? "backup" : b.partsSummary) (\(ByteCountFormatter.string(fromByteCount: Int64(b.sizeBytes), countStyle: .file))) to \(fw.name)."
        }
    }

    func restore(_ backup: Backup, context: ModelContext, includeSamples: Bool) async {
        await run("Restore") {
            guard let archive = backup.archive else { throw FM1Error.unsupported("This backup cannot be written back over MIDI.") }
            let dev = try await connect()
            defer { dev.link.close() }
            try await Archives.restore(archive, to: dev, includeSamples: includeSamples, progress: archiveProgress("Restore", "Writing"))
            return "Restored \(backup.label) to \(dev.identity.text)."
        }
    }

    struct SwapOptions {
        var backupFirst = true
        var continueWithoutBackup = false
        var restoreAfter = true
        var includeSamples = true
    }

    /// Back up the current firmware's work, install `target`, then restore its last saved settings.
    func swap(to target: Firmware, context: ModelContext, options: SwapOptions) async {
        let title = "Install \(target.name)"
        await run(title) {
            guard let data = target.packageData else { throw FM1Error.badPackage("\(target.name) has no firmware file yet. Import or download it first.") }
            let pkg = try FirmwarePackage(data: data)
            let started = Date()
            let dev = try await connect()
            let from = dev.identity
            let current = context.firmware(forIdentity: from)
            guard from.model == pkg.model else {
                dev.link.close()
                throw FM1Error.wrongModel(device: from.text, package: pkg.product)
            }

            // 1. back up
            var tookBackup = false
            if options.backupFirst {
                progress(title, "Backing up \(current.name)…", nil)
                do {
                    let archive = try await Archives.capture(dev, includeSamples: options.includeSamples,
                                                             progress: archiveProgress(title, "Backing up \(current.name):"))
                    let b = try Backup.from(archive, label: "Before installing \(target.name)", kind: "auto")
                    b.firmware = current
                    context.insert(b)
                    try context.save()
                    tookBackup = true
                    append("backup saved: \(b.partsSummary)")
                } catch {
                    if !options.continueWithoutBackup {
                        dev.link.close()
                        throw FM1Error.stopped("Could not back up \(current.name): \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n\nNothing was installed. Turn on “Continue without a backup” to install anyway.")
                    }
                    append("no backup: \(error.localizedDescription)")
                }
            }
            dev.link.close()

            // 2. install
            let event = InstallEvent(firmware: target, from: from.text, to: pkg.product)
            event.backupTaken = tookBackup
            event.deviceName = UIDevice.current.name
            context.insert(event)
            let total = Double(OTAUpdater.expectedRequests(imageSize: pkg.logicalImage.count))
            let installed: DeviceIdentity
            do {
                installed = try await updater.install(pkg) { [weak self] step in
                    Task { @MainActor in
                        guard let self else { return }
                        switch step {
                        case let .write(n): self.progress(title, "Writing firmware… keep the cable connected", min(Double(n) / total, 1))
                        case let .verify(n): self.progress(title, "FM-1 is checking the package (\(n))", nil)
                        default: self.progress(title, step.label + "…", nil)
                        }
                    }
                }
            } catch {
                event.message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                event.duration = Date().timeIntervalSince(started)
                try? context.save()
                throw error
            }
            event.success = true
            event.duration = Date().timeIntervalSince(started)
            if target.status == .notTried { target.status = .tried }
            try context.save()

            // 3. restore
            var summary = "\(target.name) is installed (\(installed.text))."
            if options.restoreAfter, let b = target.latestRestorableBackup, let archive = b.archive {
                progress(title, "Restoring your saved \(target.name) settings…", nil)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                do {
                    let dev2 = try await connect()
                    defer { dev2.link.close() }
                    try await Archives.restore(archive, to: dev2, includeSamples: options.includeSamples,
                                               progress: archiveProgress(title, "Restoring settings:"))
                    event.restored = true
                    try? context.save()
                    summary += " Restored the backup from \(b.date.formatted(date: .abbreviated, time: .shortened))."
                } catch {
                    summary += " The firmware is installed, but restoring settings failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                }
            }
            return summary
        }
    }

    /// Finish an install that was cut off (the device is waiting in update mode).
    func resume(_ target: Firmware, context: ModelContext) async {
        await run("Resume install") {
            guard let data = target.packageData else { throw FM1Error.badPackage("No firmware file for \(target.name).") }
            let pkg = try FirmwarePackage(data: data)
            let total = Double(OTAUpdater.expectedRequests(imageSize: pkg.logicalImage.count))
            guard let id = try await updater.resume(pkg, onStep: { [weak self] step in
                Task { @MainActor in
                    if case let .write(n) = step { self?.progress("Resume install", "Writing firmware…", min(Double(n) / total, 1)) }
                    else { self?.progress("Resume install", step.label + "…", nil) }
                }
            }) else { throw FM1Error.device("No FM-1 in update mode was found.") }
            let e = InstallEvent(firmware: target, from: "update loader", to: id.text)
            e.success = true
            e.message = "Resumed an interrupted install"
            e.deviceName = UIDevice.current.name
            context.insert(e)
            if target.status == .notTried { target.status = .tried }
            try context.save()
            return "\(target.name) is installed (\(id.text))."
        }
    }
}
