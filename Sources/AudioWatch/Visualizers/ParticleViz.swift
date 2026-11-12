import Foundation
import simd

/// Chladni-plate cymatics. Like a real plate driven at one frequency, the music's dominant pitch picks ONE
/// plate mode (n, m); a plate's resonant frequency grows with n² + m², so higher pitch → more intricate figure.
/// The mode only changes when the pitch moves clearly, so the sand has time to settle on the nodal lines.
final class CymaticsViz: Visualizer {
    private struct Mode { let n: Int, m: Int, sign: Float; var k: Float { Float(n * n + m * m) } }

    /// Square free-plate modes cos(nπx)cos(mπy) ± cos(mπx)cos(nπy), ordered by resonant frequency.
    private static let modes: [Mode] = {
        var out: [Mode] = []
        for m in 2...12 { for n in 0..<m { for sign: Float in [-1, 1] { out.append(Mode(n: n, m: m, sign: sign)) } } }
        return out.sorted { ($0.k, $0.sign, $0.n) < ($1.k, $1.sign, $1.n) }
    }()

    private var frame: UInt32 = 0
    private var level: Float = 0
    private var logK: Float = log(5)
    private var current = 0
    private var previous = 0
    private var fade: Float = 1
    private var held: Double = 0

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let n = max(1000, Int(s.particleCount))
        let modes = Self.modes
        if !rc.frozen {
            frame &+= 1
            let bins = 48
            let b = rc.analyzer.bands(count: bins, s: s)
            // Pitch estimate: log-frequency centroid weighted by v³ so the loudest region wins.
            var wSum: Float = 0, pos: Float = 0
            for (i, v) in b.enumerated() { let w = v * v * v; wSum += w; pos += w * Float(i) / Float(bins - 1) }
            let lvl = min(1.2, b.max() ?? 0)
            level = Envelope.step(level, lvl, Envelope.coeffs(smoothing: s.smoothing, dt: rc.dt))
            if wSum > 1e-3 {
                let fMin = Float(max(10, s.minFreq))
                let fMax = max(fMin * 1.5, Float(min(s.maxFreq, rc.analyzer.sampleRate / 2 - 1)))
                let hz = fMin * pow(fMax / fMin, pos / wSum)
                // ~130 Hz → simplest figure, ~4 kHz → the finest in the table
                let target = log(min(modes.last!.k, max(4, 4 * pow(hz / 130, 1.05))))
                let k = Float(1 - exp(-rc.dt * 3))
                logK += (target - logK) * k
            }
            held += rc.dt
            fade = min(1, fade + Float(rc.dt / 0.7))
            let want = modes.indices.min { abs(log(modes[$0].k) - logK) < abs(log(modes[$1].k) - logK) } ?? 0
            if want != current && abs(log(modes[want].k) - log(modes[current].k)) > 0.1 && held > 0.6 && fade >= 1 {
                previous = current
                current = want
                fade = 0
                held = 0
            }
        }
        let ma = modes[previous], mc = modes[current]
        let t = fade * fade * (3 - 2 * fade)

        var sim = SimUniforms()
        sim.w0 = SIMD4(Float(ma.n), Float(ma.m), ma.sign, 0)
        sim.w1 = SIMD4(Float(mc.n), Float(mc.m), mc.sign, t)
        sim.shake = rc.frozen ? 0 : 0.2 + level * 1.3
        sim.speed = rc.frozen ? 0 : Float(0.3 + s.motion * 1.5)
        sim.dtScale = Float(rc.dt * 60)
        sim.time = Float(rc.time)
        sim.beat = rc.frozen ? 0 : rc.beat
        sim.level = level
        sim.count = UInt32(n)
        sim.frame = frame
        sim.kind = ParticleKind.cymatics.rawValue
        sim.p0 = Float(s.reach)
        let dom = Float(current) / Float(modes.count - 1)
        let side = rc.minDim * 0.9 * Float(s.zoom) * (1 + 0.04 * rc.beat)
        var d = PartDrawUniforms()
        d.origin = rc.center - SIMD2(side, side) / 2
        d.extent = SIMD2(side, side)
        d.dotR = rc.unit * 0.9 * min(1.2, max(0.25, (200_000 / Float(n)).squareRoot()))
        d.alphaK = n > 200_000 ? max(0.25, pow(200_000 / Float(n), 0.35)) : 1
        d.phase = rc.phase
        d.colorByFreq = s.colorBy == .frequency ? 1 : 0
        d.square = s.segmented ? 1 : 0
        d.domT = dom
        d.speedK = 120
        d.kind = ParticleKind.cymatics.rawValue
        d.count = UInt32(n)
        f.particles = ParticleDraw(kind: .cymatics, count: n, bandCount: 0, sim: sim, draw: d)

        // Plate outline
        let o = d.origin, e = d.extent
        let c = rc.inkC(0.12)
        f.line(o, o + SIMD2(e.x, 0), c, 1)
        f.line(o + SIMD2(e.x, 0), o + e, c, 1)
        f.line(o + e, o + SIMD2(0, e.y), c, 1)
        f.line(o + SIMD2(0, e.y), o, c, 1)
    }
}

/// Curl-noise particle flow; each particle is bound to a frequency band and moves with its energy.
final class FlowViz: Visualizer {
    private var frame: UInt32 = 0
    private var time: Double = 0

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let n = max(1000, Int(s.particleCount))
        let bands = 256
        let treble = min(1.5, rc.analyzer.level(4000, 14000, s: s))
        if !rc.frozen {
            frame &+= 1
            time += rc.dt * (0.4 + s.motion)
        }

        var sim = SimUniforms()
        sim.speed = rc.frozen ? 0 : Float(0.5 + s.motion)
        sim.dtScale = Float(rc.dt * 60)
        sim.time = Float(time)
        sim.turb = 0.3 + treble * 1.5
        sim.noiseScale = Float(2.5 / s.zoom)
        sim.beat = rc.frozen ? 0 : rc.beat
        sim.count = UInt32(n)
        sim.frame = frame
        sim.bandCount = UInt32(bands)
        sim.kind = ParticleKind.flow.rawValue
        sim.p0 = Float(s.reach)
        sim.aspect = rc.size.x / max(rc.size.y, 1)

        var d = PartDrawUniforms()
        d.origin = .zero
        d.extent = rc.size
        d.dotR = rc.unit * 0.8 * min(1.2, max(0.25, (200_000 / Float(n)).squareRoot()))
        d.alphaK = n > 200_000 ? max(0.25, pow(200_000 / Float(n), 0.35)) : 1
        d.phase = rc.phase
        d.colorByFreq = s.colorBy == .frequency ? 1 : 0
        d.square = s.segmented ? 1 : 0
        // Streak = the path of the last ~33 ms (4 frames at 120 fps), whatever the frame rate. Counting it in frames made
        // slow frames draw longer streaks, which cost more and slowed the next frame further.
        d.streak = s.style == .points ? 0 : 4 * min(1, 0.5 / max(sim.dtScale, 1e-3))
        d.speedK = 150 / Float(max(0.05, s.reach))  // colour by flow speed, independent of Reach
        d.kind = ParticleKind.flow.rawValue
        d.count = UInt32(n)
        d.bandCount = UInt32(bands)
        f.particles = ParticleDraw(kind: .flow, count: n, bandCount: bands, sim: sim, draw: d)
    }
}
