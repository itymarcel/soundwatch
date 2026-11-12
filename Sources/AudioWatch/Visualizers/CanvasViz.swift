import Foundation
import simd

// Experimental 3D modes in which the music creates things that live for a while and then disappear:
// primitives, a particle field disturbed by invisible masses, and a patch of glowing mushrooms.

// MARK: - Shared: onsets, easing, springs

/// Spectral-flux onsets in three fixed bands (kick ≈ 30–150 Hz, snare/body ≈ 150 Hz–1.7 kHz, hats above),
/// each against its own adaptive threshold.
struct Onsets {
    private var prev: [Float] = []
    private var avg = [Float](repeating: 0.02, count: 3)
    private var since = [Double](repeating: 1, count: 3)

    /// Returns (band, strength 0…1) for each band that fired this frame.
    mutating func step(_ rc: RenderContext) -> [(band: Int, strength: Float)] {
        step(analyzer: rc.analyzer, s: rc.s, dt: rc.dt)
    }

    mutating func step(analyzer: Analyzer, s: VizSettings, dt: Double) -> [(band: Int, strength: Float)] {
        var s2 = s
        s2.minFreq = 30; s2.maxFreq = 16_000
        let b = analyzer.bands(count: 36, s: s2)
        for g in 0..<3 { since[g] += dt }
        guard prev.count == b.count else { prev = b; return [] }
        var out: [(band: Int, strength: Float)] = []
        for (g, range) in [0..<9, 9..<23, 23..<36].enumerated() {
            var flux: Float = 0
            for i in range { flux += max(0, b[i] - prev[i]) }
            flux /= Float(range.count)
            if flux > avg[g] * 2.2 + 0.015, since[g] > 0.08 {
                since[g] = 0
                out.append((g, min(1, flux * 5)))
            }
            avg[g] += (flux - avg[g]) * Float(1 - exp(-dt / 0.4))
        }
        prev = b
        return out
    }
}

enum Ease {
    static func outCubic(_ t: Float) -> Float { let u = 1 - min(1, max(0, t)); return 1 - u * u * u }
    static func inCubic(_ t: Float) -> Float { let u = min(1, max(0, t)); return u * u * u }
    static func inOutCubic(_ t: Float) -> Float {
        let u = min(1, max(0, t))
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }
    /// Overshoots a little (≈10 %) and settles: a soft "pop".
    static func outBack(_ t: Float) -> Float {
        let u = min(1, max(0, t)) - 1, c1: Float = 1.2, c3 = c1 + 1
        return 1 + c3 * u * u * u + c1 * u * u
    }
}

/// Critically damped spring: follows a target smoothly with no overshoot and no frame-rate dependence.
struct SmoothValue {
    var x: Float = 0, v: Float = 0
    mutating func step(to target: Float, dt: Float, omega: Float) -> Float {
        let f = 1 + 2 * dt * omega, oo = omega * omega, hoo = dt * oo, hhoo = dt * hoo
        let inv = 1 / (f + hhoo)
        let nx = (f * x + dt * v + hhoo * target) * inv
        v = (v + hoo * (target - x)) * inv
        x = nx
        return x
    }
}

private func rand3(_ r: Float) -> SIMD3<Float> {
    SIMD3(Float.random(in: -r...r), Float.random(in: -r...r), Float.random(in: -r...r))
}

private func circle(_ n: Int, radius: Float, y: Float = 0) -> [SIMD3<Float>] {
    (0...n).map { k in
        let a = 2 * Float.pi * Float(k) / Float(n)
        return SIMD3(cos(a) * radius, y, sin(a) * radius)
    }
}

// MARK: - Shared: meshes and lighting

/// Indexed triangle mesh with per-vertex normals.
struct Mesh {
    var v: [SIMD3<Float>] = []
    var n: [SIMD3<Float>] = []
    var t: [SIMD3<Int32>] = []

    /// A (rows+1) × (cols+1) vertex grid from a parametric surface; `wrap` closes the u direction.
    static func grid(rows: Int, cols: Int, wrap: Bool, _ f: (Float, Float) -> SIMD3<Float>) -> Mesh {
        var m = Mesh()
        let cu = wrap ? cols : cols + 1
        for r in 0...rows {
            for c in 0..<cu { m.v.append(f(Float(c) / Float(cols), Float(r) / Float(rows))) }
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let a = Int32(r * cu + c), b = Int32(r * cu + (c + 1) % cu)
                let d = Int32((r + 1) * cu + c), e = Int32((r + 1) * cu + (c + 1) % cu)
                m.t.append(SIMD3(a, b, e)); m.t.append(SIMD3(a, e, d))
            }
        }
        m.computeNormals()
        return m
    }

    /// Flat-shaded polyhedron: every face gets its own vertices, so normals stay crisp.
    static func faces(_ verts: [SIMD3<Float>], _ polys: [[Int]]) -> Mesh {
        var m = Mesh()
        for p in polys {
            let base = Int32(m.v.count)
            for i in p { m.v.append(verts[i]) }
            for k in 1..<(p.count - 1) { m.t.append(SIMD3(base, base + Int32(k), base + Int32(k + 1))) }
        }
        m.computeNormals()
        return m
    }

    mutating func computeNormals() {
        n = .init(repeating: .zero, count: v.count)
        for f in t {
            let a = v[Int(f.x)], b = v[Int(f.y)], c = v[Int(f.z)]
            let fn = simd_cross(b - a, c - a)
            n[Int(f.x)] += fn; n[Int(f.y)] += fn; n[Int(f.z)] += fn
        }
        for i in n.indices { n[i] = simd_length(n[i]) > 1e-9 ? simd_normalize(n[i]) : SIMD3(0, 1, 0) }
    }

    mutating func append(_ o: Mesh) {
        let base = Int32(v.count)
        v += o.v; n += o.n
        t += o.t.map { $0 &+ SIMD3(repeating: base) }
    }
}

