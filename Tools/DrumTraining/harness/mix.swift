import Foundation
func wavTracks(_ dir: String) -> [Track] {
    let fs = (try! FileManager.default.contentsOfDirectory(atPath: dir)).filter { $0.hasSuffix(".wav") }.sorted()
    return fs.map { f in
        let wav = dir + "/" + f
        let txt = (try? String(contentsOfFile: wav.replacingOccurrences(of: ".wav", with: ".txt"), encoding: .utf8)) ?? ""
        let ann = txt.split(separator: "\n").compactMap { l -> (Double, String)? in
            let q = l.split(whereSeparator: { $0 == " " || $0 == "\t" }); guard q.count >= 2, let t = Double(q[0]) else { return nil }; return (t, String(q[1])) }
        return Track(name: f, wav: wav, ann: ann)
    }
}
func evalSet(_ ts: [Track], label: String) -> Double {
    var res = [[Score]](repeating: [], count: ts.count)
    DispatchQueue.concurrentPerform(iterations: ts.count) { i in
        let det = runNew(readWav(ts[i].wav))
        res[i] = (0..<3).map { d in score(det[d], ts[i].ann.filter { targets[d].contains($0.1) }.map(\.0).sorted(), ts[i].ann.filter { neutral[d].contains($0.1) }.map(\.0)) }
    }
    let tot = (0..<3).map { d in res.reduce(Score()) { var a = $0; a.tp += $1[d].tp; a.fp += $1[d].fp; a.fn += $1[d].fn; a.offs += $1[d].offs; return a } }
    return report(tot, label)
}
func feats(_ ts: [Track]) -> [TrackFeat] {
    var f = [TrackFeat?](repeating: nil, count: ts.count)
    DispatchQueue.concurrentPerform(iterations: ts.count) { i in f[i] = features(ts[i]) }
    return f.map { $0! }
}
let S = DATA
func testSets() -> [(String, [Track])] {
    let idmt = wavTracks(S + "/idmt/t")
    return [("IDMT real ", idmt.filter { $0.name.hasPrefix("Real") }), ("IDMT techno", idmt.filter { $0.name.hasPrefix("Techno") }),
            ("IDMT wave ", idmt.filter { $0.name.hasPrefix("Wave") }), ("SYN hand  ", wavTracks(S + "/syn")), ("SYN rtest ", wavTracks(S + "/rtest"))]
}
func runMix() {
    let mdb = loadTracks()
    let extraN = Int(env["NEXTRA"] ?? "60")!
    let extra = Array(wavTracks(S + "/rtrain").prefix(extraN))
    let fm = feats(mdb), fx = feats(extra)
    let H = Int(env["HID"] ?? "32")!, ep = Int(env["EPOCHS"] ?? "10")!
    let thr = Float(env["THR"] ?? "0.7")!
    if env["THR"] != nil { for d in 0..<3 { DrumDetector.baseThreshold[d] = thr } }
    if env["NOCV"] == nil {
        let folds = [mdb.indices.filter { $0 % 2 == 0 }, mdb.indices.filter { $0 % 2 == 1 }]
        var total = [Score](repeating: Score(), count: 3)
        for (fi, test) in folds.enumerated() {
            let net = trainNet(folds[1 - fi].map { fm[$0] } + fx, hidden: H, epochs: ep)
            DrumDetector.nets = [net]
            var res = [[Score]](repeating: [], count: test.count)
            DispatchQueue.concurrentPerform(iterations: test.count) { j in
                let t = mdb[test[j]]; let det = runNew(readWav(t.wav))
                res[j] = (0..<3).map { d in score(det[d], t.ann.filter { targets[d].contains($0.1) }.map(\.0).sorted(), t.ann.filter { neutral[d].contains($0.1) }.map(\.0)) }
            }
            for r in res { for d in 0..<3 { total[d].tp += r[d].tp; total[d].fp += r[d].fp; total[d].fn += r[d].fn; total[d].offs += r[d].offs } }
        }
        _ = report(total, "MDB CV     ")
    }
    let net = trainNet(fm + fx, hidden: H, epochs: ep)
    DrumDetector.nets = [net]
    var blob = Data()
    for a in [net.mean, net.invStd, net.w1, net.b1, net.w2, net.b2] { a.withUnsafeBufferPointer { blob.append(Data(buffer: $0)) } }
    try! "\(net.nIn) \(net.nHid)\n\(blob.base64EncodedString())\n".write(toFile: env["OUT"] ?? "netmix.txt", atomically: true, encoding: .utf8)
    var s = 0.0
    for (name, ts) in testSets() { s += evalSet(ts, label: name) }
    print(String(format: "unseen-sets mean %.3f", s / 5))
}
func runSets() { var s = 0.0; for (name, ts) in testSets() { s += evalSet(ts, label: name) }; print(String(format: "unseen-sets mean %.3f", s / 5)) }
