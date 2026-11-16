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

    func action(_ kind: String, _ arg: String = "") async -> ActionResult {
        guard let web else { return .init(ok: false, message: "The emulator is not loaded.") }
        busy = true
        defer { busy = false }
        do {
            let r = try await web.callAsyncJavaScript("return await window.__fm1action(kind, arg)", arguments: ["kind": kind, "arg": arg],
                                                      contentWorld: .page) as? [String: Any] ?? [:]
            let result = ActionResult(ok: r["ok"] as? Bool ?? false, message: r["message"] as? String ?? "",
                                      name: r["name"] as? String, text: r["text"] as? String)
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

    static let pageURL = URL(string: "https://joakimeriksson.github.io/fm1-emu/?embed=1")!
    private var sha: String { SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined() }
    private var saves: [EmulatorSave] { allSaves.filter { $0.packageSHA == sha } }

    var body: some View {
        NavigationStack {
            EmulatorWebView(controller: emu, package: package, fileName: fileName, pads: pads)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(closing ? "Saving…" : "Close") { Task { await close() } }.disabled(closing)
                    }
                    ToolbarItem(placement: .primaryAction) { savesMenu }
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
            // play through the silent switch, like an instrument
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        .confirmationDialog("Reset the emulator's settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Save a copy, then reset") { Task { if await keep(label: "Before reset", auto: false) { await reset() } } }
            Button("Reset without saving", role: .destructive) { Task { await reset() } }
        } message: { Text("Erases the saved settings and patches for \(title) in the emulator and restarts it from the firmware's factory state.") }
        .confirmationDialog("Restore this save?", isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }),
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
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { emu.saveStatus = "Could not read that file."; return }
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
                if let latest = saves.first, let d = latest.payload {
                    ShareLink(items: ExportFiles.urls([(latest.fileName, d)])) { Label("Share latest save", systemImage: "square.and.arrow.up") }
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
        let web = WKWebView(frame: .zero, configuration: config)
        web.isInspectable = true
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
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
        coordinator.monitor?.stop()
        coordinator.parent.pads.emulatorSink.set(nil)
        web.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
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
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, action.navigationType == .linkActivated,
                  url.host != EmulatorScreen.pageURL.host || action.targetFrame == nil else { return .allow }
            await UIApplication.shared.open(url)
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
                let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
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

    /// Injected before the page's own scripts.
    static let bridgeJS = #"""
    (() => {
      // --- Web MIDI stand-in: every MIDI input of the iPhone/iPad, forwarded by the app
      const input = { id: "ios-all", name: "All MIDI inputs (app)", manufacturer: "", type: "input",
        state: "connected", connection: "open", onmidimessage: null,
        addEventListener() {}, removeEventListener() {},
        open: async () => input, close: async () => input };
      const access = { inputs: new Map([[input.id, input]]), outputs: new Map(), sysexEnabled: false,
        onstatechange: null, addEventListener() {}, removeEventListener() {} };
      try { Object.defineProperty(navigator, "requestMIDIAccess", { value: async () => access, configurable: true }); } catch (e) {}
      window.__fm1midi = (msgs) => {
        for (const b of msgs) if (input.onmidimessage) input.onmidimessage({ data: new Uint8Array(b), timeStamp: performance.now() });
      };

      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const $ = (id) => document.getElementById(id);
      const fileFrom = (data, name) => {
        const dt = new DataTransfer();
        dt.items.add(new File([data], name, { type: "application/octet-stream" }));
        return dt.files;
      };

      // --- the app answers the page's confirm() for its own actions
      let autoConfirm = 0;
      const pageConfirm = window.confirm.bind(window);
      window.confirm = (m) => { if (autoConfirm > 0) { autoConfirm--; return true; } return pageConfirm(m); };

      // --- exports: the page saves a .fm1save through a download link; hand it to the app instead
      let exportWaiter = null;
      const click = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        if (this.download && this.href.startsWith("blob:") && exportWaiter) {
          const w = exportWaiter, name = this.download;
          exportWaiter = null;
          fetch(this.href).then((r) => r.text()).then((text) => w({ name, text }), () => w(null));
          return;
        }
        return click.call(this);
      };

      window.__fm1load = async (b64, name) => {
        for (let i = 0; i < 300; i++) {
          const sel = $("fw");
          if (sel && sel.options.length > 0 && $("open")) break;
          await sleep(100);
        }
        await sleep(400); // the page's module attaches its handlers right after filling the list
        const bin = atob(b64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        const open = $("open");
        if (!open) return "The emulator page changed: no file input found.";
        open.files = fileFrom(bytes, name);
        open.dispatchEvent(new Event("change"));
        const midi = $("midi");
        if (midi && !midi.disabled) { midi.value = "*"; midi.dispatchEvent(new Event("change")); }
        return "ok";
      };

      // save | export | import (arg: .fm1save text) | reset  ->  { ok, message, name?, text? }
      window.__fm1action = async (kind, arg) => {
        const status = $("save-status");
        const result = (extra = {}) => ({ ok: status?.dataset.error !== "true", message: status?.textContent || "", ...extra });
        const before = status?.textContent;
        const changed = async (ms) => { for (let t = 0; t < ms; t += 100) { if (status?.textContent !== before) break; await sleep(100); } await sleep(150); };
        if (status) status.dataset.error = "false";
        switch (kind) {
          case "save": {
            const b = $("save-now"); if (!b) return { ok: false, message: "No save control on the page." };
            b.click(); await changed(3000); return result();
          }
          case "export": {
            const b = $("export-save"); if (!b) return { ok: false, message: "No export control on the page." };
            const got = await new Promise((resolve) => {
              exportWaiter = resolve;
              b.click();
              setTimeout(() => { if (exportWaiter === resolve) { exportWaiter = null; resolve(null); } }, 8000);
            });
            if (!got) return { ok: false, message: (status?.textContent || "") || "Start the firmware first, then save." };
            return { ok: true, message: "Exported", name: got.name, text: got.text };
          }
          case "import": {
            const inp = $("import-save"); if (!inp) return { ok: false, message: "No import control on the page." };
            autoConfirm = 1;
            inp.files = fileFrom(arg, "restore.fm1save");
            inp.dispatchEvent(new Event("change"));
            await changed(6000);
            autoConfirm = 0;
            return result();
          }
          case "reset": {
            const b = $("reset-save"); if (!b) return { ok: false, message: "No reset control on the page." };
            autoConfirm = 1;
            b.click();
            await changed(6000);
            autoConfirm = 0;
            return result();
          }
        }
        return { ok: false, message: "unknown action" };
      };
    })();
    """#
}