/// Lights and projects meshes into screen triangles. Chrome: mirror metal shaded per pixel (triFrag), alpha-blended, painter-sorted.
/// Fresnel: glows where the surface turns away from the viewer (glassy rims), additive.
struct Painter {
    private var tris: [(TriVert, TriVert, TriVert, Float)] = []

    mutating func add(_ m: Mesh, view: simd_float3x3, rc: RenderContext, world: Float, look: SurfaceLook,
                      rgb: SIMD3<Float>, alpha: Float,
                      pos: (SIMD3<Float>) -> SIMD3<Float>, normal: (SIMD3<Float>) -> SIMD3<Float>) {
        guard alpha > 0.003 else { return }
        var out = [TriVert](repeating: TriVert(p: .zero, color: .zero), count: m.v.count)
        var depth = [Float](repeating: 0, count: m.v.count)
        let cam = SIMD3<Float>(0, 0, 3.6)
        for i in m.v.indices {
            let w = pos(m.v[i])
            let q = view * w
            var nn = simd_normalize(view * normal(m.n[i]))
            let toCam = simd_normalize(cam - q)
            var ndv = simd_dot(nn, toCam)
            if ndv < 0 { nn = -nn; ndv = -ndv }                   // two-sided
            var c: SIMD3<Float>, a: Float
            var chromeN = SIMD4<Float>(), chromeE = SIMD4<Float>()
            if look == .chrome {
                // lit per pixel in triFrag: pass the normal and eye vector, the colour only tints the metal
                c = rgb
                a = alpha * 0.97
                chromeN = SIMD4(nn, 1)
                chromeE = SIMD4(cam - q, 0)
            } else {                                              // fresnel (lines never reach the painter)
                let fr = pow(1 - ndv, 2.2)
                c = rgb * (0.12 + 1.6 * fr)
                a = alpha * (0.06 + 0.94 * fr)
            }
            let (p, _) = project(w, view, rc, world: world)
            out[i] = TriVert(p: p, color: SIMD4(c, a), n: chromeN, e: chromeE)
            depth[i] = q.z
        }
        for f in m.t {
            let i = Int(f.x), j = Int(f.y), k = Int(f.z)
            tris.append((out[i], out[j], out[k], (depth[i] + depth[j] + depth[k]) / 3))
        }
    }

    /// Emits everything collected this frame; shaded triangles far-to-near so nearer ones cover.
    mutating func flush(_ f: FrameBuilder, look: SurfaceLook) {
        if look == .chrome {
            tris.sort { $0.3 < $1.3 }
            for t in tris { f.trisOver.append(t.0); f.trisOver.append(t.1); f.trisOver.append(t.2) }
        } else {
            for t in tris { f.trisAdd.append(t.0); f.trisAdd.append(t.1); f.trisAdd.append(t.2) }
        }
        tris.removeAll(keepingCapacity: true)
    }
}

// MARK: - Primitives

/// 3D primitives conjured by the music. Every onset brings a shape into space; it hangs there, breathing
/// with its band, then leaves. Kicks bring the big round shapes, snares the solids, hats the small marks.
/// Lines: stroked in edge by edge. Shaded / Fresnel: solid or glassy surfaces that pop in and shrink away.
final class PrimitivesViz: Visualizer {
    private struct Prim {
        var kind: Int
        var edges: [(SIMD3<Float>, SIMD3<Float>)]
        var pos: SIMD3<Float>
        var size: Float
        var axis: SIMD3<Float>
        var angle: Float
        var spin: Float
        var born: Double
        var life: Double
        var band: Int
        var strength: Float
        var hue: Float
    }
    private var prims: [Prim] = []
    private var onsets = Onsets()
    private var painter = Painter()
    private var clock = 0.0
    private var drift: Float = 0
    private var levels = [SmoothValue](repeating: SmoothValue(), count: 3)

    private static let meshes: [Mesh] = makeMeshes()

