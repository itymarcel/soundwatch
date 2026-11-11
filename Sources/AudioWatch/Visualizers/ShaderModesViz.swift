import Foundation
import simd

// Modes drawn per pixel by a full-screen shader (see membraneFrag / fanFrag / glassFrag in Shaders.swift).
// The CPU side only keeps the music-driven state (bumps, rings, ring frames) and hands it over as a float list.

private func rnd() -> Float { Float.random(in: 0...1) }

private func baseUniforms(_ rc: RenderContext) -> ShaderModeUniforms {
    var u = ShaderModeUniforms()
    u.viewPt = rc.size
    u.center = rc.center
    u.pan = rc.camera.pan
    u.zoom = rc.camera.zoom
    u.time = Float(rc.time)
    u.phase = rc.phase
    u.colorByFreq = rc.s.colorBy == .frequency ? 1 : 0
    u.level = min(1.5, rc.analyzer.level(30, 16_000, s: rc.s))
    u.bass = min(1.5, rc.analyzer.level(20, 140, s: rc.s))
    u.beat = rc.beat
    u.reach = Float(rc.s.reach)
    return u
}

// MARK: - Membrane

/// A grey rubber sheet; hits push bumps up from underneath and send ripples across it.
final class MembraneViz: Visualizer {
    private struct Bump {
        var p: SIMD2<Float>
        var r: Float
        var h: Float
        var age: Float = 0
        var life: Float
        var ring: Float
    }
    private var bumps: [Bump] = []
    private var onsets = Onsets()
    private var bass = SmoothValue()

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let dt = Float(rc.dt)
        let aspect = rc.size.x / max(rc.size.y, 1)
        let sizeK = Float(s.size)
        if !rc.frozen {
            for hit in onsets.step(rc) { spawn(hit.band, hit.strength, aspect: aspect, size: sizeK) }
            for i in bumps.indices { bumps[i].age += dt }
            bumps.removeAll { $0.age > $0.life * 3 }
            let cap = Int(s.membraneBumps)
            if bumps.count > cap { bumps.removeFirst(bumps.count - cap) }
        }
        let speed = 0.25 + 0.5 * Float(s.motion)
        var data: [Float] = []
        data.reserveCapacity(bumps.count * 6)
        for b in bumps {
            let env = (1 - exp(-b.age / 0.12)) * exp(-b.age / b.life)
            let ringR = b.age * speed
            let ringA = b.ring * exp(-b.age / 1.1)
            data += [b.p.x, b.p.y, b.r, b.h * env, ringR, ringA]
        }
        var u = baseUniforms(rc)
        let lv = rc.frozen ? bass.x : bass.step(to: u.bass, dt: dt, omega: 6)
        u.bass = lv
        u.world = rc.minDim * 0.5 * Float(s.zoom)
        u.count = Float(bumps.count)
        u.p0 = SIMD4(Float(s.reach), Float(s.membraneTint), Float(s.membraneRelief), aspect)
        u.p1 = SIMD4(0.11 * sizeK, 0, 0, 0)
        f.shaderMode = ShaderModeDraw(kind: .membrane, u: u, data: data)
    }

    private func spawn(_ band: Int, _ strength: Float, aspect: Float, size: Float) {
        let st = 0.4 + 0.6 * strength
        let (r, h, life, spread): (Float, Float, Float, Float) = switch band {
        case 0: (0.32 + 0.22 * rnd(), 0.55 * st, 3.2, 0.45)     // kick: broad swell near the middle
        case 1: (0.14 + 0.12 * rnd(), 0.4 * st, 2.0, 0.8)       // snare: rounder bump
        default: (0.05 + 0.04 * rnd(), -0.22 * st, 0.8, 1.0)    // hat: small sharp dent
        }
        let a = rnd() * 2 * .pi, d = sqrt(rnd()) * spread
        let p = SIMD2(cos(a) * d * aspect, sin(a) * d)
        bumps.append(Bump(p: p, r: r * size, h: h, life: life, ring: 0.05 * st * (band == 0 ? 1.4 : 1)))
    }
}

// MARK: - Spectral Fan

