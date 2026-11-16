import Foundation

/// Cuts a sample into pad slices: at detected transients (hits), or in equal parts.
/// Works on mono Float samples; returns slice start frames, ascending, first one 0.
public enum SliceDetector {
    public static func equal(frames: Int, count: Int = 16) -> [Int] {
        guard frames > 0, count > 0 else { return [0] }
        return (0..<count).map { $0 * frames / count }
    }

    /// Start frames of `count` slices at the strongest onsets; if the sample has fewer hits than
    /// slices, the longest slices are halved until there are `count`.
    public static func transients(_ samples: [Float], sampleRate: Double, count: Int = 16,
                                  minGap: Double = 0.06) -> [Int] {
        let n = samples.count
        guard n > 0, count > 1 else { return [0] }
        let hop = 256, win = 1024
        let hops = max(0, (n - win) / hop + 1)
        guard hops > 4 else { return equal(frames: n, count: count) }

        // log energy per hop, and its rise (the onset strength)
        var energy = [Float](repeating: 0, count: hops)
        for h in 0..<hops {
            var s: Float = 0
            let start = h * hop
            for i in start..<(start + win) { s += samples[i] * samples[i] }
            energy[h] = log10(s / Float(win) + 1e-9)
        }
        var onset = [Float](repeating: 0, count: hops)
        for h in 1..<hops { onset[h] = max(0, energy[h] - energy[h - 1]) }

        // local peaks above an adaptive threshold
        let mean = onset.reduce(0, +) / Float(hops)
        let sd = sqrt(onset.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(hops))
        let threshold = mean + 0.5 * sd
        var peaks: [(hop: Int, strength: Float)] = []
        for h in 1..<hops where onset[h] > threshold {
            let lo = max(0, h - 3), hi = min(hops - 1, h + 3)
            if onset[lo...hi].max() == onset[h] { peaks.append((h, onset[h])) }
        }

        // strongest first, keeping a minimum gap
        let gap = Int(minGap * sampleRate)
        var starts: [Int] = [0]
        for p in peaks.sorted(by: { $0.strength > $1.strength }) {
            // place the cut just before the rise: back up half a window
            let f = max(0, p.hop * hop + win / 2 - hop)
            if starts.allSatisfy({ abs($0 - f) >= gap }) { starts.append(f) }
            if starts.count == count { break }
        }
        starts.sort()
        // too few hits: halve the longest slice until there are enough
        while starts.count < count {
            var best = 0, len = 0
            for i in starts.indices {
                let end = i + 1 < starts.count ? starts[i + 1] : n
                if end - starts[i] > len { len = end - starts[i]; best = i }
            }
            guard len > 2 else { break }
            starts.insert(starts[best] + len / 2, at: best + 1)
        }
        return starts
    }

    /// Min/max per bucket, for drawing a waveform.
    public static func peaks(_ samples: [Float], buckets: Int) -> [(min: Float, max: Float)] {
        guard !samples.isEmpty, buckets > 0 else { return [] }
        let per = max(1, samples.count / buckets)
        return stride(from: 0, to: samples.count, by: per).map { s in
            let slice = samples[s..<min(s + per, samples.count)]
            return (slice.min() ?? 0, slice.max() ?? 0)
        }
    }
}
