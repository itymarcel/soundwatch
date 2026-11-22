import Foundation
import simd

/// Landscape (`VizMode.forest`), Forest scene (the City scene is CityViz): a flight down a river valley through an endless forest, drawn by ForestGPU (meshes, not raymarched).
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
    private var loud = SmoothValue()
    /// How far the wind has carried things (snow, rain, falling leaves) so far, metres in x / z; the camera's last position.
    private var drift = SIMD2<Float>()
    private var lastPos: SIMD3<Float>?
    private var camVel = SIMD3<Float>()
    private var z: Double = 4000
    private var wander: Float = 0
    private var onsets = Onsets()
    private var flocks: [Flock] = []
    /// Seconds until a hit may start another flock; and since the last one (some come by now and then anyway).
    private var birdWait: Float = 4
    private var sinceBirds: Float = 0
    /// Fireflies (night): world position, velocity, heading angles, blink phase / rate, flash from hits, ground height.
    private var flyP: [SIMD3<Float>] = [], flyV: [SIMD3<Float>] = [], flyAng: [SIMD2<Float>] = []
    private var flyPhase: [Float] = [], flyRate: [Float] = [], flyFlash: [Float] = [], flyGround: [Float] = []
    private var flyLoud = SmoothValue()
    /// How visible the fireflies are from the loudness (0 in silence … 1 loud), see `stepFireflies` call.
    private var flyOn: Float = 0
    /// How much is going on (0 in silence … 1 with music playing, from the loudness): scales the flight speed, the
    /// camera's weave and the wind, so the forest comes to rest when the music stops (user: "moving too much even
    /// when no music is playing").
    private var act: Float = 0
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

    /// The Landscape's other scene.
    private let city = CityViz()

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        if rc.s.landScene == .city { city.build(f, rc); return }
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
            // loudness → activity (dBFS with Gain: −60 dB → 0, ≥ −20 dB → 1); wakes in 0.5 s, settles over 2 s
            let db = 20 * log10f(rc.analyzer.rms(last: 2048) * Float(s.gain) + 1e-7)
            let x = min(1, max(0, (db + 60) / 40))
            let target = x * x * (3 - 2 * x)
            act += (target - act) * (1 - exp(-dt / (target > act ? 0.5 : 2.0)))
            // forwards with the music (a slow drift in silence), the bass pushes; metres per second
            let speed = (2.5 + 10 * motion) * (0.04 + 0.96 * act) * (1 + 1.5 * rush.step(to: bass * reach, dt: dt, omega: 5))
            z -= Double(dt * speed)
            if z < 0 {   // the world repeats: move the birds with the camera's jump
                z += Self.period
                for f in flocks { for i in f.p.indices { f.p[i].z += Float(Self.period) } }
                for i in flyP.indices { flyP[i].z += Float(Self.period) }
            }
            wander += dt * (0.1 + 0.9 * act)
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
        // the season: how high the sun climbs at noon (~15° in midwinter, ~57° at midsummer)
        let season = ForestSeason(day: Float((s.forSeason.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)) * 364)
        let noon = 36 + 21 * season.temp
        // night: the sun becomes the moon (at least ~22° up so its light reaches into the valley)
        let nightRaw = Float(min(1, max(0, s.forNight)))
        let night = smoothstep(0, 1, nightRaw)
        var el = (2 + (noon - 2) * pow(sin(Float.pi * t), 3)) * Float.pi / 180
        el += (max(el, 22 * Float.pi / 180) - el) * night
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
        var sunI = 3.0 * (0.35 + 0.65 * smoothstep(0.0, 0.3, sin(el))) * (1 + 0.12 * rc.beat)
        // dusk → night: a cold dim moonlight, a deep blue sky (the stars are drawn in the shader)
        // blended geometrically (in log space): a linear mix stays bright daylight until the very end of the slider
        func dusk(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            let w = 1 - nightRaw
            return SIMD3(pow(max(a.x, 1e-4), w) * pow(b.x, nightRaw), pow(max(a.y, 1e-4), w) * pow(b.y, nightRaw),
                         pow(max(a.z, 1e-4), w) * pow(b.z, nightRaw))
        }
        sunCol = dusk(sunCol, SIMD3<Float>(0.55, 0.66, 1.0) * 0.1)
        zenith = dusk(zenith, SIMD3<Float>(0.0035, 0.0055, 0.015))
        horizon = dusk(horizon, SIMD3<Float>(0.013, 0.017, 0.032))

        // weather: an overcast, greyer sky and thicker mist; rain (snowfall when it's cold), heavier when the music is loud
        let overcast = Float(s.forWeather)
        if !rc.frozen { _ = loud.step(to: min(1, rc.analyzer.level(30, 16_000, s: s)), dt: dt, omega: 3) }
        let fall = overcast * (0.55 + 0.45 * loud.x)
        let snowShare = smoothstep(-0.3, -0.6, season.temp)
        let grey = SIMD3<Float>(0.42, 0.45, 0.5) * (0.55 + 0.45 * (1 - low))
        zenith = simd_mix(zenith, horizon, SIMD3(repeating: 0.25 * season.snow))     // a paler winter sky
        zenith = simd_mix(zenith, grey * 0.85, SIMD3(repeating: overcast * 0.75))
        horizon = simd_mix(horizon, grey * 1.1, SIMD3(repeating: overcast * 0.7))
        sunI *= 1 - 0.55 * overcast
        // the wind carries snow, rain and falling leaves (gusts = the bass)
        let windDir = simd_normalize(SIMD2<Float>(0.8, -0.6))
        // the wind calms down to a light stir in silence
        let wind = Float(s.forWind) * (0.15 + 0.85 * act)
        let windVel = windDir * (0.4 + 1.6 * wind * (0.3 + 1.5 * gust.x))
        if !rc.frozen {
            drift += windVel * dt
            if let lp = lastPos, dt > 0 {
                let v = (pos - lp) / dt
                if simd_length(v) < 200 { camVel += (v - camVel) * min(1, dt * 8) }
            }
            lastPos = pos
        }

        // birds: a hit sets a flock off from the trees ahead (and now and then one comes by anyway)
        var birdData: [SIMD4<Float>] = []
        let amount = Float(s.forBirds)
        let hits = rc.frozen ? [] : onsets.step(rc)
        if !rc.frozen && amount > 0 {
            let hardest = hits.map(\.strength).max() ?? 0
            birdWait -= dt; sinceBirds += dt
            if flocks.count < 2 && birdWait <= 0 && (hardest > 0.6 || (sinceBirds > 40 + 40 * (1 - amount) && act > 0.3)) {
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

        // fireflies: they come out as it gets dark
        let flyVis = smoothstep(0.3, 0.8, nightRaw) * Float(s.forFireflies)
        var flyData: [SIMD4<Float>] = []
        if flyVis > 0.001 {
            if !rc.frozen {
                _ = flyLoud.step(to: min(1, rc.analyzer.level(30, 16_000, s: s)), dt: dt, omega: 3)
                stepFireflies(dt: dt, cam: pos, forward: baseF, hits: hits, loud: flyLoud.x, gust: gust.x, beat: rc.beat)
                // quieter music = fewer, dimmer fireflies, none in silence (dBFS with Gain: −65 dB → 0, ≥ −15 dB → 1);
                // up in 0.3 s, down over 1.2 s so short pauses don't blink them out
                let db = 20 * log10f(rc.analyzer.rms(last: 2048) * Float(s.gain) + 1e-7)
                let x = min(1, max(0, (db + 65) / 50))
                let target = x * x * (3 - 2 * x)
                flyOn += (target - flyOn) * (1 - exp(-dt / (target > flyOn ? 0.3 : 1.2)))
            }
            let count = min(flyP.count, Int(Float(ForestGPU.fireflyCap) * min(1, Float(s.forFireflies))))
            let fade = smoothstep(0.3, 0.8, nightRaw)
            flyData.reserveCapacity(count * 2)
            for i in 0..<count {
                // a slow glow / dark rhythm, plus the flashes that hits set off
                let blink = pow(max(0, sin(flyPhase[i])), 3)
                // each one has its own loudness threshold: the quieter it gets, the more of them go dark
                let th = Float((UInt32(truncatingIfNeeded: i &* 2_654_435_761) >> 8) & 0xFFFF) / 65535 * 0.7
                let on = smoothstep(th, th + 0.3, flyOn) * (0.3 + 0.7 * flyOn)
                let b = (0.06 + 0.94 * blink + 1.2 * flyFlash[i]) * (1 + 0.25 * rc.beat) * fade * on
                flyData.append(SIMD4(flyP[i], b))
                // each firefly glows in a colour of the palette (spread over it, golden-ratio steps), kept bright
                let pc = rc.palette.rgb(rc.phase + Float(i) * 0.618034)
                let c = pc / max(0.05, max(pc.x, max(pc.y, pc.z)))
                flyData.append(SIMD4(c * 1.05, 0))
            }
        } else if !flyP.isEmpty && nightRaw < 0.2 {
            flyP.removeAll(); flyV.removeAll(); flyAng.removeAll(); flyPhase.removeAll(); flyRate.removeAll(); flyFlash.removeAll(); flyGround.removeAll()
        }

        let fov = 2 * atan(tan(0.5 * 62 * Float.pi / 180) / max(0.3, rc.camera.zoom * Float(s.zoom)))
        let input = ForestInput(
            camPos: pos, forward: fwd, up: up, fovY: fov, time: Float(rc.time),
            sunDir: sunDir, sunCol: sunCol, sunI: sunI, zenith: zenith, horizon: horizon,
            mist: Float(s.forMist) + 0.3 * overcast + 0.08 * season.snow, clouds: min(1, Float(s.forClouds) + 0.8 * overcast),
            gust: gust.x * 1.5, shimmer: shimmer.x, level: min(1.5, rc.analyzer.level(30, 16_000, s: s)),
            bandLight: Float(s.forGlow), beat: rc.beat,
            windDir: windDir, wind: wind,
            density: Float(s.forTrees), exposure: exp2(Float(s.brightness) * 0.75) * (1 + 0.9 * night), bands: data, birds: birdData,
            seasonA: SIMD4(season.snow, season.foliage, season.autumn, season.fresh),
            seasonB: SIMD4(season.flowers, season.blossom, season.dry, season.ice),
            seasonC: SIMD4(season.lateFlowers, season.temp, overcast * (1 - snowShare), season.litter),
            precip: SIMD4(fall * (1 - snowShare), fall * snowShare,
                          season.leafFall * (0.3 + 0.9 * min(1, gust.x)), season.petals * (0.4 + 0.8 * min(1, gust.x))),
            drift: SIMD4(drift.x, drift.y, windVel.x, windVel.y), camVel: camVel, night: night, fireflies: flyData)
        var u = baseUniforms(rc)
        u.count = Float(n)
        if Self.trace {
            frameNo += 1
            if frameNo % 30 == 0 { print("FOREST z=\(z) act=\(act) pos=\(pos) gust=\(gust.x) shimmer=\(shimmer.x) birds=\(flocks.map { $0.p.count }) data=\(data)") }
            if frameNo % 30 == 0 { print("FOREST season=\(season) fall=\(fall) snowShare=\(snowShare)") }
        }
        f.shaderMode = ShaderModeDraw(kind: .forest, u: u, data: data, forest: input)
    }
}

