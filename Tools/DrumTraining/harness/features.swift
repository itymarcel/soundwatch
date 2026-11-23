import Foundation
// Per-track frame features (band rises) + labels per drum: 1 positive, 0 negative, -1 ignored.
struct TrackFeat { var x: [[Float]]; var y: [[Int8]] }
func features(_ t: Track, posWin: (Double, Double) = (0, Double(env["POSWIN"] ?? "0.025")!), negGap: (Double, Double) = (0.02, 0.07)) -> TrackFeat {
    let w = readWav(t.wav)
    let det = DrumDetector(sampleRate: w.sr)
    var xs: [[Float]] = [], ts: [Double] = []
    w.mono.withUnsafeBufferPointer { p in
        var i = 0
        while i + 256 <= p.count { _ = det.push(p.baseAddress! + i, count: 256); xs.append(det.feat); ts.append(Double(det.sampleClock) / w.sr); i += 256 }
    }
    var ys: [[Int8]] = []
    for d in 0..<3 {
        let on = t.ann.filter { targets[d].contains($0.1) }.map(\.0).sorted()
        var y = [Int8](repeating: 0, count: xs.count)
        var j = 0
        for f in 0..<xs.count {
            let tf = ts[f]
            while j < on.count && on[j] < tf - 0.2 { j += 1 }
            var lab: Int8 = 0
            var k = j
            while k < on.count && on[k] <= tf + negGap.0 {
                let a = tf - on[k]                       // frame end after the onset by a
                if a >= posWin.0 && a <= posWin.1 { lab = 1; break }
                if a >= -negGap.0 && a <= negGap.1 { lab = -1 }
                k += 1
            }
            y[f] = lab
        }
        ys.append(y)
    }
    return TrackFeat(x: xs, y: ys)
}