    /// Surface meshes for kinds 0–7 (kinds 8+ are line marks in every render).
    private static func makeMeshes() -> [Mesh] {
        var out: [Mesh] = []
        // 0 sphere
        out.append(Mesh.grid(rows: 14, cols: 28, wrap: true) { (u: Float, v: Float) -> SIMD3<Float> in
            let th: Float = v * .pi, ph: Float = u * 2 * .pi
            return SIMD3<Float>(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
        })
        // 1 torus
        out.append(Mesh.grid(rows: 10, cols: 40, wrap: true) { (u: Float, v: Float) -> SIMD3<Float> in
            let a: Float = u * 2 * .pi, b: Float = v * 2 * .pi
            let rr: Float = 0.8 + 0.2 * cos(b)
            return SIMD3<Float>(rr * cos(a), 0.2 * sin(b), rr * sin(a))
        })
        // 2 octahedron
        let ov: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        out.append(Mesh.faces(ov, [[2, 0, 4], [2, 4, 1], [2, 1, 5], [2, 5, 0], [3, 4, 0], [3, 1, 4], [3, 5, 1], [3, 0, 5]]))
        // 3 helix tube
        out.append(Mesh.grid(rows: 6, cols: 120, wrap: false) { (u: Float, v: Float) -> SIMD3<Float> in
            let a: Float = u * 6 * .pi
            let c = SIMD3<Float>(cos(a) * 0.5, u * 2 - 1, sin(a) * 0.5)
            let k: Float = 0.5 * 6 * .pi
            let tangent = simd_normalize(SIMD3<Float>(-sin(a) * k, 2, cos(a) * k))
            let n1 = simd_normalize(simd_cross(tangent, SIMD3<Float>(0, 1, 0)))
            let n2 = simd_cross(tangent, n1)
            let b: Float = v * 2 * .pi
            return c + (n1 * cos(b) + n2 * sin(b)) * 0.07
        })
        // 4 cube
        var cv: [SIMD3<Float>] = []
        for i in 0..<8 {
            let x: Float = Float(i & 1) * 2 - 1, y: Float = Float((i >> 1) & 1) * 2 - 1, z: Float = Float((i >> 2) & 1) * 2 - 1
            cv.append(SIMD3<Float>(x, y, z) * 0.6)
        }
        out.append(Mesh.faces(cv, [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]))
        // 5 tetrahedron
        let tv: [SIMD3<Float>] = [SIMD3<Float>(1, 1, 1) * 0.6, SIMD3<Float>(1, -1, -1) * 0.6, SIMD3<Float>(-1, 1, -1) * 0.6, SIMD3<Float>(-1, -1, 1) * 0.6]
        out.append(Mesh.faces(tv, [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]]))
        // 6 plane
        out.append(Mesh.grid(rows: 1, cols: 1, wrap: false) { (u: Float, v: Float) -> SIMD3<Float> in SIMD3<Float>(u * 2 - 1, 0, v * 2 - 1) })
        // 7 nested square frames
        var frames = Mesh()
        let sizes: [Float] = [1, 0.7, 0.45, 0.25]
        for (k, r) in sizes.enumerated() {
            let z: Float = Float(k) * 0.4 - 0.6, w: Float = r * 0.18
            frames.append(Mesh.grid(rows: 1, cols: 4, wrap: true) { (u: Float, v: Float) -> SIMD3<Float> in
                let a: Float = u * 2 * .pi + .pi / 4
                let rr: Float = (r - w * v) * Float(2).squareRoot()
                return SIMD3<Float>(cos(a) * rr, sin(a) * rr, z)
            })
        }
        out.append(frames)
        return out
    }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let dt = Float(rc.dt)
        let raw = [rc.analyzer.level(30, 150, s: s), rc.analyzer.level(150, 1700, s: s), rc.analyzer.level(1700, 14000, s: s)]
        var lv = [Float](repeating: 0, count: 3)
        for g in 0..<3 { lv[g] = levels[g].step(to: min(1, raw[g]), dt: dt, omega: 14) }
        if !rc.frozen {
            clock += rc.dt
            drift += Float(rc.dt * s.motion * 0.12)
            for hit in onsets.step(rc) {
                var n = s.primDensity
                while n > 0 {
                    if n >= 1 || Double.random(in: 0..<1) < n { spawn(hit.band, hit.strength) }
                    n -= 1
                }
            }
            prims.removeAll { clock - $0.born > $0.life }
            let cap = s.look == .lines ? 400 : 120                        // surfaces cost more
            if prims.count > cap { prims.removeFirst(prims.count - cap) }
        }