/// Spectral arcs on one side of a seam, beat rings on the other, dust over both.
final class FanViz: Visualizer {
    private static let bandCount = 64
    private static let maxRings = 16
    private var smoother = Smoother()
    private var onsets = Onsets()
    private var rings: [SIMD3<Float>] = []   // age, strength, colour t
    private var scroll: Float = 0
    private var seamFlash: Float = 0

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let dt = Float(rc.dt)
        let vals = smoother.step(rc.analyzer.bands(count: Self.bandCount, s: s), smoothing: s.smoothing, dt: rc.dt, frozen: rc.frozen)
        if !rc.frozen {
            scroll += dt * Float(s.motion) * 0.5
            if scroll > 1000 { scroll -= 1000 }
            for hit in onsets.step(rc) {
                rings.append(SIMD3(0, 0.35 + 0.65 * hit.strength, Float(hit.band) / 2))
                if hit.band == 0 { seamFlash = max(seamFlash, hit.strength) }
            }
            for i in rings.indices { rings[i].x += dt }
            rings.removeAll { $0.x > 4 }
            if rings.count > Self.maxRings { rings.removeFirst(rings.count - Self.maxRings) }
            seamFlash *= exp(-dt / 0.2)
        }
        var data = vals.map { min($0, 1.5) }
        for r in rings { data += [r.x, r.y, r.z] }
        var u = baseUniforms(rc)
        u.world = rc.minDim * 0.5 * Float(s.zoom)
        u.count = Float(rings.count)
        u.beat = max(u.beat, seamFlash)
        u.p0 = SIMD4(Float(s.fanArcs), scroll, s.mirror ? 1 : 0, Float(Self.bandCount))
        u.p1 = SIMD4(0.35 + 0.3 * Float(s.motion), Float(s.size), 0, 0)
        f.shaderMode = ShaderModeDraw(kind: .fan, u: u, data: data)
    }
}

// MARK: - Glass Stack

/// A stack of translucent rings and discs, one per band, raymarched as glowing glass shells.
final class GlassViz: Visualizer {
    private var smoother = Smoother()
    private var spin: Float = 0
    private var clock: Float = 0

    private static func h(_ i: Int, _ k: Int) -> Float {
        var r = SplitMix(seed: UInt64(i * 7919 + k * 104_729 + 17))
        return Float(r.unit())
    }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let n = max(3, min(12, Int(s.glassRings)))
        let vals = smoother.step(rc.analyzer.bands(count: n, s: s), smoothing: s.smoothing, dt: rc.dt, frozen: rc.frozen)
        if !rc.frozen {
            spin += Float(rc.dt * s.motion) * 0.25
            clock += Float(rc.dt) * (0.3 + Float(s.motion))
        }
        let reach = Float(s.reach)
        let sizeK = Float(s.size)
        var data: [Float] = []
        data.reserveCapacity(n * 20)
        for i in 0..<n {
            let lv = min(1.3, vals[i])
            let fi = Float(i)
            let y = (n == 1 ? 0 : -0.85 + 1.7 * fi / Float(n - 1)) + 0.05 * sin(clock * 0.6 + fi * 1.3) + 0.1 * lv * reach
            let disc = Self.h(i, 1) > 0.55
            let R = (0.32 + 0.5 * Self.h(i, 0)) * (1 + 0.3 * lv * reach) * sizeK
            let tube = (0.045 + 0.05 * Self.h(i, 2)) * sizeK
            let discW = (0.1 + 0.16 * Self.h(i, 3)) * sizeK
            let ax = 0.18 * sin(clock * 0.4 + fi * 1.7) + 0.4 * lv * reach * (Self.h(i, 4) - 0.5)
            let az = 0.18 * cos(clock * 0.33 + fi * 2.3) + 0.4 * lv * reach * (Self.h(i, 5) - 0.5)
            let m = rotX(ax) * rotZ(az)
            let inv = m.transpose
            let t = (s.colorBy == .frequency ? fi / Float(max(1, n - 1)) : min(1, lv)) + rc.phase
            let c = SIMD3<Float>(0.12 * sin(clock * 0.5 + fi), y, 0.12 * cos(clock * 0.45 + fi * 1.9))
            // rows of the world → ring transform
            data += [c.x, c.y, c.z, R,
                     inv[0][0], inv[1][0], inv[2][0], tube,
                     inv[0][1], inv[1][1], inv[2][1], discW,
                     inv[0][2], inv[1][2], inv[2][2], disc ? 1 : 0,
                     lv, t, 0, 0]
        }
        let view = rotX(0.3) * rc.camera.rotation * rotY(spin)
        var u = baseUniforms(rc)
        u.view0 = SIMD4(view[0][0], view[1][0], view[2][0], 0)
        u.view1 = SIMD4(view[0][1], view[1][1], view[2][1], 0)
        u.view2 = SIMD4(view[0][2], view[1][2], view[2][2], 0)
        u.world = rc.minDim * 0.36 * Float(s.zoom) * (1 + 0.04 * rc.beat)
        u.count = Float(n)
        u.p0 = SIMD4(Float(s.glassSoft), 3.6, Float(s.size), 0)
        f.shaderMode = ShaderModeDraw(kind: .glass, u: u, data: data)
    }
}

