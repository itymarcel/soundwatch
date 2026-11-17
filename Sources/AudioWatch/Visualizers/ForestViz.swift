import Foundation
import simd

/// Forest: a flight down a river valley through an endless forest, drawn by ForestGPU (meshes, not raymarched).
/// The CPU keeps the music state (band levels relative to their own average and peak, like Orbs / Infinity), the
/// flight (Motion = base speed, Reach = how hard the bass pushes), the sun and sky colours, and the camera.
final class ForestViz: Visualizer {
    private var smoother = Smoother()
    private var levels: [SmoothValue] = []
    private var avgs: [Float] = []
    private var peaks: [Float] = []
    private var rush = SmoothValue()
    private var gust = SmoothValue()
    private var shimmer = SmoothValue()
    private var z: Double = 4000
    private var wander: Float = 0
    private var onsets = Onsets()
    private var flocks: [Flock] = []
    /// Seconds until a hit may start another flock; and since the last one (some come by now and then anyway).
    private var birdWait: Float = 4
    private var sinceBirds: Float = 0
    private var rng = SplitMix(seed: 0xB1_2D5)
    private static let bands = 8
    private static let period: Double = 8192
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var frameNo = 0

    /// A flock of birds: boids (keep apart, match the neighbours' heading, stay together) chasing a goal that
    /// sweeps over the river ahead of the camera, keeping clear of the ground; after a while they leave.
    final class Flock {
        var p: [SIMD3<Float>] = [], v: [SIMD3<Float>] = [], phase: [Float] = [], size: [Float] = []
        var ground: [Float] = []
        var age: Float = 0, life: Float, seed: Float, side: Float
        var swirl = SIMD3<Float>()
        init(life: Float, seed: Float, side: Float) { self.life = life; self.seed = seed; self.side = side }
    }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let dt = Float(rc.dt)
        let n = Self.bands
        if levels.count != n {
            levels = .init(repeating: SmoothValue(), count: n)
            avgs = .init(repeating: 0.1, count: n)
            peaks = .init(repeating: 0.2, count: n)
        }
        let vals = smoother.step(rc.analyzer.bands(count: n, s: s), smoothing: min(s.smoothing, 0.6), dt: rc.dt, frozen: rc.frozen)
        let bass = min(1.3, rc.analyzer.level(20, 140, s: s))
        let motion = Float(s.motion), reach = Float(s.reach)
        if !rc.frozen {
            for i in 0..<n {
                let v = vals[i]
                avgs[i] += (v - avgs[i]) * (1 - exp(-dt / 1.5))
                peaks[i] = max(v, peaks[i] * exp(-dt / 3))
                let steady = min(1, v / max(peaks[i], 0.05))
                let rise = min(1, max(0, v - avgs[i]) / max(peaks[i] - avgs[i], 0.03))
                let quiet = min(1, v / 0.03)
                _ = levels[i].step(to: (0.35 * steady + 0.65 * rise) * quiet, dt: dt, omega: 16)
            }
            // always forwards (even at Motion 0), the bass pushes; metres per second
            let speed = (2.5 + 10 * motion) * (1 + 1.5 * rush.step(to: bass * reach, dt: dt, omega: 5))
            z -= Double(dt * speed)
            if z < 0 {   // the world repeats: move the birds with the camera's jump
                z += Self.period
                for f in flocks { for i in f.p.indices { f.p[i].z += Float(Self.period) } }
            }
            wander += dt
            // gusts swell and fade over about a second (faster made the trees twitch)
            _ = gust.step(to: 0.5 * (levels[0].x + levels[1].x), dt: dt, omega: 1.6)
            _ = shimmer.step(to: (levels[n - 1].x + levels[n - 2].x + levels[n - 3].x) / 3, dt: dt, omega: 10)
        }
        let data = levels.map { min(1.2, max(0, $0.x) * reach) }

        // the flight: low over the river, gently weaving, looking down the valley
        let zf = Float(z)
        let pos = SIMD3<Float>(ForestTerrain.riverCenter(zf) + 1.5 * sin(wander * 0.05), 3.2 + 0.8 * sin(wander * 0.07), zf)
        let ahead: Float = 32
        let target = SIMD3<Float>(ForestTerrain.riverCenter(zf - ahead) + 2.5 * sin(wander * 0.031), pos.y - 1.0, zf - ahead)
        let baseF = simd_normalize(target - pos)
        let baseR = simd_normalize(simd_cross(baseF, SIMD3(0, 1, 0)))
        let baseU = simd_cross(baseR, baseF)
        // the user's orbit turns the view about the camera
        let rot = rc.camera.rotation
        let fc = rot * SIMD3<Float>(0, 0, -1), uc = rot * SIMD3<Float>(0, 1, 0)
        let fwd = baseR * fc.x + baseU * fc.y - baseF * fc.z      // camera space: x right, y up, z back
        let up = baseR * uc.x + baseU * uc.y - baseF * uc.z

