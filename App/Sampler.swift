// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import AVFoundation
import FM1Kit
import Foundation
import SwiftData

/// Per-pad playback settings of a kit.
struct PadSettings: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable { case oneShot, gate }
    var mode: Mode = .oneShot
    /// Choking pads cut each other off (one voice for the whole chopped loop).
    var choke = true
    var volume: Float = 1
    var pitch: Int = 0
}

struct KitSettings: Codable, Hashable {
    /// Start frame of each of the 16 slices (in the source file's sample rate).
    var starts: [Int]
    var pads: [PadSettings] = Array(repeating: PadSettings(), count: 16)
    var slicing: String = "transients"
}

/// A sample sliced across the 16 pads. The audio file is kept as imported.
@Model
final class SampleKit {
    var name: String = ""
    var createdAt: Date = Date()
    var fileName: String = ""
    @Attribute(.externalStorage) var audio: Data?
    var sampleRate: Double = 44100
    var frames: Int = 0
    var settingsData: Data?
    @Relationship(deleteRule: .nullify, inverse: \ControllerProfile.kit) var profiles: [ControllerProfile]? = []

    init(name: String, fileName: String, audio: Data) {
        self.name = name
        self.fileName = fileName
        self.audio = audio
    }

    var settings: KitSettings {
        get { settingsData.flatMap { try? JSONDecoder().decode(KitSettings.self, from: $0) } ?? KitSettings(starts: SliceDetector.equal(frames: frames)) }
        set { settingsData = try? JSONEncoder().encode(newValue) }
    }
}

/// A kit decoded for playback: mono samples for drawing and slicing, and stereo buffers per slice.
/// The slices and settings are swapped together under a lock, so the CoreMIDI thread always plays a
/// consistent snapshot while the UI edits.
final class LoadedKit: @unchecked Sendable {
    /// Longest sample accepted: about 70 MB of decoded audio, a safe amount on any iPhone.
    static let maxSeconds = 120.0

    struct Snapshot { let settings: KitSettings; let slices: [AVAudioPCMBuffer] }

    let mono: [Float]
    let sampleRate: Double
    let source: AVAudioPCMBuffer
    private let lock = NSLock()
    private var current: Snapshot
    private var peakCache: [Int: [(min: Float, max: Float)]] = [:]

    var settings: KitSettings { lock.withLock { current.settings } }
    var snapshot: Snapshot { lock.withLock { current } }

    init(data: Data, fileName: String, settings: KitSettings?, engineFormat: AVAudioFormat) throws {
        let ext = (fileName as NSString).pathExtension.isEmpty ? "m4a" : (fileName as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) <= file.processingFormat.sampleRate * Self.maxSeconds else {
            throw NSError(domain: "Sampler", code: 4, userInfo: [NSLocalizedDescriptionKey: "Samples can be up to two minutes long."])
        }
        guard file.length > 0, let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Sampler", code: 1, userInfo: [NSLocalizedDescriptionKey: "That file has no audio."])
        }
        try file.read(into: raw)
        sampleRate = file.processingFormat.sampleRate

        // mono mix for the waveform and slicing
        let n = Int(raw.frameLength), chans = Int(raw.format.channelCount)
        var m = [Float](repeating: 0, count: n)
        if let d = raw.floatChannelData {
            for c in 0..<chans { for i in 0..<n { m[i] += d[c][i] / Float(chans) } }
        }
        mono = m

