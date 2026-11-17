import Foundation
import simd

/// The Landscape's City scene: a flight down an avenue through an endless city at night, ray-traced by CityGPU.
/// The CPU keeps the music state and everything that moves:
/// - 8 band levels (relative to their own average and peak): every tower listens to one, its lit windows climb like a meter.
/// - light drones flying along the streets (one band each), which light the facades and cast the buildings' shadows;
/// - searchlights at intersections ahead, swinging to new angles on every beat;
/// - kick waves: a hard kick sends a ring of light running out along the streets from a point ahead;
/// - lightning (Storm) on hard snare hits: hard shadows of every tower across the city for a moment;
/// - traffic, faster with the mids. Motion / Reach = speed (the bass pushes), like the Forest.
final class CityViz {
    static let C: Double = 16          // lot size (m); a block = 4 lots + a 16 m street
    static let period = 5
    private var smoother = Smoother()
    private var levels: [SmoothValue] = []
    private var avgs: [Float] = [], peaks: [Float] = []
    private var rush = SmoothValue()
    private var midS = SmoothValue()
    private var shimmer = SmoothValue()
    private var crown = SmoothValue()
    private var z: Double = 0
    private var wander: Float = 0
    private var trafficOff: Double = 0
    private var onsets = Onsets()
    private var rng = SplitMix(seed: 0xC17_7)
    private var kickGlow: Float = 0
    /// How many windows are lit (0…1), from the loudness: silence → almost all dark, quiet → a few, loud → all.
    private var lightsOn: Float = 0.5
    /// Fly-bys: drones that shoot past close to the camera (drawn after the regular drones, up to 2 at once).
    private var flybys: [Drone] = []
    private var flyWait: Float = 4

    private struct Drone { var x: Double; var y: Float; var z: Double; var vx: Double; var vz: Double; var phase: Float; var band: Int }
    private var drones: [Drone] = []
    private struct Beam { var x: Double; var z: Double; var az: Float; var el: Float; var tAz: Float; var tEl: Float; var spin: Float }
    private var beams: [Beam] = []
    private var lastBeat = -1
    private struct Wave { var x: Double; var z: Double; var age: Float; var strength: Float }
    private var waves: [Wave] = []
    private var waveSlot = 0
    private var flashT: [Float] = []         // times since lightning strikes (one entry per flicker)
    private var flashDir = SIMD3<Float>(0.3, 0.8, -0.4)
    private var stormWait: Float = 3
    /// Debug: AUDIOWATCH_CITY_DEBUG=1 draws only the grid walk (timing), 2 skips the lighting.
    private static let debug = Float(ProcessInfo.processInfo.environment["AUDIOWATCH_CITY_DEBUG"] ?? "0") ?? 0
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var frameNo = 0

    /// x of the avenue the camera flies down (the middle of street column 4).
    private static let avenueX = (Double(period - 1) + 0.5) * C
    /// Drone light slots in the shader (8 regular + 2 fly-bys); must match DRONES / BEAMS in CityShaders.swift.
    static let maxDrones = 10

