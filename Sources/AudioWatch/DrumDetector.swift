import Accelerate
import Foundation

/// Kick / snare / hats onsets, computed on the audio itself (every 256 samples, ~5 ms), not per picture frame.
///
/// 1. Front end (after SuperFlux, Böck & Widmer, DAFx 2013): energies in 6 bands per octave (30 Hz…16 kHz), each band
///    from the shortest FFT that still resolves it (2048 / 1024 / 512 samples). Per band the rise of the log energy over
///    the maximum of its neighbours a quarter window earlier (the max filter keeps vibrato and slides from reading as
///    onsets). The log has a floor 50 dB under the music's current level, so faint leakage into a silent band (a hat's
///    thump in the kick band) isn't a huge rise. Everything is relative: Gain, the volume and the mix level don't matter.
/// 2. A small network (3 × one hidden layer of 32, averaged) turns 5 feature groups per band (band above its own 1 s
///    average, the rises of this and the two previous frames, band level against the whole mix) into a kick / snare /
///    hats probability per frame. Band rules alone couldn't separate a bass pluck from a kick, or a snare from hats
///    (they fired on each other), which is what the network learns from annotated music.
/// 3. Peak picking per drum and sensitivity: fires when the probability crosses the level's threshold on a rise, then
///    waits a refractory time. Strength = loudness of the drum's own band (time-domain filters, the last ~15 ms) in dB
///    against its recent hits: as loud as usual = 0.65, +7 dB = 1, −13 dB = 0.
///
/// Training (offline harness, not in the repo; see CLAUDE.md): MDB Drums (Southall et al., ISMIR 2017; 23 MedleyDB mixes
/// with kick / snare / hi-hat annotations, CC BY-NC-SA 4.0) + 8 synthetic electronic tracks. F-measure (±50 ms) on music
/// it never saw (IDMT-SMT-Drums loops + synthetic electronic tracks): kick 0.90, snare 0.71, hats 0.89; the old per-frame
/// band flux on gain-scaled display bands: 0.64 / 0.37 / 0.75 (3552 false kicks vs 440; with Gain 0.2 it found 5 % of the
/// snares in real mixes). Cross-validated on MDB (trained on the other half): ≈ 0.71 / 0.60 / 0.77 vs 0.51 / 0.43 / 0.53.
final class DrumDetector {
    struct Hit {
        var drum: Int
        var strength: Float
        /// Sample clock (detector's own count of samples pushed) at detection.
        var sample: Int64
        /// Bit L set = it counts at sensitivity level L (0 = least sensitive … `levels` − 1).
        var levels: UInt8
    }

    static let hop = 256
    static let bandsPerOctave = 6.0
    static let fLo = 30.0, fHi = 16_000.0
    /// Sensitivity levels: probability thresholds per drum at the normal level, and the offset per level.
    static let levels = 5, normalLevel = 2
    static var baseThreshold: [Float] = [0.82, 0.7, 0.65]
    static let levelOffset: [Float] = [0.15, 0.08, 0, -0.1, -0.2]
    static let levelNames = ["Very low", "Low", "Normal", "High", "Very high"]
    static let refractory: [Double] = [0.09, 0.07, 0.05]

    let sampleRate: Double
    private(set) var bandHz: [Double] = []
    private var bandFFT: [Int] = []
    private var bandBins: [[(Int, Float)]] = []
    private var bandLag: [Int] = []