        // the engine's format, for playback
        guard let conv = AVAudioConverter(from: raw.format, to: engineFormat) else {
            throw NSError(domain: "Sampler", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't convert this audio."])
        }
        let outFrames = AVAudioFrameCount(Double(n) * engineFormat.sampleRate / sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: outFrames) else {
            throw NSError(domain: "Sampler", code: 3, userInfo: [NSLocalizedDescriptionKey: "Out of memory."])
        }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return raw
        }
        if let err { throw err }
        source = out
        let s = (settings ?? KitSettings(starts: SliceDetector.transients(m, sampleRate: sampleRate))).normalized(frames: n)
        current = Snapshot(settings: s, slices: Self.cut(source: out, sourceRate: sampleRate, starts: s.starts))
    }

    /// New settings. Slices are re-cut only when the slice points moved (volume or pitch changes
    /// just swap the settings). Safe to call from any thread.
    func update(_ new: KitSettings) {
        let s = new.normalized(frames: mono.count)
        let old = snapshot
        let slices = old.settings.starts == s.starts ? old.slices : Self.cut(source: source, sourceRate: sampleRate, starts: s.starts)
        lock.withLock { current = Snapshot(settings: s, slices: slices) }
    }

    /// Min/max per bucket for drawing, cached per width.
    func peaks(buckets: Int) -> [(min: Float, max: Float)] {
        if let p = lock.withLock({ peakCache[buckets] }) { return p }
        let p = SliceDetector.peaks(mono, buckets: buckets)
        lock.withLock { peakCache[buckets] = p }
        return p
    }

    /// Slice buffers in engine frames, with a short fade at both ends against clicks.
    static func cut(source: AVAudioPCMBuffer, sourceRate: Double, starts: [Int]) -> [AVAudioPCMBuffer] {
        let ratio = source.format.sampleRate / sourceRate
        let total = Int(source.frameLength)
        let s = starts.map { min(total, max(0, Int(Double($0) * ratio))) }
        return s.indices.map { i in
            let a = s[i], b = i + 1 < s.count ? max(a, s[i + 1]) : total
            let len = b - a
            let buf = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(max(len, 1)))!
            buf.frameLength = AVAudioFrameCount(max(len, 1))
            let fade = min(len / 4, Int(source.format.sampleRate * 0.003))
            for c in 0..<Int(source.format.channelCount) {
                guard let src = source.floatChannelData?[c], let dst = buf.floatChannelData?[c] else { continue }
                if len == 0 { dst[0] = 0; continue }       // an empty slice plays one frame of silence
                for j in 0..<len {
                    var g: Float = 1
                    if j < fade { g = Float(j) / Float(fade) } else if j >= len - fade { g = Float(len - j) / Float(fade) }
                    dst[j] = src[a + j] * g
                }
            }
            return buf
        }
    }
}

extension KitSettings {
    /// Exactly 16 ascending slice starts within the sample and 16 pad settings, whatever was synced.
    func normalized(frames: Int) -> KitSettings {
        var s = self
        var st = starts.map { min(max(0, $0), max(frames - 1, 0)) }.sorted()
        if st.count != 16 || st.first != 0 { st = SliceDetector.equal(frames: frames) }
        s.starts = st
        if pads.count < 16 { s.pads += Array(repeating: PadSettings(), count: 16 - pads.count) }
        if pads.count > 16 { s.pads = Array(pads.prefix(16)) }
        return s
    }
}

/// The slice sampler's audio: 16 voices (player + varispeed) into the main mixer. Triggered from
/// the CoreMIDI thread (SMC-PAD pads) or the UI; one kit per controller model.
final class SlicePlayer: @unchecked Sendable {
    let engine = AVAudioEngine()
    let format: AVAudioFormat
    private var voices: [(player: AVAudioPlayerNode, speed: AVAudioUnitVarispeed)] = []
    private var voicePad: [Int?]
    /// Bumped each time a voice starts, so a late completion from an earlier play can't free it.
    private var voiceGen: [UInt64]
    private var nextVoice = 0
    private let lock = NSLock()
    private var kits: [ControllerModel: LoadedKit] = [:]
    /// Called on any thread when a pad plays (for the on-screen pads).
    var onTrigger: (@Sendable (ControllerModel, Int) -> Void)?
    /// While the mic records, the session stays in play-and-record; playback must not switch it back.
    static var recording = false

