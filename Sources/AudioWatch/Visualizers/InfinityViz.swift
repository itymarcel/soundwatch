import Foundation
import simd

/// Infinity: a flight between endless fractal castles, drawn by one raymarching shader (`infinityFrag`).
/// A Mandelbox is mirrored into a lattice; kicks push its fold; the patterns on its walls and the speaker cones
/// scattered over them each light up / pump with one frequency band. The CPU side only keeps the music state
/// (band levels, travel, fold) and the camera.
final class InfinityViz: Visualizer {
    private var smoother = Smoother()
    private var levels: [SmoothValue] = []
    private var avgs: [Float] = []
    private var peaks: [Float] = []
    private var onsets = Onsets()
    /// Distance flown, and the fold the kicks push around.
    private var travel: Double = 0
    private var fold = SmoothValue()
    private var foldKick: Float = 0
    /// Where the camera is along its lattice cell (0…1 of one period) and the travel already counted into it.
    private var castleU: Double = 0
    private var castleTravel: Double = 0
    private var wander: Float = 0
    private var rush = SmoothValue()

    /// Vertical field of view: the ray through the top of the window (zoom 1) has slope 1 / focal.
    private static let focal: Float = 1.25
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var frameNo = 0
    /// Debug: AUDIOWATCH_INF_STEPS=1 draws the march's step count (red), hit (green) and depth (blue) instead of the picture.
    /// 5 = without the pre-pass (timing A/B), 7 = where the pre-pass start changes the hit (red).
    private static let debugCode = Float(ProcessInfo.processInfo.environment["AUDIOWATCH_INF_STEPS"] ?? "") ?? 0

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let dt = Float(rc.dt)
        let n = max(2, min(16, Int(s.infBands.rounded())))
        if levels.count != n {
            levels = .init(repeating: SmoothValue(), count: n)
            avgs = .init(repeating: 0.1, count: n)
            peaks = .init(repeating: 0.2, count: n)
        }
        let vals = smoother.step(rc.analyzer.bands(count: n, s: s), smoothing: min(s.smoothing, 0.6), dt: rc.dt, frozen: rc.frozen)
        let bass = min(1.3, rc.analyzer.level(20, 140, s: s))
        let motion = Float(s.motion)
        var kick: Float = 0
        if !rc.frozen {
            for i in 0..<n {
                // like Orbs: each band against its own average and peak, so it reacts whatever Gain is
                let v = vals[i]
                avgs[i] += (v - avgs[i]) * (1 - exp(-dt / 1.5))
                peaks[i] = max(v, peaks[i] * exp(-dt / 3))
                let steady = min(1, v / max(peaks[i], 0.05))
                let rise = min(1, max(0, v - avgs[i]) / max(peaks[i] - avgs[i], 0.03))
                let quiet = min(1, v / 0.03)                      // silence stays still
                _ = levels[i].step(to: (0.35 * steady + 0.65 * rise) * quiet, dt: dt, omega: 16)
            }
            for hit in onsets.step(rc) where hit.band == 0 { kick = max(kick, hit.strength) }
            // always forwards, even with Motion at 0 (the user's usual value); the bass pushes us along faster
            let speed = (0.3 + motion) * (1 + 1.2 * rush.step(to: bass * Float(s.reach), dt: dt, omega: 5))
            travel += Double(dt * speed)
            foldKick *= exp(-dt / 0.9)
            wander += dt * (0.25 + 0.5 * motion)
            // an accented kick pushes the fold, always the same way; it eases back afterwards
            if kick > 0.35 { foldKick = max(foldKick, 0.5 + 0.5 * kick) }
        }
        let reach = Float(s.reach)
        let data = levels.map { min(1.2, max(0, $0.x) * reach) }

        var u = baseUniforms(rc)
        u.world = rc.minDim * 0.5 * Float(s.zoom) * Self.focal
        u.count = Float(n)
        u.bass = Float(s.chromeTint)
        u.p2 = SIMD4(2, Float(s.chromeTurn), Float(s.chromeBlur), 0)

        let morph = min(1, max(0, Float(s.infMorph))) * 0.3   // the slider's full range = the tame third of the first version
        let target = Float(s.infFold) + 0.22 * morph * foldKick
        let fv = rc.frozen ? fold.x : fold.step(to: target, dt: dt, omega: 2.2)
        let fc = min(1.2, max(-0.2, fv))
        let kickFold = max(0, fv - Float(s.infFold))       // how far the last kick has pushed the fold right now
        let rushNow = rush.x
        // Every structure sits in a box; mirrored copies sit a little farther apart, which leaves an endless canyon
        // between every two of them: the camera flies along that (always free) gap.
        var scale: Float = 3        // how much finer each fold is (the shader picks its level of detail from it)
        var box: Float = 4.4        // the box's half size
        var shape: Float = 0        // Bubbles: strength of the inversions; City: skyline height
        var wrap: Double = 1        // how many periods the camera flies before it is moved back (the City repeats after 16)
        switch s.infStructure {
        case .castle:
            scale = 2.0 + 0.9 * fc
            box = 2 * (scale + 1) / (scale - 1)     // how far a Mandelbox reaches
        case .vault:
            scale = -(1.5 + 0.9 * min(1, max(0, fc)))
        case .bubbles:
            // the packing changes shape only slowly with its strength: kicks and the bass get a much bigger say here
            scale = 2
            shape = 1.08 + 0.22 * fc + 0.6 * kickFold + 0.12 * (morph / 0.3) * rushNow * min(1, reach)
        case .city:
            shape = 0.45 + 0.55 * fc
            wrap = 16
        }
        let half = box + 0.22
        u.reach = shape
        u.p2.w = s.infStructure.shaderIndex
        // p0.z: the Mandelbox's min radius² (breathes with the bass); the City: how far towers rise with their band
        let p0z = s.infStructure == .city ? 2 * morph / 0.3 * reach : 0.25 + 0.08 * morph * reach * min(1, bass)
        u.p0 = SIMD4(s.infPattern.shaderIndex, scale, p0z,
                     max(5, min(14, Float(s.infCastleDetail.rounded()))))
        u.p1 = SIMD4(half, s.infSurface.shaderIndex, s.infSpeakers ? 1 : 0, Self.debugCode)
        // The lattice's period follows the fold. Measured in world units, the camera's place would be rescaled by
        // every kick (by more and more the farther it had flown: the scenery lurched back and forth). So its place
        // is kept as a fraction of the period it is in, and only the flight moves it: always forwards.
        castleU += (travel - castleTravel) * 0.35 / Double(2 * half)
        castleU -= (castleU / wrap).rounded(.down) * wrap
        castleTravel = travel
        let eye = SIMD3(half * 0.55 * sin(wander * 0.043), half + 0.12 * sin(wander * 0.13), -Float(castleU) * 2 * half)
        let view = rc.camera.rotation * rotZ(0.2 * sin(wander * 0.11)) * rotX(0.3 * sin(wander * 0.09)) * rotY(0.35 * sin(wander * 0.15))
        u.view0 = SIMD4(view[0][0], view[1][0], view[2][0], eye.x)
        u.view1 = SIMD4(view[0][1], view[1][1], view[2][1], eye.y)
        u.view2 = SIMD4(view[0][2], view[1][2], view[2][2], eye.z)
        if Self.trace {
            frameNo += 1
            if frameNo % 30 == 0 { print("INF travel=\(travel) u=\(castleU) fold=\(fv) p0=\(u.p0) p1=\(u.p1) eye=\(eye) data=\(data)") }
        }
        f.shaderMode = ShaderModeDraw(kind: .infinity, u: u, data: data)
    }
}
