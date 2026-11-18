// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

/// Previews of a piece for the audio import's review, as loops (the Swift twin of web/src/audio/preview.ts): the
/// original audio of its 4 bars, and what SLOOP will play from it (the notes and drums found, each part looping at
/// its own track length, in plain sounds: SLOOP plays them with the tracks' own sounds). Mono, 22050 Hz; the same 4
/// bars each, so they loop without a seam.
public enum SLOOPPreview {
    public static let sampleRate = 22050.0

    /// The original audio of a piece's 4 bars, from the song's mono samples.
    public static func original(_ samples: [Float], _ sec: SLOOPAudioSection) -> [Float] {
        let a = Int((sec.start * sampleRate).rounded()), n = frames(sec)
        var out = [Float](repeating: 0, count: n)
        if a < samples.count { for i in 0..<min(n, samples.count - a) { out[i] = samples[a + i] } }
        return normalised(out)
    }

    /// What SLOOP will play from a piece: the `parts` imported, each repeating every `lengths[part]` steps. A note still
    /// sounding at the end wraps round to the start, as it would looping.
    public static func sloop(_ sec: SLOOPAudioSection, parts: Set<SLOOPImportPlan.Part>) -> [Float] {
        let q = 15 / sec.bpm, n = frames(sec)
        var out = [Float](repeating: 0, count: n)
        func add(_ st: Int, _ x: [Float]) { let i0 = Int((Double(st) * q * sampleRate).rounded()); for k in x.indices { out[(i0 + k) % n] += x[k] } }
        func every(_ part: SLOOPImportPlan.Part, _ st: Int, _ f: (Int) -> Void) {
            let len = max(1, min(64, sec.lengths?[part.rawValue] ?? 64))
            if st < len { for s in stride(from: st, to: 64, by: len) { f(s) } }
        }
        var rng = Noise()
        if parts.contains(.drums) { for h in sec.drums { every(.drums, h.step) { s in for l in h.lanes { add(s, drum(l, &rng)) } } } }
        if parts.contains(.bass) { for b in sec.bass { every(.bass, b.step) { add($0, tone(b.pitch, Double(b.len) * q, harmonics: 5, decay: 1.2, gain: 0.55)) } } }
        if parts.contains(.keys) { for c in sec.keys { every(.keys, c.step) { s in for p in c.pitches { add(s, tone(p, Double(c.len) * q, harmonics: 3, decay: 0.8, gain: 0.14)) } } } }
        if parts.contains(.lead) { for l in sec.lead { every(.lead, l.step) { add($0, tone(l.pitch, Double(l.len) * q, harmonics: 7, decay: 1.5, gain: 0.3, hollow: true)) } } }
        return normalised(out)
    }

    /// Both: the original under what SLOOP will play.
    public static func both(_ original: [Float], _ sloop: [Float]) -> [Float] {
        normalised(original.indices.map { 0.55 * original[$0] + 0.55 * ($0 < sloop.count ? sloop[$0] : 0) })
    }

    static func frames(_ sec: SLOOPAudioSection) -> Int { max(1, Int((64 * (15 / sec.bpm) * sampleRate).rounded())) }

    /// A note: `harmonics` partials (odd only when `hollow`, a reedier lead), a 5 ms attack, a decay, a 10 ms release.
    static func tone(_ pitch: Int, _ secs: Double, harmonics: Int, decay: Double, gain: Double, hollow: Bool = false) -> [Float] {
        let f = 440 * pow(2, Double(pitch - 69) / 12), n = max(1, Int((secs * 0.95 * sampleRate).rounded())), r = min(n, Int(0.01 * sampleRate))
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            var v = 0.0
            for h in stride(from: 1, through: harmonics, by: hollow ? 2 : 1) where f * Double(h) < sampleRate / 2 { v += sin(2 * .pi * f * Double(h) * t) / Double(h) }
            return Float(gain * v * min(1, t / 0.005) * exp(-t * decay) * (i >= n - r ? Double(n - i) / Double(r) : 1))
        }
    }

    /// SLOOP's drum lanes as plain sounds: 0 kick, 2 snare, 4 closed hat, 5 open hat (others: a click).
    static func drum(_ lane: Int, _ rng: inout Noise) -> [Float] {
        let len = [0: 0.3, 2: 0.2, 4: 0.05, 5: 0.3][lane] ?? 0.03, n = Int(len * sampleRate)
        var x = [Float](repeating: 0, count: n), ph = 0.0, prev = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate, w = rng.next()
            switch lane {
            case 0: ph += 2 * .pi * (50 + 100 * exp(-t * 30)) / sampleRate; x[i] = Float(sin(ph) * exp(-t * 10))
            case 2: x[i] = Float((0.5 * w * exp(-t * 20) + 0.4 * sin(2 * .pi * 190 * t) * exp(-t * 25)) * 0.8)
            default: x[i] = Float(0.3 * (w - prev) * exp(-t * (lane == 5 ? 8 : 70))); prev = w     // (a difference: bright noise)
            }
        }
        return x
    }

    /// The same noise every time (a linear congruential generator): previews don't change between plays.
    struct Noise {
        var s: UInt32 = 7
        mutating func next() -> Double { s = s &* 1664525 &+ 1013904223; return Double(s) / 4294967296 * 2 - 1 }
    }

    static func normalised(_ x: [Float]) -> [Float] {
        let m = x.reduce(0) { max($0, abs($1)) }
        return m > 0 ? x.map { $0 * 0.85 / m } : x
    }
}