    init(voiceCount: Int = 16) {
        format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        voicePad = Array(repeating: nil, count: voiceCount)
        voiceGen = Array(repeating: 0, count: voiceCount)
        for _ in 0..<voiceCount {
            let p = AVAudioPlayerNode(), v = AVAudioUnitVarispeed()
            engine.attach(p); engine.attach(v)
            engine.connect(p, to: v, format: format)
            engine.connect(v, to: engine.mainMixerNode, format: format)
            voices.append((p, v))
        }
        let nc = NotificationCenter.default
        // a call, Siri or a route change stops the engine: forget the voices, restart on the next hit
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] _ in self?.clearVoices() }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in self?.clearVoices() }
    }

    static func configureSession(recording: Bool = false) {
        Self.recording = recording
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(recording ? .playAndRecord : .playback, mode: .default,
                           options: recording ? [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP] : [.mixWithOthers])
        try? s.setPreferredIOBufferDuration(0.005)
        try? s.setActive(true)
    }

    /// Starts the engine if needed; false when it can't run right now (e.g. during a phone call).
    @discardableResult
    func start() -> Bool {
        if engine.isRunning { return true }
        if !Self.recording { Self.configureSession() }
        engine.prepare()
        do { try engine.start() } catch { return false }
        return engine.isRunning
    }

    /// Stops rendering (in the background, when no pads are connected) to save battery.
    func pause() {
        clearVoices()
        if engine.isRunning { engine.pause() }
    }

    private func clearVoices() {
        lock.withLock { for i in voicePad.indices { voicePad[i] = nil; voiceGen[i] &+= 1 } }
    }

    func setKit(_ kit: LoadedKit?, for model: ControllerModel) {
        lock.withLock { kits[model] = kit }
        if kit != nil { start() }
    }

    func kit(for model: ControllerModel) -> LoadedKit? { lock.withLock { kits[model] } }

    /// velocity 0 = pad released.
    func trigger(model: ControllerModel, pad: Int, velocity: UInt8) {
        guard let kit = kit(for: model) else { return }
        play(kit, pad: pad, velocity: velocity)
        if velocity > 0 { onTrigger?(model, pad) }
    }

    /// Plays a slice of any kit (the Sampler screen auditions the kit being edited).
    func play(_ kit: LoadedKit, pad: Int, velocity: UInt8) {
        let snap = kit.snapshot
        guard snap.slices.indices.contains(pad) else { return }
        let buf = snap.slices[pad]
        let pads = snap.settings.pads
        let ps = pads.indices.contains(pad) ? pads[pad] : PadSettings()
        guard start() else { return }

        // decide under the lock, call into AVFoundation outside it (stop() can wait on completions)
        var toStop: [Int] = []
        var voice = -1
        var gen: UInt64 = 0
        lock.withLock {
            if velocity == 0 {
                if ps.mode == .gate { for (i, p) in voicePad.enumerated() where p == pad { toStop.append(i); voicePad[i] = nil; voiceGen[i] &+= 1 } }
                return
            }
            // choke: stop every voice playing a choking pad (and always this pad's own last voice)
            for (i, p) in voicePad.enumerated() {
                guard let p else { continue }
                let other = pads.indices.contains(p) ? pads[p] : PadSettings()
                if p == pad || (ps.choke && other.choke) { toStop.append(i); voicePad[i] = nil; voiceGen[i] &+= 1 }
            }
            voice = voicePad.firstIndex(where: { $0 == nil }) ?? nextVoice
            nextVoice = (voice + 1) % voices.count
            voicePad[voice] = pad
            voiceGen[voice] &+= 1
            gen = voiceGen[voice]
        }
        for i in toStop where i != voice { voices[i].player.stop() }
        guard voice >= 0 else { return }
        let v = voices[voice], i = voice
        v.player.stop()
        v.player.volume = ps.volume * (0.25 + 0.75 * Float(velocity) / 127)
        v.speed.rate = Float(pow(2, Double(ps.pitch) / 12))
        v.player.scheduleBuffer(buf, at: nil, options: .interrupts) { [weak self] in
            guard let self else { return }
            self.lock.withLock { if self.voiceGen[i] == gen { self.voicePad[i] = nil } }
        }
        v.player.play()
    }

    func stopAll() {
        clearVoices()
        voices.forEach { $0.player.stop() }
    }
}