    private final class Spec {
        let n: Int
        let fft: vDSP.FFT<DSPSplitComplex>
        let window: [Float]
        var buf: [Float], re: [Float], im: [Float], pow: [Float]
        let norm: Float
        init(_ n: Int) {
            self.n = n
            fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)!
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
            buf = .init(repeating: 0, count: n); re = .init(repeating: 0, count: n / 2); im = re; pow = re
            norm = 1 / window.reduce(0) { $0 + $1 * $1 }
        }
        /// Power spectrum (density) of the newest n samples at `x` (oldest first).
        func run(_ x: UnsafePointer<Float>) {
            buf.withUnsafeMutableBufferPointer { b in vDSP_vmul(x, 1, window, 1, b.baseAddress!, 1, vDSP_Length(n)) }
            let h = n / 2
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(h)) }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &pow)
            } }
            vDSP.multiply(norm, pow, result: &pow)
        }
    }
    private let specs = [Spec(2048), Spec(1024), Spec(512)]
    /// Band centres below these use the longer FFTs.
    private static let split = (300.0, 2000.0)

    private var hist: [Float]
    private var pending = 0
    /// Samples pushed so far.
    private(set) var sampleClock: Int64 = 0

    private static let lagCap = 8
    private var maxHist: [[Float]]
    private var frame = 0
    private var flux: [Float] = [], logE: [Float] = [], slow: [Float] = [], bandE: [Float] = []
    private var refLevel: Float = 0
    /// Network input of the newest frame: [band above its 1 s average, rise t, rise t−1, rise t−2, band vs mix level].
    private(set) var feat: [Float] = []
    /// Energy floor under the level reference (power ratio; 1e-5 = −50 dB).
    private static let relFloor: Float = 1e-5

    /// The networks in use (averaged). Defaults to the trained model; the harness swaps them.
    static var nets: [DrumNet] = DrumModel.nets
    /// Probability per drum of the newest frame.
    private(set) var activation: [Float] = [0, 0, 0]
    private var useNets = true

    // strength: band energies per hop from two-pole filters (kick < 150 Hz, snare 1…8 kHz, hats > 6 kHz), in dB
    private var fl1: Float = 0, fl2: Float = 0, fs1: Float = 0, fs2: Float = 0, fsl1: Float = 0, fsl2: Float = 0
    private var fh1: Float = 0, fh2: Float = 0
    private var fAcc: [Float] = [0, 0, 0]
    private var bandDB: [[Float]] = [[-200, -200, -200], [-200, -200, -200], [-200, -200, -200]]   // last 3 hops per drum
    private var hitDB: [Float] = [.nan, .nan, .nan]
    private let cLow: Float, cMid: Float, cMidTop: Float, cHigh: Float
    private var prevAct: [Float] = [0, 0, 0]
    private var since = [[Double]](repeating: [Double](repeating: 9, count: DrumDetector.levels), count: 3)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        func coef(_ hz: Double) -> Float { Float(1 - exp(-2 * Double.pi * hz / sampleRate)) }
        cLow = coef(150); cMid = coef(1000); cMidTop = coef(8000); cHigh = coef(6000)
        hist = .init(repeating: 0, count: 2048)
        maxHist = []
        buildBands()
        let nb = bandHz.count
        maxHist = .init(repeating: .init(repeating: -23, count: nb), count: Self.lagCap)
        flux = .init(repeating: 0, count: nb); logE = flux; slow = flux; bandE = flux
        feat = .init(repeating: 0, count: 5 * nb)
        useNets = !Self.nets.isEmpty && Self.nets.allSatisfy { $0.nIn == feat.count }
    }

    private func buildBands() {
        let n = Int((log2(Self.fHi / Self.fLo) * Self.bandsPerOctave).rounded(.down))
        for k in 0..<n {
            let f0 = Self.fLo * pow(2, Double(k) / Self.bandsPerOctave)
            let f1 = Self.fLo * pow(2, Double(k + 1) / Self.bandsPerOctave)
            let fc = (f0 * f1).squareRoot()
            guard f1 < sampleRate / 2 else { break }
            let s = fc < Self.split.0 ? 0 : fc < Self.split.1 ? 1 : 2
            let binHz = sampleRate / Double(specs[s].n)
            // mean power density over [f0, f1]: bins weighted by their overlap with the band
            var bins: [(Int, Float)] = []
            let lo = max(1, Int((f0 / binHz - 0.5).rounded(.down))), hi = min(specs[s].n / 2 - 1, Int((f1 / binHz + 0.5).rounded(.up)))
            var total: Float = 0
            for i in lo...hi {
                let a = max(f0, (Double(i) - 0.5) * binHz), b = min(f1, (Double(i) + 0.5) * binHz)
                if b > a { bins.append((i, Float(b - a))); total += Float(b - a) }
            }
            if bins.isEmpty { bins = [(max(1, Int((fc / binHz).rounded())), 1)]; total = 1 }
            bins = bins.map { ($0.0, $0.1 / total) }
            bandHz.append(fc); bandFFT.append(s); bandBins.append(bins)
            bandLag.append(max(1, Int((Double(specs[s].n) / 4 / Double(Self.hop)).rounded())))
        }
    }

    /// Feeds mono samples; returns the hits found in them, oldest first.
    func push(_ x: UnsafePointer<Float>, count: Int) -> [Hit] {
        var out: [Hit] = []
        let cap = hist.count
        var i = 0
        while i < count {
            let take = min(count - i, Self.hop - pending)
            hist.withUnsafeMutableBufferPointer { h in
                let keep = cap - take
                memmove(h.baseAddress!, h.baseAddress! + take, keep * MemoryLayout<Float>.size)
                (h.baseAddress! + keep).update(from: x + i, count: take)
            }
            for j in i..<(i + take) {
                let v = x[j]
                fl1 += cLow * (v - fl1); fl2 += cLow * (fl1 - fl2)                  // kick: low-pass 150 Hz
                fs1 += cMid * (v - fs1); fs2 += cMid * (fs1 - fs2)                  // snare: high-pass 1 kHz …
                let sh = v - fs2
                fsl1 += cMidTop * (sh - fsl1); fsl2 += cMidTop * (fsl1 - fsl2)      // … low-pass 8 kHz
                fh1 += cHigh * (v - fh1); fh2 += cHigh * (fh1 - fh2)                // hats: high-pass 6 kHz
                let hh = v - fh2
                fAcc[0] += fl2 * fl2; fAcc[1] += fsl2 * fsl2; fAcc[2] += hh * hh
            }
            i += take; pending += take; sampleClock += Int64(take)
            if pending == Self.hop {
                pending = 0
                processFrame(&out)
            }
        }
        return out
    }

    private func processFrame(_ out: inout [Hit]) {
        hist.withUnsafeBufferPointer { h in
            for s in specs { s.run(h.baseAddress! + (hist.count - s.n)) }
        }
        let nb = bandHz.count
        var mean: Float = 0
        for k in 0..<nb {
            let p = specs[bandFFT[k]].pow
            var e: Float = 0
            for (i, w) in bandBins[k] { e += p[i] * w }
            bandE[k] = e
            mean += e
        }
        mean /= Float(nb)
        // level reference: the mean band energy, rising at once, falling over ~2 s
        let hopS = Double(Self.hop) / sampleRate
        refLevel = mean > refLevel ? mean : refLevel + (mean - refLevel) * Float(1 - exp(-hopS / 2))
        let floorE = refLevel * Self.relFloor + 1e-12
        let logRef = log(refLevel + 1e-12)
        for k in 0..<nb { logE[k] = log(bandE[k] + floorE) }
        let slot = frame % Self.lagCap
        for k in 0..<nb {
            maxHist[slot][k] = max(logE[k], max(k > 0 ? logE[k - 1] : -100, k + 1 < nb ? logE[k + 1] : -100))
        }
        for k in 0..<nb {
            let ref = maxHist[(frame - bandLag[k] + Self.lagCap * 4) % Self.lagCap][k]
            flux[k] = frame >= bandLag[k] ? max(0, logE[k] - ref) : 0
        }
        let a = Float(1 - exp(-hopS / 1.0))
        for k in 0..<nb {
            if frame == 0 { slow[k] = logE[k] }
            feat[3 * nb + k] = feat[2 * nb + k]
            feat[2 * nb + k] = feat[nb + k]
            feat[nb + k] = min(flux[k], 8)
            feat[k] = min(6, max(0, logE[k] - slow[k]))
            feat[4 * nb + k] = min(3, max(-14, logE[k] - logRef))
            slow[k] += (logE[k] - slow[k]) * a
        }
        frame += 1

        if useNets {
            var act: [Float] = [0, 0, 0]
            for n in Self.nets { let r = n.run(feat); for j in 0..<3 { act[j] += r[j] } }
            activation = act.map { $0 / Float(Self.nets.count) }
        }
        for d in 0..<3 {
            bandDB[d] = [bandDB[d][1], bandDB[d][2], 10 * log10(fAcc[d] / Float(Self.hop) + 1e-14)]
            fAcc[d] = 0
            let o = activation[d], prev = prevAct[d]
            prevAct[d] = o
            var mask: UInt8 = 0
            for l in 0..<Self.levels {
                since[d][l] += hopS
                let thr = min(0.97, max(0.3, Self.baseThreshold[d] + Self.levelOffset[l]))
                // fires once per crossing: above the threshold and still rising (or just crossed)
                if o > thr, o >= prev || prev <= thr, since[d][l] >= Self.refractory[d] {
                    since[d][l] = 0
                    mask |= 1 << l
                }
            }
            if mask != 0 {
                // strength: the band's loudness now against this drum's recent hits (moved by normal-level hits)
                let db = max(bandDB[d][0], bandDB[d][1], bandDB[d][2])
                let s = hitDB[d].isNaN ? 0.65 : min(1, max(0, 0.65 + (db - hitDB[d]) / 20))
                out.append(Hit(drum: d, strength: s, sample: sampleClock, levels: mask))
                if mask & (1 << Self.normalLevel) != 0 { hitDB[d] = hitDB[d].isNaN ? db : hitDB[d] + 0.15 * (db - hitDB[d]) }
            }
        }
    }
}

