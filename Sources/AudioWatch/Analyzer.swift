import Accelerate
import Foundation

/// Per-frame analysis: snapshot of the latest samples, an FFT spectrum,
/// log-spaced band extraction, and a rolling history of waveform "columns".
final class Analyzer {
    let ring: AudioRing
    private(set) var fftSize = 8192
    let snapSize = 32768

    private(set) var snapL: [Float]
    private(set) var snapR: [Float]
    /// Linear amplitude per FFT bin (full-scale sine ≈ 1.0).
    private(set) var amp: [Float]
    private(set) var sampleRate: Double = 48_000
    private(set) var lastSoundTime: Double = 0
    private(set) var lastDataTime: Double = 0
    private(set) var peakLevel: Float = 0
    /// Stereo width of the current audio: side (L−R) over mid (L+R) energy; ~0 = mono (both channels identical).
    private(set) var stereoWidth: Float = 1
    private(set) var dominantHz: Double = 0
    private var lastWritten: Int64 = 0
    /// Smoothed read position (absolute frame). Advances at the sample rate and eases toward the newest audio,
    /// so devices that deliver in uneven bursts don't make the picture lurch and stall.
    private var playhead: Double = -1
    private var lastUpdate: Double = 0
    private(set) var readEnd: Int64 = 0
    /// Latency the playhead keeps behind the newest audio (ms), for the FPS overlay.
    private(set) var bufferMs: Double = 0
    private(set) var ioBurst: Double = 0
    /// How far the picture is held back to stay in step with the speakers (ms; negative = read closer to the newest audio).
    private(set) var syncHoldMs: Double = 0
    /// The user's A/V sync offset (ms): + = picture later, − = earlier. Set per frame from `VizSettings.avSync`.
    var userSyncMs: Double = 0
    /// Smoothed time between updates (≈ the display's frame interval), for the picture's own delay.
    private var frameDt: Double = 1.0 / 120
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil

    private var fft: vDSP.FFT<DSPSplitComplex>
    private var window: [Float]
    private var windowed: [Float]
    private var re: [Float]
    private var im: [Float]
    private var sq: [Float]

    /// Short FFTs for the multi-resolution ("low latency") spectrum: a long window resolves bass but reacts late
    /// (an onset only reaches full strength once it's half a window in), so higher frequencies come from short ones.
    private final class Tier {
        let n: Int
        let fft: vDSP.FFT<DSPSplitComplex>
        let window: [Float]
        var windowed: [Float], re: [Float], im: [Float], sq: [Float], amp: [Float]
        /// Power summed over the overlapping segments, and the smoothed (fast-attack, slow-release) amplitude.
        var power: [Float], env: [Float]
        /// Per long-window bin from `i0` on (cached per FFT size / sample rate): crossfade weight, the tier bin it
        /// reads (k, k + 1, fraction) and its low / high band-mix weights. Same formulas as computed per frame before.
        var mapKey = SIMD2<Double>(0, 0), i0 = 0
        var mW: [Float] = [], mK: [Int] = [], mFr: [Float] = [], mLow: [Float] = [], mHigh: [Float] = []
        init(_ n: Int) {
            self.n = n
            fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)!
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
            windowed = .init(repeating: 0, count: n)
            re = .init(repeating: 0, count: n / 2); im = re; sq = re; amp = re; power = re; env = re
        }

