// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import CoreML
import Foundation

/// Basic Pitch's model (Spotify, Apache-2.0; App/BasicPitch, the Core ML version of the model the web app runs) on
/// the iPhone's or iPad's Neural Engine / GPU, for the audio import. It runs the model the way Basic Pitch does
/// (basic_pitch/inference.py): 2 s windows overlapping by 30 frames, half the overlap cut from each side, the rows
/// joined and trimmed to the audio's length. The notes are then made from its output by Basic Pitch's own code in
/// the web view (web/src/audio/input.ts notesFromOutput), so both apps make them the same way.
enum BasicPitchCoreML {
    static let windowSamples = 43_844, fftHop = 256, overlapFrames = 30, fps = 86, sampleRate = 22_050

    /// The model's output for mono 22050 Hz float samples, as pitch.bin: Int32 frame count, then note (n x 88), onset
    /// (n x 88), contour (n x 264), Float32.
    static func output(samples: Data) throws -> Data {
        guard let url = Bundle.main.url(forResource: "BasicPitch", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: config)
        let y = samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let pad = overlapFrames * fftHop / 2, hop = windowSamples - overlapFrames * fftHop, cut = overlapFrames / 2
        let padded = [Float](repeating: 0, count: pad) + y
        let input = try MLMultiArray(shape: [1, NSNumber(value: windowSamples), 1], dataType: .float32)
        var note: [Float] = [], onset: [Float] = [], contour: [Float] = []
        var i = 0
        while i < padded.count {
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
                for k in 0..<windowSamples { buf[k] = i + k < padded.count ? padded[i + k] : 0 }
            }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_2": input]))
            func rows(_ name: String, _ width: Int, into a: inout [Float]) {
                guard let m = out.featureValue(for: name)?.multiArrayValue else { return }
                let s1 = m.strides[1].intValue, s2 = m.strides[2].intValue, frames = m.shape[1].intValue
                for t in cut..<(frames - cut) { for k in 0..<width { a.append(m[t * s1 + k * s2].floatValue) } }
            }
            rows("Identity_1", 88, into: &note)
            rows("Identity_2", 88, into: &onset)
            rows("Identity", 264, into: &contour)
            i += hop
        }
        let n = min(y.count * fps / sampleRate, note.count / 88)
        var data = Data()
        withUnsafeBytes(of: Int32(n)) { data.append(contentsOf: $0) }
        for (a, w) in [(note, 88), (onset, 88), (contour, 264)] { a.prefix(n * w).withUnsafeBytes { data.append(contentsOf: $0) } }
        return data
    }
}