func rotZ(_ a: Float) -> simd_float3x3 {
    simd_float3x3(rows: [SIMD3(cos(a), -sin(a), 0), SIMD3(sin(a), cos(a), 0), SIMD3(0, 0, 1)])
}

// MARK: - Diamond

/// A raytraced brilliant-cut diamond (a convex solid = a list of facet planes). Lights orbit it; Movement
/// slowly wobbles and shifts the facet planes with the music. The shader refracts, bounces and disperses the light.
final class DiamondViz: Visualizer {
    private struct Facet { var n: SIMD3<Float>; var w: Float; var group: Int; var az: Float }
    private var facets: [Facet] = []
    private var facetTotal = 0
    private var smoother = Smoother()
    /// 16 band levels for the sides (4 per facet group, by direction), glided so the stone reshapes smoothly.
    private var facetSmoother = Smoother()
    private var facetLevels = [SmoothValue](repeating: SmoothValue(), count: 16)
    /// Where the bass has pushed the stone (eased back to the centre).
    private var drift = (SmoothValue(), SmoothValue(), SmoothValue())
    private var spin: Float = 0
    private var wobble: Float = 0
    /// Movement also turns the stone (under the lights): a slow, music-driven spin plus a gentle tumble.
    private var turn: Float = 0
    private var turnSpeed = SmoothValue()
    private var lightAz: [Float] = (0..<8).map { Float($0) * 2.39996 }
    private var flash = SmoothValue()

    /// Ring sizes for a cut with `total` facets (5…50): a table plus rings of facets, introduced in the order a cutter
    /// would add them as the count grows: pavilion, crown (bezel), girdle, stars, lower girdle, upper girdle.
    /// Each active ring gets a share by its weight in a real brilliant (1, 1, 2, 1, 2, 2), at least 3 facets.
    static func rings(total: Int) -> [Int] {
        let r = max(4, total - 1)
        let active = r < 9 ? 1 : r < 14 ? 2 : r < 20 ? 3 : r < 26 ? 4 : r < 36 ? 5 : 6
        let weights: [Double] = Array([1, 1, 2, 1, 2, 2].prefix(active))
        let sum = weights.reduce(0, +)
        var counts = weights.map { max(3, Int(Double(r) * $0 / sum)) }
        // hand out (or take back) the remainder so the total is exact
        var i = 0
        while counts.reduce(0, +) < r { counts[i % active] += 1; i += 1 }
        i = active - 1
        while counts.reduce(0, +) > r { if counts[i] > 3 { counts[i] -= 1 }; i = (i + active - 1) % active }
        return counts + [Int](repeating: 0, count: 6 - active)
    }

