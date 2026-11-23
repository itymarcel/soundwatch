import Foundation
struct OldOnsets {
    private var prev: [Float] = []
    private var avg = [Float](repeating: 0.02, count: 3)
    private var since = [Double](repeating: 1, count: 3)
    mutating func step(analyzer: Analyzer, s: VizSettings, dt: Double) -> [(band: Int, strength: Float)] {
        var s2 = s
        s2.minFreq = 30; s2.maxFreq = 16_000
        let b = analyzer.bands(count: 36, s: s2)
        for g in 0..<3 { since[g] += dt }
        guard prev.count == b.count else { prev = b; return [] }
        var out: [(band: Int, strength: Float)] = []
        for (g, range) in [0..<9, 9..<23, 23..<36].enumerated() {
            var flux: Float = 0
            for i in range { flux += max(0, b[i] - prev[i]) }
            flux /= Float(range.count)
            if flux > avg[g] * 2.2 + 0.015, since[g] > 0.08 {
                since[g] = 0
                out.append((g, min(1, flux * 5)))
            }
            avg[g] += (flux - avg[g]) * Float(1 - exp(-dt / 0.4))
        }
        prev = b
        return out
    }
}