extension ForestViz {
    /// Fireflies live in a box around the camera (±40 m across the river, 5 m behind … 110 m ahead), 0.3–3.5 m over the
    /// ground or the water, wandering slowly. The music: louder = faster and more restless, hits make a few of them
    /// flash (more with harder hits) and nudge them, the bass gusts lift them a little.
    private func stepFireflies(dt: Float, cam: SIMD3<Float>, forward: SIMD3<Float>, hits: [(band: Int, strength: Float)],
                               loud: Float, gust: Float, beat: Float) {
        let cap = ForestGPU.fireflyCap
        func place(_ i: Int, anywhere: Bool) {
            let z = cam.z - (anywhere ? Float(rng.unit()) * 115 - 5 : 80 + Float(rng.unit()) * 35)
            let x = ForestTerrain.riverCenter(z) + (Float(rng.unit()) * 2 - 1) * 40
            let g = max(ForestTerrain.height(SIMD2(x, z)), 0)
            let p = SIMD3<Float>(x, g + 0.3 + Float(rng.unit()) * 3, z)
            if i < flyP.count {
                flyP[i] = p; flyGround[i] = g; flyV[i] = .zero
            } else {
                flyP.append(p); flyGround.append(g); flyV.append(.zero)
                flyAng.append(SIMD2(Float(rng.unit()) * 6.283, 0)); flyPhase.append(Float(rng.unit()) * 6.283)
                flyRate.append(Float(1.2 + rng.unit() * 2.2)); flyFlash.append(0)
            }
        }
        while flyP.count < cap { place(flyP.count, anywhere: true) }
        let speed: Float = 0.35 * (1 + 1.6 * loud)
        let turn: Float = 1.2 * (1 + 1.5 * loud)
        // hits: a share of them flashes (and darts off a little)
        var flashShare: Float = 0
        for h in hits { flashShare = max(flashShare, h.strength * (h.band == 0 ? 0.25 : 0.12)) }
        let frame = Int(wander * 60)
        for i in 0..<flyP.count {
            var a = flyAng[i]
            a.x += (Float(rng.unit()) - 0.5) * turn * 4 * dt
            a.y += (Float(rng.unit()) - 0.5) * turn * 2 * dt - a.y * dt * 0.8
            flyAng[i] = a
            var want = SIMD3<Float>(cos(a.x) * cos(a.y), sin(a.y) * 0.6, sin(a.x) * cos(a.y)) * speed
            // stay near the ground: 0.3 … 3.5 m over it; the bass lifts them a little
            if (i + frame) % 8 == 0 { flyGround[i] = max(ForestTerrain.height(SIMD2(flyP[i].x, flyP[i].z)), 0) }
            let hgt = flyP[i].y - flyGround[i]
            want.y += (hgt < 0.4 ? (0.4 - hgt) * 2 : 0) - (hgt > 3.5 ? (hgt - 3.5) * 0.8 : 0) + gust * 0.25
            flyV[i] += (want - flyV[i]) * min(1, dt * 1.5)
            flyPhase[i] += dt * flyRate[i] * (1 + 0.5 * loud)
            flyFlash[i] *= exp(-dt / 0.35)
            if flashShare > 0, Float(rng.unit()) < flashShare {
                flyFlash[i] = 1
                flyV[i] += SIMD3(Float(rng.unit()) - 0.5, Float(rng.unit()) * 0.6, Float(rng.unit()) - 0.5) * 0.8
            }
            flyP[i] += flyV[i] * dt
            // behind the camera or too far to the side: a new one far ahead
            let side = flyP[i].x - ForestTerrain.riverCenter(flyP[i].z)
            if flyP[i].z > cam.z + 5 || flyP[i].z < cam.z - 125 || abs(side) > 45 { place(i, anywhere: false) }
        }
    }

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

/// The forest's season from the day of the year (0 = 1 Jan … 364 = 31 Dec), each part 0…1, all easing in and out
/// over a few weeks (a year wraps: winter runs across New Year).
struct ForestSeason: CustomStringConvertible {
    /// Snow on the ground, trees and rocks; leaves on the broadleaf trees; how far they've turned; spring's fresh green.
    var snow: Float, foliage: Float, autumn: Float, fresh: Float
    /// Meadow flowers; blossom on some broadleaf trees; dry / dead grass (straw); ice on the river.
    var flowers: Float, blossom: Float, dry: Float, ice: Float
    /// Early (white / yellow) → summer flowers (poppies, cornflowers …); −1 midwinter … 1 midsummer; leaf litter on the floor.
    var lateFlowers: Float, temp: Float, litter: Float
    /// Falling leaves (autumn) and petals (blossom time), before the gusts make more of them fall.
    var leafFall: Float, petals: Float

