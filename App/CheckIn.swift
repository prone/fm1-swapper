// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import Foundation
import Network
import Security
import Observation
import SwiftData
import UIKit

/// What one app install reports about itself (read-only status for the other installs and for
/// Claude Code on the Mac, which reads checkins/SUMMARY.md). Fields are optional so older or
/// newer app versions can read each other's reports.
struct CheckInReport: Codable, Identifiable, Hashable {
    struct Install: Codable, Hashable {
        var id: String
        var deviceName: String
        var deviceModel: String?
        var system: String?
        var appVersion: String?
        var build: String?
    }
    struct FM1: Codable, Hashable {
        var identity: String?
        var firmwareName: String?
        var family: String?
        var connected: Bool?
        var lastSeen: String?
    }
    struct LastInstall: Codable, Hashable {
        var firmware: String?
        var to: String?
        var date: String?
        var success: Bool?
        var message: String?
    }
    struct LibraryItem: Codable, Hashable, Identifiable {
        var id: String { (sha256?.isEmpty == false ? sha256 : nil) ?? "\(name ?? "")|\(product ?? "")" }
        var name: String?
        var product: String?
        var version: String?
        var sha256: String?
        var family: String?
        var status: String?
        var hasPackage: Bool?
        var lastInstalled: String?
        var installs: Int?
        var source: String?
    }
    struct Pads: Codable, Hashable {
        var connected: [String]?
        var padFirmware: String?
    }

    var format: Int?
    var install: Install
    var checkedInAt: String?
    var receivedAt: String?
    var fm1: FM1?
    var lastInstall: LastInstall?
    var library: [LibraryItem]?
    var pads: Pads?
    var tutorials: [String]?

    var id: String { install.id }
    var checkedIn: Date? { (receivedAt ?? checkedInAt).flatMap { ISO8601DateFormatter.full.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
}

extension ISO8601DateFormatter {
    static let full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Finds the Mac's check-in server (Bonjour _fm1checkin._tcp, or an address typed in), sends this
/// install's report and reads everyone's. Plain HTTP over a Network.framework connection.
@MainActor @Observable
final class CheckInService {
    static let shared = CheckInService()

    private(set) var others: [CheckInReport] = []
    private(set) var lastCheckIn: Date?
    private(set) var status = "Looking for the Mac…"
    private(set) var serverName: String?
    private var endpoint: NWEndpoint?
    private var browser: NWBrowser?
    private var timer: Timer?
    private var pending: CheckInReport?

    /// A value kept in UserDefaults, made once the first time it's asked for.
    private static func stored(_ key: String, _ make: () -> String) -> String {
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = make()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    let installID = stored("checkin.installID") { UUID().uuidString }

    /// This install's private key: its first report registers it on the Mac (trust on first use), so no
    /// other device on the network can overwrite this install's report.
    private let installKey = stored("checkin.installKey") {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.hex
    }

    /// Check-ins are opt-in: they share this install's library with the Mac on the local network.
    /// On by default in Debug (developer) builds, off in Release builds.
    var enabled: Bool {
        get {
            #if targetEnvironment(simulator)
            // simulator runs (tests) would show up as extra installs: only when a test asks for it
            if ProcessInfo.processInfo.environment["FM1_CHECKIN_IN_SIMULATOR"] == nil { return false }
            #endif
            #if DEBUG
            return UserDefaults.standard.object(forKey: "checkin.enabled") as? Bool ?? true
            #else
            return UserDefaults.standard.bool(forKey: "checkin.enabled")
            #endif
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "checkin.enabled")
            enabledChanged += 1
            if newValue { start() } else { stop() }
        }
    }
    /// Bumped when `enabled` changes, so views observing the service refresh.
    private(set) var enabledChanged = 0

    /// Optional "host:port" typed in Settings, when Bonjour can't see the Mac.
    var manualServer: String {
        get { UserDefaults.standard.string(forKey: "checkin.server") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "checkin.server"); endpoint = nil; start() }
    }

    var deviceLabel: String {
        get { UserDefaults.standard.string(forKey: "checkin.name") ?? Self.defaultLabel }
        set { UserDefaults.standard.set(newValue, forKey: "checkin.name") }
    }

    static var defaultLabel: String {
        var size = utsname(); uname(&size)
        let machine = withUnsafeBytes(of: &size.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(UIDevice.current.model) (\(machine))"
    }

    func stop() {
        browser?.cancel(); browser = nil
        timer?.invalidate(); timer = nil
        endpoint = nil; pending = nil; others = []
        status = "Off"
    }

    func start() {
        guard enabled else { status = "Off"; return }
        let manual = manualServer.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty {
            let parts = manual.split(separator: ":")
            let host = String(parts.first ?? ""), port = UInt16(parts.count > 1 ? String(parts[1]) : "8765") ?? 8765
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            serverName = manual
            status = "Using \(manual)"
            return
        }
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_fm1checkin._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.manualServer.isEmpty else { return }
                if let r = results.first {
                    self.endpoint = r.endpoint
                    if case let .service(name, _, _, _) = r.endpoint { self.serverName = name }
                    self.status = "Found \(self.serverName ?? "the Mac")"
                    if let p = self.pending { self.pending = nil; await self.send(p) }
                } else {
                    self.endpoint = nil
                    self.status = "The Mac's check-in server isn't on this network."
                }
            }
        }
        b.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                if case let .failed(e) = st { self?.status = "Can't browse the network: \(e.localizedDescription)" }
                if case .waiting = st { self?.status = "Allow Local Network access in Settings › FM-1 Swapper." }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Sends a report (kept until the Mac is found), then refreshes everyone's.
    func send(_ report: CheckInReport) async {
        guard enabled else { return }
        guard let endpoint else { pending = report; start(); return }
        guard let body = try? JSONEncoder().encode(report) else { return }
        do {
            let (code, _) = try await HTTPOverNW.request(endpoint, method: "PUT", path: "/checkins/\(installID)", body: body,
                                                         headers: ["X-Install-Key": installKey])
            if code == 403 { status = "The Mac has this install's id registered to another key. Reset it in checkins/ on the Mac."; return }
            guard code == 200 else { status = "The Mac refused the check-in (HTTP \(code))."; return }
            lastCheckIn = Date()
            status = "Checked in to \(serverName ?? "the Mac")"
            await refresh()
        } catch {
            status = "Check-in failed: \(error.localizedDescription)"
            pending = report
        }
    }

    func refresh() async {
        guard let endpoint else { return }
        struct All: Decodable { var checkins: [CheckInReport] }
        guard let (code, data) = try? await HTTPOverNW.request(endpoint, method: "GET", path: "/checkins"), code == 200,
              let all = try? JSONDecoder().decode(All.self, from: data) else { return }
        others = all.checkins.filter { $0.install.id != installID }.sorted { ($0.checkedIn ?? .distantPast) > ($1.checkedIn ?? .distantPast) }
    }

    /// Checks in now and every 5 minutes while the app is open.
    func schedule(_ make: @escaping @MainActor () -> CheckInReport) {
        timer?.invalidate()
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.send(make()) } }
        }
        Task { await send(make()) }
    }
}

