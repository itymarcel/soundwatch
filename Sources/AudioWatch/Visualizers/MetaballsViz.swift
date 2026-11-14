import Accelerate
import Foundation
import simd

// MARK: - Real Metaballs (ferrofluid in water)

/// The ferrofluid speaker: a blob of ferrofluid in water in front of an electromagnet (or up to 5). The signal chain follows the
/// device: an MSGEQ7-style equaliser picks out one of 7 bands per coil → its envelope sets the PWM duty cycle (× the dial,
/// "Magnet") → the coil current follows the duty with the coil's time constant τ = L/R (I → duty as 1 − e^(−t/τ),
/// which is why the fluid's motion looks smoothed) → field → fluid. The fluid itself is `FerroBlobSim`; only the
/// liquid is drawn (raymarched from its density volume, `metaballsFrag`).
///
/// The simulation and the volume run on a background queue; each frame blends the two newest volumes.
final class MetaballsViz: Visualizer {
    static let nx = 128, ny = 128, nz = 45
    /// The density the surface sits at.
    static let iso: Float = 0.35
    /// MSGEQ7 band edges (centres 63, 160, 400, 1k, 2.5k, 6.25k, 16k Hz).
    static let bandEdges: [Double] = [40, 100, 250, 630, 1600, 4000, 10000, 20000]

    private let sim = FerroBlobSim()
    private let queue = DispatchQueue(label: "soundwatch.metaballs", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    /// Fixed simulation step; the frame blends the last two simulated fields at its own time (smooth at any frame rate,
    /// one step behind). Handing the sim whatever time had passed made it deliver irregular steps → stutter.
    static let simStep: Float = 1.0 / 60
    private var simClock: Double = 0      // time the newest field is at
    private var showClock: Double = -1    // time being shown
    private var fieldA: [Float] = [], fieldB: [Float] = []
    private var mixBuf: [Float] = [], halfBuf: [UInt16] = []
    private var depth: Float = 0.7

    /// Per coil: current, and its band envelope's running average and peak.
    private var current: [Float] = [0, 0, 0, 0, 0]
    private var avg: [Float] = [Float](repeating: 0.1, count: 5), peak: [Float] = [Float](repeating: 0.2, count: 5)
    private var coils = 1
    /// Held duty per coil and how long it has been held.
    private var held: [Float] = [0, 0, 0, 0, 0], heldFor: [Float] = [0, 0, 0, 0, 0]
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var frame = 0
    private var updates = 0, simMs: Double = 0, stepDt: Float = 0

    init() { depth = sim.depth }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let st = rc.s
        let dt = Float(min(rc.dt, 1.0 / 20))
        if !rc.frozen {
            // Each coil has its own MSGEQ7 band (several coils spread over the 7, starting at Band); its envelope,
            // relative to its own recent level (so it drives the coil the same at any Gain), is the PWM duty
            coils = max(1, min(5, Int(st.mbMagnets.rounded())))
            let first = max(0, min(6, Int(st.mbBand.rounded())))
            let tau = Float(max(5, st.mbLag)) / 1000
            // the dial scales the coil current; 0.8 (default) = full current at full duty. Above that the coil
            // saturates (soft limit 1.5): turning it up pulls harder, but quiet moments still let the fluid go, so the
            // shape keeps switching (a limit after the signal flattened it into a constant field)
            let d0 = Float(st.mbMagnet) * 1.25
            let dial = d0 <= 1 ? d0 : 1 + 0.5 * tanh((d0 - 1) / 0.5)
            for k in 0..<5 {
                var target: Float = 0
                if k < coils {
                    let b = coils == 1 ? first : (first + Int((Float(k) * 7 / Float(coils)).rounded())) % 7
                    let env = min(1.5, rc.analyzer.level(Self.bandEdges[b], Self.bandEdges[b + 1], s: st))
                    avg[k] += (env - avg[k]) * (1 - exp(-dt / 1.5))
                    peak[k] = max(env, peak[k] * exp(-dt / 4))
                    let steady = min(1, env / max(peak[k], 0.05))
                    let rise = min(1, max(0, env - avg[k]) / max(peak[k] - avg[k], 0.03))
                    let duty = min(1, max(0, (0.15 * steady + 0.85 * rise) * 1.25 * Float(st.reach)))
                    // Hold: a clear rise (a hit) switches the coil at once; otherwise it keeps its level for a while
                    // and only then follows a clear change. Steps in the current = the fluid jumps to a new
                    // arrangement and stays there, instead of wobbling with every wiggle of the envelope.
                    let hold = Float(max(0, min(1, st.mbHold)))
                    let thr = 0.04 + 0.3 * hold, minT = 1.2 * hold
                    heldFor[k] += dt
                    if duty > held[k] + thr || (heldFor[k] >= minT && abs(duty - held[k]) > thr) || hold < 0.01 {
                        held[k] = duty; heldFor[k] = 0
                    }
                    target = held[k] * dial
                }
                // the coil current follows the duty with τ = L/R
                current[k] += (target - current[k]) * (1 - exp(-dt / tau))
            }
            showClock += Double(dt)
            // never show past the newest field (if the sim falls behind it slows down instead of jumping), and
            // never fall more than a couple of steps back
            showClock = max(simClock - 2.5 * Double(Self.simStep), min(simClock, showClock))
            if showClock > simClock - Double(Self.simStep) { step(fluid: Float(st.mbFluid)) }
        }
        frame += 1
        if Self.trace && frame % 30 == 0 { print("MBALLS current=" + current[0..<coils].map { String(format: "%.2f", $0) }.joined(separator: ",") + " drops=\(sim.count)"
                + String(format: " updates/30f=%d simMs=%.1f stepDt=%.1fms", updates, simMs / Double(max(1, updates)), stepDt * 1000 / Float(max(1, updates))))
            updates = 0; simMs = 0; stepDt = 0 }

        let vol = blended()
        var u = ShaderModeUniforms()
        u.viewPt = rc.size
        u.center = rc.center
        u.pan = rc.camera.pan
        u.zoom = rc.camera.zoom
        u.time = Float(rc.time)
        u.phase = rc.phase
        u.world = rc.minDim * 0.47 * Float(st.zoom)
        u.count = Float(Self.nx)
        let view = rc.camera.rotation
        u.view0 = SIMD4(view[0][0], view[1][0], view[2][0], 0)
        u.view1 = SIMD4(view[0][1], view[1][1], view[2][1], 0)
        u.view2 = SIMD4(view[0][2], view[1][2], view[2][2], 0)
        u.p0 = SIMD4(3.6, st.chromeEnv.exposure, Float(st.chromeTurn), Float(st.chromeBlur))
        u.p1 = SIMD4(Float(st.chromeTint), rc.phase + 0.5, depth, Self.iso)
        var draw = ShaderModeDraw(kind: .metaballs, u: u, data: [0])
        if vol.count == Self.nx * Self.ny * Self.nz {
            draw.volume = vol
            draw.volumeSize = SIMD3(Self.nx, Self.ny, Self.nz)
        }
        f.shaderMode = draw
    }

