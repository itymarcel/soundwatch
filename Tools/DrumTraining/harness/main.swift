import Foundation

let env = ProcessInfo.processInfo.environment
let DATA = env["DRUMDATA"] ?? "data"
let MDB = DATA + "/mdb"
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "new"
let tol = 0.05

struct Track { let name: String; let wav: String; let ann: [(Double, String)] }
func loadTracks() -> [Track] {
    let files = try! FileManager.default.contentsOfDirectory(atPath: MDB + "/mix").filter { $0.hasSuffix(".wav") }.sorted()
    let only = env["TRACKS"].map { Set($0.split(separator: ",").map(String.init)) }
    return files.compactMap { f in
        let base = f.replacingOccurrences(of: "_MIX.wav", with: "")
        if let o = only, !o.contains(where: { base.contains($0) }) { return nil }
        let txt = (try? String(contentsOfFile: MDB + "/ann/\(base)_class.txt", encoding: .utf8)) ?? ""
        let ann = txt.split(separator: "\n").compactMap { l -> (Double, String)? in
            let p = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard p.count >= 2, let t = Double(p[0]) else { return nil }
            return (t, String(p[1]))
        }
        return Track(name: base, wav: MDB + "/mix/" + f, ann: ann)
    }
}
// generic: TRACKFILE=path.wav ANNFILE=path.txt
func tracks() -> [Track] {
    if let w = env["WAVS"] {   // comma list of wav paths, annotation = same path with .txt
        return w.split(separator: ",").map { p in
            let wav = String(p), txt = (try? String(contentsOfFile: wav.replacingOccurrences(of: ".wav", with: ".txt"), encoding: .utf8)) ?? ""
            let ann = txt.split(separator: "\n").compactMap { l -> (Double, String)? in
                let q = l.split(whereSeparator: { $0 == " " || $0 == "\t" }); guard q.count >= 2, let t = Double(q[0]) else { return nil }; return (t, String(q[1])) }
            return Track(name: (wav as NSString).lastPathComponent, wav: wav, ann: ann)
        }
    }
    return loadTracks()
}

let targets: [Set<String>] = [["KD"], ["SD"], ["HH", "CY"]]
let neutral: [Set<String>] = [["TT"], ["TT"], []]
let names = ["kick", "snare", "hats"]

struct Score { var tp = 0, fp = 0, fn = 0; var offs: [Double] = [] }
func score(_ det: [Double], _ ref: [Double], _ neu: [Double]) -> Score {
    var s = Score()
    var used = [Bool](repeating: false, count: ref.count)
    var j0 = 0
    for d in det.sorted() {
        while j0 < ref.count && ref[j0] < d - tol { j0 += 1 }
        var best = -1, bd = tol + 1
        var j = j0
        while j < ref.count && ref[j] <= d + tol { if !used[j] && abs(ref[j] - d) < bd { bd = abs(ref[j] - d); best = j }; j += 1 }
        if best >= 0 { used[best] = true; s.tp += 1; s.offs.append(d - ref[best]) }
        else if neu.contains(where: { abs($0 - d) <= tol }) { }
        else { s.fp += 1 }
    }
    s.fn = used.filter { !$0 }.count
    return s
}

let level = Int(env["LEVEL"] ?? "2")!
let strengthLock = NSLock()
var allStrengths: [[Float]] = [[], [], []]
func runNew(_ w: Wav) -> [[Double]] {
    var strengths: [[Float]] = [[], [], []]
    defer { strengthLock.lock(); for d in 0..<3 { allStrengths[d] += strengths[d] }; strengthLock.unlock() }
    let det = DrumDetector(sampleRate: w.sr)
    var out: [[Double]] = [[], [], []]
    w.mono.withUnsafeBufferPointer { p in
        var i = 0
        while i < p.count {
            let n = min(512, p.count - i)
            for h in det.push(p.baseAddress! + i, count: n) where h.levels & (1 << level) != 0 { out[h.drum].append(Double(h.sample) / w.sr); strengths[h.drum].append(h.strength) }
            i += n
        }
    }
    return out
}

func runOld(_ w: Wav) -> [[Double]] {
    let fps = Double(env["FPS"] ?? "120")!
    var s = VizSettings()
    if let g = env["GAIN"] { s.gain = Double(g)! }
    if let f = env["FLOOR"] { s.floorDB = Double(f)! }
    if let t = env["TILT"] { s.tilt = Double(t)! }
    let fft = Int(env["FFT"] ?? "8192")!
    let ring = AudioRing(); ring.sampleRate = w.sr
    let an = Analyzer(ring: ring)
    an.lowLatency = true
    an.beatLock = env["LOCK"] != nil
    var lastBeat = 0
    var on = OldOnsets()
    var out: [[Double]] = [[], [], []]
    var pos = 0, acc = 0.0, t = 0.0
    w.mono.withUnsafeBufferPointer { p in
        while pos < p.count {
            acc += w.sr / fps
            let n = min(Int(acc), p.count - pos); acc -= Double(n)
            ring.writeFrames(l: p.baseAddress! + pos, r: p.baseAddress! + pos, frames: n)
            pos += n; t += 1 / fps
            an.update(now: t, fftSize: fft)
            if env["BEATMODE"] != nil {
                if an.beatCount > lastBeat { out[0].append(Double(an.readEnd) / w.sr); lastBeat = an.beatCount }
            } else {
                for h in on.step(analyzer: an, s: s, dt: 1 / fps) { out[h.band].append(Double(an.readEnd) / w.sr) }
            }
        }
    }
    return out
}

