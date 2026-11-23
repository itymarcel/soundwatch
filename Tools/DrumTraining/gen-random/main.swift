import Foundation
func R(_ a: Double, _ b: Double) -> Double { a + (b - a) * rnd() }
func pick<T>(_ a: [T]) -> T { a[Int(rnd() * Double(a.count)) % a.count] }
func drive(_ s: [Double], _ k: Double) -> [Double] { k < 0.05 ? s : s.map { tanh($0 * (1 + 4 * k)) / tanh(1 + 4 * k) } }
func hat808(_ dec: Double, _ tune: Double) -> [Double] {
    let fs = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].map { $0 * tune }
    let n = Int(max(0.08, dec * 5) * sr); var hp1 = 0.0, x1 = 0.0
    var ph = [Double](repeating: 0, count: 6)
    return (0..<n).map { i in let t = Double(i) / sr
        var s = 0.0; for k in 0..<6 { ph[k] = (ph[k] + fs[k] / sr).truncatingRemainder(dividingBy: 1); s += ph[k] < 0.5 ? 1 : -1 }
        s = s / 6 + 0.3 * noise()
        hp1 = 0.85 * (hp1 + s - x1); x1 = s
        return hp1 * exp(-t / dec) * 0.7 }
}
func rim() -> [Double] { (0..<Int(0.08 * sr)).map { i in let t = Double(i) / sr; return (sin(2 * .pi * 1700 * t) * 0.6 + noise() * 0.5) * exp(-t / 0.008) } }
func reverb(_ x: [Double], _ amt: Double) -> [Double] {
    guard amt > 0.02 else { return x }
    var y = x + [Double](repeating: 0, count: Int(0.6 * sr))
    for (d, gk) in [(0.0297, 0.77), (0.0371, 0.74), (0.0411, 0.72), (0.0437, 0.7)] {
        let D = Int(d * sr); var buf = [Double](repeating: 0, count: y.count)
        for i in 0..<y.count { let v = (i < x.count ? x[i] : 0) + (i >= D ? buf[i - D] * gk : 0); buf[i] = v; y[i] += v * amt * 0.25 }
    }
    return y
}
func arp(_ f: Double, _ len: Double) -> [Double] {
    let n = Int(len * sr); var ph = 0.0
    return (0..<n).map { i in let t = Double(i) / sr; ph = (ph + f / sr).truncatingRemainder(dividingBy: 1); return (ph < 0.5 ? 1.0 : -1.0) * exp(-t / 0.06) * 0.4 }
}
func riser(_ len: Double) -> [Double] {
    let n = Int(len * sr); var lp = 0.0
    return (0..<n).map { i in let t = Double(i) / sr; let a = 1 - exp(-2 * .pi * (300 + 8000 * t / len) / sr); lp += a * (noise() - lp); return lp * t / len }
}
func vox(_ f: Double, _ len: Double) -> [Double] {
    let n = Int(len * sr); var ph = 0.0, b1 = 0.0, b2 = 0.0
    return (0..<n).map { i in let t = Double(i) / sr
        ph = (ph + f * (1 + 0.012 * sin(2 * .pi * 5.5 * t)) / sr).truncatingRemainder(dividingBy: 1)
        let s = 2 * ph - 1; b1 += 0.08 * (s - b1); b2 += 0.3 * (s - b2)
        return (b1 + 0.5 * (b2 - b1)) * min(1, t / 0.05) * min(1, (len - t) / 0.05) }
}