        let view = rotX(0.18) * rc.camera.rotation * rotY(drift)
        let world = rc.minDim * 0.36 * Float(s.zoom)
        let lw = max(0.8, rc.unit * 1.1)
        for p in prims {
            let ageS = Float(clock - p.born)
            let age = ageS / Float(p.life)
            let t: Float = s.colorBy == .frequency ? p.hue : min(1, p.strength * (0.5 + lv[p.band]))
            let breathe = 1 + 0.18 * lv[p.band] * Float(s.reach)
            let q = simd_quatf(angle: p.angle + p.spin * ageS, axis: p.axis)
            let surface = s.look != .lines && p.kind < Self.meshes.count

            if surface {
                // pop in with a soft overshoot, leave by shrinking and fading
                let inK = Ease.outBack(ageS / 0.45)
                let outT = max(0, (age - 0.7) / 0.3)
                let scale = p.size * breathe * inK * (1 - 0.6 * Ease.inCubic(outT))
                let alpha = (1 - Ease.inCubic(outT)) * (0.75 + 0.25 * p.strength)
                let rgb = rc.palette.rgb(t + rc.phase)
                painter.add(Self.meshes[p.kind], view: view, rc: rc, world: world, look: s.look, rgb: rgb, alpha: alpha,
                            pos: { p.pos + q.act($0) * scale }, normal: { q.act($0) })
                continue
            }

            let drawIn = min(1, age / 0.18)                         // first ~18 % of life: stroke it in
            let ease = Ease.outCubic(drawIn)
            let flash: Float = age < 0.25 ? 1.4 : 1
            let alpha = (1 - Ease.inCubic(max(0, (age - 0.6) / 0.4))) * (0.7 + 0.3 * p.strength) * flash
            let scale = p.size * breathe * (0.85 + 0.15 * ease)
            let shown = Float(p.edges.count) * ease
            let col = rc.col(t + rc.phase, alpha)
            for (k, e) in p.edges.enumerated() {
                let frac = shown - Float(k)
                guard frac > 0 else { break }
                let a = p.pos + q.act(e.0) * scale
                var b = p.pos + q.act(e.1) * scale
                if frac < 1 { b = a + (b - a) * frac }               // the edge being drawn right now
                let (pa, ka) = project(a, view, rc, world: world)
                let (pb, kb) = project(b, view, rc, world: world)
                f.line(pa, pb, col, lw * 0.5 * (ka + kb))
            }
            if drawIn < 1, Int(shown) < p.edges.count {              // the pen tip while drawing
                let last = p.edges[Int(shown)]
                let head = p.pos + q.act(last.0 + (last.1 - last.0) * (shown - floor(shown))) * scale
                let (ph, kh) = project(head, view, rc, world: world)
                f.dot(ph, lw * 2.5 * kh, rc.col(t + rc.phase, 1))
            }
        }
        painter.flush(f, look: s.look)
    }

    private func spawn(_ band: Int, _ strength: Float) {
        let kinds: [[Int]] = [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]]
        let kind = kinds[band].randomElement()!
        let size: Float = [Float.random(in: 0.35...0.7), Float.random(in: 0.16...0.34), Float.random(in: 0.05...0.16)][band]
        let life: Double = [Double.random(in: 2.5...4), Double.random(in: 1.4...2.4), Double.random(in: 0.6...1.2)][band]
        prims.append(Prim(kind: kind, edges: Self.edges(kind),
                          pos: SIMD3(Float.random(in: -1.3...1.3), Float.random(in: -0.75...0.75), Float.random(in: -0.8...0.8)),
                          size: size * (0.6 + 0.6 * strength), axis: simd_normalize(rand3(1) + SIMD3(0, 0.01, 0)),
                          angle: Float.random(in: 0..<(2 * .pi)), spin: Float.random(in: -0.6...0.6), born: clock, life: life,
                          band: band, strength: strength, hue: Float(band) * 0.33 + Float.random(in: -0.06...0.06)))
    }

    /// Unit-size outline of each primitive kind, in drawing order.
    private static func edges(_ kind: Int) -> [(SIMD3<Float>, SIMD3<Float>)] {
        func poly(_ pts: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] { zip(pts, pts.dropFirst()).map { ($0, $1) } }
        switch kind {
        case 0:   // wire sphere: latitudes, then meridians
            var e: [(SIMD3<Float>, SIMD3<Float>)] = []
            for k in 1..<6 {
                let th = Float.pi * Float(k) / 6
                e += poly(circle(32, radius: sin(th), y: cos(th)))
            }
            for k in 0..<6 {
                let ph = Float.pi * Float(k) / 6
                e += poly((0...32).map { i in
                    let th = 2 * Float.pi * Float(i) / 32
                    return SIMD3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
                })
            }
            return e
        case 1:   // torus outline: rings around the tube and along it
            var e: [(SIMD3<Float>, SIMD3<Float>)] = []
            for r in [0.6, 0.8, 1.0] as [Float] { e += poly(circle(48, radius: r)) }
            for k in 0..<12 {
                let a = 2 * Float.pi * Float(k) / 12
                e += poly((0...16).map { i in
                    let b = 2 * Float.pi * Float(i) / 16
                    return SIMD3((0.8 + 0.2 * cos(b)) * cos(a), 0.2 * sin(b), (0.8 + 0.2 * cos(b)) * sin(a))
                })
            }
            return e
        case 2:   // octahedron
            let v: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
            return [(2, 0), (2, 4), (2, 1), (2, 5), (3, 0), (3, 4), (3, 1), (3, 5), (0, 4), (4, 1), (1, 5), (5, 0)].map { (v[$0.0], v[$0.1]) }
        case 3:   // helix
            return poly((0...90).map { i in
                let t = Float(i) / 90
                return SIMD3(cos(t * 6 * .pi) * 0.5, t * 2 - 1, sin(t * 6 * .pi) * 0.5)
            })
        case 4:   // cube
            let c: [SIMD3<Float>] = (0..<8).map { SIMD3(Float($0 & 1) * 2 - 1, Float(($0 >> 1) & 1) * 2 - 1, Float(($0 >> 2) & 1) * 2 - 1) }
            return [(0, 1), (1, 3), (3, 2), (2, 0), (4, 5), (5, 7), (7, 6), (6, 4), (0, 4), (1, 5), (2, 6), (3, 7)].map { (c[$0.0] * 0.6, c[$0.1] * 0.6) }
        case 5:   // tetrahedron
            let v: [SIMD3<Float>] = [SIMD3(1, 1, 1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1)].map { $0 * 0.6 }
            return [(0, 1), (1, 2), (2, 0), (0, 3), (1, 3), (2, 3)].map { (v[$0.0], v[$0.1]) }
        case 6:   // grid plane
            var e: [(SIMD3<Float>, SIMD3<Float>)] = []
            for k in 0...6 {
                let u = Float(k) / 3 - 1
                e.append((SIMD3(u, 0, -1), SIMD3(u, 0, 1)))
                e.append((SIMD3(-1, 0, u), SIMD3(1, 0, u)))
            }
            return e
        case 7:   // nested square frames
            let sizes: [Float] = [1, 0.7, 0.45, 0.25]
            var e: [(SIMD3<Float>, SIMD3<Float>)] = []
            for (k, r) in sizes.enumerated() {
                let z = Float(k) * 0.4 - 0.6
                let c: [SIMD3<Float>] = [SIMD3(-r, -r, z), SIMD3(r, -r, z), SIMD3(r, r, z), SIMD3(-r, r, z), SIMD3(-r, -r, z)]
                e += poly(c)
            }
            return e
        case 8:   // burst of rays
            return (0..<10).map { _ in (SIMD3<Float>(), simd_normalize(rand3(1) + SIMD3(0.001, 0, 0))) }
        case 9:   // axis cross
            return [(SIMD3(-1, 0, 0), SIMD3(1, 0, 0)), (SIMD3(0, -1, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(0, 0, 1))]
        case 10:  // barcode
            var x: Float = -1
            var e: [(SIMD3<Float>, SIMD3<Float>)] = []
            while x < 1 {
                let h = Float.random(in: 0.3...1)
                e.append((SIMD3(x, -h, 0), SIMD3(x, h, 0)))
                x += Float.random(in: 0.04...0.22)
            }
            return e
        default:  // dashed line
            return (0..<8).map { k in
                let a = Float(k) / 4 - 1
                return (SIMD3(a, 0, 0), SIMD3(a + 0.14, 0, 0))
            }
        }
    }
}