/// One hidden layer (ReLU), three sigmoid outputs (kick, snare, hats); inputs standardised with the stored mean / std.
struct DrumNet {
    var nIn: Int, nHid: Int
    var mean: [Float], invStd: [Float]
    var w1: [Float], b1: [Float]          // nHid × nIn, row-major
    var w2: [Float], b2: [Float]          // 3 × nHid

    func run(_ x: [Float]) -> [Float] {
        var xs = [Float](repeating: 0, count: nIn)
        vDSP.subtract(x, mean, result: &xs)
        vDSP.multiply(xs, invStd, result: &xs)
        var h = [Float](repeating: 0, count: nHid)
        w1.withUnsafeBufferPointer { W in xs.withUnsafeBufferPointer { X in
            for j in 0..<nHid {
                var z: Float = 0
                vDSP_dotpr(W.baseAddress! + j * nIn, 1, X.baseAddress!, 1, &z, vDSP_Length(nIn))
                h[j] = max(0, z + b1[j])
            }
        } }
        return (0..<3).map { o in
            var z = b2[o]
            for j in 0..<nHid { z += w2[o * nHid + j] * h[j] }
            return 1 / (1 + exp(-z))
        }
    }

    /// From base64 little-endian Float32s: mean, invStd (nIn each), w1 (nHid·nIn), b1 (nHid), w2 (3·nHid), b2 (3).
    init(nIn: Int, nHid: Int, mean: [Float], invStd: [Float], w1: [Float], b1: [Float], w2: [Float], b2: [Float]) {
        self.nIn = nIn; self.nHid = nHid; self.mean = mean; self.invStd = invStd; self.w1 = w1; self.b1 = b1; self.w2 = w2; self.b2 = b2
    }
    init?(nIn: Int, nHid: Int, base64: String) {
        guard let d = Data(base64Encoded: base64), d.count == 4 * (2 * nIn + nHid * nIn + nHid + 3 * nHid + 3) else { return nil }
        var f = [Float](repeating: 0, count: d.count / 4)
        _ = f.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        var o = 0
        func take(_ n: Int) -> [Float] { defer { o += n }; return Array(f[o..<o + n]) }
        self.init(nIn: nIn, nHid: nHid, mean: take(nIn), invStd: take(nIn), w1: take(nHid * nIn), b1: take(nHid), w2: take(3 * nHid), b2: take(3))
    }
}