func song(seed: UInt64, dur: Double) -> Mix {
    g = seed &* 2654435761 &+ 99
    var drums = Mix(dur), music = Mix(dur)
    let bpm = R(70, 178), b = 60 / bpm, swing = rnd() < 0.4 ? R(0, 0.25) : 0
    // kit
    let kp = (R(70, 200), R(35, 65), R(0.08, 0.6), R(0, 1.0), R(0, 1))
    let snareKind = Int(rnd() * 3)   // 0 snare, 1 clap, 2 rim
    let sp = (R(150, 290), R(0.05, 0.3), R(0.3, 1.5))
    let hatKind = Int(rnd() * 2), hdec = R(0.01, 0.06), htune = R(0.8, 1.4)
    let kickS = drive(kick(kp.0, kp.1, kp.2, click: kp.3), kp.4)
    let snS = reverb(snareKind == 0 ? snare(sp.0, sp.1, noiseAmt: sp.2) : snareKind == 1 ? clap() : rim(), rnd() < 0.5 ? R(0, 0.8) : 0)
    let hatC = hatKind == 0 ? hat(hdec) : hat808(hdec, htune)
    let hatO = hatKind == 0 ? hat(R(0.15, 0.5)) : hat808(R(0.15, 0.5), htune)
    let style = Int(rnd() * 4)       // 0 four-on-floor, 1 backbeat, 2 breakbeat, 3 half-time
    let hatRate = pick([2, 4, 4, 2, 3])
    let dv = { R(0.5, 1.0) }
    // music
    let bassKind = Int(rnd() * 4), root = R(36, 62)
    let musicLevel = R(0.15, 1.6), hasPad = rnd() < 0.6, hasStabs = rnd() < 0.6, hasArp = rnd() < 0.4, hasVox = rnd() < 0.35, pump = rnd() < 0.4
    var t = 0.3, beat = 0
    var kickTimes: [Double] = []
    while t < dur - 1.5 {
        let pos = beat % 4, bar = beat / 4
        func sw(_ x: Double) -> Double { let fr = x.truncatingRemainder(dividingBy: 1); return fr == 0.5 ? x + swing * 0.5 : x }
        var kicks: [Double] = [], snares: [Double] = []
        switch style {
        case 0: kicks = [0]; if pos % 2 == 1 { snares = [0] }
        case 1: if pos == 0 || pos == 2 { kicks = [0] }; if pos == 2 && rnd() < 0.4 { kicks.append(0.5) }; if pos % 2 == 1 { snares = [0] }; if rnd() < 0.15 { snares.append(0.75) }
        case 2: kicks = pos == 0 ? [0] : pos == 2 ? [0.5] : []; snares = pos == 1 ? [0] : pos == 3 ? [0] : []; if rnd() < 0.3 { snares.append(pick([0.25, 0.75])) }
        default: if pos == 0 { kicks = [0] }; if pos == 1 && rnd() < 0.5 { kicks.append(0.5) }; if pos == 2 { snares = [0] }
        }
        if rnd() < 0.05 { kicks = []; snares = [] }    // breaks
        for k in kicks { let tt = t + sw(k) * b; hit(&drums, tt, kickS, dv(), "KD"); kickTimes.append(tt) }
        for s in snares { hit(&drums, t + sw(s) * b, snS, s == 0 ? dv() : R(0.2, 0.5), "SD") }
        let roll = rnd() < 0.08
        let rate = roll ? 8 : hatRate
        for h in 0..<rate {
            let x = Double(h) / Double(rate)
            if hatRate == 2 && h == 0 && style == 0 && rnd() < 0.7 { continue }   // offbeat-only hats
            let open = !roll && rnd() < 0.08
            hit(&drums, t + sw(x) * b, open ? hatO : hatC, R(0.3, 0.9), "HH")
        }
        // bass
        let note = root * pow(2, pick([0, 0, 3, 5, 7, -2]) / 12)
        switch bassKind {
        case 0: if rnd() < 0.8 { music.add(t + b / 2, sawBass(note, b * 0.45, filt: R(0.2, 1)), 0.5) }
        case 1: if pos == 0 { music.add(t, sub808(note, b * R(1, 3.5), glideTo: rnd() < 0.3 ? note * 1.33 : nil), 0.6) }
        case 2: if pos == 0 { music.add(t, sawBass(note, b * 4 - 0.01, filt: 0.1), 0.35); music.add(t, sawBass(note * 1.007, b * 4 - 0.01, filt: 0.1), 0.35) }
        default: for e in 0..<2 where rnd() < 0.6 { music.add(t + Double(e) * b / 2, sawBass(note * pick([1, 2]), b * 0.4, filt: R(0.3, 1)), 0.45) }
        }
        let ch = [note * 4, note * 5.04, note * 5.99, note * 8].map { $0 * pick([1, 2]) }
        if hasStabs && rnd() < 0.35 { music.add(t + pick([0, 0.5, 0.75]) * b, chord(ch, R(0.1, 0.4), bright: R(0.3, 1.5)), 0.35) }
        if hasArp { for s in 0..<4 where rnd() < 0.7 { music.add(t + Double(s) * b / 4, arp(pick(ch) * 2, b / 4), 0.25) } }
        if rnd() < 0.08 { music.add(t, pluck(pick(ch)), 0.4) }
        if hasPad && pos == 0 && bar % 4 == 0 { music.add(t, pad(Array(ch.prefix(3)), b * 16), 0.25) }
        if hasVox && pos == 0 && rnd() < 0.5 { music.add(t + R(0, 0.5) * b, vox(pick(ch), b * R(0.5, 3)), 0.3) }
        if bar % 8 == 6 && pos == 0 && rnd() < 0.4 { music.add(t, riser(b * 8), 0.3) }
        t += b; beat += 1
    }
    if pump { for kt in kickTimes { let o = Int(kt * sr); for i in 0..<Int(0.25 * sr) where o + i < music.x.count { music.x[o + i] *= 0.3 + 0.7 * Double(i) / (0.25 * sr) } } }
    for i in music.x.indices { drums.x[i] += music.x[i] * musicLevel }
    // master tone: random low / high shelf-ish
    let lpA = 1 - exp(-2 * .pi * R(6000, 20000) / sr); var lp = 0.0
    for i in drums.x.indices { lp += lpA * (drums.x[i] - lp); drums.x[i] = lp }
    return drums
}
let outDir = CommandLine.arguments[1], n = Int(CommandLine.arguments[2])!, base = UInt64(CommandLine.arguments[3])!
for i in 0..<n {
    let m = song(seed: base + UInt64(i), dur: 30)
    write(m, outDir + "/r\(base + UInt64(i))", level: pow(10, -R(0, 40) / 20) * 0.8)
}
