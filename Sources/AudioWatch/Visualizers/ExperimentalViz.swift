import Accelerate
import Foundation
import simd

// Experimental modes, each borrowed from a different field: delay embedding from dynamical systems
// (Attractor), the Victorian harmonograph (pitch ratios) and the
// vibration modes of a circular drum skin.

func rotX(_ a: Float) -> simd_float3x3 {
    simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(a), -sin(a)), SIMD3(0, sin(a), cos(a))])
}

func rotY(_ a: Float) -> simd_float3x3 {
    simd_float3x3(rows: [SIMD3(cos(a), 0, sin(a)), SIMD3(0, 1, 0), SIMD3(-sin(a), 0, cos(a))])
}

// MARK: - Attractor

/// Takens delay embedding: the waveform drawn as the 3D curve (x(t), x(t−τ), x(t−2τ)).
/// τ follows a quarter period of the dominant pitch, so a pure tone always traces a clean loop.
final class AttractorViz: Visualizer {
    private var tau: Double = 30
    private var peak: Float = 0.05
    private var spin: Float = 0

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let sr = rc.analyzer.sampleRate
        let hz = min(2000, max(40, rc.analyzer.dominantHz))
        if !rc.frozen {
            // glide in log space so τ never jumps when the dominant pitch flips
            let target = log(sr / (4 * hz))
            tau = exp(log(tau) + (target - log(tau)) * (1 - exp(-rc.dt * 5)))
            spin += Float(rc.dt * s.motion * 0.5)
        }
        let d = max(1, Int(tau.rounded()))
        let n = max(64, Int(s.attractorMs * sr / 1000))
        let x = rc.analyzer.recentMono(n + 2 * d)
        guard x.count == n + 2 * d else { return }

        // auto-gain: jump up to new peaks, relax over ~1 s, so the figure fills the view without pumping
        var pk: Float = 0
        for v in x { pk = max(pk, abs(v)) }
        if !rc.frozen { peak = pk > peak ? pk : max(1e-3, peak + (pk - peak) * Float(1 - exp(-rc.dt / 1.0))) }
        let a = Float(s.gain) * 0.75 * Float(s.reach) / max(peak, 1e-3)

        let world = rc.minDim * 0.42 * Float(s.zoom) * (1 + 0.05 * rc.beat)
        // the (1,1,1) diagonal is where slow content lives; tilt it so the loops open towards the viewer
        let view = rotX(0.5) * rc.camera.rotation * rotY(0.785 + spin)
        let camDist: Float = 3.6
        let step = max(1, n / 2500)
        var pts: [SIMD2<Float>] = [], ks: [Float] = [], vel: [Float] = []
        pts.reserveCapacity(n / step + 1)
        var prev = SIMD3<Float>()
        for (j, t) in stride(from: 2 * d, to: n + 2 * d, by: step).enumerated() {
            let p = SIMD3(x[t], x[t - d], x[t - 2 * d]) * a
            let q = view * p
            let k = camDist / max(0.3, camDist - q.z)
            pts.append(rc.center + SIMD2(q.x, -q.y) * world * k)
            ks.append(k)
            vel.append(j == 0 ? 0 : simd_length(p - prev))
            prev = p
        }
        guard pts.count > 1 else { return }
        let m = pts.count
        let vMax = max(1e-4, vel.max() ?? 1)
        let lw = rc.unit * 1.1
        for i in 0..<m {
            let age = Float(i) / Float(m - 1)                     // 0 = oldest, 1 = now
            let fade = 0.12 + 0.88 * age * age
            let tc: Float = s.colorBy == .frequency ? age * 0.7 : min(1, vel[i] / vMax * 1.4)
            let col = rc.col(tc + rc.phase, fade)
            if s.style != .points, i > 0 { f.line(pts[i - 1], pts[i], col, lw * ks[i], depth: 0.5 * (ks[i - 1] + ks[i])) }
            if s.style != .lines, i % 2 == 0 { f.dot(pts[i], lw * 0.9 * ks[i], col, square: s.segmented, depth: ks[i]) }
        }
        // the newest sample as a bright head
        f.dot(pts[m - 1], lw * 3, rc.col(rc.phase + (s.colorBy == .frequency ? 0.7 : 1), 1), depth: ks[m - 1])
    }
}


/// Projects a 3D point (y up, scene centred on the origin) with a little perspective, like the scope ridges.
func project(_ p: SIMD3<Float>, _ view: simd_float3x3, _ rc: RenderContext, world: Float, camDist: Float = 3.6)
    -> (SIMD2<Float>, Float) {
    let q = view * p
    let k = camDist / max(0.3, camDist - q.z)
    return (rc.center + SIMD2(q.x, -q.y) * world * k, k)
}

// MARK: - Harmonograph