    private func unit() -> Float { Float(Double(rng.next() >> 11) / Double(1 << 53)) }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let dt = Float(rc.dt)
        let n = 8
        if levels.count != n {
            levels = .init(repeating: SmoothValue(), count: n)
            avgs = .init(repeating: 0.1, count: n); peaks = .init(repeating: 0.2, count: n)
        }
        let vals = smoother.step(rc.analyzer.bands(count: n, s: s), smoothing: min(s.smoothing, 0.6), dt: rc.dt, frozen: rc.frozen)
        let bass = min(1.3, rc.analyzer.level(20, 140, s: s))
        let mid = min(1.3, rc.analyzer.level(300, 2500, s: s))
        let motion = Float(s.motion), reach = Float(s.reach)
        let hits = rc.frozen ? [] : onsets.step(rc)
        if !rc.frozen {
            for i in 0..<n {
                let v = vals[i]
                avgs[i] += (v - avgs[i]) * (1 - exp(-dt / 1.5))
                peaks[i] = max(v, peaks[i] * exp(-dt / 3))
                let steady = min(1, v / max(peaks[i], 0.05))
                let rise = min(1, max(0, v - avgs[i]) / max(peaks[i] - avgs[i], 0.03))
                let quiet = min(1, v / 0.03)
                _ = levels[i].step(to: (0.45 * steady + 0.55 * rise) * quiet, dt: dt, omega: 14)
            }
            let speed = Double((4 + 14 * motion) * (1 + 1.5 * rush.step(to: bass * reach, dt: dt, omega: 5)))
            z -= Double(dt) * speed
            wander += dt
            _ = midS.step(to: mid, dt: dt, omega: 3)
            _ = shimmer.step(to: (levels[n - 1].x + levels[n - 2].x) / 2, dt: dt, omega: 10)
            _ = crown.step(to: rc.beat, dt: dt, omega: 18)
            trafficOff += Double(dt) * Double(7 + 16 * midS.x)
            kickGlow *= exp(-dt / 0.25)
            // windows follow the loudness (dBFS with the input Gain): −70 dB ≈ all dark, −40 a few, ≥ −12 all lit.
            // On fast (0.4 s), off slower (1.5 s), so the city doesn't blink with every pause between notes.
            let db = 20 * log10f(rc.analyzer.rms(last: 2048) * Float(s.gain) + 1e-7)
            let x = min(1, max(0, (db + 70) / 58))
            let target = 0.02 + 0.98 * x * x * (3 - 2 * x)
            lightsOn += (target - lightsOn) * (1 - exp(-dt / (target > lightsOn ? 0.4 : 1.5)))
        }
        let data = levels.map { min(1.2, max(0, $0.x) * max(0.3, reach)) }