    /// Round-brilliant proportions, girdle radius 1, y up. Ring counts may differ, so a low count gives an
    /// irregular, crystal-like stone and a high count a near-brilliant.
    private static func makeCut(total: Int) -> [Facet] {
        var f: [Facet] = []
        func tilted(_ az: Float, _ tiltDeg: Float, up: Bool, through p: SIMD3<Float>, group: Int) {
            let t = tiltDeg * .pi / 180
            let nn = SIMD3(sin(t) * cos(az), (up ? 1 : -1) * cos(t), sin(t) * sin(az))
            f.append(Facet(n: nn, w: simd_dot(nn, p), group: group, az: az))
        }
        let girdleH: Float = 0.025
        let tableY: Float = 0.34
        let c = rings(total: total)
        func ring(_ n: Int, offset: Float, _ make: (Float) -> Void) {
            guard n > 0 else { return }
            let step = 2 * Float.pi / Float(n)
            for k in 0..<n { make(Float(k) * step + offset * step) }
        }
        f.append(Facet(n: SIMD3(0, 1, 0), w: tableY, group: 0, az: 0))
        ring(c[0], offset: 0) { a in tilted(a, 40.8, up: false, through: SIMD3(cos(a), -girdleH, sin(a)), group: 3) }   // pavilion
        ring(c[1], offset: 0) { a in tilted(a, 34.5, up: true, through: SIMD3(cos(a), girdleH, sin(a)), group: 1) }     // bezel
        ring(c[2], offset: 0) { a in f.append(Facet(n: SIMD3(cos(a), 0, sin(a)), w: 1.0, group: 2, az: a)) }            // girdle
        ring(c[3], offset: 0.5) { a in tilted(a, 21, up: true, through: SIMD3(0.56 * cos(a), tableY, 0.56 * sin(a)), group: 0) } // star
        ring(c[4], offset: 0.5) { a in tilted(a, 43, up: false, through: SIMD3(cos(a), -girdleH, sin(a)), group: 3) }   // lower girdle
        ring(c[5], offset: 0.5) { a in tilted(a, 41, up: true, through: SIMD3(cos(a), girdleH, sin(a)), group: 1) }     // upper girdle
        // Few facets leave far-reaching corners (a 4-sided stone is ~2× wider at its corners than a round one):
        // measure the farthest boundary point over many directions and scale every cut to the same outer radius.
        var reach: Float = 0
        let golden = Float.pi * (3 - Float(5).squareRoot())
        for i in 0..<400 {
            let y = 1 - 2 * (Float(i) + 0.5) / 400, r = (1 - y * y).squareRoot(), th = golden * Float(i)
            let u = SIMD3(cos(th) * r, y, sin(th) * r)
            var d = Float.greatestFiniteMagnitude
            for fc in f { let k = simd_dot(fc.n, u); if k > 1e-4 { d = min(d, fc.w / k) } }
            reach = max(reach, d)
        }
        let scale = reach > 1.05 ? 1.05 / reach : 1
        for i in f.indices { f[i].w *= scale }
        return f
    }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let dt = Float(rc.dt)
        let total = max(5, min(50, Int(s.diamondFacets.rounded())))
        if total != facetTotal { facetTotal = total; facets = Self.makeCut(total: total) }
        let vals = smoother.step(rc.analyzer.bands(count: 8, s: s), smoothing: s.smoothing, dt: rc.dt, frozen: rc.frozen)
        let level = min(1.2, rc.analyzer.level(30, 16_000, s: s))
        let nl = max(1, min(8, Int(s.diamondLights)))
        if !rc.frozen {
            spin += dt * Float(s.motion) * 0.25
            wobble += dt * 0.1 * (0.6 + 0.6 * level)       // slow drift: one full sway takes about a minute
            for i in 0..<8 { lightAz[i] += dt * (0.25 + Float(s.motion) * 0.8) * (i % 2 == 0 ? 1 : -1.3) * (0.7 + 0.15 * Float(i)) }
            let fv = facetSmoother.step(rc.analyzer.bands(count: 16, s: s), smoothing: s.smoothing, dt: rc.dt, frozen: rc.frozen)
            for b in 0..<16 { _ = facetLevels[b].step(to: min(1.3, fv[b]), dt: dt, omega: 2.5) }
            let bass = min(1.3, rc.analyzer.level(20, 140, s: s))
            let push = Float(s.diamondMove) * Float(s.reach) * 0.3 * bass
            _ = drift.0.step(to: push * sin(wobble * 2.1), dt: dt, omega: 2)
            _ = drift.1.step(to: push * 0.6 * sin(wobble * 1.7 + 2), dt: dt, omega: 2)
            _ = drift.2.step(to: push * cos(wobble * 1.9), dt: dt, omega: 2)
            let target = Float(s.diamondMove) * (0.08 + 0.45 * level + 0.6 * rc.beat)
            turn += dt * turnSpeed.step(to: target, dt: dt, omega: 1.2)
        }
        let beat = rc.frozen ? flash.x : flash.step(to: rc.beat, dt: dt, omega: 18)