/// A 3D harmonograph. Real machines have two lateral pendulums (x, y) and often a rotary pendulum that swings
/// the table in a circle; a third lateral pendulum gives the depth axis here. Each pendulum is a damped
/// oscillator, A·sin(2πft + φ)·e^(−δt), and its frequency is a note being played, relative to the lowest one.
/// Just intervals (3:2, 4:3, 2:1) draw calm closed figures, equal-tempered ones precess slowly as the real
/// machines do when slightly mistuned, and clashing notes fill the figure in.
final class HarmonographViz: Visualizer {
    // pendulums: 0 = x, 1 = y, 2 = z, 3 = rotary table
    private var ratios: [Double] = [1, 1.5, 2, 1.003]
    private var amps: [Double] = [1, 1, 0.7, 0.35]
    private var phases: [Double] = [0, .pi / 2, 0.7, 0]
    private var size: Float = 0.6
    private var spin: Float = 0

    /// Damping per pendulum (per swing of the base pendulum): heavy bobs ring longer than the light table.
    private static let damping: [Double] = [1.0, 1.15, 0.85, 1.6]

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        if !rc.frozen {
            let pk = rc.analyzer.peaks(count: 4, fLo: max(40, s.minFreq), fHi: min(4000, s.maxFreq))
            if pk.count >= 2 {
                let base = pk.map(\.hz).min()!
                let byPitch = pk.sorted { $0.hz < $1.hz }
                let maxMag = pk.map(\.mag).max()!
                let k = 1 - exp(-rc.dt / 0.3)
                for i in 0..<4 {
                    let p = byPitch[(i + 1) % byPitch.count]              // x gets the 2nd note, y the 3rd, …
                    var r = p.hz / base
                    while r >= 4 { r /= 2 }                                // fold into the pendulum range
                    if i == 3 { r = 1 + (r - floor(r)) * 0.02 }            // rotary: near-unison, slow precession
                    ratios[i] = exp(log(ratios[i]) + (log(r) - log(ratios[i])) * k)
                    amps[i] += (Double(max(0.3, p.mag / maxMag)) * (i == 3 ? 0.45 : 1) - amps[i]) * k
                }
            }
            let drift: [Double] = [0.13, 0.17, 0.11, 0.07]
            for i in 0..<4 { phases[i] += rc.dt * (0.05 + s.motion) * drift[i] }
            spin += Float(rc.dt * s.motion * 0.25)
            let loud = min(1.2, rc.analyzer.level(40, 8000, s: s))
            size += (0.55 + 0.45 * loud - size) * Float(1 - exp(-rc.dt / 0.15))
        }

        let swings = min(10, max(2, s.harmonoSwings))
        let n = Int(swings * 420)
        let decayK = 3.0 / swings                                  // the slowest pendulum ends at ~5 %
        let world = rc.minDim * 0.4 * Float(s.zoom * s.reach) * size * (1 + 0.06 * rc.beat)
        let view = rotX(0.35) * rc.camera.rotation * rotY(spin)
        let ax = amps[0] + amps[3], ay = amps[1] + amps[3]
        var pts: [SIMD2<Float>] = [], ks: [Float] = [], env: [Float] = []
        pts.reserveCapacity(n); ks.reserveCapacity(n); env.reserveCapacity(n)
        let d = Self.damping
        for i in 0..<n {
            let t = Double(i) / Double(n - 1) * swings
            let w = 2 * Double.pi * t
            func osc(_ k: Int) -> Double { amps[k] * sin(w * ratios[k] + phases[k]) * exp(-decayK * d[k] * t) }
            let rot = amps[3] * exp(-decayK * d[3] * t)
            let x = (osc(0) + rot * cos(w * ratios[3])) / ax
            let y = (osc(1) + rot * sin(w * ratios[3])) / ay
            let z = osc(2) / max(0.3, amps[2])
            let (p, k) = project(SIMD3(Float(x), Float(y), Float(z) * 0.8), view, rc, world: world)
            pts.append(p); ks.append(k); env.append(Float(exp(-decayK * t)))
        }
        let lw = rc.unit * 1.1
        for i in 0..<n {
            let age = Float(i) / Float(n - 1)                         // 0 = first, widest swing … 1 = died down
            let t: Float = s.colorBy == .frequency ? age * 0.8 : 1 - env[i]
            let col = rc.col(t + rc.phase, 0.25 + 0.75 * env[i])
            if s.style != .points, i > 0 { f.line(pts[i - 1], pts[i], col, lw * ks[i], depth: 0.5 * (ks[i - 1] + ks[i])) }
            if s.style != .lines, i % 4 == 0 { f.dot(pts[i], lw * 0.9 * ks[i], col, square: s.segmented, depth: ks[i]) }
        }
    }
}

// MARK: - Drumhead

