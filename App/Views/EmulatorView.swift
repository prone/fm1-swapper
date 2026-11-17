// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import AVFoundation
import CryptoKit
import FM1Kit
import Observation
import SwiftData
import SwiftUI
import WebKit

/// "Try it": plays a firmware package on Joakim Eriksson's FM-1 emulator (github.com/joakimeriksson/fm1-emu,
/// MIT), which emulates the FM-1's CPU, panel and audio, so firmwares run unchanged. It runs in a web view
/// because the emulator compiles firmware code to WebAssembly on the fly, which iOS only allows there.
/// The app drives the page's own controls: it hands over the package as if opened with "Open .fwsc…",
/// stands in for Web MIDI (Safari has none), and saves, exports, imports and resets the emulator's
/// saved flash with the page's own save buttons (hidden in the embedded layout).
@MainActor @Observable
final class EmulatorController {
    weak var web: WKWebView?
    var status = "Loading the emulator…"
    var saveStatus = ""
    var ready = false
    var busy = false
    var reloads = 0

    struct ActionResult { var ok: Bool; var message: String; var name: String?; var text: String? }

    /// User touches reported by the page, and MIDI notes from controllers (for tutorials).
    var onUserEvent: ((String, Bool) -> Void)?

    /// Highlights panel controls; returns names the page didn't recognise.
    func spotlight(_ names: [String]) async -> [String] {
        guard let web else { return [] }
        let r = try? await web.callAsyncJavaScript("return window.__fm1spot(names)", arguments: ["names": names], contentWorld: .page)
        return r as? [String] ?? []
    }

    /// Runs tutorial actions in the emulator; "ok" or a problem.
    func perform(_ actions: [Tutorial.Action]) async -> String {
        guard let web, let data = try? JSONEncoder().encode(actions),
              let list = try? JSONSerialization.jsonObject(with: data) else { return "The emulator is not loaded." }
        do {
            return try await web.callAsyncJavaScript("return await window.__fm1do(list)", arguments: ["list": list], contentWorld: .page) as? String ?? "?"
        } catch { return error.localizedDescription }
    }

    func isRunning() async -> Bool {
        (try? await web?.callAsyncJavaScript("return document.getElementById('start')?.hidden === true", arguments: [:], contentWorld: .page)) as? Bool ?? false
    }

    func action(_ kind: String, _ arg: String = "") async -> ActionResult {
        guard let web else { return .init(ok: false, message: "The emulator is not loaded.") }
        busy = true
        defer { busy = false }
        do {
            let r = try await web.callAsyncJavaScript("return await window.__fm1action(kind, arg)", arguments: ["kind": kind, "arg": arg],
                                                      contentWorld: .page) as? [String: Any] ?? [:]
            var result = ActionResult(ok: r["ok"] as? Bool ?? false, message: String((r["message"] as? String ?? "").prefix(300)),
                                      name: r["name"] as? String, text: r["text"] as? String)
            // the page is third-party: never store an oversized "save" it hands back
            if let t = result.text, t.utf8.count > 8 << 20 { result = ActionResult(ok: false, message: "That save is too large to keep (over 8 MB).") }
            saveStatus = result.message
            return result
        } catch {
            saveStatus = error.localizedDescription
            return .init(ok: false, message: error.localizedDescription)
        }
    }
}

