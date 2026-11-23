import Foundation
// Synthetic electronic tracks with exact drum annotations (time + KD/SD/HH), plus confounders.
let sr = 48000.0
var g: UInt64 = 7
func rnd() -> Double { g = g &* 6364136223846793005 &+ 1442695040888963407; return Double(g >> 11) / Double(1 << 53) }
func noise() -> Double { rnd() * 2 - 1 }
struct Mix { var x: [Double]; var ann: [(Double, String)] = []
    init(_ sec: Double) { x = .init(repeating: 0, count: Int(sec * sr)) }
    mutating func add(_ t: Double, _ s: [Double], _ gain: Double) { let o = Int(t * sr); for i in s.indices where o + i < x.count && o + i >= 0 { x[o + i] += s[i] * gain } }
}
func kick(_ f0: Double = 130, _ f1: Double = 48, _ dec: Double = 0.35, click: Double = 0.3) -> [Double] {
    let n = Int(dec * 2.5 * sr); var ph = 0.0
    var hp = 0.0
    return (0..<n).map { i in let t = Double(i) / sr
        let f = f1 + (f0 - f1) * exp(-t / 0.03); ph += 2 * .pi * f / sr
        let c = noise() * click * exp(-t / 0.003); hp = c
        return sin(ph) * exp(-t / dec) + hp }
}
func snare(_ tone: Double = 185, _ dec: Double = 0.18, noiseAmt: Double = 0.8) -> [Double] {
    let n = Int(0.5 * sr); var lp = 0.0, prev = 0.0
    return (0..<n).map { i in let t = Double(i) / sr
        let nz = noise(); lp += 0.5 * (nz - lp); let hpn = nz - lp; prev = hpn   // brighter noise
        _ = prev
        return 0.6 * sin(2 * .pi * tone * t) * exp(-t / 0.06) + 0.4 * sin(2 * .pi * tone * 1.7 * t) * exp(-t / 0.04) + noiseAmt * hpn * exp(-t / dec) }
}
func clap() -> [Double] {
    let n = Int(0.4 * sr); var bp1 = 0.0, bp2 = 0.0
    return (0..<n).map { i in let t = Double(i) / sr
        var env = exp(-t / 0.12)
        for k in 0..<3 { let tk = t - Double(k) * 0.01; if tk >= 0 && tk < 0.01 { env = max(env, exp(-tk / 0.004)) } }
        let nz = noise(); bp1 += 0.3 * (nz - bp1); bp2 += 0.3 * (bp1 - bp2)
        return (nz - bp2) * 0.6 * env + bp1 * 0.2 * env }
}
func hat(_ dec: Double = 0.04) -> [Double] {
    let n = Int(max(0.1, dec * 5) * sr); var lp = 0.0
    return (0..<n).map { i in let t = Double(i) / sr
        let nz = noise(); lp += 0.7 * (nz - lp); var v = nz - lp
        v += 0.3 * sin(2 * .pi * 7400 * t) * sin(2 * .pi * 10300 * t)
        return v * exp(-t / dec) * 0.6 }
}
func sawBass(_ f: Double, _ len: Double, filt: Double = 1.0) -> [Double] {
    let n = Int(len * sr); var ph = 0.0, lp = 0.0, lp2 = 0.0
    return (0..<n).map { i in let t = Double(i) / sr
        ph = (ph + f / sr).truncatingRemainder(dividingBy: 1); let s = 2 * ph - 1
        let fc = 150 + 2500 * filt * exp(-t / 0.08); let a = 1 - exp(-2 * .pi * fc / sr)
        lp += a * (s - lp); lp2 += a * (lp - lp2)
        let env = min(1, t / 0.004) * (t > len - 0.02 ? (len - t) / 0.02 : 1)
        return lp2 * env }
}
func sub808(_ f: Double, _ len: Double, glideTo: Double? = nil) -> [Double] {
    let n = Int(len * sr); var ph = 0.0
    return (0..<n).map { i in let t = Double(i) / sr
        let ff = glideTo.map { f + ($0 - f) * min(1, t / 0.12) } ?? f
        ph += 2 * .pi * ff / sr
        let env = min(1, t / 0.003) * exp(-t / 1.2) * (t > len - 0.02 ? (len - t) / 0.02 : 1)
        return tanh(1.5 * sin(ph)) * env }
}
func chord(_ fs: [Double], _ len: Double, bright: Double = 1) -> [Double] {
    let n = Int(len * sr); var ph = [Double](repeating: 0, count: fs.count); var lp = 0.0
    return (0..<n).map { i in let t = Double(i) / sr
        var s = 0.0
        for k in fs.indices { ph[k] = (ph[k] + fs[k] * (1 + 0.003 * Double(k)) / sr).truncatingRemainder(dividingBy: 1); s += 2 * ph[k] - 1 }
        let fc = 400 + 4000 * bright * exp(-t / 0.15); lp += (1 - exp(-2 * .pi * fc / sr)) * (s - lp)
        return lp / Double(fs.count) * min(1, t / 0.003) * exp(-t / (len * 0.6)) }
}
func pluck(_ f: Double) -> [Double] {   // piano-ish
    let n = Int(1.2 * sr)
    return (0..<n).map { i in let t = Double(i) / sr
        var s = 0.0; for h in 1...6 { s += sin(2 * .pi * f * Double(h) * t) / Double(h) * exp(-t * Double(h) * 2.5) }
        return s * min(1, t / 0.002) }
}
func pad(_ fs: [Double], _ len: Double) -> [Double] {
    let n = Int(len * sr)
    return (0..<n).map { i in let t = Double(i) / sr
        var s = 0.0; for f in fs { s += sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * f * 2.003 * t) }
        return s / Double(fs.count) * min(1, t / 1.5) * min(1, (len - t) / 1.5) }
}
func write(_ m: Mix, _ name: String, level: Double) {
    let pk = m.x.map(abs).max()! + 1e-9
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let n = m.x.count
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16); d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
    for v in m.x { let s = Int16(max(-32767, min(32767, v / pk * level * 32767))); u16(UInt16(bitPattern: s)) }
    try! d.write(to: URL(fileURLWithPath: name + ".wav"))
    try! m.ann.sorted { $0.0 < $1.0 }.map { String(format: "%.5f %@", $0.0, $0.1) }.joined(separator: "\n").write(toFile: name + ".txt", atomically: true, encoding: .utf8)
}
let out = CommandLine.arguments[1]
let dur = 40.0
func hit(_ m: inout Mix, _ t: Double, _ s: [Double], _ gain: Double, _ c: String) { m.add(t, s, gain); m.ann.append((t, c)) }