func applyParams() {
    guard let j = env["P"], let d = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any] else { return }
    for dr in 0..<3 { if let v = d["floor\(dr)"] as? Double { DrumDetector.baseThreshold[dr] = Float(v) } }
    if let v = d["floor"] as? Double { for i in 0..<3 { DrumDetector.baseThreshold[i] = Float(v) } }
}

applyParams()
if let p = env["NET"] { DrumDetector.nets = p.split(separator: ",").map { loadNet(String($0)) } }
if mode == "netcv" { runNetCV(tracks()); exit(0) }
if mode == "mix" { runMix(); exit(0) }
if mode == "sets" { runSets(); exit(0) }
let ts = tracks()
let fpLock = NSLock()
var fpInfo = [[String: Int]](repeating: [:], count: 3)
var results = [[Score]](repeating: [Score(), Score(), Score()], count: ts.count)
DispatchQueue.concurrentPerform(iterations: ts.count) { i in
    let w = readWav(ts[i].wav)
    let det = mode == "old" ? runOld(w) : runNew(w)
    var r: [Score] = []
    for d in 0..<3 {
        let ref = ts[i].ann.filter { targets[d].contains($0.1) }.map(\.0).sorted()
        let neu = ts[i].ann.filter { neutral[d].contains($0.1) }.map(\.0)
        r.append(score(det[d], ref, neu))
        if env["FPINFO"] != nil {
            // false positives: what other annotation is nearest (within 50 ms)?
            var c: [String: Int] = [:]
            var used = Set<Int>()
            for x in det[d].sorted() {
                if let j = ref.indices.first(where: { !used.contains($0) && abs(ref[$0] - x) <= tol }) { used.insert(j); continue }
                let near = ts[i].ann.filter { abs($0.0 - x) <= tol }.min { abs($0.0 - x) < abs($1.0 - x) }
                let key = near.map { $0.1 } ?? (ref.contains { x - $0 > tol && x - $0 < 0.25 } ? "after-own" : "none")
                c[key, default: 0] += 1
            }
            fpLock.lock(); for (k, v) in c { fpInfo[d][k, default: 0] += v }; fpLock.unlock()
        }
    }
    results[i] = r
}
func f(_ s: Score) -> (Double, Double, Double) {
    let p = Double(s.tp) / Double(max(1, s.tp + s.fp)), r = Double(s.tp) / Double(max(1, s.tp + s.fn))
    return (p, r, p + r > 0 ? 2 * p * r / (p + r) : 0)
}
let verbose = env["V"] != nil
if verbose {
    for (i, t) in ts.enumerated() {
        let line = (0..<3).map { d -> String in let (p, r, ff) = f(results[i][d]); return String(format: "%@ P%.2f R%.2f F%.2f (%d/%d/%d)", names[d], p, r, ff, results[i][d].tp, results[i][d].fp, results[i][d].fn) }.joined(separator: " | ")
        print(t.name.replacingOccurrences(of: "MusicDelta_", with: "").padding(toLength: 14, withPad: " ", startingAt: 0), line)
    }
}
var meanF = 0.0
for d in 0..<3 {
    var tot = Score()
    var trackF = 0.0
    for i in 0..<ts.count { let s = results[i][d]; tot.tp += s.tp; tot.fp += s.fp; tot.fn += s.fn; tot.offs += s.offs; trackF += f(s).2 }
    let (p, r, ff) = f(tot)
    let offs = tot.offs.sorted()
    let med = offs.isEmpty ? 0 : offs[offs.count / 2] * 1000
    meanF += ff / 3
    print(String(format: "%-6@ P %.3f  R %.3f  F %.3f  (mean track F %.3f)  tp %d fp %d fn %d  offset median %+.1f ms", names[d], p, r, ff, trackF / Double(ts.count), tot.tp, tot.fp, tot.fn, med))
}
print(String(format: "meanF %.3f", meanF))
if env["STRENGTH"] != nil { for d in 0..<3 { let a = allStrengths[d].sorted(); if !a.isEmpty { print(names[d], "strength p10/50/90:", a[a.count/10], a[a.count/2], a[a.count*9/10]) } } }
if env["FPINFO"] != nil { for d in 0..<3 { print(names[d], "fp near:", fpInfo[d].sorted { $0.value > $1.value }) } }