    init(day d: Float) {
        func w(_ a: Float, _ b: Float, _ c: Float, _ e: Float) -> Float { Self.window(d, a, b, c, e) }
        // day numbers: Feb 31, Mar 59, Apr 90, May 120, Jun 151, Jul 181, Aug 212, Sep 243, Oct 273, Nov 304, Dec 334
        temp = -cos(2 * .pi * (d - 20) / 365)
        snow = w(326, 348, 365 + 52, 365 + 82)          // late Nov … late Mar
        foliage = w(97, 132, 285, 325)                   // leaf-out in April / May, bare by late November
        autumn = w(250, 293, 345, 360)
        fresh = w(95, 118, 145, 185)
        flowers = w(80, 118, 192, 245)
        blossom = w(88, 106, 124, 140)
        dry = max(1 - w(75, 118, 262, 322), 0.4 * w(198, 228, 250, 272))
        ice = w(350, 365 + 14, 365 + 40, 365 + 62)
        lateFlowers = ForestSeason.smooth(135, 172, d)
        litter = w(275, 305, 365 + 85, 365 + 130)
        leafFall = w(265, 290, 312, 332)
        petals = w(102, 114, 128, 142)
    }

    /// 0 before a, rising to 1 by b, 1 until c, falling to 0 by e (days; c and e may run past 365 into the next year).
    static func window(_ d: Float, _ a: Float, _ b: Float, _ c: Float, _ e: Float) -> Float {
        func f(_ x: Float) -> Float {
            if x <= a || x >= e { return 0 }
            if x < b { return smooth(a, b, x) }
            if x <= c { return 1 }
            return 1 - smooth(c, e, x)
        }
        return max(f(d), f(d + 365), f(d - 365))
    }
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
    var description: String {
        String(format: "snow %.2f foliage %.2f autumn %.2f fresh %.2f flowers %.2f blossom %.2f dry %.2f ice %.2f leafFall %.2f petals %.2f temp %.2f",
               snow, foliage, autumn, fresh, flowers, blossom, dry, ice, leafFall, petals, temp)
    }
}