// MARK: - Field

/// A ball of particles at rest on a loose 3D lattice, each on a spring to its home. Invisible spheres of
/// different sizes and masses appear with the music: each one attracts particles (more mass, more pull) but
/// no particle can enter it, so the particles pile up on its surface and reveal its shape. When a sphere
/// vanishes its shell is released and the particles drift home; Springiness sets how hard they pull back.
final class FieldViz: Visualizer {
    private struct Body {
        var pos: SIMD3<Float>
        var vel: SIMD3<Float>
        var radius: Float
        var mass: Float
        var born: Double
        var life: Double
        /// 0 … 1 presence (eased in and out); scales radius and mass.
        var k: Float = 0
    }
    private var home: [SIMD3<Float>] = [], pos: [SIMD3<Float>] = [], vel: [SIMD3<Float>] = []
    private var builtFor = 0
    private var bodies: [Body] = []
    private var onsets = Onsets()
    private var clock = 0.0
    private var drift: Float = 0
    /// Particles fill a ball of this radius.
    private static let ballR: Float = 1

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        ensure(Int(s.fieldParticles))
        let dt = Float(min(rc.dt, 1.0 / 30))
        if !rc.frozen {
            clock += rc.dt
            drift += dt * Float(s.motion) * 0.06
            for hit in onsets.step(rc) where bodies.count < 14 { spawn(hit.band, hit.strength) }
            for i in bodies.indices {
                let age = Float((clock - bodies[i].born) / bodies[i].life)
                // ease in over the first 15 %, out over the last 30 %
                bodies[i].k = Ease.outCubic(age / 0.15) * (1 - Ease.inOutCubic((age - 0.7) / 0.3))
                bodies[i].pos += bodies[i].vel * dt * Float(0.3 + s.motion)
                // bounce softly off the inside of the ball
                let r = simd_length(bodies[i].pos), limit = Self.ballR * 0.85
                if r > limit {
                    let n = bodies[i].pos / r
                    bodies[i].vel -= 2 * simd_dot(bodies[i].vel, n) * n
                    bodies[i].pos = n * limit
                }
            }
            bodies.removeAll { clock - $0.born > $0.life }
            simulate(dt, spring: Float(0.15 + 4.5 * s.fieldSpring * s.fieldSpring), reach: Float(s.reach))
        }

        let view = rotX(0.25) * rc.camera.rotation * rotY(drift)
        let world = rc.minDim * 0.44 * Float(s.zoom)
        let lw = max(0.7, rc.unit * 0.9)
        let byFreq = s.colorBy == .frequency, phase = rc.phase, square: Float = s.segmented ? 1 : 0
        if s.style == .points {
            // One dot per particle: fill the list in place, on all cores (this loop used to be most of the frame's CPU time).
            let n = pos.count, base = f.add.count
            f.add.append(contentsOf: repeatElement(Seg(a: .zero, b: .zero, color: .zero, width: 0), count: n))
            home.withUnsafeBufferPointer { H in
            pos.withUnsafeBufferPointer { P in
            f.add.withUnsafeMutableBufferPointer { A in
                let chunks = Self.chunks(n)
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    for i in (c * n / chunks)..<((c + 1) * n / chunks) {
                        let e = min(1, simd_length(P[i] - H[i]) * 5)
                        let tc: Float = byFreq ? (H[i].x + Self.ballR) / (2 * Self.ballR) : 0.3 + 0.7 * e
                        let (p, k) = project(P[i], view, rc, world: world)
                        A[base + i] = Seg(a: p, b: p, color: rc.col(tc + phase, 0.4 + 0.6 * e), width: 2 * lw * k, cap: square)
                    }
                }
            } } }
            return
        }
        for i in pos.indices {
            let off = simd_length(pos[i] - home[i])
            let e = min(1, off * 5)
            let tc: Float = byFreq ? (home[i].x + Self.ballR) / (2 * Self.ballR) : 0.3 + 0.7 * e   // palettes start near black
            let col = rc.col(tc + phase, 0.4 + 0.6 * e)
            let (p, k) = project(pos[i], view, rc, world: world)
            if simd_length(vel[i]) > 0.02 {
                let (pt, _) = project(pos[i] - vel[i] * 0.06, view, rc, world: world)
                f.line(pt, p, col, lw * k)
                if s.style == .lines { continue }
            }
            f.dot(p, lw * k, col, square: s.segmented)
        }
    }

    /// How many pieces to split a per-particle loop into (one per ~8k particles, at most 32).
    private static func chunks(_ n: Int) -> Int { max(1, min(32, n / 8192)) }

    private func spawn(_ band: Int, _ strength: Float) {
        // kicks: big and heavy, long-lived; snares: medium; hats: small, light and brief
        let radius: Float = [Float.random(in: 0.28...0.5), Float.random(in: 0.15...0.28), Float.random(in: 0.06...0.13)][band]
        let life: Double = [Double.random(in: 2.5...4.5), Double.random(in: 1.5...2.8), Double.random(in: 0.7...1.3)][band]
        let density: Float = [1.4, 1.0, 0.7][band]
        let mass = radius * radius * radius * density * (0.6 + 0.8 * strength) * 10
        var p = rand3(1)
        while simd_length(p) > 1 { p = rand3(1) }
        bodies.append(Body(pos: p * Self.ballR * 0.75,
                           vel: rand3(0.25), radius: radius * (0.8 + 0.4 * strength), mass: mass,
                           born: clock, life: life))
    }

    private func simulate(_ dt: Float, spring: Float, reach: Float) {
        let damp = exp(-dt * 2.6)
        let active = bodies.filter { $0.k > 0.001 }
        home.withUnsafeBufferPointer { H in
        pos.withUnsafeMutableBufferPointer { P in
        vel.withUnsafeMutableBufferPointer { V in
            let n = P.count, chunks = Self.chunks(n)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
            for i in (c * n / chunks)..<((c + 1) * n / chunks) {
                let p = P[i]
                var force = (H[i] - p) * spring
                for b in active {
                    let d = p - b.pos
                    let r = b.radius * b.k
                    let range = r * 3.2 + 0.05
                    let d2 = simd_length_squared(d)
                    guard d2 < range * range else { continue }
                    let dist = max(d2.squareRoot(), 1e-4)
                    let dir = d / dist
                    if dist < r {
                        force += dir * (r - dist) * 60                   // solid: no entry, push to the surface
                    } else {
                        let g = b.mass * b.k * reach / (dist * dist + 0.02)   // gravity-like pull toward the surface
                        let fade = 1 - (dist - r) / (range - r)
                        force -= dir * g * fade * fade
                    }
                }
                let v = (V[i] + force * dt) * damp
                V[i] = v
                P[i] = p + v * dt
            }
            }
        } } }
    }

    /// Homes on a jittered 3D lattice, keeping the points inside the ball.
    private func ensure(_ want: Int) {
        guard want != builtFor else { return }
        builtFor = want
        let R = Self.ballR
        let cell = pow(4 / 3 * Float.pi * R * R * R / Float(want), 1.0 / 3.0)
        let n = max(2, Int(2 * R / cell))
        home = []
        home.reserveCapacity(want)
        for x in 0..<n { for y in 0..<n { for z in 0..<n {
            let g = (SIMD3(Float(x), Float(y), Float(z)) / Float(n - 1) * 2 - 1) * R + rand3(cell * 0.15)
            if simd_length(g) <= R { home.append(g) }
        } } }
        pos = home
        vel = .init(repeating: .zero, count: home.count)
    }
}

