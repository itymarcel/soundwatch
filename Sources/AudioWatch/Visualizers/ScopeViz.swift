import Foundation
import simd

/// Zero-crossing-triggered oscilloscope with several ways to draw the trace (see `ScopeShape`).
final class ScopeViz: Visualizer {
    /// One triggered trace per lane: min/max pairs when decimated, single samples otherwise.
    private struct Trace { var v: [Float]; var lane: Int }

    private var frozen: [Trace] = []
    private var frozenAmp: Float = 0
    private var rot: Double = 0
    /// Ridgeline history (newest first), each resampled to `ridgeRes` points.
    private var ridges: [[Float]] = []
    private var ridgeAcc: Double = 0
    private let ridgeRes = 480
    private let ridgeCount = 90

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let lanes = s.stereo ? 2 : 1
        var traces: [Trace]
        var amp: Float
        if rc.frozen && !frozen.isEmpty {
            traces = frozen; amp = frozenAmp
        } else {
            (traces, amp) = capture(rc, lanes: lanes)
            frozen = traces; frozenAmp = amp
            rot += rc.dt * s.motion * 0.4
        }
        let reach = Float(s.reach)
        let lw = rc.unit * 1.2
        let dash: Float = s.segmented ? lw * 5 : 0

        switch s.scopeShape {
        case .line: drawLine(f, rc, traces, lanes: lanes, amp: amp, lw: lw, dash: dash, reach: reach)
        case .filled: drawFilled(f, rc, traces, lanes: lanes, amp: amp, reach: reach)
        case .circle: drawCircle(f, rc, traces, amp: amp, lw: lw, dash: dash, reach: reach)
        case .bloom: drawBloom(f, rc, traces, amp: amp, lw: lw, dash: dash, reach: reach)
        case .ridgeline: drawRidges(f, rc, traces, amp: amp, lw: lw, reach: reach)
        }
    }

    // MARK: - Capture

    private func capture(_ rc: RenderContext, lanes: Int) -> ([Trace], Float) {
        let s = rc.s, a = rc.analyzer
        let count = min(max(Int(s.scopeMs * 0.001 * a.sampleRate), 16), a.snapSize / 2)
        let search = min(Int(a.sampleRate / 25), a.snapSize - count - 1)
        let base = a.snapSize - count - search
        let L = a.snapL, R = a.snapR

        // Latest rising zero crossing (with a little hysteresis) so the trace holds still.
        var start = base + search
        var j = search - 1
        while j >= 4 {
            let i = base + j
            if L[i - 1] + R[i - 1] < 0 && L[i] + R[i] >= 0 && L[i - 4] + R[i - 4] < -0.002 { start = i; break }
            j -= 1
        }

        let target = 2048   // enough points for any shape at any window width
        let step = max(1, count / target)
        var out: [Trace] = []
        for lane in 0..<lanes {
            func sample(_ i: Int) -> Float {
                lanes == 1 ? 0.5 * (L[i] + R[i]) : (lane == 0 ? L[i] : R[i])
            }
            var v: [Float] = []
            v.reserveCapacity(count / step * 2 + 2)
            var i = 0
            while i < count {
                if step > 1 {
                    var lo: Float = 1e9, hi: Float = -1e9
                    for k in i..<min(i + step, count) { let x = sample(start + k); lo = min(lo, x); hi = max(hi, x) }
                    v.append(lo); v.append(hi)
                } else {
                    v.append(sample(start + i))
                }
                i += step
            }
            out.append(Trace(v: v, lane: lane))
        }
        return (out, min(1, a.rms(last: count) * 3 * Float(s.gain)))
    }

    private func color(_ rc: RenderContext, _ pos: Float, _ amp: Float, _ alpha: Float = 1) -> SIMD4<Float> {
        rc.col((rc.s.colorBy == .frequency ? 0.75 * pos : amp) + rc.phase, alpha)
    }

    private func emit(_ f: FrameBuilder, _ rc: RenderContext, _ pts: [SIMD2<Float>], lw: Float, dash: Float,
                      depths: [Float]? = nil, color: (Int) -> SIMD4<Float>) {
        guard pts.count > 1 else { return }
        if rc.s.style != .points { f.polyline(pts, lw, dash: dash, depths: depths, color: color) }
        if rc.s.style != .lines {
            let dStep = max(1, pts.count / 3000)
            for k in stride(from: 0, to: pts.count, by: dStep) {
                f.dot(pts[k], rc.unit * 1.1, color(k), square: rc.s.segmented, depth: depths?[k] ?? 0)
            }
        }
    }

    // MARK: - Shapes

    private func drawLine(_ f: FrameBuilder, _ rc: RenderContext, _ traces: [Trace], lanes: Int, amp: Float,
                          lw: Float, dash: Float, reach: Float) {
        let s = rc.s, w = rc.size.x
        let laneH = rc.size.y / Float(lanes)
        let scale = laneH * 0.42 * Float(s.gain * s.zoom) * reach
        for t in traces {
            let cy = laneH * (Float(t.lane) + 0.5)
            for mirror in (s.mirror ? [false, true] : [false]) {
                let sign: Float = mirror ? 1 : -1
                let n = t.v.count
                let pts = (0..<n).map { k in SIMD2(Float(k) / Float(n - 1) * w, cy + sign * t.v[k] * scale) }
                emit(f, rc, pts, lw: lw, dash: dash) { self.color(rc, pts[$0].x / w, amp) }
            }
        }
    }

    private func drawFilled(_ f: FrameBuilder, _ rc: RenderContext, _ traces: [Trace], lanes: Int, amp: Float, reach: Float) {
        let s = rc.s, w = rc.size.x
        let laneH = rc.size.y / Float(lanes)
        let scale = laneH * 0.42 * Float(s.gain * s.zoom) * reach
        let cols = min(Int(w / max(1, rc.unit * 1.5)), 1400)
        let barW = max(1, w / Float(cols) * (s.segmented ? 0.6 : 1.05))
        for t in traces {
            let cy = laneH * (Float(t.lane) + 0.5)
            f.line(SIMD2(0, cy), SIMD2(w, cy), rc.inkC(0.15), 1)
            let n = t.v.count
            for c in 0..<cols {
                // min/max of the samples under this column
                let k0 = c * n / cols, k1 = max(k0 + 1, (c + 1) * n / cols)
                var lo: Float = 0, hi: Float = 0
                for k in k0..<min(k1, n) { lo = min(lo, t.v[k]); hi = max(hi, t.v[k]) }
                if s.mirror { let p = max(-lo, hi); lo = -p; hi = p }
                let x = Float(c) / Float(cols) * w
                let pk = max(-lo, hi)
                let col = color(rc, x / w, s.colorBy == .frequency ? amp : min(1, pk * 2), 0.35 + 0.65 * min(1, pk * 3))
                if s.style != .points {
                    f.rect(x: x, y: cy - hi * scale, w: barW, h: max(1, (hi - lo) * scale), col)
                }
                if s.style != .lines {
                    f.dot(SIMD2(x + barW / 2, cy - hi * scale), rc.unit, col, square: s.segmented)
                    f.dot(SIMD2(x + barW / 2, cy - lo * scale), rc.unit, col, square: s.segmented)
                }
            }
        }
    }

    /// Samples a trace at `n` evenly spaced points, tapering the last few percent back to the start value so a
    /// closed loop has no seam.
    private func loop(_ v: [Float], _ n: Int) -> [Float] {
        guard v.count > 1 else { return .init(repeating: 0, count: n) }
        let taper = max(1, n / 16)
        return (0..<n).map { k in
            let x = v[min(v.count - 1, k * v.count / n)]
            let d = n - k
            guard d < taper else { return x }
            let t = Float(d) / Float(taper)
            return x * t + v[0] * (1 - t)
        }
    }

    private func drawCircle(_ f: FrameBuilder, _ rc: RenderContext, _ traces: [Trace], amp: Float,
                            lw: Float, dash: Float, reach: Float) {
        let s = rc.s, c = rc.center
        let r0 = rc.minDim * 0.27 * Float(s.zoom)
        let scale = rc.minDim * 0.16 * Float(s.gain * s.zoom) * reach
        let n = 720
        for t in traces {
            let base = r0 * (traces.count > 1 ? (t.lane == 0 ? 1.12 : 0.78) : 1)
            f.circle(c, base, rc.inkC(0.1), 1)
            let v = loop(t.v, n)
            for mirror in (s.mirror ? [false, true] : [false]) {
                let sign: Float = mirror ? -1 : 1
                let rotF = Float(rot)
                var pts = (0..<n).map { k -> SIMD2<Float> in
                    let th: Float = Float(k) / Float(n) * 2 * Float.pi - Float.pi / 2 + rotF
                    let r: Float = max(0, base + sign * v[k] * scale)
                    return c + SIMD2<Float>(cos(th), sin(th)) * r
                }
                pts.append(pts[0])
                emit(f, rc, pts, lw: lw, dash: dash) { self.color(rc, Float($0) / Float(n), amp) }
            }
        }
    }

    /// The trace in polar form, folded into a kaleidoscope: 2 × petals wedges, every other one mirrored so the
    /// wedges join seamlessly. Radius follows the waveform directly, so the flower IS the sound.
    private func drawBloom(_ f: FrameBuilder, _ rc: RenderContext, _ traces: [Trace], amp: Float,
                           lw: Float, dash: Float, reach: Float) {
        let s = rc.s, c = rc.center
        let petals = 6, wedges = petals * 2
        let r0 = rc.minDim * 0.24 * Float(s.zoom)
        let scale = rc.minDim * 0.5 * Float(s.gain * s.zoom) * reach
        let n = 200   // points per wedge
        let rotF = Float(rot)
        for t in traces {
            let v = loop(t.v, n)
            let laneK: Float = t.lane == 0 ? 1 : 0.62
            var pts: [SIMD2<Float>] = []
            pts.reserveCapacity(wedges * n + 1)
            for wdg in 0..<wedges {
                let a0: Float = Float(wdg) / Float(wedges) * 2 * Float.pi + rotF
                for k in 0..<n {
                    let u: Float = Float(k) / Float(n)
                    let x: Float = wdg % 2 == 0 ? v[k] : v[n - 1 - k]
                    let r: Float = max(0, (r0 + x * scale) * laneK)
                    let th: Float = a0 + u * 2 * Float.pi / Float(wedges)
                    pts.append(c + SIMD2<Float>(cos(th), sin(th)) * r)
                }
            }
            pts.append(pts[0])
            let total = Float(pts.count)
            emit(f, rc, pts, lw: lw, dash: dash) { k in
                // colour mirrors with the wedges so the symmetry reads in colour too
                let u = Float(k % n) / Float(n)
                let pos: Float = (k / n) % 2 == 0 ? u : 1 - u
                return self.color(rc, s.colorBy == .frequency ? pos : Float(k) / total, amp)
            }
        }
    }

    /// Ridgeline as real 3D: each past trace is a line across x at depth z, height = waveform. Rows glide back
    /// continuously between pushes, and the camera orbits the whole landscape (drag to look around).
    private func drawRidges(_ f: FrameBuilder, _ rc: RenderContext, _ traces: [Trace], amp: Float, lw: Float, reach: Float) {
        let s = rc.s
        let rate = 30 + 60 * s.motion   // new ridges per second
        if !rc.frozen, !traces.isEmpty {
            ridgeAcc += rc.dt * rate
            var pushes = 0
            while ridgeAcc >= 1 && pushes < 4 {
                ridgeAcc -= 1
                pushes += 1
                ridges.insert(ridgeRow(traces), at: 0)
            }
            if ridgeAcc > 1 { ridgeAcc = 0 }
            if ridges.count > ridgeCount { ridges.removeLast(ridges.count - ridgeCount) }
        }
        guard !ridges.isEmpty else { return }

        // World: x ∈ [-1, 1], height y, depth z ∈ [0, 2] (0 = newest, front). Scaled to the window below.
        let world = rc.minDim * 0.62 * Float(s.zoom)
        let heightK = 0.7 * Float(s.gain) * reach * (s.mirror ? -1 : 1)
        let spacing: Float = 2 / Float(ridgeCount)
        let glide = Float(ridgeAcc)                 // fraction of the way to the next push
        // default view: looking down onto the landscape; the user's orbit goes on top
        let view = Self.rotX(0.55) * rc.camera.rotation
        let camDist: Float = 4.2
        func project(_ p: SIMD3<Float>) -> (SIMD2<Float>, Float) {
            let q = view * p                         // landscape is centred on the origin
            let k = camDist / max(0.3, camDist - q.z)
            return (rc.center + SIMD2(q.x, 0.12 - q.y) * world * k, k)   // lift slightly: the tilt pushes the front down
        }
        let step = max(1, ridgeRes / 240)
        // back to front so nearer ridges draw last
        for (i, row) in ridges.enumerated().reversed() {
            let z = (Float(i) + glide) * spacing
            let ageK = z / 2
            let alpha = (1 - ageK) * (1 - ageK) * 0.9 + 0.1
            let inFade = i == 0 ? glide : 1          // newest ridge fades in instead of popping
            var pts: [SIMD2<Float>] = []
            var ks: [Float] = []
            pts.reserveCapacity(ridgeRes / step + 1)
            for k in stride(from: 0, to: ridgeRes, by: step) {
                let x: Float = Float(k) / Float(ridgeRes - 1) * 2 - 1
                let (sp, kk) = project(SIMD3(x, row[k] * heightK, -z + 1))
                pts.append(sp); ks.append(kk)
            }
            emit(f, rc, pts, lw: lw * 0.8, dash: 0, depths: ks) { j in
                let k = j * step
                let pos: Float = s.colorBy == .frequency ? ageK * 1.2 : Float(k) / Float(self.ridgeRes)
                return self.color(rc, pos, min(1, abs(row[k]) * 4), alpha * inFade)
            }
        }
    }

    private func ridgeRow(_ traces: [Trace]) -> [Float] {
        let n = traces[0].v.count
        // Mean of the lanes, with a raised-cosine window so ridges rise out of a flat floor at the edges.
        return (0..<ridgeRes).map { k in
            var x: Float = 0
            for tr in traces { x += tr.v[min(n - 1, k * n / ridgeRes)] }
            let u = Float(k) / Float(ridgeRes - 1)
            return x / Float(traces.count) * (0.5 - 0.5 * cos(2 * .pi * u))
        }
    }

    private static func rotX(_ a: Float) -> simd_float3x3 {
        simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(a), -sin(a)), SIMD3(0, sin(a), cos(a))])
    }
}
