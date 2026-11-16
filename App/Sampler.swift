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
final class LoadedKit: @unchecked Sendable {
    let mono: [Float]
    let sampleRate: Double
    let source: AVAudioPCMBuffer
    private(set) var slices: [AVAudioPCMBuffer] = []
    private(set) var settings: KitSettings

    init(data: Data, fileName: String, settings: KitSettings?, engineFormat: AVAudioFormat) throws {
        let ext = (fileName as NSString).pathExtension.isEmpty ? "m4a" : (fileName as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
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
        self.settings = settings ?? KitSettings(starts: SliceDetector.transients(m, sampleRate: sampleRate))
        cut()
    }

    func update(_ s: KitSettings) { settings = s; cut() }

    /// Slice buffers in engine frames, with a short fade at both ends against clicks.
    private func cut() {
        let ratio = source.format.sampleRate / sampleRate
        let total = Int(source.frameLength)
        let starts = settings.starts.map { min(total, Int(Double($0) * ratio)) }
        slices = starts.indices.map { i in
            let a = starts[i], b = i + 1 < starts.count ? starts[i + 1] : total
            let len = max(1, b - a)
            let buf = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(len))!
            buf.frameLength = AVAudioFrameCount(len)
            let fade = min(len / 4, Int(source.format.sampleRate * 0.003))
            for c in 0..<Int(source.format.channelCount) {
                guard let src = source.floatChannelData?[c], let dst = buf.floatChannelData?[c] else { continue }
                for j in 0..<len {
                    var g: Float = 1
                    if j < fade { g = Float(j) / Float(fade) } else if j >= len - fade { g = Float(len - j) / Float(fade) }
                    dst[j] = src[a + j] * g
                }
            }
            return buf
        }
    }

    func slice(_ i: Int) -> AVAudioPCMBuffer? { slices.indices.contains(i) ? slices[i] : nil }
}

/// The slice sampler's audio: 16 voices (player + varispeed) into the main mixer. Triggered from
/// the CoreMIDI thread (SMC-PAD pads) or the UI; one kit per controller model.
final class SlicePlayer: @unchecked Sendable {
    let engine = AVAudioEngine()
    let format: AVAudioFormat
    private var voices: [(player: AVAudioPlayerNode, speed: AVAudioUnitVarispeed)] = []
    private var voicePad: [Int?]
    private var nextVoice = 0
    private let lock = NSLock()
    private var kits: [ControllerModel: LoadedKit] = [:]
    /// Called on any thread when a pad plays (for the on-screen pads).
    var onTrigger: (@Sendable (ControllerModel, Int) -> Void)?

    init(voiceCount: Int = 16) {
        format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        voicePad = Array(repeating: nil, count: voiceCount)
        for _ in 0..<voiceCount {
            let p = AVAudioPlayerNode(), v = AVAudioUnitVarispeed()
            engine.attach(p); engine.attach(v)
            engine.connect(p, to: v, format: format)
            engine.connect(v, to: engine.mainMixerNode, format: format)
            voices.append((p, v))
        }
    }

    static func configureSession(recording: Bool = false) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(recording ? .playAndRecord : .playback, mode: .default,
                           options: recording ? [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP] : [.mixWithOthers])
        try? s.setPreferredIOBufferDuration(0.005)
        try? s.setActive(true)
    }

    func start() {
        guard !engine.isRunning else { return }
        Self.configureSession()
        engine.prepare()
        try? engine.start()
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
        guard let buf = kit.slice(pad) else { return }
        let ps = kit.settings.pads.indices.contains(pad) ? kit.settings.pads[pad] : PadSettings()
        if !engine.isRunning { start() }
        lock.lock()
        if velocity == 0 {
            if ps.mode == .gate { for (i, p) in voicePad.enumerated() where p == pad { voices[i].player.stop(); voicePad[i] = nil } }
            lock.unlock()
            return
        }
        // choke: stop every voice playing a choking pad (and always this pad's own last voice)
        for (i, p) in voicePad.enumerated() {
            guard let p else { continue }
            let other = kit.settings.pads.indices.contains(p) ? kit.settings.pads[p] : PadSettings()
            if p == pad || (ps.choke && other.choke) { voices[i].player.stop(); voicePad[i] = nil }
        }
        let i = voicePad.firstIndex(where: { $0 == nil }) ?? nextVoice
        nextVoice = (i + 1) % voices.count
        voicePad[i] = pad
        lock.unlock()
        let v = voices[i]
        v.player.stop()
        v.player.volume = ps.volume * (0.25 + 0.75 * Float(velocity) / 127)
        v.speed.rate = Float(pow(2, Double(ps.pitch) / 12))
        v.player.scheduleBuffer(buf, at: nil, options: .interrupts) { [weak self] in
            self?.lock.withLock { if self?.voicePad[i] == pad { self?.voicePad[i] = nil } }
        }
        v.player.play()
    }

    func stopAll() {
        lock.withLock { for i in voicePad.indices { voicePad[i] = nil } }
        voices.forEach { $0.player.stop() }
    }
}
