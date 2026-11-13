import Accelerate
import Foundation

/// Live tempo and beat-phase tracker (causal: only past audio).
///
/// 1. Onset strength (ODF), one value per 256-sample chunk (~5 ms): half-wave rectified rise of the log energy in three
///    bands (low < 200 Hz, mid, high > 2.5 kHz; averaged over 48 / 32 / 16 ms), summed. Kicks, snares and hats all count.
/// 2. Tempo, 4× a second: autocorrelation of the last 8 s of ODF, scored as a comb over 1…4 beat periods (so the beat and
///    its multiples agree) and weighted by a broad prior around 120 BPM (60…200 BPM). A different tempo must win several
///    estimates in a row before it replaces the current one, so it doesn't flicker between e.g. 120 and 60.
/// 3. Phase: a comb template (8 past beats at the tempo, newer weighted more) slid over the ODF says how long ago the
///    last beat was. A beat clock runs at the tempo and is pulled gently toward that measurement (phase-locked loop),
///    so it keeps going through breaks, fills and syncopation, and its beats are *predicted*, not detected late.
/// 4. Confidence = the weakest of: phase template sharpness, onsets on ≥ ~6 of the last 8 beats standing out from the gaps
///    between beats (rejects pads, swells), autocorrelation at the period, and agreement of the clock with the newest bar
///    (drops within ~1-2 s when the tempo changes). Locks above 0.5, unlocks below 0.25.
///
/// Downbeats (bar position) were tried with a kick-band accent and dropped: on four-on-the-floor every beat has a kick,
/// and snares reach into the kick band, so it guessed. A reliable one would need harmonic change (chords move on bar 1).
/// Tested on synthetic drums (AUDIOWATCH_TRACE BEAT lines): beats within ±2 ms once locked, lock after ~5 s.
final class BeatTracker {
    /// Seconds per ODF sample.
    private(set) var hop: Double
    private let cap: Int
    private var odf: [Float]
    private var n = 0

    // ODF state: band log energies averaged over ~48 / 32 / 16 ms. Shorter windows see the beating of chord tones
    // (e.g. a 4:5:6 chord on 110 Hz pulses at 27.5 Hz) as a stream of onsets.
    private static let smoothChunks = [9, 6, 3]
    private static let histMask = 31
    private var eHist = [[Float]](repeating: .init(repeating: 0, count: 32), count: 3)
    private var lHist = [[Float]](repeating: .init(repeating: -18, count: 32), count: 3)
    private var eIdx = 0

    // Tempo
    /// Beat period in ODF samples (fractional); 0 = not known yet.
    private(set) var period: Double = 0
    private var candidate: Double = 0
    private var candidateWins = 0
    private var sinceTempo = 0
    private var x: [Float]
    private var acf: [Float]

    // Phase
    /// Fraction of the current beat elapsed at the newest analysed sample (0 = on the beat).
    private(set) var phase: Double = 0
    /// Beats elapsed (the clock's wraps); with `phase` the continuous beat position.
    private(set) var beatIndex = 0
    /// 0…1, how clearly the music has a steady pulse at this tempo (smoothed).
    private(set) var confidence: Float = 0
    /// Autocorrelation of the onsets at the beat period (0…1): how much the onsets really repeat at this tempo.
    /// Sparse onsets (pads, a chord every few seconds) can still give a sharp phase template, but not this.
    private(set) var periodicity: Float = 0
    /// The ODF peaks this long after the real onset (smoothed band energies, measured: ~13 ms); the beat clock subtracts it.
    private static let odfDelay = 0.013
    /// Share of the last 8 beats that had an onset (diagnostics).
    private(set) var onsetShare: Float = 0
    /// Smoothed |phase error| of the beat clock against the onsets (beats).
    private var errAvg: Float = 0
    private var sincePhase = 0

    init(hop: Double) {
        self.hop = hop
        cap = Int((8.5 / hop).rounded(.up))
        odf = .init(repeating: 0, count: cap)
        x = .init(repeating: 0, count: cap)
        acf = .init(repeating: 0, count: cap)
    }

    var bpm: Double { period > 0 ? 60 / (period * hop) : 0 }
    var periodSeconds: Double { period * hop }
    /// Steady enough to trust the predicted beats. Locks above confidence 0.5, unlocks below 0.25 (so it doesn't flicker on borderline material).
    private(set) var locked = false
    /// Continuous beat position (beats) at the newest analysed sample.
    var position: Double { Double(beatIndex) + phase }

    // MARK: - Input