        // Movement = how much the music reshapes the stone. Each side listens to its own band (pavilion = bass …
        // table = treble, split by direction): it tilts (shape) and moves out or in (size). Low vs high bands
        // stretch the whole stone taller or wider, and the bass pushes it off-centre (position).
        let move = Float(s.diamondMove)
        let reach = Float(s.reach)
        let orient = rotY(turn) * rotX(move * 0.35 * sin(wobble * 0.8)) * rotZ(move * 0.25 * sin(wobble * 0.6 + 1.3))
        let low = (facetLevels[0].x + facetLevels[1].x + facetLevels[2].x + facetLevels[3].x) / 4
        let high = (facetLevels[12].x + facetLevels[13].x + facetLevels[14].x + facetLevels[15].x) / 4
        let k = move * reach
        // stretch: plane n·x ≤ w under x' = S x becomes (S⁻¹n)·x' ≤ w
        let sy = 1 + k * 0.45 * (low - 0.25), sxz = 1 + k * 0.3 * (high - 0.25)
        let inv = SIMD3(1 / max(sxz, 0.5), 1 / max(sy, 0.5), 1 / max(sxz, 0.5))
        let offset = SIMD3(drift.0.x, drift.1.x, drift.2.x)
        var data: [Float] = []
        data.reserveCapacity(facets.count * 4 + nl * 8)
        for (i, fc) in facets.enumerated() {
            let quarter = Int((fc.az / (2 * .pi) + 1) * 4) % 4
            let base: Int = switch fc.group {
            case 3: 0               // pavilion: bands 0–3
            case 2: 4               // girdle: 4–7
            case 1: 8               // crown: 8–11
            default: 12             // table + stars: 12–15
            }
            let lv = facetLevels[base + quarter].x
            let fi = Float(i)
            let jitter = SIMD3(sin(wobble * 1.3 + fi * 1.7), sin(wobble * 0.9 + fi * 2.3), sin(wobble * 1.1 + fi * 0.7))
            let tilt = move * 0.03 + k * 0.55 * lv                         // shape
            var n = simd_normalize(fc.n + jitter * tilt)
            var w = fc.w * (1 + k * (0.4 * lv - 0.1) + move * 0.02 * jitter.x)   // size: loud sides push out, quiet ones sink in
            let sn = n * inv                                                 // stretch
            w /= simd_length(sn)
            n = orient * simd_normalize(sn)
            w += simd_dot(n, offset)                                         // position
            data += [n.x, n.y, n.z, w]
        }
        // lights: direction (xyz) + sharpness, colour + intensity
        for i in 0..<nl {
            let fi = Float(i)
            let lv = min(1.3, vals[(i * 8 / nl) % 8])   // lights spread over the spectrum, bass first
            let el = 0.45 + 0.4 * sin(lightAz[i] * 0.37 + fi * 1.9)
            let az = lightAz[i]
            let dir = SIMD3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
            let c = rc.palette.rgb(fi / Float(nl) + rc.phase)
            let col = c * 0.55 + SIMD3(repeating: 0.45)
            let inten = 0.35 + 2.2 * lv + 1.5 * beat
            data += [dir.x, dir.y, dir.z, 90 + 60 * fi, col.x, col.y, col.z, inten]
        }
        let view = rotX(0.62) * rc.camera.rotation * rotY(spin)
        var u = baseUniforms(rc)
        u.view0 = SIMD4(view[0][0], view[1][0], view[2][0], 0)
        u.view1 = SIMD4(view[0][1], view[1][1], view[2][1], 0)
        u.view2 = SIMD4(view[0][2], view[1][2], view[2][2], 0)
        u.world = rc.minDim * 0.4 * Float(s.zoom) * Float(s.size) * (1 + 0.03 * beat)
        u.count = Float(facets.count)
        u.p0 = SIMD4(Float(nl), Float(s.diamondFire), 3.6, 0)
        f.shaderMode = ShaderModeDraw(kind: .diamond, u: u, data: data)
    }
}