// 1 house 124: four-on-the-floor, clap 2/4, offbeat hats, saw bass on offbeats, chord stabs, pad
do { var m = Mix(dur); let b = 60 / 124.0; let notes = [55.0, 55, 65.4, 49]
    var t = 0.5
    var k = 0
    while t < dur - 1 { let bar = k / 4
        hit(&m, t, kick(), 0.9, "KD")
        if k % 4 == 1 || k % 4 == 3 { hit(&m, t, clap(), 0.5, "SD") }
        hit(&m, t + b / 2, hat(0.03), 0.25 + 0.1 * rnd(), "HH")
        if k % 8 == 7 { hit(&m, t + b * 0.75, hat(0.2), 0.2, "HH") }
        m.add(t + b / 2, sawBass(notes[bar % 4], b * 0.45), 0.5)
        if rnd() < 0.3 { m.add(t + b * 0.75 + 0.002, chord([261.6, 329.6, 392, 523], 0.25), 0.35) }
        if k % 16 == 0 { m.add(t, pad([220, 277, 330], b * 16), 0.15) }
        t += b; k += 1 }
    write(m, out + "/house", level: 0.7); write(m, out + "/house_quiet", level: 0.022) }
// 2 hip-hop 90 with swing, boom-bap, piano chords, long 808
do { var m = Mix(dur); let b = 60 / 90.0
    var t = 0.5, k = 0
    while t < dur - 1 { let pos = k % 4
        if pos == 0 || (pos == 2 && rnd() < 0.5) { hit(&m, t, kick(90, 50, 0.25, click: 0.5), 0.9, "KD") }
        if pos == 0 && rnd() < 0.4 { hit(&m, t + b * 0.75, kick(90, 50, 0.25, click: 0.5), 0.7, "KD") }
        if pos == 1 || pos == 3 { hit(&m, t, snare(200, 0.15), 0.6, "SD") }
        for e in 0..<2 { hit(&m, t + Double(e) * b * 0.58, hat(0.025), 0.2 + 0.1 * rnd(), "HH") }
        if pos == 0 { m.add(t, sub808([41.2, 46.2, 55, 36.7][(k / 4) % 4], b * 3.5), 0.6) }
        if pos == 0 || pos == 2 { for f in [[220.0, 277, 330], [196.0, 247, 294]][(k / 8) % 2] { m.add(t + b * 0.5, pluck(f), 0.12) } }
        t += b; k += 1 }
    write(m, out + "/hiphop", level: 0.7); write(m, out + "/hiphop_quiet", level: 0.022) }
