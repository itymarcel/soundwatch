import Accelerate
import Foundation
// Trains DrumNet: masked, class-balanced BCE, Adam, minibatches.
func trainNet(_ data: [TrackFeat], hidden H: Int = 32, epochs: Int = 10, seed: UInt64 = UInt64(env["SEED"] ?? "1")!, posW: Float = Float(env["POSW"] ?? "0.25")!) -> DrumNet {
    var X: [[Float]] = [], Y: [[Int8]] = []
    for t in data { for f in t.x.indices where (0..<3).contains(where: { t.y[$0][f] >= 0 }) { X.append(t.x[f]); Y.append([t.y[0][f], t.y[1][f], t.y[2][f]]) } }
    let nIn = X[0].count, n = X.count
    var mean = [Float](repeating: 0, count: nIn), sd = mean
    for x in X { for i in 0..<nIn { mean[i] += x[i] } }
    for i in 0..<nIn { mean[i] /= Float(n) }
    for x in X { for i in 0..<nIn { let d = x[i] - mean[i]; sd[i] += d * d } }
    let inv = sd.map { 1 / max(0.05, ($0 / Float(n)).squareRoot()) }
    for r in 0..<n { for i in 0..<nIn { X[r][i] = (X[r][i] - mean[i]) * inv[i] } }
    // class weights: positives weigh posW of the total per output
    var pw = [Float](repeating: 1, count: 3), nw = pw
    for o in 0..<3 {
        let p = Float(Y.filter { $0[o] == 1 }.count), q = Float(Y.filter { $0[o] == 0 }.count)
        pw[o] = posW * (p + q) / p; nw[o] = (1 - posW) * (p + q) / q
    }
    var rng = SystemRandomNumberGenerator()
    _ = rng
    var g = seed
    func rnd() -> Float { g = g &* 6364136223846793005 &+ 1442695040888963407; return Float(g >> 40) / Float(1 << 24) }
    var w1 = (0..<H * nIn).map { _ in (rnd() * 2 - 1) * (2 / Float(nIn)).squareRoot() }
    var b1 = [Float](repeating: 0.01, count: H)
    var w2 = (0..<3 * H).map { _ in (rnd() * 2 - 1) * (1 / Float(H)).squareRoot() }
    var b2 = [Float](repeating: -1, count: 3)
    var params: [Float] { w1 + b1 + w2 + b2 }
    let P = w1.count + b1.count + w2.count + b2.count
    var m = [Float](repeating: 0, count: P), v = m
    let bs = 256, lr: Float = 1e-3, wd: Float = 1e-4
    var order = Array(0..<n)
    var step = 0
    for _ in 0..<epochs {
        for i in stride(from: n - 1, to: 0, by: -1) { let j = Int(rnd() * Float(i + 1)) % (i + 1); order.swapAt(i, j) }
        for start in stride(from: 0, to: n, by: bs) {
            let end = min(n, start + bs)
            let nT = 8
            var gs = [[Float]](repeating: [Float](repeating: 0, count: P), count: nT)
            DispatchQueue.concurrentPerform(iterations: nT) { t in
                var gl = [Float](repeating: 0, count: P)
                var h = [Float](repeating: 0, count: H), dh = h
                var r = start + t
                while r < end {
                    let x = X[order[r]], y = Y[order[r]]
                    x.withUnsafeBufferPointer { xp in w1.withUnsafeBufferPointer { wp in
                        for j in 0..<H { var z: Float = 0; vDSP_dotpr(wp.baseAddress! + j * nIn, 1, xp.baseAddress!, 1, &z, vDSP_Length(nIn)); h[j] = max(0, z + b1[j]) }
                    } }
                    for j in 0..<H { dh[j] = 0 }
                    let o2 = w1.count + b1.count
                    for o in 0..<3 where y[o] >= 0 {
                        var z = b2[o]; for j in 0..<H { z += w2[o * H + j] * h[j] }
                        let p = 1 / (1 + exp(-z))
                        let e = (p - Float(y[o])) * (y[o] == 1 ? pw[o] : nw[o])
                        for j in 0..<H { gl[o2 + o * H + j] += e * h[j]; dh[j] += e * w2[o * H + j] }
                        gl[o2 + 3 * H + o] += e
                    }
                    for j in 0..<H where h[j] > 0 && dh[j] != 0 {
                        let d = dh[j]
                        gl.withUnsafeMutableBufferPointer { gp in x.withUnsafeBufferPointer { xp in
                            var dd = d
                            vDSP_vsma(xp.baseAddress!, 1, &dd, gp.baseAddress! + j * nIn, 1, gp.baseAddress! + j * nIn, 1, vDSP_Length(nIn))
                        } }
                        gl[w1.count + j] += d
                    }
                    r += nT
                }
                gs[t] = gl
            }
            var gsum = gs[0]
            for t in 1..<nT { vDSP.add(gsum, gs[t], result: &gsum) }
            let scale = 1 / Float(end - start)
            step += 1
            let c1 = 1 - pow(0.9, Float(step)), c2 = 1 - pow(0.999, Float(step))
            var idx = 0
            func upd(_ a: inout [Float], decay: Bool) {
                for k in a.indices {
                    let gk = gsum[idx] * scale + (decay ? wd * a[k] : 0)
                    m[idx] = 0.9 * m[idx] + 0.1 * gk; v[idx] = 0.999 * v[idx] + 0.001 * gk * gk
                    a[k] -= lr * (m[idx] / c1) / ((v[idx] / c2).squareRoot() + 1e-8)
                    idx += 1
                }
            }
            upd(&w1, decay: true); upd(&b1, decay: false); upd(&w2, decay: true); upd(&b2, decay: false)
        }
    }
    return DrumNet(nIn: nIn, nHid: H, mean: mean, invStd: inv, w1: w1, b1: b1, w2: w2, b2: b2)
}