        // the flight: down the avenue, low in the canyon (Altitude 0) … over the roofs (1)
        let alt = Float(s.cityAlt)
        let camY = 3 + 160 * pow(alt, 1.6) + (0.4 + 1.5 * alt) * sin(wander * 0.11)
        let camX = Self.avenueX + Double(2.2 * sin(wander * 0.07))
        let camPos = SIMD3<Double>(camX, Double(camY), z)
        let yaw = 0.1 * sin(wander * 0.043), pitch = -(0.04 + 0.42 * alt) + 0.03 * sin(wander * 0.061)
        let baseF = simd_normalize(SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)))
        let baseR = simd_normalize(simd_cross(baseF, SIMD3(0, 1, 0)))
        let baseU = simd_cross(baseR, baseF)
        let rot = rc.camera.rotation
        let fc = rot * SIMD3<Float>(0, 0, -1), uc = rot * SIMD3<Float>(0, 1, 0)
        let fwd = simd_normalize(baseR * fc.x + baseU * fc.y - baseF * fc.z)
        let upv = baseR * uc.x + baseU * uc.y - baseF * uc.z
        let right = simd_normalize(simd_cross(fwd, upv))
        let up = simd_cross(right, fwd)
        let fov = 2 * atan(tan(0.5 * 64 * Float.pi / 180) / max(0.3, rc.camera.zoom * Float(s.zoom)))

        let cellX = Int32((camX / Self.C).rounded(.down)), cellZ = Int32((z / Self.C).rounded(.down))
        func rel(_ x: Double, _ y: Float, _ zz: Double) -> SIMD3<Float> {
            SIMD3(Float(x - Double(cellX) * Self.C), y, Float(zz - Double(cellZ) * Self.C))
        }
        let pa = rc.palette.rgb(rc.phase + 0.05), pb = rc.palette.rgb(rc.phase + 0.55), pc = rc.palette.rgb(rc.phase + 0.3)

        if !rc.frozen { stepDrones(count: Int((8 * s.cityLights).rounded()), dt: dt, cam: camPos, data: data) }
        if !rc.frozen { stepBeams(count: Int((4 * s.cityBeams).rounded()), dt: dt, cam: camPos, beat: rc.analyzer.beatCount) }
        if !rc.frozen { stepFlybys(amount: Float(s.cityFlyby), dt: dt, cam: camPos, hits: hits, data: data) }
        if !rc.frozen { stepEvents(hits: hits, dt: dt, cam: camPos, storm: Float(s.cityStorm)) }

        var L: [SIMD4<Float>] = []
        for i in 0..<4 {
            if i < waves.count {
                let w = waves[i]
                let r = rel(w.x, 0, w.z)
                L.append(SIMD4(r.x, r.z, 8 + 75 * w.age, w.strength * exp(-w.age / 1.1) * min(1, w.age * 20)))
            } else { L.append(SIMD4()) }
        }
        let all = Array((drones + flybys).prefix(Self.maxDrones))
        for i in 0..<Self.maxDrones {
            if i < all.count {
                let d = all[i]
                let lv = data[d.band]
                let fly = i >= drones.count
                let col = rc.palette.rgb(rc.phase + Float(i) / 8 + 0.02)
                L.append(SIMD4(rel(d.x, d.y, d.z), 130))
                L.append(SIMD4(col, 260 * (fly ? 0.7 + 1.2 * lv : 0.25 + 1.6 * lv)))
            } else { L.append(SIMD4()); L.append(SIMD4()) }
        }
        for i in 0..<4 {
            if i < beams.count {
                let b = beams[i]
                let dir = SIMD3<Float>(cos(b.az) * cos(b.el), sin(b.el), sin(b.az) * cos(b.el))
                L.append(SIMD4(rel(b.x, 1, b.z), 0.9))
                L.append(SIMD4(dir, 0.8 + 1.6 * rc.beat + 0.6 * bass))
            } else { L.append(SIMD4()); L.append(SIMD4()) }
        }

        let flash = flashT.reduce(Float(0)) { $0 + ($1 >= 0 ? exp(-$1 / 0.07) : 0) }
        let P = 3072.0
        func pmod(_ v: Double) -> Float { Float(v - P * (v / P).rounded(.down)) }
        let cz = Double(cellZ) * Self.C, cx = Double(cellX) * Self.C
        var U = CityUniforms()
        U.right = SIMD4(right, 0)
        U.up = SIMD4(up, tan(fov / 2))
        U.fwd = SIMD4(fwd, 0)
        U.cam = SIMD4(rel(camX, camY, z), Float(rc.time.truncatingRemainder(dividingBy: 3600)))
        U.cell = SIMD4(cellX, cellZ, 0, 0)
        U.cfg = SIMD4(Float(s.cityTowers), Float(s.cityWet), Float(s.cityTraffic), Float(s.forMist))
        U.cfg2 = SIMD4(Float(s.forGlow), Float(all.count), Float(min(beams.count, 4)), Float(s.forTint))
        U.music = SIMD4(bass, midS.x, shimmer.x, rc.beat)
        U.music2 = SIMD4(min(1.5, rc.analyzer.level(30, 16_000, s: s)), kickGlow, crown.x, lightsOn)
        U.traffic = SIMD4(pmod(cz - trafficOff), pmod(cz + trafficOff), pmod(cx - trafficOff), pmod(cx + trafficOff))
        U.flash = SIMD4(flashDir, min(2, flash * Float(s.cityStorm > 0 ? 1 : 0)))
        U.colA = SIMD4(pa, 0); U.colB = SIMD4(pb, 0); U.colC = SIMD4(pc, 1.25)
        U.bands0 = SIMD4(data[0], data[1], data[2], data[3]); U.bands1 = SIMD4(data[4], data[5], data[6], data[7])
        U.cfg3 = SIMD4(Float(s.cityGloom), Self.debug, Float(s.cityReflect), Float(s.cityReflBlur))

        if Self.trace {
            frameNo += 1
            if frameNo % 30 == 0 { print("CITY z=\(Int(z)) y=\(camY) drones=\(drones.count) flybys=\(flybys.count) lights=\(lightsOn) beams=\(beams.count) waves=\(waves.count) flash=\(flash) data=\(data.map { (($0 * 100).rounded()) / 100 })") }
        }
        var u = baseUniforms(rc)
        u.count = Float(n)
        f.shaderMode = ShaderModeDraw(kind: .city, u: u, data: data, city: CityInput(u: U, lights: L))
    }

    // MARK: - Things that move

    /// Street centre lines near a coordinate: avenues run along z at x = (5a + 4.5)·16, cross streets along x likewise.
    private static func streetLine(_ index: Int) -> Double { (Double(index * period + period - 1) + 0.5) * C }
    private static func streetIndex(near v: Double) -> Int { Int(((v / C - Double(period - 1) - 0.5) / Double(period)).rounded()) }

    private func stepDrones(count: Int, dt: Float, cam: SIMD3<Double>, data: [Float]) {
        if drones.count > count { drones.removeLast(drones.count - count) }
        while drones.count < count { drones.append(spawnDrone(cam: cam, band: drones.count % 8, first: true)) }
        for i in drones.indices {
            var d = drones[i]
            let lv = data[d.band]
            d.phase += dt
            let k = 1 + 1.2 * Double(lv)
            d.x += d.vx * Double(dt) * k
            d.z += d.vz * Double(dt) * k
            d.y += (sin(d.phase * 0.7) * 2.5 + (lv - 0.3) * 6) * dt
            d.y = min(75, max(5, d.y))
            let ahead = cam.z - d.z
            if ahead < -40 || ahead > 520 || abs(d.x - cam.x) > 420 { d = spawnDrone(cam: cam, band: d.band, first: false) }
            drones[i] = d
        }
    }

    private func spawnDrone(cam: SIMD3<Double>, band: Int, first: Bool) -> Drone {
        let ahead = Double(first ? 40 + unit() * 380 : 260 + unit() * 220)
        let speed = Double(6 + 12 * unit()) * (unit() < 0.5 ? -1 : 1)
        let y = 8 + 45 * unit() * unit() + 6 * unit()
        if unit() < 0.5 {
            // along an avenue
            let a = Self.streetIndex(near: cam.x) + Int((unit() * 5).rounded(.down)) - 2
            return Drone(x: Self.streetLine(a) + Double(unit() * 6 - 3), y: y, z: cam.z - ahead, vx: 0, vz: speed, phase: unit() * 6, band: band)
        }
        let b = Self.streetIndex(near: cam.z - ahead)
        return Drone(x: cam.x + Double(unit() * 300 - 150), y: y, z: Self.streetLine(b) + Double(unit() * 6 - 3), vx: speed, vz: 0, phase: unit() * 6, band: band)
    }

    /// Fly-bys: every few seconds (sooner with the slider, and a hard hit brings the next one closer) a light shoots past
    /// near the camera: across the next cross street ahead, overtaking from behind, or head-on along the avenue.
    /// They pass a few metres to the side and above, so they never fly through the camera.
    private func stepFlybys(amount: Float, dt: Float, cam: SIMD3<Double>, hits: [(band: Int, strength: Float)], data: [Float]) {
        for i in flybys.indices {
            var d = flybys[i]
            d.phase += dt
            d.x += d.vx * Double(dt); d.z += d.vz * Double(dt)
            d.y += sin(d.phase * 2.3) * 0.8 * dt
            flybys[i] = d
        }
        flybys.removeAll { d in
            let ahead = cam.z - d.z
            return ahead < -90 || ahead > 650 || abs(d.x - cam.x) > 260
        }
        guard amount > 0 else { flyWait = 2; return }
        flyWait -= dt
        for h in hits where h.strength > 0.6 { flyWait -= 2.5 * h.strength * amount }
        guard flyWait <= 0, flybys.count < 2 else { return }
        flyWait = (2 + 28 * pow(1 - amount, 1.5)) * (0.5 + unit())
        let band = Int(unit() * 8) & 7
        let side: Double = unit() < 0.5 ? -1 : 1
        let y = Float(cam.y) + 2.5 + 5 * unit()
        let kind = unit()
        if kind < 0.4 {
            // across the cross street ahead, from one side to the other
            let b = Self.streetIndex(near: cam.z - Double(60 + unit() * 110))
            let v = Double(28 + 22 * unit())
            flybys.append(Drone(x: cam.x - side * 220, y: y, z: Self.streetLine(b) + Double(unit() * 6 - 3),
                                vx: side * v, vz: 0, phase: unit() * 6, band: band))
        } else if kind < 0.7 {
            // overtaking: from behind, a few metres beside / above, much faster than the camera
            flybys.append(Drone(x: cam.x + side * Double(3 + 4 * unit()), y: y, z: cam.z + 70,
                                vx: 0, vz: -Double(45 + 25 * unit()), phase: unit() * 6, band: band))
        } else {
            // head-on: comes down the avenue towards the camera and passes beside it
            flybys.append(Drone(x: cam.x + side * Double(3 + 4 * unit()), y: y, z: cam.z - 600,
                                vx: 0, vz: Double(25 + 20 * unit()), phase: unit() * 6, band: band))
        }
    }

    private func stepBeams(count: Int, dt: Float, cam: SIMD3<Double>, beat: Int) {
        if beams.count > count { beams.removeLast(beams.count - count) }
        func spawn(first: Bool) -> Beam {
            let ahead = Double(first ? 120 + unit() * 380 : 380 + unit() * 200)
            let a = Self.streetIndex(near: cam.x) + Int((unit() * 7).rounded(.down)) - 3
            let b = Self.streetIndex(near: cam.z - ahead)
            let az = unit() * 6.28, el = 0.9 + 0.5 * unit()
            return Beam(x: Self.streetLine(a), z: Self.streetLine(b), az: az, el: el, tAz: az, tEl: el, spin: (unit() - 0.5) * 0.5)
        }
        while beams.count < count { beams.append(spawn(first: true)) }
        let newBeat = beat != lastBeat
        lastBeat = beat
        for i in beams.indices {
            var b = beams[i]
            if cam.z - b.z < -60 { b = spawn(first: false) }
            if newBeat && unit() < 0.7 { b.tAz += (unit() - 0.5) * 2.4; b.tEl = 0.75 + 0.7 * unit() }
            b.tAz += b.spin * dt
            b.az += (b.tAz - b.az) * (1 - exp(-dt * 5))
            b.el += (b.tEl - b.el) * (1 - exp(-dt * 4))
            beams[i] = b
        }
    }

    private func stepEvents(hits: [(band: Int, strength: Float)], dt: Float, cam: SIMD3<Double>, storm: Float) {
        for i in waves.indices { waves[i].age += dt }
        waves.removeAll { $0.age > 6 }
        flashT = flashT.map { $0 + dt }.filter { $0 < 1 }
        stormWait -= dt
        for h in hits {
            if h.band == 0 && h.strength > 0.3 {
                kickGlow = max(kickGlow, h.strength)
                // a ring of light from a crossing ahead
                let ahead = Double(50 + unit() * 160)
                let b = Self.streetIndex(near: cam.z - ahead)
                let a = Self.streetIndex(near: cam.x) + Int((unit() * 3).rounded(.down)) - 1
                let w = Wave(x: Self.streetLine(a), z: Self.streetLine(b), age: 0, strength: min(1, 0.4 + h.strength))
                if waves.count < 4 { waves.append(w) } else { waves[waveSlot % 4] = w; waveSlot += 1 }
            }
            if h.band == 1 && storm > 0 && stormWait <= 0 && h.strength > 0.75 - 0.4 * storm {
                // lightning: two or three flickers, from a random direction high up
                let az = unit() * 6.28, el = 0.6 + 0.5 * unit()
                flashDir = SIMD3(cos(az) * cos(el), sin(el), sin(az) * cos(el))
                flashT += [0, -0.09 - 0.05 * unit()]
                if unit() < 0.6 { flashT.append(-0.25 - 0.1 * unit()) }
                stormWait = 2 + 14 * (1 - storm) * (0.6 + 0.8 * unit())
            }
        }
    }
}