        // sun and sky from the time of day, tinted by the palette
        let t = Float(min(1, max(0, s.forSun)))
        // most of the slider's range is the interesting low sun; noon is only around the middle
        let el = (2 + 55 * pow(sin(Float.pi * t), 3)) * Float.pi / 180
        let az = Float.pi * (0.15 + 0.7 * t)
        let sunDir = simd_normalize(SIMD3(cos(az) * cos(el), sin(el), -sin(az) * cos(el)))
        let low = 1 - smoothstep(0.05, 0.65, sin(el))
        let tint = Float(s.forTint)
        let pa = rc.palette.rgb(rc.phase + 0.1), pb = rc.palette.rgb(rc.phase + 0.6)
        var sunCol = simd_mix(SIMD3<Float>(1.0, 0.94, 0.86), SIMD3(1.0, 0.52, 0.24), SIMD3(repeating: low))
        sunCol = simd_mix(sunCol, pa * 1.1, SIMD3(repeating: tint * 0.6))
        var zenith = simd_mix(SIMD3<Float>(0.16, 0.34, 0.78), SIMD3(0.14, 0.18, 0.4), SIMD3(repeating: low))
        zenith = simd_mix(zenith, pb * 0.7, SIMD3(repeating: tint))
        var horizon = simd_mix(SIMD3<Float>(0.62, 0.74, 0.9), SIMD3(0.98, 0.62, 0.42), SIMD3(repeating: low))
        horizon = simd_mix(horizon, pa, SIMD3(repeating: tint * 0.7))
        let sunI = 3.0 * (0.35 + 0.65 * smoothstep(0.0, 0.3, sin(el))) * (1 + 0.12 * rc.beat)

        // birds: a hit sets a flock off from the trees ahead (and now and then one comes by anyway)
        var birdData: [SIMD4<Float>] = []
        let amount = Float(s.forBirds)
        if !rc.frozen && amount > 0 {
            let hits = onsets.step(rc)
            let hardest = hits.map(\.strength).max() ?? 0
            birdWait -= dt; sinceBirds += dt
            if flocks.count < 2 && birdWait <= 0 && (hardest > 0.6 || sinceBirds > 40 + 40 * (1 - amount)) {
                spawnFlock(at: pos, forward: baseF, strength: max(hardest, 0.5), amount: amount)
                birdWait = 6 + Float(rng.unit()) * 24 * (1.2 - amount)
                sinceBirds = 0
            } else if hardest > 0.45 {
                // a hit while they fly: the flock lurches (a murmuration's sudden turn)
                for f in flocks {
                    f.swirl += SIMD3(Float(rng.unit() - 0.5) * 30, Float(rng.unit() - 0.3) * 12, Float(rng.unit() - 0.5) * 30) * hardest
                }
            }
            stepFlocks(dt: dt, cam: pos, forward: baseF, beat: rc.beat)
        } else if amount <= 0 {
            flocks.removeAll()
        }
        for f in flocks { for i in f.p.indices { birdData.append(SIMD4(f.p[i], f.phase[i])); birdData.append(SIMD4(f.v[i], f.size[i])) } }

        let fov = 2 * atan(tan(0.5 * 62 * Float.pi / 180) / max(0.3, rc.camera.zoom * Float(s.zoom)))
        let input = ForestInput(
            camPos: pos, forward: fwd, up: up, fovY: fov, time: Float(rc.time),
            sunDir: sunDir, sunCol: sunCol, sunI: sunI, zenith: zenith, horizon: horizon,
            mist: Float(s.forMist), clouds: Float(s.forClouds),
            gust: gust.x * 1.5, shimmer: shimmer.x, level: min(1.5, rc.analyzer.level(30, 16_000, s: s)),
            bandLight: Float(s.forGlow), beat: rc.beat,
            windDir: simd_normalize(SIMD2<Float>(0.8, -0.6)), wind: Float(s.forWind),
            density: Float(s.forTrees), exposure: exp2(Float(s.brightness) * 0.75), bands: data, birds: birdData)
        var u = baseUniforms(rc)
        u.count = Float(n)
        if Self.trace {
            frameNo += 1
            if frameNo % 30 == 0 { print("FOREST z=\(z) pos=\(pos) gust=\(gust.x) shimmer=\(shimmer.x) birds=\(flocks.map { $0.p.count }) data=\(data)") }
        }
        f.shaderMode = ShaderModeDraw(kind: .forest, u: u, data: data, forest: input)
    }
}