/// Minimal HTTP/1.0 client on NWConnection (the server closes after each response). Everything runs
/// on one serial queue, so the continuation is resumed exactly once; responses are capped at 2 MB.
enum HTTPOverNW {
    static let maxResponse = 2 << 20

    static func request(_ endpoint: NWEndpoint, method: String, path: String, body: Data = Data(),
                        headers: [String: String] = [:]) async throws -> (Int, Data) {
        let queue = DispatchQueue(label: "fm1.checkin.http")
        let conn = NWConnection(to: endpoint, using: .tcp)
        var head = "\(method) \(path) HTTP/1.0\r\nHost: fm1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        let request = Data((head + "\r\n").utf8) + body
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Int, Data), Error>) in
            var done = false
            var buffer = Data()
            // all of these run on `queue`
            func finish(_ r: Result<(Int, Data), Error>) {
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(with: r)
            }
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if buffer.count > maxResponse { finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
                    if let error { finish(.failure(error)); return }
                    if complete {
                        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)),
                              let status = String(data: buffer[..<split.lowerBound], encoding: .utf8),
                              let code = Int(status.split(separator: " ").dropFirst().first ?? "") else {
                            finish(.failure(URLError(.badServerResponse))); return
                        }
                        finish(.success((code, Data(buffer[split.upperBound...]))))
                    } else { receive() }
                }
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: request, completion: .contentProcessed { e in if let e { finish(.failure(e)) } })
                    receive()
                case let .failed(e), let .waiting(e): finish(.failure(e))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { finish(.failure(URLError(.timedOut))) }
        }
    }
}

extension CheckInReport {
    /// This install's report, from the library, the FM-1 connection and the pads.
    @MainActor
    static func make(context: ModelContext, device: DeviceController, pads: ControllerHub) -> CheckInReport {
        let iso = ISO8601DateFormatter.full
        let info = Bundle.main.infoDictionary
        let firmwares = (try? context.fetch(FetchDescriptor<Firmware>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let events = (try? context.fetch(FetchDescriptor<InstallEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []

        // the FM-1: now, or as last seen by this install
        let d = UserDefaults.standard
        var fm1: FM1?
        if let id = device.identity, !id.isLoader {
            d.set(id.text, forKey: "checkin.lastIdentity")
            d.set(Date(), forKey: "checkin.lastSeen")
        }
        if let text = d.string(forKey: "checkin.lastIdentity"), let id = DeviceIdentity(text: text) {
            let fw = firmwares.installed(id)
            fm1 = FM1(identity: text, firmwareName: fw?.name, family: id.family.rawValue,
                      connected: device.identity?.text == text,
                      lastSeen: (d.object(forKey: "checkin.lastSeen") as? Date).map(iso.string(from:)))
        }
        let last = events.first.map {
            LastInstall(firmware: $0.firmware?.name, to: $0.toIdentity, date: iso.string(from: $0.date), success: $0.success,
                        message: $0.message.isEmpty ? nil : $0.message)
        }
        let library = firmwares.map { f in
            LibraryItem(name: f.name, product: f.product, version: f.version.isEmpty ? nil : f.version, sha256: f.sha256,
                        family: f.familyRaw, status: f.status.label, hasPackage: f.hasPackage,
                        lastInstalled: f.lastInstalled.map(iso.string(from:)), installs: f.installCount,
                        source: f.repo.isEmpty ? (f.sourceURL.isEmpty ? nil : f.sourceURL) : f.repo)
        }
        let svc = CheckInService.shared
        return CheckInReport(
            format: 1,
            install: Install(id: svc.installID, deviceName: svc.deviceLabel, deviceModel: CheckInService.defaultLabel,
                             system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                             appVersion: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String),
            checkedInAt: iso.string(from: Date()),
            fm1: fm1, lastInstall: last, library: library,
            pads: Pads(connected: pads.connected.map { "\($0.model.displayName) (\($0.name))" }, padFirmware: pads.padName),
            tutorials: TutorialLibrary.all.map(\.id))
    }
}
