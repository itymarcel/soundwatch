import Accelerate
import Foundation
import simd

// MARK: - Splashs (ferrofluid pool)

/// A dish of ferrofluid over an electromagnet that the bass drives, simulated from the physics of the material and
/// raymarched in 3D (ferroFrag).
///
/// Ferrofluid = magnetite nanoparticles (~10 nm, coated with a surfactant) in a carrier oil (developed at NASA in the
/// 1960s to move rocket fuel without gravity). It's superparamagnetic: its magnetisation follows the field without
/// remanence and saturates along the Langevin curve M = Mₛ·L(ξ), L(ξ) = coth ξ − 1/ξ. What the model uses:
///
/// 1. **Mound.** The magnetic pressure μ₀∫M dH pulls the fluid towards the strongest field (over the coil) against
///    gravity, so it gathers into a mound that grows narrower and taller with the current and slumps back when the
///    current drops (viscous, so it lags). Its volume stays the same.
/// 2. **Surface waves and the Rosensweig instability.** Small ripples η on the surface obey the dispersion relation
///    (Cowley & Rosensweig 1967) ω² = g·k + (σ/ρ)·k³ − (μ₀M²/ρ)·k² (deep fluid): gravity and surface tension restore
///    the surface, the normal magnetisation destabilises it. Above the critical magnetisation M꜀² = 2√(ρgσ)/μ₀ the
///    modes around the capillary wavenumber k꜀ = √(ρg/σ) grow: spikes, about 2π/k꜀ apart. The linear part is solved
///    per Fourier mode (exact oscillator rotation + viscous damping ∝ k²); the magnetic term varies with the local
///    field, so it's applied in real space (−m(x)·∇²η). The field concentrates at raised points (field focusing), so
///    the magnetic pull grows with the local height: −m(x)(1 + β·η)∇²η. That nonlinearity is what picks the
///    hexagonal spike lattice of real ferrofluid (an η² term alone only lifted the whole fluid; without any, it formed
///    stripes); a cubic term saturates the spike height. Checked offline: 1.05× critical stays flat, 1.2× gives a
///    small hexagon of spikes over the coil, 1.45× about 20 spikes spreading outward.
/// 3. **Field.** The coil's field falls off from its axis like a dipole's; with the Langevin curve the magnetisation
///    saturates over the coil, so spikes first appear in the middle and spread outward as the current rises.
///
/// Units: dish radius 1, heights in the same units, time in seconds. The grid spans ±`extent` (the fluid stays near
/// the middle), so the spikes get ~11 cells each.
final class FerroViz: Visualizer {
    static let n = 128
    static let extent: Float = 0.72
    private static let log2n: vDSP_Length = 7
    private let fft = vDSP_create_fftsetup(7, FFTRadix(kFFTRadix2))!

    // Fourier state of the ripple height η and its rate of change
    private var er = [Float](repeating: 0, count: n * n), ei = [Float](repeating: 0, count: n * n)
    private var vr = [Float](repeating: 0, count: n * n), vi = [Float](repeating: 0, count: n * n)
    // per mode: restoring ω (gravity + surface tension), damping, low-pass for the real-space forcing
    private var omega = [Float](repeating: 0, count: n * n)
    private var damp = [Float](repeating: 0, count: n * n)
    private var lowpass = [Float](repeating: 0, count: n * n)
    // real-space work arrays
    private var eta = [Float](repeating: 0, count: n * n)
    private var force = [Float](repeating: 0, count: n * n)
    private var wr = [Float](repeating: 0, count: n * n), wi = [Float](repeating: 0, count: n * n)
    private var height = [Float](repeating: 0, count: n * n)
    private var blur = [Float](repeating: 0, count: n * n)
    private var tmp = [Float](repeating: 0, count: n * n)
    // per frame: fluid thickness of the mound and the local magnetic coefficient m(x)
    private var z0 = [Float](repeating: 0, count: n * n)
    private var mField = [Float](repeating: 0, count: n * n)

    // Material constants (dish units). k꜀ = √(g/s) ≈ 52 → spikes ~0.12 apart; ω(k꜀) ≈ 42/s (ripples ~0.15 s).
    private let g: Float = 17
    private let s: Float = 0.0063
    private var mCrit: Float { 2 * sqrt(g * s) }

    private var onsets = Onsets()
    private var coil: Float = 0          // coil current, 0…~1.3 (follows the bass)
    private var width = SmoothValue()    // mound radius
    private var bounce = SmoothValue()   // the mound's jump on kicks
    private var center = SIMD2<Float>(0, 0)
    private var t: Float = 0
    private var avg: Float = 0.1, peak: Float = 0.2
    private var rng = SplitMix(seed: 0xFE770)
    private var impulses: [(p: SIMD2<Float>, r: Float, a: Float)] = []
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var frame = 0