extension ForestViz {
    private func spawnFlock(at cam: SIMD3<Float>, forward: SIMD3<Float>, strength: Float, amount: Float) {
        let side: Float = rng.unit() < 0.5 ? -1 : 1
        let f = Flock(life: 14 + Float(rng.unit()) * 14, seed: Float(rng.unit()) * 100, side: side)
        let fwd = simd_normalize(SIMD3(forward.x, 0, forward.z))
        let right = SIMD3<Float>(-fwd.z, 0, fwd.x)
        let ahead = Float(55 + rng.unit() * 50), off = Float(18 + rng.unit() * 25)
        var c: SIMD3<Float> = cam + fwd * ahead
        c += right * (side * off)
        c.y = ForestTerrain.height(SIMD2(c.x, c.z)) + 13
        let k: Float = 0.5 + 0.5 * min(1, strength)
        let n = Int(30 + 260 * amount * k)
        for _ in 0..<min(n, ForestGPU.birdCap / 2) {
            var d: SIMD3<Float>
            repeat { d = SIMD3(Float(rng.unit()), Float(rng.unit()), Float(rng.unit())) * 2 - 1 } while simd_length_squared(d) > 1
            f.p.append(c + d * SIMD3(14, 3, 14))
            // startled: up and out of the trees
            f.v.append(SIMD3(d.x * 3, 5 + Float(rng.unit()) * 3, d.z * 3) - right * side * 3)
            f.phase.append(Float(rng.unit()) * 6.28)
            f.size.append(Float(0.8 + rng.unit() * 0.5))
            f.ground.append(c.y - 13)
        }
        flocks.append(f)
    }

    private func stepFlocks(dt: Float, cam: SIMD3<Float>, forward: SIMD3<Float>, beat: Float) {
        let fwd = simd_normalize(SIMD3(forward.x, 0, forward.z))
        for f in flocks {
            f.age += dt
            f.swirl *= exp(-dt / 1.2)
            // the goal: sweeping over the river ahead of the camera, then away and up once their time is over
            let gz = cam.z + fwd.z * (70 + 15 * sin(f.age * 0.25 + f.seed))
            var goal = SIMD3<Float>(ForestTerrain.riverCenter(gz) + f.side * 20 * sin(f.age * 0.3 + f.seed), 0, gz)
            goal.y = max(ForestTerrain.height(SIMD2(goal.x, goal.z)), 0) + 26 + 8 * sin(f.age * 0.45 + f.seed)
            if f.age > f.life { goal = cam + SIMD3(f.side * 400, 160, fwd.z * 300) }
            goal += f.swirl
            let n = f.p.count
            let fast: Float = 12 + 4 * beat
            for i in 0..<n {
                var sep = SIMD3<Float>(), ali = SIMD3<Float>(), coh = SIMD3<Float>()
                var cnt: Float = 0
                let pi = f.p[i]
                for j in 0..<n where j != i {
                    let d = f.p[j] - pi
                    let d2 = simd_length_squared(d)
                    if d2 < 64 {
                        cnt += 1; ali += f.v[j]; coh += d
                        if d2 < 6 { sep -= d / max(d2, 0.05) }
                    }
                }
                var acc = SIMD3<Float>()
                if cnt > 0 {
                    let align: SIMD3<Float> = (ali / cnt - f.v[i]) * 1.0
                    let cohere: SIMD3<Float> = (coh / cnt) * 0.22
                    acc += align + cohere + sep * 5
                }
                let toGoal = goal - pi
                acc += (simd_normalize(toGoal) * fast - f.v[i]) * 0.7
                // keep clear of the ground (its height is looked up every few frames per bird)
                if (i + Int(f.age * 60)) % 6 == 0 { f.ground[i] = ForestTerrain.height(SIMD2(pi.x, pi.z)) }
                let clear = f.ground[i] + 12 - pi.y
                if clear > 0 { acc.y += clear * 2.5 }
                var v = f.v[i] + acc * dt
                let sp = simd_length(v)
                v *= min(max(sp, 7), 17) / max(sp, 1e-3)
                f.v[i] = v
                f.p[i] = pi + v * dt
                // wingbeats: faster when climbing, gliding now and then on the way down
                let rate: Float = v.y < -1.5 && sin(f.age * 0.7 + Float(i)) > 0.3 ? 0 : 13 + max(0, v.y) * 2
                f.phase[i] += dt * rate
                if rate == 0 { f.phase[i] = f.phase[i] * 0.95 + 1.2 * 0.05 }
            }
        }
        flocks.removeAll { f in f.age > f.life && simd_distance(f.p.first ?? cam, cam) > 350 || f.age > f.life + 40 }
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