// MARK: - Mushrooms

/// Bioluminescent mushrooms. Onsets sprout new ones; they grow faster when the music is busy, each glows and
/// bobs with its own frequency band, puffs spores on beats, and after a while wilts, droops and fades.
/// Mycelium threads on the ground link each mushroom to its nearest neighbours. Every movement is eased or
/// spring-smoothed so nothing jumps.
final class MushroomsViz: Visualizer {
    private struct Shroom {
        var base: SIMD2<Float>
        var height: Float
        var capR: Float
        var band: Int
        var hue: Float
        var lean: SIMD2<Float>
        var growth: Float = 0                                     // 0 … 1, linear; shown eased
        var age: Double = 0
        var lifespan: Double
        var wilt: Float = 0                                       // 0 … 1, linear; shown eased
        var energy = SmoothValue()
        var sizeClass: Int                                        // 0 kick (big), 1 snare, 2 hats (tiny)
        var target: Float = 0                                     // growth steps toward this on its band's hits
        var grownAge: Double = 0                                  // time spent fully grown
        var spots: [SIMD2<Float>]                                 // (angle, radial fraction) of glowing spots
    }
    private struct Spore { var p: SIMD3<Float>; var v: SIMD3<Float>; var life: Float; var hue: Float }

    private var shrooms: [Shroom] = []
    private var spores: [Spore] = []
    private var onsets = Onsets()
    private var painter = Painter()
    private var busy = SmoothValue()
    private var drift: Float = 0
    private var lastBeat = 0
    private let ground: Float = -0.75

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let lv = rc.analyzer.bands(count: 12, s: s)
        let dt = Float(rc.dt)
        let activity = busy.step(to: min(1.2, rc.analyzer.level(40, 8000, s: s)), dt: dt, omega: 3)
        if !rc.frozen {
            drift += dt * Float(s.motion) * 0.05
            let maxN = Int(s.shroomCount)
            let hits = onsets.step(rc)
            for hit in hits {
                // each hit in a mushroom's band nudges its growth a small step: big ones on kicks, tiny ones on hats
                let step: [Float] = [0.045, 0.06, 0.025]
                for i in shrooms.indices where shrooms[i].sizeClass == hit.band && shrooms[i].wilt == 0 {
                    shrooms[i].target = min(1, shrooms[i].target + step[min(2, hit.band)] * (0.6 + 0.8 * hit.strength) * Float(s.reach))
                }
                if shrooms.filter({ $0.wilt == 0 }).count < maxN { sprout(lv, hit.strength, size: hit.band) }
            }
            if shrooms.isEmpty && activity > 0.15 { sprout(lv, 0.5, size: 0) }
            let beat = rc.analyzer.beatCount != lastBeat
            lastBeat = rc.analyzer.beatCount
            let alive = shrooms.count
            for i in shrooms.indices {
                shrooms[i].age += rc.dt
                // a very slow creep so quiet passages still grow, plus the beat steps above;
                // growth glides toward the target with an ease-out so each step swells in softly
                shrooms[i].target = min(1, shrooms[i].target + dt * 0.012 * (0.3 + activity))
                shrooms[i].growth += (shrooms[i].target - shrooms[i].growth) * (1 - exp(-dt * 2.5))
                if shrooms[i].growth > 0.97 { shrooms[i].grownAge += rc.dt }
                _ = shrooms[i].energy.step(to: min(1.2, lv[shrooms[i].band] * 1.1), dt: dt, omega: 12)
                if shrooms[i].grownAge > shrooms[i].lifespan || shrooms[i].age > 120 || alive - i > maxN + 4 {
                    shrooms[i].wilt = min(1, shrooms[i].wilt + dt / 3.5)
                }
                if beat, shrooms[i].growth > 0.6, shrooms[i].wilt < 0.4, shrooms[i].energy.x > 0.35 { puff(shrooms[i]) }
            }
            shrooms.removeAll { $0.wilt >= 1 }
            for i in spores.indices {
                spores[i].v += SIMD3(sin(spores[i].p.y * 9 + drift * 30) * 0.08, 0.04, cos(spores[i].p.x * 9) * 0.08) * dt
                spores[i].v *= exp(-dt * 0.8)
                spores[i].p += spores[i].v * dt
                spores[i].life -= dt / 3.2
            }
            spores.removeAll { $0.life <= 0 }
        }