    init() {
        let n = Self.n
        let kc = sqrt(g / s)
        for y in 0..<n {
            for x in 0..<n {
                let kx = Float(x < n / 2 ? x : x - n) * .pi / Self.extent, ky = Float(y < n / 2 ? y : y - n) * .pi / Self.extent
                let k = sqrt(kx * kx + ky * ky)
                let i = y * n + x
                omega[i] = sqrt(g * k + s * k * k * k)
                damp[i] = 2.5 + 0.0015 * k * k               // viscous damping ∝ k² (ferrofluid is a thick oil)
                lowpass[i] = exp(-pow(k / (2.6 * kc), 4))
            }
        }
        width.x = 0.6
        // a little noise so the pattern has something to grow from
        for i in 0..<(n * n) { er[i] = (Float(rng.unit()) - 0.5) * 2; ei[i] = (Float(rng.unit()) - 0.5) * 2 }
        er[0] = 0; ei[0] = 0
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    private func rnd() -> Float { Float(rng.unit()) }

    /// Langevin function: magnetisation of a superparamagnet relative to saturation.
    private static func langevin(_ x: Float) -> Float { x < 1e-3 ? x / 3 : 1 / tanh(x) - 1 / x }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let st = rc.s
        let dt = Float(min(rc.dt, 1.0 / 20))
        let n = Self.n
        let volume = 0.03 * Float(st.ferroFluid)
        let splash = Float(st.ferroSplash)
        let magnet = Float(st.ferroSpikes)

        if !rc.frozen {
            t += dt
            // coil current = the bass, relative to its own recent level (reacts the same whatever Gain is)
            let bass = min(1.5, rc.analyzer.level(20, 140, s: st))
            avg += (bass - avg) * (1 - exp(-dt / 1.5))
            peak = max(bass, peak * exp(-dt / 4))
            let steady = min(1, bass / max(peak, 0.05))
            let rise = min(1, max(0, bass - avg) / max(peak - avg, 0.03))
            let target = (0.55 * steady + 0.45 * rise) * Float(st.reach)
            coil += (target - coil) * (1 - exp(-dt * (target > coil ? 25 : 6)))
            for hit in onsets.step(rc) {
                let a = hit.strength * splash
                if hit.band == 0 {
                    bounce.v += 2.5 * a
                    coil = min(1.6, coil + 0.25 * a)
                } else {
                    // snare / hat: a drop-like jolt somewhere on the fluid
                    let ang = rnd() * 2 * .pi, d = sqrt(rnd()) * width.x * 0.8
                    impulses.append((center + SIMD2(cos(ang), sin(ang)) * d, hit.band == 1 ? 0.07 : 0.035, (hit.band == 1 ? -9 : -5) * a))
                }
            }
            _ = bounce.step(to: 0, dt: dt, omega: 9)
            // the fluid gathers over the coil when the field is on and slumps back out when it's off (viscous lag)
            let mc = Self.langevin(4 * coil) / Self.langevin(4)
            _ = width.step(to: 0.68 - 0.24 * mc, dt: dt, omega: 5)
            let motion = Float(st.motion)
            let wander = SIMD2(sin(0.23 * t), cos(0.17 * t + 1)) * 0.03 * motion
            center += (wander - center) * (1 - exp(-dt * 1.5))

            prepareField(magnet: magnet, volume: volume)
            let steps = max(1, min(8, Int((dt * 300).rounded(.up))))
            for _ in 0..<steps { substep(dt / Float(steps)) }
        }

        // visible height = mound + ripples (spikes made pointier, troughs shallower), clipped at the dish
        buildHeight(volume: volume)
        var data = [Float](repeating: 0, count: n * n * 4)
        let dx: Float = 2 * Self.extent / Float(n)
        // ambient occlusion from how much higher the surroundings are (valleys between spikes, the dish at the fluid)
        boxBlur(height, into: &blur, radius: 4)
        var hmax: Float = 0
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let h = height[i]
                hmax = max(hmax, h)
                let hl = height[y * n + max(0, x - 1)], hr = height[y * n + min(n - 1, x + 1)]
                let hd = height[max(0, y - 1) * n + x], hu = height[min(n - 1, y + 1) * n + x]
                data[i * 4] = h
                data[i * 4 + 1] = (hr - hl) / (2 * dx)
                data[i * 4 + 2] = (hu - hd) / (2 * dx)
                data[i * 4 + 3] = max(0.25, min(1, 1 - 9 * max(0, blur[i] - h)))
            }
        }
        frame += 1
        if let dump = ProcessInfo.processInfo.environment["AUDIOWATCH_FERRO_DUMP"], frame == 400 {
            // debug: the height map seen from above as an 8-bit PGM (white = high)
            var bytes = [UInt8]("P5 \(n) \(n) 255\n".utf8)
            let top = max(height.max() ?? 1, 1e-4)
            for y in (0..<n).reversed() { for x in 0..<n { bytes.append(UInt8(max(0, min(255, height[y * n + x] / top * 255)))) } }
            try? Data(bytes).write(to: URL(fileURLWithPath: dump))
        }
        if Self.trace && frame % 30 == 0 {
            var lo: Float = 0, hi: Float = 0
            vDSP_minv(eta, 1, &lo, vDSP_Length(n * n)); vDSP_maxv(eta, 1, &hi, vDSP_Length(n * n))
            print(String(format: "FERRO coil=%.2f width=%.2f eta=%.3f…%.3f hmax=%.3f", coil, width.x, lo, hi, hmax))
        }

        var u = ShaderModeUniforms()
        u.viewPt = rc.size
        u.center = rc.center
        u.pan = rc.camera.pan
        u.zoom = rc.camera.zoom
        u.time = Float(rc.time)
        u.phase = rc.phase
        u.world = rc.minDim * 0.55 * Float(st.zoom)
        u.count = Float(n)
        let view = rotX(0.85) * rc.camera.rotation
        u.view0 = SIMD4(view[0][0], view[1][0], view[2][0], 0)
        u.view1 = SIMD4(view[0][1], view[1][1], view[2][1], 0)
        u.view2 = SIMD4(view[0][2], view[1][2], view[2][2], 0)
        u.p0 = SIMD4(3.6, st.chromeEnv.exposure, Float(st.chromeTurn), Float(st.chromeBlur))
        u.p1 = SIMD4(hmax + 0.01, Float(st.chromeTint), rc.phase + 0.5, Self.extent)
        f.shaderMode = ShaderModeDraw(kind: .ferro, u: u, data: data)
    }

    /// Mound profile: (1 − r²/w²)^1.5 holding `volume` (its integral is π w² A / 2.5).
    private func mound(_ p: SIMD2<Float>, volume: Float) -> Float {
        let w = width.x
        let a = 2.5 * volume / (.pi * w * w) * (1 + 0.25 * bounce.x)
        let q = 1 - simd_length_squared(p - center) / (w * w)
        return q > 0 ? a * q * sqrt(q) : 0
    }

    /// Mound thickness and m(x) = μ₀M²/ρ for this frame: Langevin magnetisation of the coil's dipole-like field;
    /// its peak over the coil centre is 0.9…1.6× critical at full current (Magnet 0…1).
    private func prepareField(magnet: Float, volume: Float) {
        let n = Self.n
        let dx: Float = 2 * Self.extent / Float(n)
        let mPeak = mCrit * (0.9 + 0.7 * magnet) / (Self.langevin(4) * Self.langevin(4))
        for y in 0..<n {
            let py = -Self.extent + (Float(y) + 0.5) * dx
            for x in 0..<n {
                let p = SIMD2(-Self.extent + (Float(x) + 0.5) * dx, py)
                let i = y * n + x
                z0[i] = mound(p, volume: volume)
                let r2 = simd_length_squared(p - center)
                let field = coil / pow(1 + r2 / 0.16, 1.5)       // on-axis-normalised dipole falloff
                let mag = Self.langevin(4 * field)
                mField[i] = mPeak * mag * mag * min(1, z0[i] / 0.03)   // thin fluid can't hold tall spikes
            }
        }
    }

    private func substep(_ h: Float) {
        let n = Self.n, nn = n * n
        let dx: Float = 2 * Self.extent / Float(n)
        let idx2 = 1 / (dx * dx)
        inverse(er, ei, into: &eta)
        // field focusing at raised points (β) → hexagonal spikes; cubic term: spike height saturates (~0.05-0.1)
        let beta: Float = 50, kCube: Float = 2_000_000
        for y in 0..<n {
            let yu = ((y + 1) % n) * n, yd = ((y + n - 1) % n) * n, yr = y * n
            for x in 0..<n {
                let i = yr + x
                let e = eta[i]
                if z0[i] < 0.004 {                                // no fluid here: the ripple field is held flat
                    force[i] = -400 * e
                    continue
                }
                let lap = (eta[yr + (x + 1) % n] + eta[yr + (x + n - 1) % n] + eta[yu + x] + eta[yd + x] - 4 * e) * idx2
                var fv = -mField[i] * (1 + beta * e) * lap - kCube * e * e * e
                fv += (rnd() - 0.5) * 0.4                         // thermal agitation keeps the pattern alive
                force[i] = fv
            }
        }
        if !impulses.isEmpty {
            for y in 0..<n {
                let py = -Self.extent + (Float(y) + 0.5) * dx
                for x in 0..<n where z0[y * n + x] >= 0.004 {
                    let p = SIMD2(-Self.extent + (Float(x) + 0.5) * dx, py)
                    for imp in impulses {
                        force[y * n + x] += imp.a / h * exp(-simd_length_squared(p - imp.p) / (imp.r * imp.r)) * 0.02
                    }
                }
            }
            impulses.removeAll()
        }
        // forcing → Fourier, low-passed (keeps the explicit magnetic term stable at short wavelengths)
        forward(force, into: &wr, &wi)
        for i in 0..<nn {
            let lp = lowpass[i] * h
            vr[i] += wr[i] * lp
            vi[i] += wi[i] * lp
            // free oscillation of each mode under gravity + surface tension, exactly, then viscous damping
            let w = omega[i]
            let dmp = exp(-damp[i] * h)
            if w < 1e-4 { er[i] = 0; ei[i] = 0; vr[i] = 0; vi[i] = 0; continue }
            let c = cos(w * h), sn = sin(w * h)
            let er2 = er[i] * c + vr[i] / w * sn, ei2 = ei[i] * c + vi[i] / w * sn
            let vr2 = -er[i] * w * sn + vr[i] * c, vi2 = -ei[i] * w * sn + vi[i] * c
            er[i] = er2 * dmp; ei[i] = ei2 * dmp
            vr[i] = vr2 * dmp; vi[i] = vi2 * dmp
        }
    }

    private func buildHeight(volume: Float) {
        let n = Self.n
        let dx: Float = 2 * Self.extent / Float(n)
        inverse(er, ei, into: &eta)
        for y in 0..<n {
            let py = -Self.extent + (Float(y) + 0.5) * dx
            for x in 0..<n {
                let px = -Self.extent + (Float(x) + 0.5) * dx
                let p = SIMD2(px, py)
                let i = y * n + x
                if simd_length_squared(p) > 0.96 * 0.96 { height[i] = 0; continue }
                let z0 = mound(p, volume: volume)
                if z0 <= 0 { height[i] = 0; continue }
                let e = eta[i]
                let shaped = e > 0 ? e * 1.3 : e * 0.6   // pointed tips, rounded valleys
                height[i] = max(0, z0 + shaped * min(1, z0 / 0.03))
            }
        }
    }

    private func boxBlur(_ src: [Float], into dst: inout [Float], radius r: Int) {
        let n = Self.n
        let inv = 1 / Float(2 * r + 1)
        for y in 0..<n {
            var acc: Float = 0
            for k in -r...r { acc += src[y * n + max(0, min(n - 1, k))] }
            for x in 0..<n {
                tmp[y * n + x] = acc * inv
                acc += src[y * n + min(n - 1, x + r + 1)] - src[y * n + max(0, x - r)]
            }
        }
        for x in 0..<n {
            var acc: Float = 0
            for k in -r...r { acc += tmp[max(0, min(n - 1, k)) * n + x] }
            for y in 0..<n {
                dst[y * n + x] = acc * inv
                acc += tmp[min(n - 1, y + r + 1) * n + x] - tmp[max(0, y - r) * n + x]
            }
        }
    }

    // MARK: FFT helpers (vDSP, unscaled forward; inverse divided by N²)

    private func forward(_ src: [Float], into re: inout [Float], _ im: inout [Float]) {
        let nn = Self.n * Self.n
        re = src
        for i in 0..<nn { im[i] = 0 }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(fft, &sc, 1, 0, Self.log2n, Self.log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    private func inverse(_ re: [Float], _ im: [Float], into out: inout [Float]) {
        var r2 = re, i2 = im
        let nn = Self.n * Self.n
        r2.withUnsafeMutableBufferPointer { rp in
            i2.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(fft, &sc, 1, 0, Self.log2n, Self.log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        var scale = 1 / Float(nn)
        vDSP_vsmul(r2, 1, &scale, &out, 1, vDSP_Length(nn))
    }
}