struct EmulatorScreen: View {
    let title: String
    let package: Data
    let fileName: String
    var firmware: Firmware?
    /// Opens with this tutorial running.
    var tutorial: Tutorial?
    /// An emulator save to import once the page is ready (a SLOOP song from the song editor), and what to say then.
    var startSave: String? = nil
    var startHint: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ControllerHub.self) private var pads
    @Query(sort: \EmulatorSave.date, order: .reverse) private var allSaves: [EmulatorSave]
    @AppStorage("emuKeepOnClose") private var keepOnClose = true
    @State private var emu = EmulatorController()
    @State private var confirmReset = false
    @State private var restoreTarget: EmulatorSave?
    @State private var naming = false
    @State private var saveName = ""
    @State private var importing = false
    @State private var closing = false
    @State private var player: TutorialPlayer?
    @State private var sharing: ShareItems?
    @AppStorage("tutorialDock") private var dock: TutorialDock = .bottom

    @ViewBuilder private var tutorialCard: some View {
        if let player {
            TutorialCard(player: player, dock: $dock) { Task { await closeTutorial() } }
                .transition(.opacity)
        }
    }
    @State private var startedTutorial = false
    @State private var importedStart = false

    private var availableTutorial: Tutorial? { tutorial ?? firmware.flatMap(TutorialLibrary.tutorial(for:)) }

    static let pageURL = URL(string: "https://joakimeriksson.github.io/fm1-emu/?embed=1")!
    /// SHA-256 of the package, computed once (it keys the emulator saves).
    @State private var shaCache: String?
    private var sha: String {
        if let s = shaCache ?? firmware.map(\.sha256), !s.isEmpty { return s }
        return SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
    }
    private var saves: [EmulatorSave] { allSaves.filter { $0.packageSHA == sha } }

    var body: some View {
        NavigationStack {
            EmulatorWebView(controller: emu, package: package, fileName: fileName, pads: pads)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(closing ? "Saving…" : "Close") { Task { await close() } }.disabled(closing)
                    }
                    ToolbarItem(placement: .primaryAction) { savesMenu }
                    if let t = availableTutorial {
                        ToolbarItem(placement: .primaryAction) {
                            Button { Task { await toggleTutorial(t) } } label: {
                                Label("Tutorial", systemImage: player == nil ? "graduationcap" : "graduationcap.fill")
                            }
                            .disabled(!emu.ready)
                        }
                    }
                }
                .shareSheet($sharing)
                // the card docks in its own strip; the emulator page shrinks to fit beside it
                .safeAreaInset(edge: .top, spacing: 0) { if dock == .top { tutorialCard } }
                .safeAreaInset(edge: .bottom, spacing: 0) { if dock == .bottom { tutorialCard } }
                .safeAreaInset(edge: .leading, spacing: 0) { if dock == .left { tutorialCard } }
                .safeAreaInset(edge: .trailing, spacing: 0) { if dock == .right { tutorialCard } }
                .onChange(of: emu.ready) {
                    if emu.ready, let save = startSave, !importedStart {
                        importedStart = true
                        Task {
                            let r = await emu.action("import", save)
                            emu.status = r.ok ? (startHint ?? "Tap Start") : "Couldn't load the song: \(r.message)"
                        }
                    }
                    if emu.ready, tutorial != nil, !startedTutorial, let t = tutorial { startedTutorial = true; Task { await toggleTutorial(t) } }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 2) {
                        Text(emu.status)
                        if !emu.saveStatus.isEmpty { Text(emu.saveStatus).foregroundStyle(.tertiary) }
                    }
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(6).frame(maxWidth: .infinity).background(.bar)
                }
        }
        .onAppear {
            if shaCache == nil, firmware == nil { shaCache = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined() }
            // play through the silent switch, like an instrument
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        .confirmationDialog("Reset the emulator's settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Save a copy, then reset") { Task { if await keep(label: "Before reset", auto: false) { await reset() } } }
            Button("Reset without saving", role: .destructive) { Task { await reset() } }
        } message: { Text("Erases the saved settings and patches for \(title) in the emulator and restarts it from the firmware's factory state.") }
        .confirmationDialog("Restore this save?", isPresented: $restoreTarget.isPresent(),
                            titleVisibility: .visible, presenting: restoreTarget) { s in
            Button("Restore \(s.label)", role: .destructive) { Task { await restore(s) } }
        } message: { _ in Text("Replaces the emulator's current settings and patches for this firmware.") }
        .alert("Name this save", isPresented: $naming) {
            TextField("e.g. Bass patches", text: $saveName)
            Button("Save") { let n = saveName; Task { await keep(label: n.isEmpty ? "Saved" : n, auto: false) } }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { r in
            guard case let .success(url) = r else { return }
            guard let data = try? readImport(url, maxBytes: ImportLimit.emulatorSave), let text = String(data: data, encoding: .utf8) else {
                emu.saveStatus = "Could not read that file (saves are up to 8 MB)."; return
            }
            Task { _ = await emu.action("import", text) }
        }
    }

    private var savesMenu: some View {
        Menu {
            Section {
                Button { Task { await emu.action("save") } } label: { Label("Save now", systemImage: "square.and.arrow.down") }
                Button { saveName = ""; naming = true } label: { Label("Save a copy to the library…", systemImage: "tray.and.arrow.down") }
            }
            if !saves.isEmpty {
                Section("Restore") {
                    ForEach(saves) { s in
                        Button("\(s.isAuto ? "Last session" : s.label) · \(s.date.formatted(date: .abbreviated, time: .shortened))") { restoreTarget = s }
                    }
                }
            }
            Section {
                Button { importing = true } label: { Label("Import .fm1save file…", systemImage: "doc.badge.arrow.up") }
                if let latest = saves.first {
                    Button { if let d = latest.payload { sharing = ShareItems(files: [(latest.fileName, d)]) } } label: {
                        Label("Share latest save", systemImage: "square.and.arrow.up")
                    }
                }
                Toggle("Keep a copy when closing", isOn: $keepOnClose)
            }
            Section {
                Button(role: .destructive) { confirmReset = true } label: { Label("Reset to factory settings…", systemImage: "arrow.counterclockwise") }
            }
            Section {
                Button { emu.reloads += 1 } label: { Label("Reload emulator", systemImage: "arrow.clockwise") }
            }
        } label: {
            if emu.busy { ProgressView() } else { Image(systemName: "externaldrive") }
        }
        .disabled(!emu.ready)
    }

    /// Exports the emulator's saved flash into the library. Returns false when nothing could be exported.
    @discardableResult
    private func keep(label: String, auto: Bool) async -> Bool {
        let r = await emu.action("export")
        guard r.ok, let text = r.text, let data = text.data(using: .utf8) else { return false }
        if auto, let old = saves.first(where: \.isAuto) {
            old.payload = data
            old.date = Date()
        } else {
            let s = EmulatorSave(label: label, packageSHA: sha, firmwareName: firmware?.name ?? title, payload: data, isAuto: auto)
            s.firmware = firmware
            context.insert(s)
        }
        try? context.save()
        emu.saveStatus = auto ? "Kept this session's settings in your library" : "Saved “\(label)” to your library"
        return true
    }

    private func reset() async { _ = await emu.action("reset") }

    private func toggleTutorial(_ t: Tutorial) async {
        if player != nil { await closeTutorial(); return }
        let p = TutorialPlayer(tutorial: t)
        p.emulator = emu
        emu.onUserEvent = { [weak p] name, down in p?.userEvent(name, down: down) }
        pads.tutorialNav = { [weak p] delta in
            guard let p else { return }
            Task { delta > 0 ? await p.next() : await p.back() }
        }
        player = p
        await p.begin()
        #if DEBUG
        if ProcessInfo.processInfo.environment["FM1_DEMO_TUTORIAL"] != nil { await autoplay(p) }
        #endif
    }

    #if DEBUG
    /// tools/tutorial-check.sh: plays every step (and its demo) so each can be screenshotted.
    private func autoplay(_ p: TutorialPlayer) async {
        for i in p.tutorial.steps.indices {
            await p.go(i)
            NSLog("TUTSTEP \(i + 1)/\(p.tutorial.steps.count) begin \(p.step.title)")
            await p.showMe()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            NSLog("TUTSTEP \(i + 1)/\(p.tutorial.steps.count) shown problem=\(p.problem ?? "none")")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        NSLog("TUTDONE")
    }
    #endif

    private func closeTutorial() async {
        await player?.stop()
        player = nil
        emu.onUserEvent = nil
        pads.tutorialNav = nil
    }

    private func restore(_ s: EmulatorSave) async {
        guard let d = s.payload, let text = String(data: d, encoding: .utf8) else { return }
        _ = await emu.action("import", text)
    }

    private func close() async {
        if keepOnClose, emu.ready {
            closing = true
            await keep(label: "Last session", auto: true)
        }
        dismiss()
    }
}