    /// One chunk's mean-square energies of the low / mid / high bands.
    func push(low: Float, mid: Float, high: Float) {
        let e = [low, mid, high]
        let weights: [Float] = [1.0, 0.8, 0.6]
        var flux: [Float] = [0, 0, 0]
        let m = Self.histMask
        let slot = eIdx & m
        for b in 0..<3 {
            eHist[b][slot] = e[b]
            let k = Self.smoothChunks[b]
            var s: Float = 0
            for j in 0..<k { s += eHist[b][(eIdx - j + m + 1) & m] }
            let l = log(s / Float(k) + 1e-8)
            lHist[b][slot] = l
            // rise against the previous (non-overlapping) window; ignore rises under ~1 dB (leftover ripple)
            flux[b] = max(0, l - lHist[b][(eIdx - k + m + 1) & m] - 0.25)
        }
        eIdx += 1
        var v: Float = 0
        for b in 0..<3 { v += weights[b] * flux[b] }
        odf[n % cap] = v
        n += 1

        advanceClock()

        sinceTempo += 1
        if sinceTempo >= Int(0.25 / hop) { sinceTempo = 0; estimateTempo() }
        sincePhase += 1
        if sincePhase >= 2 { sincePhase = 0; measurePhase() }
    }

    // MARK: - Beat clock

    private func advanceClock() {
        guard period > 0 else { return }
        phase += 1 / period
        if phase >= 1 { phase -= 1; beatIndex += 1 }
    }

    // MARK: - Tempo