        /// Power spectrum of the n samples (mono = average of l and r) ending at `end` (exclusive), added into `power`.
        func accumulate(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, end: Int) {
            let off = end - n
            windowed.withUnsafeMutableBufferPointer { wd in
                window.withUnsafeBufferPointer { wn in
                    for i in 0..<n { wd[i] = (l[off + i] * 0.5 + r[off + i] * 0.5) * wn[i] }
                }
            }
            let h = n / 2
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(h))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    vDSP.squareMagnitudes(split, result: &sq)
                }
            }
            vDSP.add(power, sq, result: &power)
        }
    }
    private let tiers = [Tier(2048), Tier(4096)]
    /// Below this many bins per octave a tier is too coarse; it fades in over the two octaves above that point.
    private static let tierBinsPerOctave: Double = 16
    var lowLatency = true
    /// Envelope on the short-window bins (seconds). Measured on music: 4× less flicker than raw, snare still ~25 ms.
    private static let tierRise = 0.012
    private static let tierFall = 0.12

    // ---- Transient gain (part of "low latency")
    // A symmetric FFT window only shows a hit at full strength once the hit is well inside it: ~150 ms late for the
    // long window that resolves the bass, ~40 ms for the short ones. But *when* the energy arrives is known much
    // sooner from the samples themselves: three band-filtered energies (low / mid / high) per 256-sample chunk.
    // So each part of the spectrum is scaled by (that band's energy in the last few ms) / (its energy as the FFT
    // window weights it). The FFT still says which frequencies sound; the time domain says how loud right now.
    // For a steady sound the ratio is 1 and nothing changes.
    private static let gainBands = 3
    /// Debug aid: AUDIOWATCH_NOGAIN=1 turns the transient gain off (to compare reaction times and steadiness).
    private static let noGain = ProcessInfo.processInfo.environment["AUDIOWATCH_NOGAIN"] != nil
    private var useGain = true
    private static let gainHist = 256                                   // chunks kept (≥ the longest window)
    private var bandE = [[Float]](repeating: .init(repeating: 0, count: Analyzer.gainHist), count: Analyzer.gainBands)
    private var gLp1: Float = 0, gLp2: Float = 0, gHp1: Float = 0, gHp2: Float = 0
    private var gAcc = [Float](repeating: 0, count: Analyzer.gainBands)
    /// Chunks averaged for "right now" per band: the bass needs a full cycle or so, the highs very little.
    private static let gainShort = [4, 3, 2]
    private var gainWeights: [Int: [Float]] = [:]
    /// `bandMix` per long-window bin (low, high), cached per FFT size / sample rate for `applyTransientGain`.
    private var gainMixKey = SIMD2<Double>(0, 0)
    private var gainMixLow: [Float] = [], gainMixHigh: [Float] = []

    /// Per-chunk weights of an n-sample Hann window (squared: it's applied to energies), newest chunk first; with
    /// `welch` the average of that window and one half a window earlier (what the short tiers measure).
    private func windowWeights(_ n: Int, welch: Bool) -> [Float] {
        let key = welch ? -n : n
        if let w = gainWeights[key] { return w }
        let c = Self.chunk
        func hann2(_ back: Double) -> Double {                           // `back` = samples before the window's end
            guard back >= 0, back <= Double(n) else { return 0 }
            let h = 0.5 * (1 - cos(2 * Double.pi * (1 - back / Double(n))))
            return h * h
        }
        let count = min(Self.gainHist, (welch ? n * 3 / 2 : n) / c)
        // averaged over each chunk (not just its middle): at the window's tail the weight grows so steeply that the
        // middle alone would be several times off, and the newest chunks are exactly the ones that matter here
        var w = (0..<count).map { j -> Float in
            var acc = 0.0
            for k in 0..<16 {
                let back = (Double(j) + (Double(k) + 0.5) / 16) * Double(c)
                acc += welch ? 0.5 * (hann2(back) + hann2(back - Double(n / 2))) : hann2(back)
            }
            return Float(acc / 16)
        }
        let sum = w.reduce(0, +)
        if sum > 0 { for i in w.indices { w[i] /= sum } }
        gainWeights[key] = w
        return w
    }

    /// Gain per band (low, mid, high) for a spectrum measured through an n-sample window ending at the playhead.
    private func transientGains(window n: Int, welch: Bool) -> SIMD3<Float> {
        let w = windowWeights(n, welch: welch)
        var g = SIMD3<Float>(repeating: 1)
        guard colCount > w.count else { return g }
        for b in 0..<Self.gainBands {
            var win: Float = 0, now: Float = 0
            let m = Self.gainShort[b]
            for j in 0..<w.count {
                let e = bandE[b][(colCount - 1 - j) % Self.gainHist]
                win += e * w[j]
                if j < m { now += e }
            }
            now /= Float(m)
            // 1e-9 ≈ −90 dB: below that it's silence, leave it alone rather than amplify noise
            g[b] = min(200, max(0.1, ((now + 1e-9) / (win + 1e-9)).squareRoot()))
        }
        return g
    }

    /// How much of the low and of the high band's gain applies at frequency f (the rest is the mid band's).
    @inline(__always) private static func bandMix(_ f: Float) -> (low: Float, high: Float) {
        (min(1, max(0, 1 - log2(max(f, 1) / 150))), min(1, max(0, log2(max(f, 1) / 1800))))
    }

    // Band mapping cache
    private struct MapKey: Equatable { var count: Int; var fMin: Double; var fMax: Double; var sr: Double }
    private var mapKey: MapKey?
    private var bLo: [Int] = []
    private var bHi: [Int] = []
    private var bCenter: [Float] = []
    private var bOctave: [Float] = []

    // Waveform columns (one per `chunk` frames)
    struct Column {
        var minL: Float = 0, maxL: Float = 0, minR: Float = 0, maxR: Float = 0
        var rms: Float = 0
        /// 0 = bass-heavy, 1 = treble-heavy
        var bright: Float = 0
    }
    static let chunk = 256
    private let colCap = 8192
    private var cols: [Column]
    private(set) var colCount = 0
    private var consumed: Int64 = -1
    private var acc = Column()
    private var accN = 0
    private var accSq: Float = 0
    private var eLow: Float = 0, eMid: Float = 0, eHigh: Float = 0
    private var lp: Float = 0, hpState: Float = 0
    private var tmpL: [Float]
    private var tmpR: [Float]

    init(ring: AudioRing) {
        self.ring = ring
        snapL = .init(repeating: 0, count: snapSize)
        snapR = .init(repeating: 0, count: snapSize)
        amp = .init(repeating: 0, count: fftSize / 2)
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        windowed = .init(repeating: 0, count: fftSize)
        re = .init(repeating: 0, count: fftSize / 2)
        im = .init(repeating: 0, count: fftSize / 2)
        sq = .init(repeating: 0, count: fftSize / 2)
        cols = .init(repeating: Column(), count: colCap)
        tmpL = .init(repeating: 0, count: 8192)
        tmpR = .init(repeating: 0, count: 8192)
    }

    // MARK: - Per-frame update

    /// Changes the analysis FFT size (power of two, 1024…32768).
    func configure(fftSize n: Int) {
        guard n != fftSize, n >= 1024, n <= snapSize, n & (n - 1) == 0 else { return }
        fftSize = n
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        windowed = .init(repeating: 0, count: n)
        re = .init(repeating: 0, count: n / 2)
        im = .init(repeating: 0, count: n / 2)
        sq = .init(repeating: 0, count: n / 2)
        amp = .init(repeating: 0, count: n / 2)
        mapKey = nil
    }

    /// Writes a max-pyramid of the amplitude spectrum (level 0 = raw bins) for the GPU. Returns level count.
    func buildPyramid(into p: UnsafeMutablePointer<Float>, capacity: Int, offsets: inout [UInt32]) -> Int {
        let half = fftSize / 2
        guard half * 2 <= capacity else { return 0 }
        amp.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: half) }
        var off = 0, size = half, level = 0
        offsets[0] = 0
        while size > 1 && level < 15 {
            let next = (size + 1) / 2
            let dst = off + size
            for i in 0..<next {
                let a = p[off + 2 * i]
                let b = 2 * i + 1 < size ? p[off + 2 * i + 1] : a
                p[dst + i] = max(a, b)
            }
            off = dst; size = next; level += 1
            offsets[level] = UInt32(off)
        }
        return level + 1
    }

    func update(now: Double, fftSize n: Int) {
        configure(fftSize: n)
        sampleRate = ring.sampleRate
        let written = ring.totalWritten
        if written != lastWritten { lastDataTime = now; lastWritten = written }

        let dt = lastUpdate > 0 ? min(0.1, now - lastUpdate) : 0
        lastUpdate = now
        ioBurst = ring.burst
        let margin = ioBurst * 1.25 + sampleRate * 0.002
        // The tap hears a sample ~28 ms (built-in speakers) to 100–250 ms (Bluetooth) before the speaker plays it. The
        // picture shows a hit after its own path: the buffer margin, the analysis (with Low latency the onset shows within
        // ~one 256-sample chunk via the transient gain; without it the FFT window lags more), and ~1.5 frames to the screen
        // (the drawable is taken before the analysis, then GPU + present). Hold the picture back by whatever the speaker
        // path exceeds that (any device, not only slow ones), plus the user's A/V sync offset. A negative total can
        // only eat into the margin: audio that hasn't arrived can't be shown.
        if dt > 0 { frameDt += (min(dt, 0.05) - frameDt) * 0.05 }
        let analysisDelay = lowLatency ? 0.008 : 0.035
        let ownPath = margin / sampleRate + analysisDelay + 1.5 * frameDt
        // The automatic part never reads closer than the margin (its estimate isn't exact enough to move the picture
        // earlier); only the user's offset can. Built-in speakers come out at ~0, Bluetooth at its latency − ~26 ms.
        let hold = max(0, ring.outputLatency - ownPath) + userSyncMs / 1000
        syncHoldMs = min(0.5, max(-margin / sampleRate, hold)) * 1000
        let target = Double(written) - margin - syncHoldMs / 1000 * sampleRate
        if playhead < 0 || abs(target - playhead) > sampleRate * 0.25 {
            playhead = target
        } else {
            playhead += dt * sampleRate
            playhead += (target - playhead) * (1 - exp(-dt / 0.35))
        }
        playhead = min(playhead, Double(written))
        if Self.trace { print("TRACE written=\(written) readEnd=\(Int64(playhead)) hold=\(syncHoldMs) out=\(ring.outputLatency * 1000) dt=\(dt) burst=\(ioBurst) bufMs=\((Double(written) - playhead) / sampleRate * 1000) sr=\(sampleRate)") }
        readEnd = max(0, Int64(playhead))
        bufferMs = (Double(written) - playhead) / sampleRate * 1000

        snapL.withUnsafeMutableBufferPointer { l in
            snapR.withUnsafeMutableBufferPointer { r in
                ring.copy(endingAt: readEnd, count: snapSize, l: l.baseAddress!, r: r.baseAddress!)
            }
        }

        processColumns()   // first: the chunk energies up to the playhead drive the transient gain below
        // Beat clock: the tracker's position is at the last finished chunk; the picture appears ~1.5 frames from now and
        // the speaker plays that audio `outputLatency` after the tap saw it. Predict the beat position for the sound
        // that's heard when this frame is on screen (+ the user's A/V offset).
        let processedEnd = Double(readEnd) - Double(accN)
        beatLookahead = (Double(written) - processedEnd) / sampleRate + 1.5 * frameDt - ring.outputLatency - userSyncMs / 1000
        updateBeats()

        let off = snapSize - fftSize
        var peak: Float = 0, sideE: Float = 0, midE: Float = 0
        snapL.withUnsafeBufferPointer { L in snapR.withUnsafeBufferPointer { R in
            window.withUnsafeBufferPointer { wn in windowed.withUnsafeMutableBufferPointer { wd in
                for i in 0..<fftSize {
                    let m = 0.5 * (L[off + i] + R[off + i])
                    let sd = 0.5 * (L[off + i] - R[off + i])
                    sideE += sd * sd; midE += m * m
                    wd[i] = m * wn[i]
                    peak = max(peak, abs(m))
                }
            } }
        } }
        if peak > 1e-4 { lastSoundTime = now }
        peakLevel = peak
        if midE > 1e-6 { stereoWidth = (sideE / midE).squareRoot() }

        let half = fftSize / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &sq)
            }
        }
        sq[0] = 0
        vForce.sqrt(sq, result: &amp)
        vDSP.multiply(1 / Float(half), amp, result: &amp)
        useGain = lowLatency && !Self.noGain
        if lowLatency { if useGain { applyTransientGain() }; blendTiers(dt: dt) }
        if Self.trace { print("LEVEL written=\(written) readEnd=\(readEnd) snare=\(levelRaw(1500, 6000)) bass=\(levelRaw(30, 150)) beats=\(beatCount)") }
        dominantHz = Double(vDSP.indexOfMaximum(amp).0) * sampleRate / Double(fftSize)
    }

    /// Scales the long-window spectrum by the transient gains (see above).
    private func applyTransientGain() {
        let g = transientGains(window: fftSize, welch: false)
        if g == SIMD3(repeating: 1) { return }
        let half = fftSize / 2
        let key = SIMD2(Double(fftSize), sampleRate)
        if gainMixKey != key || gainMixLow.count != half {
            gainMixKey = key
            let binHz = Float(sampleRate / Double(fftSize))
            gainMixLow = .init(repeating: 0, count: half); gainMixHigh = gainMixLow
            for i in 1..<half {
                let m = Self.bandMix(Float(i) * binHz)
                gainMixLow[i] = m.low; gainMixHigh[i] = m.high
            }
        }
        gainMixLow.withUnsafeBufferPointer { lo in gainMixHigh.withUnsafeBufferPointer { hi in
            amp.withUnsafeMutableBufferPointer { a in
                for i in 1..<half { a[i] *= g.x * lo[i] + g.z * hi[i] + g.y * (1 - lo[i] - hi[i]) }
            }
        } }
    }

    /// Runs the short FFTs on the newest samples and crossfades them into `amp` (same amplitude scale: a sine of
    /// amplitude A reads A/2 at any FFT size). Each tier takes over across one octave, once its bins are fine enough.
    private func blendTiers(dt: Double) {
        let binHz = sampleRate / Double(fftSize)
        // largest tier first, so the shortest window ends up on top at high frequencies
        for t in tiers.reversed() where t.n < fftSize {
            // Welch: average the newest window with one half a window earlier. Halves the estimate's noise for
            // ~n/4 samples of extra delay (~10 ms at 2048).
            let h = t.n / 2
            vDSP.fill(&t.power, with: 0)
            snapL.withUnsafeBufferPointer { L in snapR.withUnsafeBufferPointer { R in
                t.accumulate(L.baseAddress!, R.baseAddress!, end: snapSize)
                t.accumulate(L.baseAddress!, R.baseAddress!, end: snapSize - h)
            } }
            t.power[0] = 0
            vDSP.multiply(0.5, t.power, result: &t.power)
            vForce.sqrt(t.power, result: &t.amp)
            vDSP.multiply(1 / Float(h), t.amp, result: &t.amp)
            // ~12 ms rise, ~120 ms fall: onsets stay sharp, but single-frame noise spikes and the up/down
            // flicker of a short window are ironed out.
            let rise = Float(exp(-dt / Self.tierRise)), fall = Float(exp(-dt / Self.tierFall))
            t.amp.withUnsafeBufferPointer { ta in t.env.withUnsafeMutableBufferPointer { te in
                for k in 0..<h {
                    let v = ta[k], e = te[k]
                    let c = v >= e ? rise : fall
                    te[k] = e * c + v * (1 - c)
                }
            } }

            let tg = useGain ? transientGains(window: t.n, welch: true) : SIMD3<Float>(repeating: 1)
            let tBin = sampleRate / Double(t.n)
            let start = tBin * Self.tierBinsPerOctave   // an octave at f spans f / tBin bins
            let i0 = max(1, Int(start / binHz))
            let half = fftSize / 2
            guard i0 < half else { continue }
            let key = SIMD2(Double(fftSize), sampleRate)
            if t.mapKey != key || t.i0 != i0 || t.mW.count != half - i0 {
                t.mapKey = key; t.i0 = i0
                t.mW = []; t.mK = []; t.mFr = []; t.mLow = []; t.mHigh = []
                for i in i0..<half {
                    let f = Double(i) * binHz
                    t.mW.append(Float(min(1, log2(f / start) / 2)))      // 0 → 1 over two octaves, so no visible seam
                    let c = Float(f / tBin)
                    let k = min(Int(c), h - 2)
                    t.mK.append(k); t.mFr.append(c - Float(k))
                    let m = Self.bandMix(Float(f))
                    t.mLow.append(m.low); t.mHigh.append(m.high)
                }
            }
            t.env.withUnsafeBufferPointer { env in amp.withUnsafeMutableBufferPointer { a in
                t.mW.withUnsafeBufferPointer { W in t.mK.withUnsafeBufferPointer { K in t.mFr.withUnsafeBufferPointer { FR in
                    t.mLow.withUnsafeBufferPointer { LO in t.mHigh.withUnsafeBufferPointer { HI in
                        for j in 0..<(half - i0) {
                            let w = W[j], k = K[j], fr = FR[j], lo = LO[j], hi = HI[j]
                            let v = (env[k] * (1 - fr) + env[k + 1] * fr) * (tg.x * lo + tg.z * hi + tg.y * (1 - lo - hi))
                            a[i0 + j] = a[i0 + j] * (1 - w) + v * w
                        }
                    } }
                } } }
            } }
        }
    }

    // MARK: - Spectrum queries

    /// Strongest spectral peaks (Hz, magnitude) between fLo and fHi, at least ~¾ semitone apart, loudest first.
    /// Positions are refined by parabolic interpolation on the log magnitude.
    func peaks(count: Int, fLo: Double = 40, fHi: Double = 4000) -> [(hz: Double, mag: Float)] {
        let binHz = sampleRate / Double(fftSize)
        let lo = max(2, Int(fLo / binHz)), hi = min(amp.count - 2, Int(fHi / binHz))
        guard hi > lo else { return [] }
        let top = amp[lo...hi].max() ?? 0
        guard top > 1e-5 else { return [] }
        var cand: [(hz: Double, mag: Float)] = []
        for i in lo...hi where amp[i] > amp[i - 1] && amp[i] >= amp[i + 1] && amp[i] > top * 0.08 {
            let l = log(amp[i - 1] + 1e-9), c = log(amp[i] + 1e-9), r = log(amp[i + 1] + 1e-9)
            let d = l - 2 * c + r
            let off = abs(d) > 1e-9 ? 0.5 * (l - r) / d : 0
            cand.append((hz: (Double(i) + Double(max(-0.5, min(0.5, off)))) * binHz, mag: amp[i]))
        }
        cand.sort { $0.mag > $1.mag }
        var out: [(hz: Double, mag: Float)] = []
        for c in cand where out.allSatisfy({ abs(log2(c.hz / $0.hz)) > 0.06 }) {
            out.append(c)
            if out.count == count { break }
        }
        return out
    }

    /// Spectrum magnitude at `hz` (linear interpolation between bins).
    func magnitude(at hz: Double) -> Float {
        let c = hz / (sampleRate / Double(fftSize))
        let i = Int(c)
        guard i >= 1, i < amp.count - 1 else { return 0 }
        let f = Float(c - Double(i))
        return amp[i] * (1 - f) + amp[i + 1] * f
    }

    /// Mono samples of the newest `count` frames (oldest first), for waveform-shape modes.
    func recentMono(_ count: Int) -> [Float] {
        let n = min(count, snapSize)
        return (snapSize - n..<snapSize).map { 0.5 * (snapL[$0] + snapR[$0]) }
    }

    /// `count` log-spaced bands between the settings' min/max frequency, normalized 0…~1.5.
    func bands(count: Int, s: VizSettings) -> [Float] {
        let fMin = max(10, s.minFreq)
        let fMax = max(fMin * 1.5, min(s.maxFreq, sampleRate / 2 - 1))
        ensureMap(count: count, fMin: fMin, fMax: fMax)

        var out = [Float](repeating: 0, count: count)
        let floorDB = Float(s.floorDB), gain = Float(s.gain), tilt = Float(s.tilt)
        let inv = 1 / -floorDB
        amp.withUnsafeBufferPointer { a in
            for k in 0..<count {
                let lo = bLo[k], hi = bHi[k]
                var v: Float
                if hi - lo <= 1 {
                    let c = bCenter[k]
                    let i0 = Int(c)
                    let f = c - Float(i0)
                    v = a[i0] * (1 - f) + a[i0 + 1] * f
                } else {
                    v = 0
                    for i in lo..<hi { v = max(v, a[i]) }
                }
                let db = 20 * log10f(v + 1e-9) + tilt * bOctave[k]
                out[k] = min(1.5, max(0, (db - floorDB) * inv) * gain)
            }
        }
        return out
    }

    /// Normalized level of a frequency range (e.g. bass), 0…~1.5.
    func level(_ fLo: Double, _ fHi: Double, s: VizSettings) -> Float {
        let binHz = sampleRate / Double(fftSize)
        let lo = max(1, Int(fLo / binHz)), hi = min(amp.count - 1, max(lo + 1, Int(fHi / binHz)))
        var m: Float = 0
        for i in lo..<hi { m = max(m, amp[i]) }
        let floorDB = Float(s.floorDB)
        let db = 20 * log10f(m + 1e-9)
        return min(1.5, max(0, (db - floorDB) / -floorDB) * Float(s.gain))
    }

    private func levelRaw(_ fLo: Double, _ fHi: Double) -> Float {
        let binHz = sampleRate / Double(fftSize)
        var m: Float = 0
        for i in max(1, Int(fLo / binHz))..<min(amp.count, Int(fHi / binHz)) { m = max(m, amp[i]) }
        return m
    }

    /// RMS of the most recent `count` frames (mono).
    func rms(last count: Int) -> Float {
        let n = min(count, snapSize)
        var sum: Float = 0
        for i in (snapSize - n)..<snapSize {
            let m = 0.5 * (snapL[i] + snapR[i])
            sum += m * m
        }
        return sqrt(sum / Float(max(n, 1)))
    }

    private func ensureMap(count: Int, fMin: Double, fMax: Double) {
        let key = MapKey(count: count, fMin: fMin, fMax: fMax, sr: sampleRate)
        if key == mapKey { return }
        mapKey = key
        let half = fftSize / 2
        let binHz = sampleRate / Double(fftSize)
        let ratio = fMax / fMin
        bLo = .init(repeating: 0, count: count)
        bHi = .init(repeating: 0, count: count)
        bCenter = .init(repeating: 0, count: count)
        bOctave = .init(repeating: 0, count: count)
        for k in 0..<count {
            let f0 = fMin * pow(ratio, Double(k) / Double(count))
            let f1 = fMin * pow(ratio, Double(k + 1) / Double(count))
            let fc = sqrt(f0 * f1)
            let lo = min(max(1, Int(floor(f0 / binHz))), half - 2)
            bLo[k] = lo
            bHi[k] = min(max(lo + 1, Int(ceil(f1 / binHz))), half - 1)
            bCenter[k] = Float(min(max(1, fc / binHz), Double(half - 2)))
            bOctave[k] = Float(log2(fc / 1000))
        }
    }

    // MARK: - Waveform columns

    /// Most recent columns, oldest first.
    func recentColumns(_ n: Int) -> ArraySlice<Column> {
        let count = min(n, colCount, colCap)
        var out = [Column]()
        out.reserveCapacity(count)
        for i in (colCount - count)..<colCount { out.append(cols[i % colCap]) }
        return out[...]
    }

    // Beat fallback (tempo not locked): detected kicks (snares too after ~2.5 s without a kick).
    private var sampleClock: Int64 = 0
    private var lastBeatSample: Int64 = -1_000_000
    private var lastKickSample: Int64 = -1_000_000
    private var hitBeatCount = 0

    // MARK: - Drum hits

    /// Kick / snare / hats onsets, run on every chunk the columns consume (see DrumDetector).
    private var drums = DrumDetector(sampleRate: 48_000)
    private var chunkMono = [Float](repeating: 0, count: Analyzer.chunk)
    struct DrumEvent {
        var seq: Int
        var drum: Int
        var strength: Float
        /// `sampleClock` when it was detected.
        var sample: Int64
        /// Bit L = it counts at sensitivity level L (`DrumDetector.levels`).
        var levels: UInt8
    }
    private var drumEvents: [DrumEvent] = []
    /// Number of the newest drum hit (0 = none yet); consumers remember the last one they read.
    private(set) var drumSeq = 0

    /// Hits after `seq` that count at sensitivity `level`, at most `maxAge` seconds old (so a consumer that paused
    /// doesn't get a burst of old ones), oldest first.
    func drumHits(after seq: Int, level: Int = DrumDetector.normalLevel, maxAge: Double = 0.25) -> [DrumEvent] {
        let minSample = sampleClock - Int64(maxAge * sampleRate)
        return drumEvents.filter { $0.seq > seq && $0.sample >= minSample && $0.levels & (1 << level) != 0 }
    }

    private func pushDrums() {
        if abs(drums.sampleRate - sampleRate) > 1 { drums = DrumDetector(sampleRate: sampleRate) }
        let hits = chunkMono.withUnsafeBufferPointer { drums.push($0.baseAddress!, count: Self.chunk) }
        for h in hits {
            drumSeq += 1
            drumEvents.append(DrumEvent(seq: drumSeq, drum: h.drum, strength: h.strength, sample: sampleClock, levels: h.levels))
            if Self.trace { print(String(format: "DRUM %@ strength=%.2f levels=%d at=%lld p=%.2f", ["kick", "snare", "hats"][h.drum], h.strength, Int(h.levels), sampleClock, drums.activation[h.drum])) }
            guard h.levels & (1 << DrumDetector.normalLevel) != 0 else { continue }
            if h.drum == 0 { lastKickSample = sampleClock }
            let beatHit = h.drum == 0 || (h.drum == 1 && Double(sampleClock - lastKickSample) > sampleRate * 2.5)
            if beatHit && Double(sampleClock - lastBeatSample) > sampleRate * 0.15 {
                lastBeatSample = sampleClock
                hitBeatCount += 1
            }
        }
        if drumEvents.count > 96 { drumEvents.removeFirst(drumEvents.count - 64) }
    }

    // MARK: - Beats (tracked tempo, or detected hits as a fallback)

    private(set) var tracker = BeatTracker(hop: Double(Analyzer.chunk) / 48_000)
    /// Use the tempo tracker's predicted beats while it's locked (setting "Lock to tempo").
    var beatLock = true
    /// Counts beats from whichever source is active; only ever increases.
    private(set) var beatCount = 0
    /// 1 right on a beat, decaying to 0 over ~150 ms.
    private(set) var beatPulse: Float = 0
    /// Beat position (beats, continuous) for what's heard when this frame shows; valid while `tempoLocked`.
    private(set) var beatPosition: Double = 0
    private(set) var tempoLocked = false
    /// 0→1 over each beat of the tracked tempo (for what's heard now); 0 until a tempo is known.
    private(set) var beatRamp: Float = 0
    private var beatLookahead: Double = 0
    private var lastTrackedBeat = 0
    private var lastHitCount = 0

    private func updateBeats() {
        let t = tracker
        if t.period > 0 {
            let p = t.position + beatLookahead / t.periodSeconds
            beatRamp = Float(p - p.rounded(.down))
        }
        if beatLock && t.locked {
            let pos = t.position + beatLookahead / t.periodSeconds
            let whole = Int(pos.rounded(.down))
            if !tempoLocked { lastTrackedBeat = whole }             // just switched over: no extra beat
            else if whole > lastTrackedBeat { beatCount += 1; lastTrackedBeat = whole }
            let since = (pos - Double(lastTrackedBeat)) * t.periodSeconds
            beatPulse = since < 0 ? 0 : Float(exp(-since / 0.15))
            beatPosition = pos
            tempoLocked = true
        } else {
            beatCount += max(0, hitBeatCount - lastHitCount)
            let age = Double(sampleClock - lastBeatSample) / sampleRate
            beatPulse = age < 0 ? 0 : Float(exp(-age / 0.15))
            tempoLocked = false
        }
        lastHitCount = hitBeatCount
        if Self.trace {
            print(String(format: "BEAT readEnd=%lld pos=%.4f phase=%.4f bpm=%.2f conf=%.2f per=%.3f hits=%.2f locked=%d count=%d look=%.1f", readEnd - Int64(accN),
                         t.position, t.phase, t.bpm, t.confidence, t.periodicity, t.onsetShare, tempoLocked ? 1 : 0, beatCount, beatLookahead * 1000))
        }
    }

    private func processColumns() {
        let written = readEnd   // consume only up to the smoothed playhead
        if consumed < 0 || written - consumed > Int64(sampleRate) {
            consumed = max(0, written - Int64(Self.chunk))
        }
        let aLow = 1 - exp(-2 * Float.pi * 200 / Float(sampleRate))
        let aHigh = 1 - exp(-2 * Float.pi * 2500 / Float(sampleRate))
        let chunk = Self.chunk

        while consumed < written {
            let want = min(Int(written - consumed), tmpL.count)
            let got = tmpL.withUnsafeMutableBufferPointer { l in
                tmpR.withUnsafeMutableBufferPointer { r in
                    ring.copy(from: consumed, count: want, l: l.baseAddress!, r: r.baseAddress!)
                }
            }
            if got == 0 { break }
            for i in 0..<got {
                let l = tmpL[i], r = tmpR[i], m = 0.5 * (l + r)
                if accN == 0 {
                    acc = Column(minL: l, maxL: l, minR: r, maxR: r)
                } else {
                    acc.minL = min(acc.minL, l); acc.maxL = max(acc.maxL, l)
                    acc.minR = min(acc.minR, r); acc.maxR = max(acc.maxR, r)
                }
                accSq += m * m
                chunkMono[accN] = m
                lp += aLow * (m - lp)
                hpState += aHigh * (m - hpState)
                let high = m - hpState, mid = hpState - lp
                eLow += lp * lp; eMid += mid * mid; eHigh += high * high
                // transient-gain bands: two poles each, for a cleaner split than the one-pole ones above
                gLp1 += aLow * (m - gLp1); gLp2 += aLow * (gLp1 - gLp2)
                gHp1 += aHigh * (m - gHp1); gHp2 += aHigh * (gHp1 - gHp2)
                let gh = m - gHp2, gm = gHp2 - gLp2
                gAcc[0] += gLp2 * gLp2; gAcc[1] += gm * gm; gAcc[2] += gh * gh
                accN += 1
                if accN == chunk {
                    for b in 0..<Self.gainBands { bandE[b][colCount % Self.gainHist] = gAcc[b] / Float(chunk); gAcc[b] = 0 }
                    let hop = Double(chunk) / sampleRate
                    if abs(tracker.hop - hop) > 1e-9 { tracker = BeatTracker(hop: hop) }
                    let slot = colCount % Self.gainHist
                    tracker.push(low: bandE[0][slot], mid: bandE[1][slot], high: bandE[2][slot])
                    acc.rms = sqrt(accSq / Float(chunk))
                    let rl = sqrt(eLow), rm = sqrt(eMid), rh = sqrt(eHigh) * 2.5
                    acc.bright = min(1, (0.5 * rm + rh) / (rl + rm + rh + 1e-9))
                    sampleClock += Int64(chunk)
                    pushDrums()
                    cols[colCount % colCap] = acc
                    colCount += 1
                    accN = 0; accSq = 0; eLow = 0; eMid = 0; eHigh = 0
                }
            }
            consumed += Int64(got)
        }
    }
}