struct EmulatorWebView: UIViewRepresentable {
    let controller: EmulatorController
    let package: Data
    let fileName: String
    let pads: ControllerHub

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        config.userContentController.addUserScript(WKUserScript(source: Self.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "fm1tutorial")
        let web = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        web.isInspectable = true
        #endif
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // The emulator is an instrument: taps, double-taps and focusing its menus must never zoom the page
        // (the viewport lock in bridgeJS stops WebKit's own zoom; this stops pinching).
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 1
        web.scrollView.bouncesZoom = false
        controller.web = web
        context.coordinator.startMIDI()
        context.coordinator.reloads = controller.reloads
        web.load(URLRequest(url: EmulatorScreen.pageURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.reloads != controller.reloads {
            context.coordinator.reloads = controller.reloads
            context.coordinator.loaded = false
            controller.ready = false
            web.load(URLRequest(url: EmulatorScreen.pageURL))
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "fm1tutorial")
        coordinator.monitor?.stop()
        coordinator.parent.pads.emulatorSink.set(nil)
        web.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            // only the emulator page's own main frame may report touches
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == EmulatorScreen.pageURL.host,
                  let d = message.body as? [String: Any], let name = d["name"] as? String, name.count <= 32 else { return }
            controller.onUserEvent?(name, d["down"] as? Bool ?? true)
        }

        let parent: EmulatorWebView
        var monitor: MIDIInputMonitor?
        var loaded = false
        var reloads = 0
        private var pending: [[UInt8]] = []
        private var flushScheduled = false
        private var demoExport: String?

        init(_ p: EmulatorWebView) { parent = p }
        var controller: EmulatorController { parent.controller }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !loaded else { return }
            loaded = true
            controller.status = "Loading \(parent.fileName)…"
            Task {
                do {
                    let r = try await webView.callAsyncJavaScript("return await window.__fm1load(b64, name)",
                                                                  arguments: ["b64": parent.package.base64EncodedString(), "name": parent.fileName],
                                                                  contentWorld: .page)
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["FM1_DEMO_AUTOSTART"] != nil {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        _ = try? await webView.evaluateJavaScript("document.getElementById('start').click()")
                        if ProcessInfo.processInfo.environment["FM1_DEMO_ACTIONS"] != nil {
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            for k in ["save", "export", "reset"] {
                                let r = await controller.action(k)
                                NSLog("FM1DEMO \(k): ok=\(r.ok) msg=\(r.message) bytes=\(r.text?.count ?? -1)")
                                if k == "export", let t = r.text { demoExport = t }
                                try? await Task.sleep(nanoseconds: 4_000_000_000)
                            }
                            if let t = demoExport {
                                let r = await controller.action("import", t)
                                NSLog("FM1DEMO import: ok=\(r.ok) msg=\(r.message)")
                            }
                        }
                    }
                    #endif
                    let midi = monitor?.sourceNames.count ?? 0
                    controller.ready = r as? String == "ok"
                    controller.status = (controller.ready ? "Tap Start, then play the panel" : "\(r ?? "")")
                        + (midi > 0 ? " · MIDI from \(midi) source\(midi == 1 ? "" : "s")" : "")
                } catch {
                    controller.status = "Could not hand the firmware to the emulator: \(error.localizedDescription)"
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
        private func fail(_ error: Error) {
            controller.status = "The emulator needs an internet connection to load: \(error.localizedDescription)"
        }

        // Links off the emulator page (GitHub, reports) open in Safari.
        /// The emulator page (https://joakimeriksson.github.io/fm1-emu/…) and its own subframes stay in
        /// the view; the injected bridge must never run on another site. Plain web links open in Safari;
        /// every other scheme (tel:, sms:, other apps) is refused.
        static func isEmulatorPage(_ url: URL) -> Bool {
            // (URL.path drops the trailing slash: "/fm1-emu/?embed=1" has the path "/fm1-emu")
            url.scheme == "https" && url.host == EmulatorScreen.pageURL.host && (url.path == "/fm1-emu" || url.path.hasPrefix("/fm1-emu/"))
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let mainFrame = action.targetFrame?.isMainFrame ?? false
            if mainFrame, Self.isEmulatorPage(url) { return .allow }
            if !mainFrame, action.targetFrame != nil, ["about", "blob", "data"].contains(url.scheme ?? "") || Self.isEmulatorPage(url) {
                return .allow
            }
            if action.navigationType == .linkActivated || action.targetFrame == nil, ["https", "http"].contains(url.scheme ?? "") {
                await UIApplication.shared.open(url)
            }
            return .cancel
        }

        // The page's own confirm()/alert() (the app's actions answer theirs in JavaScript).
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async -> Bool {
            await present(message, cancel: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            _ = await present(message, cancel: false)
        }

        private func present(_ message: String, cancel: Bool) async -> Bool {
            guard let top = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return false }
            var vc = top
            while let p = vc.presentedViewController { vc = p }
            return await withCheckedContinuation { cont in
                // titled as the page's, so a message from the third-party page can't pass for one of the app's own
                let a = UIAlertController(title: "The emulator page says", message: String(message.prefix(500)), preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default) { _ in cont.resume(returning: true) })
                if cancel { a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cont.resume(returning: false) }) }
                vc.present(a, animated: true)
            }
        }

        func startMIDI() {
            let m = MIDIInputMonitor()
            m.onMessage = { [weak self] bytes in
                Task { @MainActor in self?.enqueue(bytes) }
            }
            monitor = m
            // SMC-PADs arrive mapped through the pad router instead of raw
            if parent.pads.sendToEmulator {
                m.exclude = ControllerRouter.smcPadPattern
                parent.pads.emulatorSink.set { [weak self] bytes in Task { @MainActor in self?.enqueue(bytes) } }
            }
        }

        private func enqueue(_ bytes: [UInt8]) {
            guard loaded else { return }
            if bytes.count > 2, bytes[0] & 0xE0 == 0x80 { // note on/off reaches the tutorial too
                controller.onUserEvent?("#\(bytes[1])", bytes[0] & 0xF0 == 0x90 && bytes[2] > 0)
            }
            pending.append(bytes)
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                flushScheduled = false
                let batch = pending
                pending.removeAll()
                let js = "window.__fm1midi && window.__fm1midi([" + batch.map { "[" + $0.map(String.init).joined(separator: ",") + "]" }.joined(separator: ",") + "])"
                controller.web?.evaluateJavaScript(js)
            }
        }
    }

    /// Injected before the page's own scripts: web/public/emu-bridge.js, shared with the web app.
    static let bridgeJS: String = {
        guard let u = Bundle.main.url(forResource: "emu-bridge", withExtension: "js"), let js = try? String(contentsOf: u, encoding: .utf8) else {
            assertionFailure("emu-bridge.js missing from the app bundle")
            return ""
        }
        return js
    }()
}
