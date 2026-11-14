import Foundation
import simd

// MARK: - Real Metaballs (ferrofluid in water)

/// The ferrofluid speaker: ferrofluid in water inside a glass sphere, with 3–13 electromagnets spread over a sphere
/// around it. The signal chain follows the device: each coil gets its own slice of the spectrum (log-spaced from
/// 40 Hz to 16 kHz, rotated by Band) → its envelope sets the PWM duty cycle (× the dial, "Magnet") → the coil current
/// follows the duty with the coil's time constant τ = L/R → field → fluid. The fluid itself is a particle simulation on
/// the GPU (`FerroGPU`); only the liquid is drawn (raymarched from its density volume, `metaballsFrag`).
final class MetaballsViz: Visualizer {
    /// The density the surface sits at (the volume is 1 inside the liquid).
    static let iso: Float = 0.5
    static let maxCoils = 13

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
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var frame = 0

    /// The spectrum slice of coil k of n (log-spaced 40 Hz … 16 kHz), rotated by `band` (0…6).
    static func slice(_ k: Int, of n: Int, band: Double) -> (Double, Double) {
        let shift = Int((band / 7 * Double(n)).rounded())
        let s = Double((k + shift) % n)
        let ratio = 16_000.0 / 40.0
        return (40 * pow(ratio, s / Double(n)), 40 * pow(ratio, (s + 1) / Double(n)))
    }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let st = rc.s
        let dt = Float(min(rc.dt, 1.0 / 20))
        coils = max(3, min(Self.maxCoils, Int(st.mbMagnets.rounded())))
        if !rc.frozen { drive(st, rc, dt) }
        frame += 1
        if Self.trace && frame % 30 == 0 {
            print("MBALLS current=" + current[0..<coils].map { String(format: "%.2f", $0) }.joined(separator: ","))
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
        let out = (0..<coils).map { current[$0] + 1.5 * pulse[$0] }
        draw.ferro = FerroInput(currents: out, fluid: Float(st.mbFluid), dt: dt, frozen: rc.frozen,
                                burst: pulse[0..<coils].max() ?? 0, home: Float(st.mbHome))
        f.shaderMode = draw
    }

    /// Band envelope → PWM duty (Hold) → × dial → coil current with τ = L/R.
    private func drive(_ st: VizSettings, _ rc: RenderContext, _ dt: Float) {
        let tau = Float(max(5, st.mbLag)) / 1000
        // the dial scales the coil current; 0.8 (default) = full current at full duty. Above that the coil saturates
        // (soft limit 1.5)
        let d0 = Float(st.mbMagnet) * 1.25
        let dial: Float = d0 <= 1 ? d0 : 1 + 0.5 * tanh((d0 - 1) / 0.5)
        let hold = Float(max(0, min(1, st.mbHold)))
        let thr: Float = 0.04 + 0.3 * hold
        let minT: Float = 1.2 * hold
        let reach = Float(st.reach)
        let bursts = Float(max(0, min(1, st.mbBurst)))
        var bestJump: Float = 0, best = -1
        let follow: Float = 1 - exp(-dt / tau)
        for k in 0..<Self.maxCoils {
            var target: Float = 0
            if k < coils {
                // the envelope relative to its own recent level (drives the coil the same at any Gain)
                let (lo, hi) = Self.slice(k, of: coils, band: st.mbBand)
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
        // a burst: only the hardest hit fires, then a cool-down (shorter with more Bursts) so they stay special
        cooldown -= dt
        let burstThr: Float = 0.75 - 0.4 * bursts
        if bursts > 0.01 && best >= 0 && bestJump > burstThr && cooldown <= 0 {
            pulse[best] = min(1, 0.5 + (bestJump - burstThr) / 0.3)
            cooldown = 2.2 - 1.6 * bursts
            if Self.trace { print(String(format: "MBALLS burst coil=%d strength=%.2f", best, pulse[best])) }
        }
    }
}