    private func estimateTempo() {
        let N = min(n, cap)
        guard Double(N) * hop >= 3 else { return }
        // last N ODF values, oldest first, mean removed
        for i in 0..<N { x[i] = odf[(n - N + i) % cap] }
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(N))
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(N))
        // weight the last seconds more (~4 s): a tempo change then wins within a few seconds, not after the whole window
        for i in 0..<N { x[i] *= Float(exp(-Double(N - 1 - i) * hop / 4)) }
        var e0: Float = 0
        vDSP_dotpr(x, 1, x, 1, &e0, vDSP_Length(N))
        guard e0 > 1e-6 else { confidence *= 0.9; return }

        let minL = Int((60.0 / 200 / hop).rounded(.down))
        let maxL = Int((60.0 / 60 / hop).rounded(.up))
        let maxLag = min(N * 3 / 4, 4 * maxL + 2)
        x.withUnsafeBufferPointer { xp in
            for lag in 1...maxLag {
                var d: Float = 0
                vDSP_dotpr(xp.baseAddress!, 1, xp.baseAddress! + lag, 1, &d, vDSP_Length(N - lag))
                acf[lag] = d / Float(N - lag) * Float(N) / e0
            }
        }
        func acfAt(_ l: Double) -> Float {
            let i = Int(l), f = Float(l - Double(i))
            guard i >= 1, i + 1 <= maxLag else { return 0 }
            return acf[i] * (1 - f) + acf[i + 1] * f
        }
        let combW: [Float] = [1, 0.8, 0.6, 0.45]
        func score(_ L: Double) -> Float {
            var s: Float = 0
            for k in 1...4 where Double(k) * L <= Double(maxLag) { s += combW[k - 1] * acfAt(Double(k) * L) }
            let bpm = 60 / (L * hop)
            let o = log2(bpm / 120) / 1.0
            return max(0, s) * Float(exp(-0.5 * o * o))
        }
        var best: Float = -1, bestL = 0
        var scores = [Float](repeating: 0, count: maxL + 2)
        for L in minL...maxL {
            scores[L] = score(Double(L))
            if scores[L] > best { best = scores[L]; bestL = L }
        }
        guard best > 0 else { return }
        // parabolic refinement
        var Lf = Double(bestL)
        if bestL > minL && bestL < maxL {
            let a = scores[bestL - 1], b = scores[bestL], c = scores[bestL + 1]
            let den = a - 2 * b + c
            if den < 0 { Lf += Double(0.5 * (a - c) / den) }
        }
        defer { periodicity = period > 0 ? max(0, acfAt(period)) : 0 }
        if period == 0 {
            period = Lf
            return
        }
        // near the current tempo: follow it smoothly
        if abs(Lf / period - 1) < 0.04 {
            period += (Lf - period) * 0.25
            candidateWins = 0
            return
        }
        // elsewhere: must clearly beat the current tempo several times in a row
        if score(Lf) > score(period) * 1.15 {
            if candidate > 0 && abs(Lf / candidate - 1) < 0.04 { candidateWins += 1 } else { candidate = Lf; candidateWins = 1 }
            if candidateWins >= (locked ? 4 : 3) {
                period = Lf
                candidateWins = 0
                confidence *= 0.5
            }
        } else {
            candidateWins = 0
        }
    }

    // MARK: - Phase

    private func measurePhase() {
        guard period > 0 else { return }
        let K = 8
        guard Double(n) > Double(K) * period + 2 else { return }
        let P = period
        let count = max(2, Int(P.rounded()))
        var best: Float = -1, bestPhi = 0, sum: Float = 0
        var best3: Float = -1, bestPhi3 = 0                      // the newest bar (4 beats) only: reacts to a change at once
        var s = [Float](repeating: 0, count: count)
        for phi in 0..<count {
            var acc: Float = 0, w: Float = 1
            for k in 0..<K {
                acc += w * odfAt(Double(n - 1 - phi) - Double(k) * P)
                w *= 0.8
                if k == 3, acc > best3 { best3 = acc; bestPhi3 = phi }
            }
            s[phi] = acc
            sum += acc
            if acc > best { best = acc; bestPhi = phi }
        }
        guard best > 1e-5 else { confidence *= 0.98; return }
        var phiF = Double(bestPhi)
        let a = s[(bestPhi - 1 + count) % count], c = s[(bestPhi + 1) % count]
        let den = a - 2 * best + c
        if den < 0 { phiF += Double(0.5 * (a - c) / den) }
        let mean = sum / Float(count)
        let inst = (best - mean) / best
        // A clear pulse gives ~0.6-0.8; noise or no rhythm ~0.2-0.35.
        let cPhase = min(1, max(0, (inst - 0.3) / 0.35))
        // A real beat has an onset on (nearly) every beat; a few big events (a chord every few seconds) can still
        // make a sharp template. Share of the last K beats with an onset of at least 30 % of the strongest one.
        // The onset must also stand out from the gaps between beats (median of 5 points from ¼ to ¾ of the way to
        // the next beat): a swell or riser raises the onset strength everywhere, a drum hit only on the beat.
        var peaks = [Float](repeating: 0, count: K), gaps = [Float](repeating: 0, count: K)
        for k in 0..<K {
            let c = Double(n - 1 - bestPhi) - Double(k) * P
            for d in -3...3 { peaks[k] = max(peaks[k], odfAt(c + Double(d))) }
            let between = (0..<5).map { odfAt(c - P * (0.25 + 0.125 * Double($0))) }.sorted()
            gaps[k] = between[2]
        }
        let top = peaks.max() ?? 0
        let hits = Float((0..<K).filter { peaks[$0] >= 0.3 * top && peaks[$0] >= 1.8 * gaps[$0] + 1e-4 }.count) / Float(K)
        let cHits = min(1, max(0, (hits - 0.5) / 0.3))
        let cPeriod = min(1, max(0, (periodicity - 0.05) / 0.15))
        onsetShare = hits
        let measured = (phiF + Self.odfDelay / hop) / P
        var err = measured - phase
        err -= err.rounded()                                     // wrap to −0.5…0.5
        // While locked the clock and the newest beats agree within a few %; if they keep disagreeing (tempo changed, lost
        // the beat), stop trusting the clock within ~0.5 s instead of firing beats in the wrong place.
        var err3 = (Double(bestPhi3) + Self.odfDelay / hop) / P - phase
        err3 -= err3.rounded()
        errAvg += (Float(abs(err3)) - errAvg) * Float(1 - exp(-2 * hop / 0.4))
        let cErr = min(1, max(0, 1 - (errAvg - 0.06) / 0.08))

        let c01 = min(cPhase, cHits, cPeriod, cErr)
        let tau: Float = c01 < confidence && cErr < 0.5 ? 0.3 : 1.5         // drop fast on disagreement, else ~1.5 s
        confidence += (c01 - confidence) * (1 - exp(-2 * Float(hop) / tau))
        if confidence > 0.5 { locked = true } else if confidence < 0.25 { locked = false }
        // Pull the clock toward the measurement: snap when lost, gently when locked (~0.3 s), so single
        // off-beat hits don't drag it.
        let gain = confidence < 0.15 ? 0.5 : (abs(err) > 0.25 ? 0.06 : 0.035)
        phase += err * gain
        // Second-order loop: a steady lead/lag means the tempo is slightly off; nudge the period (follows gradual
        // tempo drift, e.g. a live drummer or a DJ pitch ride, between the 4×/s tempo estimates).
        if confidence > 0.3 && abs(err) < 0.2 { period *= 1 - 0.004 * err }
        if phase < 0 { phase += 1; beatIndex -= 1 } else if phase >= 1 { phase -= 1; beatIndex += 1 }
    }

    /// ODF at a fractional absolute index (0 outside the kept history).
    private func odfAt(_ pos: Double) -> Float {
        let i = Int(pos.rounded(.down))
        guard i >= max(0, n - cap + 1), i + 1 <= n - 1 else { return i == n - 1 && i >= 0 ? odf[i % cap] : 0 }
        let f = Float(pos - Double(i))
        return odf[i % cap] * (1 - f) + odf[(i + 1) % cap] * f
    }
}
