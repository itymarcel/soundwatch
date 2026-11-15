import Foundation
import simd

// MARK: - Real Metaballs (ferrofluid in water)

/// The ferrofluid speaker: ferrofluid in water inside a glass sphere, with 3–24 electromagnets spread over a sphere
/// around it. The signal chain follows the device: each coil gets its own slice of the spectrum (log-spaced from
/// 30 Hz to 17 kHz, handed out to the coils in a shuffled order) → its envelope sets the PWM duty cycle (× the dial, "Magnet") → the coil current
/// follows the duty with the coil's time constant τ = L/R → field → fluid. The fluid itself is a particle simulation on
/// the GPU (`FerroGPU`); only the liquid is drawn (raymarched from its density volume, `metaballsFrag`).
final class MetaballsViz: Visualizer {
    /// The density the surface sits at (the volume is 1 inside the liquid).
    static let iso: Float = 0.5
    static let maxCoils = 24

    /// Per coil: current, and its band envelope's running average and peak.
    private var current = [Float](repeating: 0, count: maxCoils)
    private var avg = [Float](repeating: 0.1, count: maxCoils), peak = [Float](repeating: 0.2, count: maxCoils)
    /// Held duty per coil and how long it has been held.
    private var held = [Float](repeating: 0, count: maxCoils), heldFor = [Float](repeating: 0, count: maxCoils)
    private var coils = 6
    /// Hits: each coil's envelope followed fast (a sudden jump above it = a hit) and the pulse a hit sets off.
    private var fast = [Float](repeating: 0, count: maxCoils), pulse = [Float](repeating: 0, count: maxCoils)
    /// Time until the next burst may fire (they should stay special).
    private var cooldown: Float = 0
    /// Rest: how long every coil has been (nearly) off, and how far the liquid has settled into a ball (0…1).
    private var quietFor: Float = 0, rest: Float = 0
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var frame = 0

    /// Which slice of the spectrum each coil gets: a shuffle of 0..<coils (the same one every time for a given count),
    /// so neighbouring bands sit on different sides of the sphere.
    private var bandOf: [Int] = []

    /// Slice s of n of the spectrum (log-spaced 30 Hz … 17 kHz).
    static func slice(_ s: Int, of n: Int) -> (Double, Double) {
        let ratio = 17_000.0 / 30.0
        return (30 * pow(ratio, Double(s) / Double(n)), 30 * pow(ratio, Double(s + 1) / Double(n)))
    }

    /// A fixed shuffle of 0..<n (Fisher–Yates on a splitmix64 stream seeded by n).
    static func shuffledBands(_ n: Int) -> [Int] {
        var state = UInt64(n) &* 0x9E3779B97F4A7C15 &+ 0x1234567
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        var a = Array(0..<n)
        for i in stride(from: n - 1, to: 0, by: -1) { a.swapAt(i, Int(next() % UInt64(i + 1))) }
        return a
    }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let st = rc.s
        let dt = Float(min(rc.dt, 1.0 / 20))
        coils = max(3, min(Self.maxCoils, Int(st.mbMagnets.rounded())))
        if bandOf.count != coils { bandOf = Self.shuffledBands(coils) }
        if !rc.frozen {
            drive(st, rc, dt)
            // no music: after a moment the liquid is gathered into a ball and drawn as a perfect sphere (surface tension
            // wins); the first coil current lets it go again at once
            let active = (0..<coils).map { current[$0] + pulse[$0] }.max() ?? 0
            quietFor = active < 0.05 ? quietFor + dt : 0
            if quietFor > 0 {
                let t = max(0, min(1, (quietFor - 0.3) / 2.2))
                rest = max(rest, t * t * (3 - 2 * t))
            } else {
                rest = max(0, rest - dt / 0.12)
            }
        }
        frame += 1
        if Self.trace && frame % 30 == 0 {
            print(String(format: "MBALLS f=%d rest=%.2f current=", frame, rest) + current[0..<coils].map { String(format: "%.2f", $0) }.joined(separator: ","))
        }

