// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import AVFoundation
import FM1Kit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The song editor's Import from audio: a file or a recording, its tempo and up to four 4-bar sections (moveable, to
/// hear against the original), then their bassline, chords, lead and drums onto the tracks chosen.
///
/// The analysis is the web app's (web/src/audio, built into App/AudioImport by `npm run build:ios-audio`): it runs in
/// a hidden web view that only loads the app's own files, so both apps find the same notes and drums.
struct AudioImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let doc: SLOOPSongDoc
    /// The plan, and the audio's name (the file's, or "Recording" and the time).
    let apply: (SLOOPImportPlan, String) -> Void

    @State private var analyser = AudioAnalyser()
    @State private var result: AudioAnalyser.Result?
    @State private var sections: [SLOOPAudioSection] = []
    @State private var targets: [Int] = []
    @State private var tracks = SLOOPImportPlan.defaultTracks
    @State private var setTempo = true
    @State private var setOrder = true
    @State private var picking = false
    @State private var recording = false
    @State private var error: String?
    @State private var audioURL: URL?
    @State private var player = LoopPlayer()
    /// The piece on repeat, and how (original, what SLOOP will play, both).
    @State private var playing: (i: Int, mode: Preview)?
    @State private var name = ""
    @State private var confirmClose = false
    /// A piece's start while its slider is dragged (analysed when let go).
    @State private var scrub: [Int: Double] = [:]

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                if let result { found(result) } else { pick }
            }
            .navigationTitle(name.isEmpty ? "Import from audio" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // (the results took a while: ask before they go)
                    Button("Close") { if result != nil { confirmClose = true } else { stopPreview(); dismiss() } }
                        .confirmationDialog("Close without importing?", isPresented: $confirmClose, titleVisibility: .visible) {
                            Button("Discard the results", role: .destructive) { stopPreview(); dismiss() }
                            Button("Keep reviewing", role: .cancel) {}
                        } message: { Text("The analysis of \"\(name)\" goes, and you'd have to run it again.") }
                }
                if result != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            stopPreview()
                            apply(SLOOPImportPlan(sections: sections, targets: targets, tracks: tracks,
                                                  tempo: setTempo ? Int((result?.bpm ?? 120).rounded()) : nil, order: setOrder), name)
                            dismiss()
                        }
                        .disabled(sections.isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { r in
                if case let .success(url) = r { run(url, name: url.deletingPathExtension().lastPathComponent) }
            }
            .sheet(isPresented: $recording) {
                RecorderSheet(hint: "Play the part, or the song near the mic, then stop. 10–30 seconds is plenty.") { run($0, name: "Recording \(Date().formatted(date: .abbreviated, time: .shortened))") }
            }
            .background(AudioAnalyserView(analyser: analyser).frame(width: 1, height: 1).opacity(0))
            .interactiveDismissDisabled(result != nil || analyser.busy)    // (no swiping the results away by accident)
        }
    }

    @ViewBuilder private var pick: some View {
        Section {
            Button { picking = true } label: { Label("Choose an audio file…", systemImage: "music.note") }
            Button { recording = true } label: { Label("Record from the microphone…", systemImage: "mic") }
        } footer: {
            Text("Turns audio into SLOOP parts: the tempo, then for up to four 4-bar sections a bassline, chords, a lead and drums (kick, snare, hats), on 16ths. A song works; one instrument at a time works best. Use audio you have the rights to. It's analysed on this device: nothing is uploaded.")
        }
        if analyser.busy {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(analyser.status).font(.subheadline)
                    if let p = analyser.progress { ProgressView(value: p) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
    }

    @ViewBuilder private func found(_ r: AudioAnalyser.Result) -> some View {
        Section {
            Text("\(Duration.seconds(r.duration).formatted(.time(pattern: .minuteSecond))) at about \(Int(r.bpm.rounded())) BPM.")
            Text(LocalizedStringKey(sections.isEmpty ? "No pieces left to import: add one below."
                 : "\(sections.count == 1 ? "One 4-bar piece" : "\(sections.count) 4-bar pieces") of the song, picked from different parts of it. **All of them are imported** when you tap Import, each into the SLOOP section it's set to (A–D). Leave out any you don't want."))   // (a key: the bold renders)
            if analyser.busy { Label(analyser.status, systemImage: "hourglass").foregroundStyle(.secondary) }
            AudioOverview(envelope: analyser.envelope, duration: r.duration,
                          pieces: sections.indices.map { (start: scrub[$0] ?? sections[$0].start, length: 16 * 60 / sections[$0].bpm, name: ["A", "B", "C", "D"][targets[$0]]) })
                .frame(height: 56)
        } footer: { Text("Drag a piece's slider to where it should start, then fine-tune by a beat or a bar; it snaps to the nearest downbeat when you let go. ▶ plays a piece on repeat: the original, what SLOOP will play from it (the parts going onto tracks, each looping at its own length, in plain sounds: on the FM-1 they play with the tracks' own sounds), or both.") }
        ForEach(sections.indices, id: \.self) { i in
            let sec = sections[i]
            Section {
                Picker("Goes into", selection: Binding(get: { targets[i] }, set: { targets[i] = $0 })) {
                    ForEach(0..<4, id: \.self) { k in Text("Section \(["A", "B", "C", "D"][k])\(doc.isEmpty(.section(k)) ? "" : " (replaces it)")").tag(k) }
                }
                let length = 16 * 60 / sec.bpm, latest = max(0, r.duration - length)
                HStack {
                    Text(clock(scrub[i] ?? sec.start) + "–" + clock((scrub[i] ?? sec.start) + length)).monospacedDigit()
                    Slider(value: Binding(get: { min(latest, scrub[i] ?? sec.start) }, set: { scrub[i] = $0 }), in: 0...max(0.1, latest)) { editing in
                        if !editing, let t = scrub[i] { moveTo(i, t) }
                    }
                    .accessibilityLabel("Where the piece starts")
                }
                .disabled(analyser.busy)
                HStack {
                    Spacer()
                    Button("−bar") { move(i, beats: -4) }.accessibilityLabel("A bar earlier")
                    Button("−beat") { move(i, beats: -1) }.accessibilityLabel("A beat earlier")
                    Button("+beat") { move(i, beats: 1) }.accessibilityLabel("A beat later")
                    Button("+bar") { move(i, beats: 4) }.accessibilityLabel("A bar later")
                }
                .buttonStyle(.bordered).disabled(analyser.busy)
                HStack {
                    ForEach(Preview.allCases, id: \.self) { mode in
                        let on = playing?.i == i && playing?.mode == mode
                        Button { preview(i, mode) } label: { Label(mode.title, systemImage: on ? "stop.fill" : "play.fill") }
                            .buttonStyle(.bordered).tint(on ? .accentColor : nil)
                            .accessibilityLabel(on ? "Stop" : "Play \(mode.title.lowercased()) on repeat")
                    }
                }
                .font(.caption)
                if let r = sec.repeats {
                    Text(LocalizedStringKey("A loop of the song: plays **\(r)×**" + (sec.lengths.map { " · drums \(bars($0["drums"])), bass \(bars($0["bass"])), chords \(bars($0["keys"]))" } ?? "") + "."
                         + (sec.unsure == true ? " Not sure of this one: it repeats little, or a new sound comes in during it." : "")))
                        .font(.caption)
                } else {
                    Text("Your pick (not one of the song's loops).").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(sec.bass.count) bass notes · \(sec.keys.count) chords · \(sec.lead.count) lead notes · \(sec.drums.count) drum steps")
                    .font(.caption).foregroundStyle(.secondary)
                Text(drumRows(sec)).font(.system(size: 11, design: .monospaced)).lineLimit(nil)
                    .accessibilityLabel("Drums found: \(sec.drums.count) steps")
                Button("Leave this piece out", role: .destructive) { sections.remove(at: i); targets.remove(at: i); scrub = [:] }
                    .disabled(analyser.busy)
            } header: { Text("Piece \(i + 1) → Section \(["A", "B", "C", "D"][targets[i]])") }
            .swipeActions { Button("Remove", role: .destructive) { sections.remove(at: i); targets.remove(at: i) } }
        }
        if sections.count < 4 {
            Section { Button("Add another piece") { add() }.disabled(analyser.busy) }
        }
        Section {
            ForEach(SLOOPImportPlan.Part.allCases, id: \.self) { part in
                Picker(label(part), selection: Binding(get: { tracks[part] ?? -1 }, set: { tracks[part] = $0 < 0 ? nil : $0 })) {
                    if part == .drums { Text("Drums").tag(SLOOPTrack.drumTrack) } else { ForEach(0..<3, id: \.self) { Text("Track \($0 + 1)").tag($0) } }
                    Text("Skip").tag(-1)
                }
            }
            Toggle("Set the tempo to \(Int(r.bpm.rounded())) BPM", isOn: $setTempo)
            Toggle("Song order: these sections in turn, 4 bars each", isOn: $setOrder)
        } header: { Text("Onto the tracks") } footer: {
            Text("The tracks chosen get these notes on 16ths, each as long as its part's pattern (a loop's 1-bar beat: 16 steps; otherwise up to 64); their sounds stay (change them on the FM-1). An empty section starts as a copy of the loop's sounds; an empty loop gets the first piece, so it plays as soon as SLOOP starts. Undo puts it all back."
                 + (Set(tracks.values).count < tracks.count ? " Two parts go on the same track: the later one replaces the earlier." : ""))
        }
        Section { Button("Use other audio") { stopPreview(); result = nil; sections = []; error = nil } }
    }

    private func label(_ p: SLOOPImportPlan.Part) -> String {
        switch p { case .bass: "Bassline"; case .keys: "Chords"; case .lead: "Lead"; case .drums: "Drums" }
    }

    private func drumRows(_ sec: SLOOPAudioSection) -> String {
        let hits = Set(sec.drums.flatMap { h in h.lanes.map { "\(h.step),\($0)" } })
        let lanes = Set(sec.drums.flatMap(\.lanes)).sorted()
        if lanes.isEmpty { return "No drums found." }
        return lanes.map { l in
            SLOOPTrack.drumLanes[l].padding(toLength: 8, withPad: " ", startingAt: 0) + " " +
                (0..<4).map { b in String((0..<16).map { hits.contains("\(b * 16 + $0),\(l)") ? "x" : "·" }) }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    // MARK: Running the analysis

    private func run(_ url: URL, name: String) {
        error = nil
        do {
            let data = try readImport(url, maxBytes: 200 << 20)
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).\(url.pathExtension)")
            try data.write(to: copy)
            audioURL = copy
            self.name = name
            Task {
                do {
                    let r = try await analyser.analyse(copy)
                    result = r
                    sections = r.sections
                    targets = Array(0..<r.sections.count)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func move(_ i: Int, beats: Int) {
        guard let r = result else { return }
        moveTo(i, sections[i].start + Double(beats) * 60 / r.bpm)
    }

    /// The piece analysed again from `start` (snapped by the analysis to the downbeat nearby).
    private func moveTo(_ i: Int, _ start: Double) {
        stopPreview()
        guard let r = result else { return }
        let t = max(0, min(r.duration - 16 * 60 / r.bpm, start))
        Task {
            do { let s = try await analyser.section(at: t); if i < sections.count { sections[i] = s } }
            catch { self.error = error.localizedDescription }
            scrub[i] = nil
        }
    }

    private func bars(_ steps: Int?) -> String { (steps ?? 64) == 16 ? "1 bar" : "\((steps ?? 64) / 16) bars" }

    private func clock(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }

    private func add() {
        guard let r = result else { return }
        let beat = 60 / r.bpm, start = sections.last.map { min(r.duration - 16 * beat, $0.start + 16 * beat) } ?? 0
        Task {
            do {
                sections.append(try await analyser.section(at: max(0, start)))
                targets.append((0..<4).first { !targets.contains($0) } ?? 0)
            } catch { self.error = error.localizedDescription }
        }
    }

    /// A piece on repeat: its original 4 bars, what SLOOP will play from it (the parts going onto tracks, each at its
    /// track's length), or both; the same again stops it.
    private func preview(_ i: Int, _ mode: Preview) {
        let same = playing?.i == i && playing?.mode == mode
        stopPreview()
        guard !same, i < sections.count else { return }
        let sec = sections[i], parts = Set(SLOOPImportPlan.Part.allCases.filter { tracks[$0] != nil })
        let orig = mode == .sloop ? nil : SLOOPPreview.original(analyser.samples, sec)
        let sloop = mode == .original ? nil : SLOOPPreview.sloop(sec, parts: parts)
        player.play(orig.flatMap { o in sloop.map { SLOOPPreview.both(o, $0) } } ?? orig ?? sloop ?? [])
        playing = (i, mode)
    }

    private func stopPreview() { player.stop(); playing = nil }
}

/// Runs the audio analysis (the web app's) in a hidden web view loading only the app's own files.
@MainActor @Observable
final class AudioAnalyser: NSObject, WKScriptMessageHandler {
    struct Result: Decodable { let bpm, duration: Double; let sections: [SLOOPAudioSection] }
    var status = ""
    var progress: Double?
    var busy = false
    /// The audio's loudness, 0...1, in 400 slices (the review's overview).
    var envelope: [Float] = []
    /// The audio as analysed (mono 22050 Hz): the previews play pieces of it.
    @ObservationIgnored var samples: [Float] = []
    @ObservationIgnored private var ready = false
    @ObservationIgnored var web: WKWebView?

    nonisolated static let scheme = "fm1audio"

    @ObservationIgnored private let files = BundleFiles()

    /// The page, made once: SwiftUI may rebuild the hidden view that shows it, and a new page would cut off an
    /// analysis running in the old one (WebKit then only says "unsupported type").
    func makeWebView() -> WKWebView {
        if let w = web { return w }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(files, forURLScheme: Self.scheme)
        config.userContentController.add(WeakHandler(self), name: "fm1audio")
        config.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        w.load(URLRequest(url: URL(string: "\(Self.scheme)://app/index.html")!))
        web = w
        return w
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let s = m["status"] as? String else { return }
        if s == "ready" { ready = true; return }
        status = String(s.prefix(120))
        progress = (m["progress"] as? Double).map { min(1, max(0, $0)) }
    }

    private func page() async throws -> WKWebView {
        for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(100)) }
        guard ready, let web else { throw FM1Error.unsupported("The audio analysis didn't start.") }
        return web
    }

    /// Analyses an audio file: decoded here (to mono 22050 Hz, as the analysis wants), then read by the page as
    /// binary (a whole song in the web view's own decoder can run it out of memory).
    func analyse(_ file: URL) async throws -> Result {
        busy = true; status = "Reading the audio…"; progress = nil
        defer { busy = false; files.input = nil; files.pitch = nil }
        let samples = try await Task.detached { try Self.monoSamples(file) }.value
        files.input = samples
        envelope = Self.envelope(samples)
        self.samples = samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // the notes' model on the Neural Engine / GPU (Core ML); if it can't run, the page runs it itself
        status = "Finding the notes (Basic Pitch)…"
        let t0 = Date()
        progress = 0
        // (at most a minute: then the page runs the model itself)
        let coreML = Task.detached { [weak self] in
            try BasicPitchCoreML.output(samples: samples) { f in Task { @MainActor in self?.progress = f } }
        }
        let limit = Task { try await Task.sleep(for: .seconds(60)); coreML.cancel() }
        files.pitch = try? await coreML.value
        limit.cancel()
        progress = nil
        #if DEBUG
        NSLog("AUDIOTEST Core ML %@ in %.1f s", files.pitch == nil ? "unavailable" : "ran", Date().timeIntervalSince(t0))
        #endif
        let web = try await page()
        return try decode(Result.self, try await run(web, "return await window.__fm1audio.analyse('')", [:]))
    }

    /// Any audio file AVFoundation reads, mixed to mono and resampled to 22050 Hz, as 32-bit float samples.
    /// The peak of each of `n` slices of Float32 samples, scaled to the loudest.
    nonisolated static func envelope(_ samples: Data, n: Int = 400) -> [Float] {
        samples.withUnsafeBytes { raw in
            let y = raw.bindMemory(to: Float.self), size = max(1, y.count / n)
            var out = (0..<n).map { k in
                var m: Float = 0
                for i in stride(from: k * size, to: min(y.count, (k + 1) * size), by: 4) { m = max(m, abs(y[i])) }
                return m
            }
            let top = out.max() ?? 0
            if top > 0 { out = out.map { $0 / top } }
            return out
        }
    }

    nonisolated static func monoSamples(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: file.processingFormat, to: out) else { throw FM1Error.unsupported("That audio can't be read.") }
        conv.downmix = true
        let chunk: AVAudioFrameCount = 32768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw FM1Error.unsupported("Out of memory.") }
        var data = Data()
        var done = false
        while true {
            let ratio = 22050 / file.processingFormat.sampleRate
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 64) else { break }
            var error: NSError?
            let status = conv.convert(to: outBuf, error: &error) { _, outStatus in
                if done { outStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf, frameCount: chunk) } catch { done = true; outStatus.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { done = true; outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let error { throw error }
            if let p = outBuf.floatChannelData?[0], outBuf.frameLength > 0 { data.append(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength))) }
            if status == .endOfStream || status == .error { break }
        }
        guard data.count >= 22050 * 4 * 4 else { throw FM1Error.unsupported("That's under 4 seconds: a 4-bar section needs more.") }
        return data
    }

    func section(at start: Double) async throws -> SLOOPAudioSection {
        busy = true; status = "Analysing…"
        defer { busy = false }
        return try decode(SLOOPAudioSection.self, try await run(page(), "return await window.__fm1audio.section(t)", ["t": start]))
    }

    /// Runs a call into the page; its answer is JSON text, or {"error": …}. WebKit's own errors say only that "an
    /// exception occurred": the message it carries is shown instead.
    private func run(_ web: WKWebView, _ js: String, _ args: [String: Any]) async throws -> String {
        do {
            guard let s = try await web.callAsyncJavaScript(js, arguments: args, contentWorld: .page) as? String else {
                throw FM1Error.unsupported("The audio analysis didn't answer.")
            }
            return s
        } catch let e as NSError where e.domain == WKError.errorDomain {
            let detail = e.userInfo["WKJavaScriptExceptionMessage"] as? String ?? e.localizedDescription
            throw FM1Error.unsupported("The audio analysis stopped: \(detail)")
        }
    }

    private struct Failure: Decodable { let error: String }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        if let f = try? JSONDecoder().decode(Failure.self, from: Data(json.utf8)) { throw FM1Error.unsupported(f.error) }
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// (WKUserContentController keeps its handlers strongly.)
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: AudioAnalyser?
        init(_ t: AudioAnalyser) { target = t }
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { target?.userContentController(uc, didReceive: message) }
        }
    }
}

