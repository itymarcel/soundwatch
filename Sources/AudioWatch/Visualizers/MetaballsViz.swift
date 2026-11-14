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
        draw.ferro = FerroInput(currents: Array(current[0..<coils]), fluid: Float(st.mbFluid), dt: dt, frozen: rc.frozen,
                                 home: Float(st.mbHome))
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
        let follow: Float = 1 - exp(-dt / tau)
        for k in 0..<Self.maxCoils {
            var target: Float = 0
            if k < coils {
                // the envelope relative to its own recent level (drives the coil the same at any Gain)
                let (lo, hi) = Self.slice(k, of: coils, band: st.mbBand)
                let env: Float = min(1.5, rc.analyzer.level(lo, hi, s: st))
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
        }
    }
}