/// A circular membrane in 3D. Each frequency band drives one of the drum's real modes, J_m(j_mn·r)·cos(mθ):
/// bass the fundamental dome, then nodal diameters and rings as frequency rises. Every mode oscillates at its
/// own (inharmonic) drum frequency ratio, slowed down to be visible.
final class DrumheadViz: Visualizer {
    private static let modes: [(m: Int, j: Double)] = [
        (0, 2.4048), (1, 3.8317), (2, 5.1356), (0, 5.5201), (3, 6.3802), (1, 7.0156),
        (4, 7.5883), (2, 8.4172), (0, 8.6537), (5, 8.7715), (3, 9.7610), (6, 9.9361),
    ]
    private var count = 0
    private var px: [Float] = [], pz: [Float] = [], rad: [Float] = []
    private var ringStarts: [Int] = []
    private var builtRings = 0
    /// Per mode: J_m(j r)·cos(mθ) and J_m(j r)·sin(mθ), radial part normalised to peak 1.
    private var shapeC: [[Float]] = [], shapeS: [[Float]] = []
    private var smoother = Smoother()
    private var phase = [Double](repeating: 0, count: 12)
    private var spin = [Double](repeating: 0, count: 12)

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        setup(Int(s.drumPoints))
        let w = smoother.step(rc.analyzer.bands(count: 12, s: s), smoothing: s.smoothing, dt: rc.dt, frozen: rc.frozen)
        let modes = Self.modes
        if !rc.frozen {
            for k in 0..<12 {
                phase[k] += rc.dt * 2 * .pi * (0.5 + 2 * s.motion) * (modes[k].j / modes[0].j).squareRoot()
                spin[k] += rc.dt * s.motion * 0.15 * (k % 2 == 0 ? 1 : -1)
            }
        }
        let heightK = 0.32 * Float(s.reach) * (1 + 0.35 * rc.beat)
        var a = [Float](repeating: 0, count: 12), cs = a, sn = a
        for k in 0..<12 {
            a[k] = w[k] * Float(cos(phase[k])) * heightK
            cs[k] = Float(cos(Double(modes[k].m) * spin[k])); sn[k] = Float(sin(Double(modes[k].m) * spin[k]))
        }

        let view = rotX(0.8) * rc.camera.rotation
        let world = rc.minDim * 0.4 * Float(s.zoom)
        var pts = [SIMD2<Float>](repeating: .zero, count: count)
        var ks = [Float](repeating: 1, count: count)
        // z = Σ a·J·cos(m(θ + spin)) = Σ (a·cos m·spin)·J·cos mθ − (a·sin m·spin)·J·sin mθ
        var zs = [Float](repeating: 0, count: count)
        for k in 0..<12 where a[k] != 0 {
            vDSP.add(multiplication: (shapeC[k], a[k] * cs[k]), zs, result: &zs)
            if modes[k].m != 0 { vDSP.add(multiplication: (shapeS[k], -a[k] * sn[k]), zs, result: &zs) }
        }
        for i in 0..<count { (pts[i], ks[i]) = project(SIMD3(px[i], zs[i], pz[i]), view, rc, world: world) }

        let lw = rc.unit * 0.8
        func colour(_ i: Int) -> SIMD4<Float> {
            let h = min(1, abs(zs[i]) * 4)
            let t: Float = s.colorBy == .frequency ? rad[i] * 0.8 : h
            return rc.col(t + rc.phase, 0.3 + 0.7 * h)
        }
        if s.style != .points {
            for r in 1..<ringStarts.count - 1 {
                let a0 = ringStarts[r], a1 = ringStarts[r + 1]
                for i in a0..<a1 {
                    let j = i + 1 < a1 ? i + 1 : a0                         // close the ring
                    f.line(pts[i], pts[j], colour(i), lw * ks[i], depth: 0.5 * (ks[i] + ks[j]))
                }
            }
        }
        if s.style != .lines {
            for i in 0..<count { f.dot(pts[i], lw * 0.9 * ks[i], colour(i), square: s.segmented, depth: ks[i]) }
        }
    }

    /// Concentric rings of points (spacing ~even over the disc) and each mode's radial/angular shape.
    private func setup(_ want: Int) {
        let rings = max(4, Int((Double(want) / .pi).squareRoot()))
        guard rings != builtRings else { return }
        builtRings = rings
        px = [0]; pz = [0]; rad = [0]; ringStarts = [0]
        var th: [Float] = [0]
        for r in 1...rings {
            ringStarts.append(px.count)
            let rr = Float(r) / Float(rings)
            let n = max(6, Int(2 * Float.pi * Float(r)))
            for k in 0..<n {
                let a = 2 * Float.pi * (Float(k) + (r % 2 == 0 ? 0.5 : 0)) / Float(n)
                px.append(rr * cos(a)); pz.append(rr * sin(a)); rad.append(rr); th.append(a)
            }
        }
        ringStarts.append(px.count)
        count = px.count
        let radial = Self.modes.map { mode -> [Float] in
            var peak: Double = 1e-9
            for k in 0...200 { peak = max(peak, abs(jn(Int32(mode.m), mode.j * Double(k) / 200))) }
            return rad.map { Float(jn(Int32(mode.m), mode.j * Double($0)) / peak) }
        }
        shapeC = Self.modes.indices.map { k in (0..<count).map { radial[k][$0] * cos(Float(Self.modes[k].m) * th[$0]) } }
        shapeS = Self.modes.indices.map { k in (0..<count).map { radial[k][$0] * sin(Float(Self.modes[k].m) * th[$0]) } }
    }
}