/// Serves `fm1audio://app/<path>` from the app's AudioImport folder only (nothing else, nothing from the network), and
/// `input.pcm`: the audio being analysed, decoded by the app.
private final class BundleFiles: NSObject, WKURLSchemeHandler {
    private let root = Bundle.main.url(forResource: "AudioImport", withExtension: nil)?.standardizedFileURL
    var input: Data?
    /// Basic Pitch's output for it, from Core ML (pitch.bin), when that ran.
    var pitch: Data?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let root, url.host == "app" else { return fail(task) }
        if url.path == "/input.pcm" || url.path == "/pitch.bin" {
            guard let input = url.path == "/input.pcm" ? input : pitch else { return fail(task) }
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "application/octet-stream", "Content-Length": "\(input.count)"])!)
            task.didReceive(input)
            task.didFinish()
            return
        }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else { return fail(task) }
        let type: String = switch file.pathExtension {
        case "html": "text/html"; case "js": "text/javascript"; case "json": "application/json"; default: "application/octet-stream"
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func fail(_ task: any WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}

/// The hidden web view, kept in the sheet so it stays alive while the sheet is open.
struct AudioAnalyserView: UIViewRepresentable {
    let analyser: AudioAnalyser
    func makeUIView(context: Context) -> WKWebView { analyser.makeWebView() }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

/// The whole audio's loudness, with each piece's 4 bars marked by the section it goes into.
struct AudioOverview: View {
    let envelope: [Float]
    let duration: Double
    let pieces: [(start: Double, length: Double, name: String)]

    var body: some View {
        Canvas { g, size in
            guard duration > 0 else { return }
            let x = { (t: Double) in CGFloat(t / duration) * size.width }
            for p in pieces {
                let r = CGRect(x: x(p.start), y: 0, width: max(2, x(p.start + p.length) - x(p.start)), height: size.height)
                g.fill(Path(r), with: .color(.accentColor.opacity(0.25)))
                g.draw(Text(p.name).font(.caption2.bold()), at: CGPoint(x: r.minX + 7, y: 8))
            }
            let w = size.width / CGFloat(max(1, envelope.count))
            var bars = Path()
            for (k, v) in envelope.enumerated() {
                let h = max(1, CGFloat(v) * (size.height - 16))
                bars.addRect(CGRect(x: CGFloat(k) * w, y: size.height - h, width: max(1, w - 0.5), height: h))
            }
            g.fill(bars, with: .color(.secondary))
        }
        .accessibilityLabel("The audio, with the pieces marked")
    }
}

/// How a piece is previewed.
enum Preview: CaseIterable {
    case original, sloop, both
    var title: String { switch self { case .original: "Original"; case .sloop: "What SLOOP will play"; case .both: "Both" } }
}

/// Plays mono 22050 Hz samples on repeat, without a seam (a buffer scheduled to loop).
final class LoopPlayer {
    private let engine = AVAudioEngine(), node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: SLOOPPreview.sampleRate, channels: 1)!
    init() { engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format) }

    func play(_ x: [Float]) {
        stop()
        guard !x.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count)) else { return }
        buf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        do { if !engine.isRunning { try engine.start() } } catch { return }
        node.scheduleBuffer(buf, at: nil, options: .loops)
        node.play()
    }

    func stop() { node.stop() }
}