        var u = ShaderModeUniforms()
        u.viewPt = rc.size
        u.center = rc.center
        u.pan = rc.camera.pan
        u.zoom = rc.camera.zoom
        u.time = Float(rc.time)
        u.phase = rc.phase
        u.world = rc.minDim * 0.47 * Float(st.zoom)
        u.count = 128
        let view = rc.camera.rotation
        u.view0 = SIMD4(view[0][0], view[1][0], view[2][0], 0)
        u.view1 = SIMD4(view[0][1], view[1][1], view[2][1], 0)
        u.view2 = SIMD4(view[0][2], view[1][2], view[2][2], 0)
        u.p0 = SIMD4(3.6, st.chromeEnv.exposure, Float(st.chromeTurn), Float(st.chromeBlur))
        u.p1 = SIMD4(Float(st.chromeTint), rc.phase + 0.5, 2, Self.iso)
        var draw = ShaderModeDraw(kind: .metaballs, u: u, data: [0])
        // a hit overdrives its coil for a moment and makes the liquid burst apart
        let amt = Float(max(0, min(2, st.mbBurstAmt)))
        let out = (0..<coils).map { current[$0] + 1.5 * amt * pulse[$0] }
        draw.ferro = FerroInput(currents: out, fluid: Float(st.mbFluid), dt: dt, frozen: rc.frozen,
                                burst: amt * (pulse[0..<coils].max() ?? 0), home: Float(st.mbHome), rest: rest)
        f.shaderMode = draw
    }

    /// Band envelope → PWM duty (Hold) → × dial → coil current with τ = L/R.
    private func drive(_ st: VizSettings, _ rc: RenderContext, _ dt: Float) {
        let tau = Float(max(5, st.mbLag)) / 1000
        // the dial scales the coil current; 0.8 (default) = full current at full duty. Above that the coil saturates
        // (soft limit 1.5); the last stretch of the slider (1.8…2) adds a little on top, since the limit is flat there
        let d0 = Float(st.mbMagnet) * 1.25
        let dial: Float = (d0 <= 1 ? d0 : 1 + 0.5 * tanh((d0 - 1) / 0.5)) + 0.75 * max(0, Float(st.mbMagnet) - 1.8)
        let hold = Float(max(0, min(1, st.mbHold)))
        let thr: Float = 0.04 + 0.3 * hold
        let minT: Float = 1.2 * hold
        let reach = Float(st.reach)
        let thrSetting = Float(max(0, min(1, st.mbBurstThr)))
        let on = st.mbBurstAmt > 0.01
        var bestJump: Float = 0, best = -1
        let follow: Float = 1 - exp(-dt / tau)
        for k in 0..<Self.maxCoils {
            var target: Float = 0
            if k < coils {
                // the envelope relative to its own recent level (drives the coil the same at any Gain)
                let (lo, hi) = Self.slice(bandOf[k], of: coils)
                let env: Float = min(1.5, rc.analyzer.level(lo, hi, s: st))
                // a hit: the envelope jumps well above its fast-following copy (relative to the band's recent peak)
                let jump = (env - fast[k]) / max(peak[k], 0.05)
                fast[k] += (env - fast[k]) * (1 - exp(-dt / 0.05))
                if jump > bestJump { bestJump = jump; best = k }
                avg[k] += (env - avg[k]) * (1 - exp(-dt / 1.5))
                peak[k] = max(env, peak[k] * exp(-dt / 4))
                let steady: Float = min(1, env / max(peak[k], 0.05))
                let rise: Float = min(1, max(0, env - avg[k]) / max(peak[k] - avg[k], 0.03))
                let duty: Float = min(1, max(0, (0.15 * steady + 0.85 * rise) * 1.25 * reach))
                // Hold: a clear rise (a hit) switches the coil at once; otherwise it keeps its level for a while
                heldFor[k] += dt
                if duty > held[k] + thr || (heldFor[k] >= minT && abs(duty - held[k]) > thr) || hold < 0.01 {
                    held[k] = duty; heldFor[k] = 0
                }
                target = held[k] * dial
            }
            current[k] += (target - current[k]) * follow
            pulse[k] *= exp(-dt / 0.12)
        }
        // a burst: only the hardest hit fires, then a cool-down (shorter with a lower threshold) so they stay special.
        // The pulse follows the hit's size (just over the threshold = half, well over = full); strength scales it later.
        cooldown -= dt
        let burstThr: Float = 0.25 + 0.9 * thrSetting
        if on && best >= 0 && bestJump > burstThr && cooldown <= 0 {
            pulse[best] = min(1, 0.5 + (bestJump - burstThr) / 0.3)
            cooldown = 0.5 + 2 * thrSetting
            if Self.trace { print(String(format: "MBALLS burst coil=%d strength=%.2f", best, pulse[best])) }
        }
    }
}