func evalNet(_ ts: [Track], _ net: DrumNet) -> [Score] {
    DrumDetector.nets = [net]
    var res = [[Score]](repeating: [], count: ts.count)
    DispatchQueue.concurrentPerform(iterations: ts.count) { i in
        let det = runNew(readWav(ts[i].wav))
        res[i] = (0..<3).map { d in score(det[d], ts[i].ann.filter { targets[d].contains($0.1) }.map(\.0).sorted(), ts[i].ann.filter { neutral[d].contains($0.1) }.map(\.0)) }
    }
    return (0..<3).map { d in res.reduce(Score()) { var a = $0; a.tp += $1[d].tp; a.fp += $1[d].fp; a.fn += $1[d].fn; a.offs += $1[d].offs; return a } }
}

func report(_ total: [Score], _ label: String) -> Double {
    var meanF = 0.0
    var parts: [String] = []
    for d in 0..<3 {
        let s = total[d]
        let p = Double(s.tp) / Double(max(1, s.tp + s.fp)), r = Double(s.tp) / Double(max(1, s.tp + s.fn))
        let ff = 2 * p * r / max(1e-9, p + r); meanF += ff / 3
        let o = s.offs.sorted()
        parts.append(String(format: "%@ P%.2f R%.2f F%.3f %+.0fms", names[d], p, r, ff, o.isEmpty ? 0 : o[o.count / 2] * 1000))
    }
    print(label, parts.joined(separator: " | "), String(format: "meanF %.3f", meanF))
    return meanF
}

func runNetCV(_ ts: [Track]) {
    var feats = [TrackFeat?](repeating: nil, count: ts.count)
    DispatchQueue.concurrentPerform(iterations: ts.count) { i in feats[i] = features(ts[i]) }
    let H = Int(env["HID"] ?? "32")!, ep = Int(env["EPOCHS"] ?? "10")!
    let folds = [ts.indices.filter { $0 % 2 == 0 }, ts.indices.filter { $0 % 2 == 1 }]
    let nets = folds.indices.map { fi in trainNet(folds[1 - fi].map { feats[$0]! }, hidden: H, epochs: ep) }
    let floors = (env["FLOORS"] ?? "0.5,0.6,0.7,0.8").split(separator: ",").map { Float($0)! }
    for fl in floors {
        for d in 0..<3 { DrumDetector.baseThreshold[d] = fl }
        var total = [Score](repeating: Score(), count: 3)
        for (fi, test) in folds.enumerated() {
            let s = evalNet(test.map { ts[$0] }, nets[fi])
            for d in 0..<3 { total[d].tp += s[d].tp; total[d].fp += s[d].fp; total[d].fn += s[d].fn; total[d].offs += s[d].offs }
        }
        _ = report(total, String(format: "floor %.2f", fl))
    }
    if env["FULL"] != nil {
        let net = trainNet(ts.indices.map { feats[$0]! }, hidden: H, epochs: ep)
        var blob = Data()
        for a in [net.mean, net.invStd, net.w1, net.b1, net.w2, net.b2] { a.withUnsafeBufferPointer { blob.append(Data(buffer: $0)) } }
        try! "\(net.nIn) \(net.nHid)\n\(blob.base64EncodedString())\n".write(toFile: "net.txt", atomically: true, encoding: .utf8)
        print("wrote net.txt")
    }
}
func loadNet(_ path: String) -> DrumNet {
    let lines = try! String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    let dims = lines[0].split(separator: " ").map { Int($0)! }
    return DrumNet(nIn: dims[0], nHid: dims[1], base64: String(lines[1]))!
}