        let view = rotX(0.22) * rc.camera.rotation * rotY(drift)
        let world = rc.minDim * 0.42 * Float(s.zoom)
        let lw = max(0.5, rc.unit * 0.8)
        func P(_ p: SIMD3<Float>) -> (SIMD2<Float>, Float) { project(p, view, rc, world: world) }
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD4<Float>, _ w: Float) {
            let (pa, ka) = P(a), (pb, kb) = P(b)
            f.line(pa, pb, c, w * 0.5 * (ka + kb))
        }

        // ground rings
        for r in [0.4, 0.8, 1.2] as [Float] {
            let pts = circle(72, radius: r, y: ground)
            for k in 1..<pts.count { line(pts[k - 1], pts[k], rc.inkC(0.05), lw * 0.6) }
        }
        // mycelium: each mushroom to its two nearest, a curving glowing thread
        for (i, a) in shrooms.enumerated() {
            let near = shrooms.indices.filter { $0 != i }
                .sorted { simd_distance(shrooms[$0].base, a.base) < simd_distance(shrooms[$1].base, a.base) }.prefix(2)
            for j in near where j > i {
                let b = shrooms[j]
                let present = min(Ease.outCubic(a.growth * 2), Ease.outCubic(b.growth * 2)) * (1 - Ease.inOutCubic(max(a.wilt, b.wilt)))
                let glow = min(1, (a.energy.x + b.energy.x) * 0.5) * present
                let col = rc.col((s.colorBy == .frequency ? (a.hue + b.hue) / 2 : glow) + rc.phase, (0.06 + 0.4 * glow) * present)
                var prev = SIMD3(a.base.x, ground, a.base.y)
                let side = SIMD2(-(b.base - a.base).y, (b.base - a.base).x)
                for k in 1...12 {
                    let t = Float(k) / 12
                    let m = a.base + (b.base - a.base) * t + side * sin(t * .pi) * 0.12
                    let p = SIMD3(m.x, ground, m.y)
                    line(prev, p, col, lw * 0.7)
                    prev = p
                }
            }
        }

        for m in shrooms {
            let energy = m.energy.x
            let g = Ease.inOutCubic(m.growth) * 0.85 + m.growth * 0.15
            let w = Ease.inOutCubic(m.wilt)
            let fade = (1 - Ease.inCubic(m.wilt)) * Ease.outCubic(m.growth * 4)
            let tc: Float = s.colorBy == .frequency ? m.hue : min(1, energy)
            let glow = (0.15 + 0.95 * min(1, energy)) * fade
            let col = rc.col(tc + rc.phase, glow)
            let stemCol = rc.col(tc + rc.phase + 0.08, 0.35 * fade + 0.3 * glow)
            let h = m.height * g * (1 - 0.15 * w) * (1 + 0.08 * energy * Float(s.reach))

            // stem: a quadratic curve that leans, then droops as the mushroom wilts
            let baseP = SIMD3(m.base.x, ground, m.base.y)
            let lean3 = SIMD3(m.lean.x, 0, m.lean.y)
            let ctrl = baseP + lean3 * h * 0.25 + SIMD3(0, h * 0.6, 0)
            let top = baseP + lean3 * h * (0.25 + w * 0.9) + SIMD3(0, h * (1 - 0.55 * w), 0)
            func stem(_ t: Float) -> SIMD3<Float> {
                let w0: Float = (1 - t) * (1 - t), w1: Float = 2 * t * (1 - t), w2: Float = t * t
                return baseP * w0 + ctrl * w1 + top * w2
            }
            // cap: a bud that opens into a dome (soft overshoot), tilts down when wilting, swells with its band
            let open = Ease.outBack((m.growth - 0.3) / 0.7)
            let R = m.capR * (0.35 + 0.65 * max(0, open)) * (1 + 0.2 * energy * Float(s.reach))
            let capH = m.capR * (0.9 - 0.45 * min(1, max(0, open)))
            let tilt = simd_quatf(angle: w * 1.3, axis: simd_normalize(SIMD3(m.lean.y, 0, -m.lean.x) + SIMD3(0.001, 0, 0)))
            func cap(_ ang: Float, _ r: Float) -> SIMD3<Float> {     // r: 0 = crown … 1 = rim
                let y = capH * (1 - r * r) - capH * 0.15
                return top + tilt.act(SIMD3(cos(ang) * r * R, y, sin(ang) * r * R))
            }

            if s.look == .lines {
                var prev = baseP
                for k in 1...14 {
                    let p = stem(Float(k) / 14)
                    line(prev, p, stemCol, lw * (2.2 - 1.2 * Float(k) / 14))
                    prev = p
                }
                let meridians = max(6, min(14, Int(m.capR * 50)))
                for k in 0..<meridians {
                    let ang = 2 * Float.pi * Float(k) / Float(meridians)
                    var pp = cap(ang, 0)
                    for j in 1...6 {
                        let p = cap(ang, Float(j) / 6)
                        line(pp, p, col, lw)
                        pp = p
                    }
                    line(top, cap(ang + .pi / Float(meridians), 1), rc.col(tc + rc.phase + 0.15, glow * 0.45), lw * 0.6)   // gills
                }
                for r in [0.45, 0.8, 1.0] as [Float] {
                    var pp = cap(0, r)
                    for k in 1...40 {
                        let p = cap(2 * Float.pi * Float(k) / 40, r)
                        line(pp, p, col, lw * (r == 1 ? 1.4 : 0.8))
                        pp = p
                    }
                }
            } else {
                let stemR = m.capR * 0.16
                let lod = min(1, max(0.3, m.capR / 0.35))          // fewer facets for small mushrooms
                let stemMesh = Mesh.grid(rows: Int(20 * lod), cols: max(8, Int(18 * lod)), wrap: true) { u, v in
                    let c = stem(v)
                    let a = u * 2 * .pi
                    return c + SIMD3(cos(a), 0, sin(a)) * stemR * (1.25 - 0.4 * v)
                }
                let capMesh = Mesh.grid(rows: max(6, Int(16 * lod)), cols: max(14, Int(48 * lod)), wrap: true) { u, v in cap(u * 2 * .pi, v) }
                let capRGB = rc.palette.rgb(tc + rc.phase) * (0.55 + 0.6 * min(1, energy))
                let stemRGB = rc.palette.rgb(tc + rc.phase + 0.08) * 0.7
                painter.add(stemMesh, view: view, rc: rc, world: world, look: s.look, rgb: stemRGB, alpha: fade,
                            pos: { $0 }, normal: { $0 })
                painter.add(capMesh, view: view, rc: rc, world: world, look: s.look, rgb: capRGB, alpha: fade,
                            pos: { $0 }, normal: { $0 })
            }
            for sp in m.spots {
                let (p, k) = P(cap(sp.x, sp.y) + SIMD3(0, 0.004, 0))
                f.dot(p, lw * (1.2 + 4 * energy) * k, rc.col(tc + rc.phase + 0.3, min(1, glow * 1.5)))
            }
        }
        painter.flush(f, look: s.look)
        for sp in spores {
            let (p, k) = P(sp.p)
            let a = Ease.outCubic(sp.life)                         // fade out gently
            f.dot(p, lw * (0.6 + 0.8 * a) * k, rc.col(sp.hue + rc.phase, a * 0.9))
        }
    }

    /// `size`: 0 = kick (big), 1 = snare (medium), 2 = hats (tiny).
    private func sprout(_ lv: [Float], _ strength: Float, size: Int) {
        // the band it belongs to: picked in proportion to what's loud now
        let total = lv.reduce(0, +)
        var pick = Float.random(in: 0..<max(total, 1e-4)), band = 0
        for (i, v) in lv.enumerated() { pick -= v; if pick <= 0 { band = i; break } }
        // heights spread log-uniformly within each class: giants (kicks) down to tiny buttons (hats)
        let ranges: [ClosedRange<Float>] = [0.42...0.95, 0.2...0.45, 0.05...0.2]
        let rg = ranges[min(2, size)]
        let h = exp(Float.random(in: log(rg.lowerBound)...log(rg.upperBound))) * (0.85 + 0.3 * strength)
        let capR = h * Float.random(in: 0.3...0.62)
        var base = SIMD2<Float>()
        for _ in 0..<16 {
            let a = Float.random(in: 0..<(2 * .pi)), r = Float.random(in: 0...1).squareRoot() * 1.4
            base = SIMD2(cos(a) * r, sin(a) * r)
            if shrooms.allSatisfy({ simd_distance($0.base, base) > ($0.capR + capR) * 0.55 }) { break }
        }
        let a = Float.random(in: 0..<(2 * .pi))
        shrooms.append(Shroom(base: base, height: h, capR: capR, band: band,
                              hue: Float(band) / 12 + Float.random(in: -0.05...0.05),
                              lean: SIMD2(cos(a), sin(a)) * Float.random(in: 0...0.6),
                              lifespan: Double.random(in: 4...9) * Double(0.7 + h * 0.5),
                              sizeClass: min(2, size),
                              spots: (0..<7).map { _ in SIMD2(Float.random(in: 0..<(2 * .pi)), Float.random(in: 0.2...0.85)) }))
        shrooms[shrooms.count - 1].target = 0.06 + 0.06 * strength       // a gentle first push out of the ground
    }

    private func puff(_ m: Shroom) {
        let h = m.height * Ease.outCubic(m.growth)
        let top = SIMD3(m.base.x + m.lean.x * h * 0.25, ground + h, m.base.y + m.lean.y * h * 0.25)
        for _ in 0..<8 where spores.count < 600 {
            let a = Float.random(in: 0..<(2 * .pi))
            spores.append(Spore(p: top + SIMD3(cos(a), 0, sin(a)) * m.capR * 0.6,
                                v: SIMD3(cos(a) * 0.12, Float.random(in: 0.05...0.25), sin(a) * 0.12),
                                life: 1, hue: m.hue + 0.3))
        }
    }
}