    /// The field at `showClock`: A (one step before `simClock`) blended towards B (at `simClock`).
    private func blended() -> [UInt16] {
        lock.lock(); defer { lock.unlock() }
        let n = fieldB.count
        guard n > 0 else { return [] }
        if fieldA.count != n { fieldA = fieldB }
        if mixBuf.count != n { mixBuf = [Float](repeating: 0, count: n); halfBuf = [UInt16](repeating: 0, count: n) }
        var a = Float(max(0, min(1, 1 - (simClock - showClock) / Double(Self.simStep))))
        vDSP_vintb(fieldA, 1, fieldB, 1, &a, &mixBuf, 1, vDSP_Length(n))
        mixBuf.withUnsafeMutableBufferPointer { g in
            halfBuf.withUnsafeMutableBufferPointer { o in
                var src = vImage_Buffer(data: g.baseAddress, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                var dst = vImage_Buffer(data: o.baseAddress, height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
                vImageConvert_PlanarFtoPlanar16F(&src, &dst, 0)
            }
        }
        return halfBuf
    }

    /// Runs one fixed step of the simulation on the background queue (unless it's still busy with the last one).
    private func step(fluid: Float) {
        guard !busy else { return }
        busy = true
        let h = Self.simStep, I = Array(current[0..<coils]), n = coils
        queue.async { [self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            sim.setFluid(fluid)
            sim.setCoils(n)
            sim.currents = I
            sim.step(h)
            var grid: [Float] = []
            sim.render(into: &grid, nx: Self.nx, ny: Self.ny, nz: Self.nz, iso: Self.iso)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async { [self] in
                lock.lock(); fieldA = fieldB; fieldB = grid; lock.unlock()
                simClock += Double(h)
                busy = false
                updates += 1; simMs += ms; stepDt += h
            }
        }
    }
}
