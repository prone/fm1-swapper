import XCTest
@testable import FM1Kit

final class SliceTests: XCTestCase {
    /// 16 decaying noise hits at known times, with quiet between.
    func hits(at times: [Double], sr: Double = 44100, length: Double) -> [Float] {
        var s = [Float](repeating: 0, count: Int(length * sr))
        var g = SystemRandomNumberGenerator()
        for (k, t) in times.enumerated() {
            let start = Int(t * sr)
            let amp = Float(0.4 + 0.5 * Double(k % 3) / 2)
            for i in 0..<Int(0.12 * sr) where start + i < s.count {
                s[start + i] += amp * Float.random(in: -1...1, using: &g) * exp(-Float(i) / Float(0.03 * sr))
            }
        }
        for i in s.indices { s[i] += Float.random(in: -0.002...0.002, using: &g) }
        return s
    }

    func testFindsHits() {
        let times: [Double] = (0..<16).map { (k: Int) -> Double in
            let jitter: Double = k % 2 == 0 ? 0 : 0.03
            return 0.05 + Double(k) * 0.27 + jitter
        }
        let starts = SliceDetector.transients(hits(at: times, length: 4.6), sampleRate: 44100)
        XCTAssertEqual(starts.count, 16)
        XCTAssertEqual(starts.first, 0)
        // every hit after the first should have a cut within 20 ms before or at it
        for t in times.dropFirst() {
            let f = Int(t * 44100)
            XCTAssertTrue(starts.contains { abs($0 - f) < 900 }, "no cut near \(t)s: \(starts)")
        }
        XCTAssertEqual(starts, starts.sorted())
    }

    func testFewHitsFallsBackToSplitting() {
        let starts = SliceDetector.transients(hits(at: [0.1, 1.0], length: 2), sampleRate: 44100)
        XCTAssertEqual(starts.count, 16)
        XCTAssertEqual(Set(starts).count, 16)
    }

    func testEqualAndPeaks() {
        XCTAssertEqual(SliceDetector.equal(frames: 1600), (0..<16).map { $0 * 100 })
        let p = SliceDetector.peaks([0, 1, -1, 0.5], buckets: 2)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].max, 1); XCTAssertEqual(p[1].min, -1)
    }
}