// 3 dnb 172: breakbeat, 16th hats, reese bass, riser every 16 bars
do { var m = Mix(dur); let b = 60 / 172.0
    let pat: [(Double, String)] = [(0, "KD"), (1, "SD"), (1.75, "SD"), (2.5, "KD"), (3, "SD")]
    var t = 0.5, bar = 0
    while t < dur - 2 {
        for (p, c) in pat { hit(&m, t + p * b, c == "KD" ? kick(150, 55, 0.18, click: 0.6) : snare(220, 0.12, noiseAmt: 1), c == "KD" ? 0.85 : (p == 1.75 ? 0.3 : 0.65), c) }
        for s in 0..<16 { hit(&m, t + Double(s) * b / 4, hat(0.02), s % 2 == 0 ? 0.25 : 0.12, "HH") }
        m.add(t, sawBass([43.6, 43.6, 49, 38.9][bar % 4], b * 4 - 0.01, filt: 0.15), 0.35)
        m.add(t, sawBass([43.6, 43.6, 49, 38.9][bar % 4] * 1.007, b * 4 - 0.01, filt: 0.15), 0.35)
        t += 4 * b; bar += 1 }
    write(m, out + "/dnb", level: 0.7); write(m, out + "/dnb_quiet", level: 0.022) }
// 4 trap 140 half-time: 808 kick + sliding subs, clap on 3, hat rolls (1/32 triplets)
do { var m = Mix(dur); let b = 60 / 140.0
    var t = 0.5, bar = 0
    while t < dur - 2 {
        let kicks = [0.0, 1.5, 2.75]
        for kp in kicks { hit(&m, t + kp * b, kick(110, 45, 0.5, click: 0.2), 0.8, "KD"); m.add(t + kp * b, sub808([43.6, 49, 38.9][Int(kp) % 3], b * 1.2, glideTo: rnd() < 0.3 ? 58 : nil), 0.5) }
        hit(&m, t + 2 * b, clap(), 0.6, "SD")
        var h = 0.0
        while h < 4 {
            let roll = bar % 2 == 1 && h >= 3
            hit(&m, t + h * b, hat(0.02), 0.22, "HH")
            h += roll ? 1.0 / 6 : 0.5
        }
        t += 4 * b; bar += 1 }
    write(m, out + "/trap", level: 0.7); write(m, out + "/trap_quiet", level: 0.022) }
// 5 no drums: plucks, stabs, saw bass notes, pad — every detection is a false positive
do { var m = Mix(dur); var t = 0.5
    m.add(0.2, pad([110, 165, 220, 277], dur - 0.5), 0.2)
    while t < dur - 1.5 {
        let r = rnd()
        if r < 0.35 { m.add(t, pluck([220, 247, 262, 294, 330, 392][Int(rnd() * 6)]), 0.3) }
        else if r < 0.6 { m.add(t, sawBass([41.2, 55, 61.7, 73.4][Int(rnd() * 4)], 0.3), 0.5) }
        else if r < 0.8 { m.add(t, chord([261.6, 329.6, 392, 494], 0.3), 0.4) }
        t += 60 / 124.0 / 2 }
    write(m, out + "/nodrums", level: 0.7) }
// 6 drums only (house kit)
do { var m = Mix(dur); let b = 60 / 124.0; var t = 0.5, k = 0
    while t < dur - 1 { hit(&m, t, kick(), 0.9, "KD"); if k % 2 == 1 { hit(&m, t, snare(), 0.6, "SD") }; hit(&m, t + b / 2, hat(0.03), 0.3, "HH"); t += b; k += 1 }
    write(m, out + "/drumsonly", level: 0.7) }
