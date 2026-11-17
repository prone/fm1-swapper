// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
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
    /// m-bootloader (or its helper) answering in MIDI mode, when the connection is a loader.
    private(set) var mboot: MBootInfo?
    private(set) var phase: Phase = .idle { didSet { if busy != wasBusy { wasBusy = busy; onBusyChange?(busy) } } }
    private var wasBusy = false
    /// Tells the pad router to stop sending to the FM-1 while it is being written.
    var onBusyChange: ((Bool) -> Void)?
    private(set) var log: [String] = []
    var busy: Bool { if case .working = phase { true } else { checking } }
    /// A quick read of the FM-1 (the song check) is on: nothing else may use the port meanwhile.
    private var checking = false
    /// The FM-1's song checksums from the last song check, so a clear can make sure the song is still that one.
    private var checkedSong: [UInt8: (size: Int, crc: UInt32)]?

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
            var info: MBootInfo?
            if found.identity.isLoader, let m = await updater.findMBoot() {
                info = m.info
                m.link.close()
                remember(m.info)
            }
            mboot = info
            connection = found.identity.isLoader ? .loader(found.identity, port: found.port) : .connected(found.identity, port: found.port)
        } else {
            mboot = nil
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
        // keep running for the short time iOS allows if the app is sent to the background mid-write
        let bg = UIApplication.shared.beginBackgroundTask(withName: title)
        defer { UIApplication.shared.endBackgroundTask(bg) }
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

    private var lastProgress = Date.distantPast

    /// Progress arrives once per OTA request or backup chunk (thousands per install): publish only
    /// whole-percent steps or text changes, at most ~10 times a second, so views aren't re-rendered
    /// for every packet.
    private func progress(_ title: String, _ detail: String, _ value: Double?) {
        if case let .working(t, _, old) = phase, t == title, value != 1, Date().timeIntervalSince(lastProgress) < 0.1 {
            // same operation within 100 ms: skip unless the bar moved a whole percent
            let step = { (v: Double?) in v.map { Int($0 * 100) } ?? -1 }
            if step(old) == step(value) { return }
        }
        lastProgress = Date()
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

    /// Saves the SLOOP song on the FM-1 (the loop in progress, the song order and sections A–D) under a name.
    func saveSong(_ name: String, context: ModelContext) async {
        await run("Save song") {
            let dev = try await connect()
            defer { dev.link.close() }
            let s = SLOOPArchive(link: dev.link)
            guard await s.supported() else {
                throw FM1Error.unsupported("\(dev.identity.text) doesn't have SLOOP's song backup. It works with SLOOP 2.3 or later and firmware built on it.")
            }
            let archive = try await s.capture(firmware: dev.identity.text, only: SLOOPArchive.songIDs, progress: archiveProgress("Save song", "Reading"))
            let fw = context.firmware(forIdentity: dev.identity)
            let b = try Backup.from(archive, label: name, kind: "song")
            b.firmware = fw
            context.insert(b)
            try context.save()
            return "Saved the song \"\(name)\"."
        }
    }

    enum SongCheck { case saved(String), unsaved, failed(String) }

    /// Whether the song on the FM-1 is one of these saved songs (compares checksums; nothing is read out or written).
    func checkSongSaved(_ songs: [Backup]) async -> SongCheck {
        guard !busy else { return .failed("The FM-1 is busy.") }
        checking = true
        defer { checking = false }
        checkedSong = nil
        do {
            let dev = try await connect()
            defer { dev.link.close() }
            let now = try await SLOOPArchive(link: dev.link).checksums()
            checkedSong = now
            if let s = songs.first(where: { $0.archive.map { SLOOPArchive.matches($0, now) } ?? false }) { return .saved(s.label) }
            return .unsaved
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Clears the song on the FM-1 (every note of the loop, sections A–D), saving it first when asked.
    func clearSong(saveFirstAs name: String?, context: ModelContext) async {
        await run("Clear the song") {
            let dev = try await connect()
            defer { dev.link.close() }
            let s = SLOOPArchive(link: dev.link)
            var saved = ""
            if let name {
                let archive = try await s.capture(firmware: dev.identity.text, only: SLOOPArchive.songIDs, progress: archiveProgress("Clear the song", "Saving"))
                let b = try Backup.from(archive, label: name, kind: "song")
                b.firmware = context.firmware(forIdentity: dev.identity)
                context.insert(b)
                try context.save()
                saved = "Saved it as \"\(name)\", then cleared"
            }
            // (not saved first: only if it's still the song that was checked)
            try await s.clearSong(unchangedSince: name == nil ? checkedSong : nil) { [weak self] done, total in
                Task { @MainActor in self?.progress("Clear the song", "Clearing…", Double(done) / Double(total)) }
            }
            return (saved.isEmpty ? "Cleared" : saved) + " the song on the FM-1: the loop's notes and sections A–D. Sounds and presets are as they were."
        }
    }

    /// Puts a saved SLOOP song back: the loop, the song order and sections A–D are replaced; presets, kits and
    /// samples on the FM-1 stay as they are.
    /// With `saveFirstAs`, the song on the FM-1 is saved under that name first (a failed save stops the load).
    func loadSong(_ song: Backup, saveFirstAs name: String? = nil, context: ModelContext? = nil) async {
        await run("Load song") {
            guard let archive = song.archive else { throw FM1Error.badPackage("This song can't be read.") }
            let dev = try await connect()
            defer { dev.link.close() }
            var saved = ""
            if let name, let context {
                let mine = try await SLOOPArchive(link: dev.link).capture(firmware: dev.identity.text, only: SLOOPArchive.songIDs,
                                                                          progress: archiveProgress("Load song", "Saving the FM-1's song"))
                let b = try Backup.from(mine, label: name, kind: "song")
                b.firmware = context.firmware(forIdentity: dev.identity)
                context.insert(b)
                try context.save()
                saved = "Saved the FM-1's song as \"\(name)\", then l"
            }
            try await Archives.restore(archive, to: dev, progress: archiveProgress("Load song", "Writing"))
            return (saved.isEmpty ? "L" : saved) + "oaded \"\(song.label)\"."
        }
    }

    /// A name for a song saved automatically before it's replaced or cleared.
    static func autoSongName() -> String { "Saved \(Date().formatted(date: .abbreviated, time: .shortened))" }

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
        /// Install M-VAVE's official V15 first, then the target. Most community firmware expects to be installed from
        /// stock V15, and custom-to-custom installs fail most often (Mooring requires V15 first for 119 of 121 packages).
        var viaV15: Firmware?
    }

    /// Whether to route an install through official V15: whenever the FM-1 isn't already running it, unless the target is V15.
    static func viaV15Recommended(from: DeviceIdentity, target: Firmware) -> Bool {
        let v15 = StockFirmware.all.first { $0.version == "V15" }!
        return !from.isLoader && from.text != v15.product && target.sha256 != v15.sha256
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

            // 2a. official V15 first, as a clean base
            var installFrom = from.text
            if let v15 = options.viaV15 {
                guard let v15Data = v15.packageData else { throw FM1Error.badPackage("The official V15 file is missing from your library, so the install via V15 can't run. Nothing was installed.") }
                let v15Pkg = try FirmwarePackage(data: v15Data)
                guard v15Pkg.stock?.version == "V15" else { throw FM1Error.badPackage("The V15 file in your library doesn't match the official release.") }
                let hop = InstallEvent(firmware: v15, from: from.text, to: v15Pkg.product)
                hop.backupTaken = tookBackup
                hop.deviceName = UIDevice.current.name
                hop.message = "Step 1 of 2, on the way to \(target.name)"
                context.insert(hop)
                let hopStart = Date()
                let hopTotal = Double(OTAUpdater.expectedRequests(imageSize: v15Pkg.logicalImage.count))
                do {
                    _ = try await updater.install(v15Pkg) { [weak self] step in
                        Task { @MainActor in
                            guard let self else { return }
                            if case let .write(n) = step { self.progress(title, "Step 1 of 2: official V15… keep the cable connected", min(Double(n) / hopTotal, 1)) }
                            else { self.progress(title, "Step 1 of 2: official V15 – " + step.label.lowercased() + "…", nil) }
                        }
                    }
                } catch {
                    hop.message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    hop.duration = Date().timeIntervalSince(hopStart)
                    try? context.save()
                    throw error
                }
                hop.success = true
                hop.duration = Date().timeIntervalSince(hopStart)
                v15.recordInstall()
                try context.save()
                installFrom = v15Pkg.product
                append("installed official V15, now \(target.name)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            // 2. install
            let event = InstallEvent(firmware: target, from: installFrom, to: pkg.product)
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
                        case let .write(n): self.progress(title, (options.viaV15 != nil ? "Step 2 of 2: " : "") + "Writing firmware… keep the cable connected", min(Double(n) / total, 1))
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
            target.recordInstall()
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
    // MARK: m-bootloader (docs/flash-chips.md; roadmap safety track levels 0–1)

    /// The chip m-bootloader reports becomes the flash chip setting (it can't be read any other way over USB).
    private func remember(_ info: MBootInfo) {
        if let newer = info.isNewerChip { UserDefaults.standard.set(newer ? MyFlashChip.newer.rawValue : MyFlashChip.older.rawValue, forKey: "myFlashChip") }
        var all = UserDefaults.standard.dictionary(forKey: "chipByUnit") ?? [:]
        all[info.unitID] = Int(info.jedec)
        UserDefaults.standard.set(all, forKey: "chipByUnit")
    }

    /// The helper package bundled with the app, checked against m-bootloader's published SHA-256.
    private func helperPackage(_ h: MBootProtocol.Helper) throws -> FirmwarePackage {
        guard let u = Bundle.main.url(forResource: h.rawValue, withExtension: "fwsc"), let d = try? Data(contentsOf: u) else {
            throw FM1Error.badPackage("m-bootloader's helper is missing from this app.")
        }
        let p = try FirmwarePackage(data: d)
        guard p.sha256 == h.sha256 else { throw FM1Error.badPackage("m-bootloader's helper doesn't match its published checksum.") }
        return p
    }

    /// Sends m-bootloader's helper as an update; the FM-1 then runs MIDI mode from RAM. Nothing is installed permanently.
    func startHelper() async {
        let title = "Check this FM-1"
        await run(title) {
            guard let now = await updater.identify(), !now.identity.isLoader else { throw FM1Error.notFound }
            guard let kind = MBootProtocol.helper(for: now.identity.family) else {
                throw FM1Error.unsupported("\(now.identity.text) isn't known to accept m-bootloader's helper. Install official V15 or a Felucca-family firmware first.")
            }
            let pkg = try helperPackage(kind)
            let m = try await updater.startHelper(pkg, accept: { MBootProtocol.helper(for: $0.family) == kind }) { [weak self] step in
                Task { @MainActor in self?.progress(title, step == .loader ? "Waiting for the helper…" : "Sending the helper…", nil) }
            }
            m.link.close()
            remember(m.info)
            mboot = m.info
            return "m-bootloader's helper is running. Flash chip \(m.info.jedecHex) (\(MBootProtocol.chip(m.info.jedec)))."
        }
    }

    /// Reads the whole flash through m-bootloader, checked block by block against the chip's CRC-32.
    func backupFlash(context: ModelContext, firmwareName: String) async {
        let title = "Back up the whole flash"
        await run(title) {
            guard let m = await updater.findMBoot() else { throw FM1Error.notFound }
            defer { m.link.close() }
            let data = try await m.backup { [weak self] done, total in
                Task { @MainActor in self?.progress(title, "Reading \(done >> 10) of \(total >> 10) KB…", Double(done) / Double(total)) }
            }
            context.insert(FlashImage(info: m.info, firmware: firmwareName, data: data))
            try context.save()
            return "Saved the whole flash (\(data.count >> 10) KB, checked against the chip)."
        }
    }

    /// Leaves m-bootloader's MIDI mode; the FM-1 restarts into its firmware.
    func restartFromMBoot() async {
        await run("Restart the FM-1") {
            guard let m = await updater.findMBoot() else { throw FM1Error.notFound }
            m.restart()
            m.link.close()
            mboot = nil
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return "The FM-1 restarted."
        }
    }

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
            target.recordInstall()
            e.deviceName = UIDevice.current.name
            context.insert(e)
            if target.status == .notTried { target.status = .tried }
            try context.save()
            return "\(target.name) is installed (\(id.text))."
        }
    }
}
