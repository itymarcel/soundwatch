import Foundation
import Metal
import Accelerate
import simd

/// Everything the Forest is built from, generated in code at first use (no image or model files):
/// the terrain's noise texture, the foliage atlas and the tree meshes.
enum ForestAssets {
    // MARK: - Noise

    /// The terrain's noise (ForestTerrain.noise) as a texture.
    static func noiseTexture(device: MTLDevice) -> MTLTexture {
        let n = ForestTerrain.size
        // half floats: filtered at full rate and half the memory traffic of rgba32Float (the terrain, water and
        // scatter shaders sample it ~30 times per pixel / vertex); the values are within ±4, so half keeps ~1e-3
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: n, height: n, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        var half = [UInt16](repeating: 0, count: n * n * 4)
        ForestTerrain.noise.withUnsafeBufferPointer { src in
            half.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(src.count), rowBytes: src.count * 4)
                var o = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(dst.count), rowBytes: dst.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &o, 0)
            }
        }
        half.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 8)
        }
        return t
    }

    // MARK: - Foliage atlas

    /// 1024 × 512, mipmapped: left half a spruce frond (a twig with needles, along x), right half a cluster of leaves.
    /// rgb = brightness variation (multiplied onto the species' colour), a = coverage.
    static func leafAtlas(device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture {
        let W = 1024, H = 512
        var px = [UInt8](repeating: 0, count: W * H * 4)
        var rng = SplitMix(seed: 0x1EAF)
        func plot(_ x: Int, _ y: Int, _ v: Float, _ a: Float) {
            guard x >= 0, y >= 0, x < W, y < H else { return }
            let o = (y * W + x) * 4
            let na = max(Float(px[o + 3]) / 255, a)
            if a >= Float(px[o + 3]) / 255 {
                let c = UInt8(max(0, min(255, v * 255)))
                px[o] = c; px[o + 1] = c; px[o + 2] = c
            }
            px[o + 3] = UInt8(max(0, min(255, na * 255)))
        }
        /// a soft line from a to b, width w px, brightness v0 → v1
        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ w0: Float, _ w1: Float, _ v0: Float, _ v1: Float) {
            let len = simd_length(b - a)
            let steps = max(1, Int(len * 1.5))
            for s in 0...steps {
                let t = Float(s) / Float(steps)
                let p = a + (b - a) * t
                let w = w0 + (w1 - w0) * t, v = v0 + (v1 - v0) * t
                let r = Int(w.rounded(.up)) + 1
                for dy in -r...r { for dx in -r...r {
                    let d = (Float(dx * dx + dy * dy)).squareRoot()
                    let cov = max(0, min(1, w * 0.5 + 0.5 - d))
                    if cov > 0 { plot(Int(p.x) + dx, Int(p.y) + dy, v, cov) }
                } }
            }
        }
        // spruce frond: a main twig along x with side twigs, needles all along both
        let midY: Float = 256
        line(SIMD2(8, midY), SIMD2(500, midY + 4), 5, 1.5, 0.35, 0.5)
        func needles(from a: SIMD2<Float>, to b: SIMD2<Float>, len0: Float, len1: Float, density: Int) {
            let dir = simd_normalize(b - a), side = SIMD2(-dir.y, dir.x)
            for k in 0..<density {
                let t = Float(k) / Float(density)
                let p = a + (b - a) * t
                let L = len0 + (len1 - len0) * t
                for sgn in [Float(-1), 1] {
                    let ang = Float(rng.unit()) * 0.5 + 0.6
                    let d = simd_normalize(dir * cos(ang) + side * sgn * sin(ang))
                    let l = L * Float(0.7 + 0.5 * rng.unit())
                    line(p, p + d * l, 2.4, 1.2, 0.55, 0.95 + Float(rng.unit()) * 0.3)
                }
            }
        }
        needles(from: SIMD2(10, midY), to: SIMD2(500, midY + 4), len0: 34, len1: 14, density: 150)
        for k in 0..<9 {
            let t = Float(k) / 9 * 0.8 + 0.08
            let base = SIMD2<Float>(10 + 490 * t, midY + 4 * t)
            for sgn in [Float(-1), 1] {
                let len = (1 - t) * 200 + 40
                let tip = base + SIMD2(len * 0.75, sgn * len * 0.62)
                line(base, tip, 3, 1, 0.4, 0.55)
                needles(from: base, to: tip, len0: 26, len1: 10, density: Int(len / 4))
            }
        }
        // leaf cluster: twigs from the middle, ~45 pointed leaves of varying size and brightness
        let c = SIMD2<Float>(768, 256)
        for _ in 0..<45 {
            let ang = Float(rng.unit() * 2 * .pi)
            let rad = Float(rng.unit().squareRoot()) * 185
            let p = c + SIMD2(cos(ang), sin(ang)) * rad
            line(c, p, 2.5, 1.2, 0.3, 0.4)
            let la = ang + Float(rng.unit() - 0.5) * 1.6
            let ld = SIMD2(cos(la), sin(la)), ls = SIMD2(-ld.y, ld.x)
            let L = Float(38 + rng.unit() * 34), Wd = L * Float(0.36 + rng.unit() * 0.12)
            let bright = Float(0.6 + rng.unit() * 0.45)
            let r = Int(L) + 2
            for dy in -r...r { for dx in -r...r {
                let q = SIMD2<Float>(Float(dx), Float(dy))
                let u = simd_dot(q, ld) / L, v = simd_dot(q, ls)
                guard u > 0, u < 1 else { continue }
                let half = Wd * 0.5 * pow(sin(Float.pi * pow(u, 0.8)), 0.9)
                let cov = max(0, min(1, half - abs(v) + 0.5))
                if cov <= 0 { continue }
                let vein = abs(v) < 1.2 ? 0.75 : 1.0
                let shade = bright * Float(vein) * (0.85 + 0.25 * u) * (1 - 0.25 * abs(v) / max(half, 1))
                plot(Int(p.x + q.x), Int(p.y + q.y), shade, cov)
            } }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: true)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
        if let cmd = queue.makeCommandBuffer(), let bl = cmd.makeBlitCommandEncoder() {
            bl.generateMipmaps(for: t)
            bl.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return t
    }

    // MARK: - Tree meshes

    /// Matches TreeV: p = position (unit tree height) + kind (0 bark, 1 leaf card); n = normal + ambient occlusion;
    /// u = atlas uv, sway weight (how much it flutters), random phase.
    struct Vertex { var p: SIMD4<Float>; var n: SIMD4<Float>; var u: SIMD4<Float> }
    struct Part { var baseVertex: Int; var indexStart: Int; var indexCount: Int }

    private final class Builder {
        var v: [Vertex] = []
        var i: [UInt32] = []
        var start = 0

        func begin() { start = v.count }

        /// A tapered tube from a to b (radius r0 → r1).
        func tube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r0: Float, _ r1: Float, sides: Int, rings: Int, sway0: Float, sway1: Float) {
            let ax = simd_normalize(b - a)
            let ref: SIMD3<Float> = abs(ax.y) > 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let s1 = simd_normalize(simd_cross(ax, ref)), s2 = simd_cross(ax, s1)
            let base = UInt32(v.count - start)
            for k in 0...rings {
                let t = Float(k) / Float(rings)
                let c = a + (b - a) * t, r = r0 + (r1 - r0) * t
                for s in 0...sides {
                    let ang = Float(s) / Float(sides) * 2 * .pi
                    let n = s1 * cos(ang) + s2 * sin(ang)
                    let p = c + n * r
                    v.append(Vertex(p: SIMD4(p, 0), n: SIMD4(n, 0.55 + 0.45 * min(1, p.y * 2)),
                                    u: SIMD4(Float(s) / Float(sides), t, sway0 + (sway1 - sway0) * t, 0)))
                }
            }
            let row = UInt32(sides + 1)
            for k in 0..<UInt32(rings) { for s in 0..<UInt32(sides) {
                let a0 = base + k * row + s, a1 = a0 + 1, b0 = a0 + row, b1 = b0 + 1
                i += [a0, b0, a1, a1, b0, b1]
            } }
        }

        /// A card along the curve `pts` (its length maps to atlas u0…u1), `side` = the across direction at each point.
        func strip(_ pts: [SIMD3<Float>], _ sides: [SIMD3<Float>], width: Float, uv: SIMD4<Float>, normal: (SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>,
                   ao: (SIMD3<Float>) -> Float, sway: (Float) -> Float, phase: Float) {
            let base = UInt32(v.count - start)
            for (k, p) in pts.enumerated() {
                let t = Float(k) / Float(pts.count - 1)
                for e in [Float(-1), 1] {
                    let q = p + sides[k] * (width * 0.5 * e)
                    let n = normal(q, simd_normalize(simd_cross(sides[k], k + 1 < pts.count ? pts[k + 1] - p : p - pts[k - 1])))
                    v.append(Vertex(p: SIMD4(q, 1), n: SIMD4(n, ao(q)),
                                    u: SIMD4(uv.x + (uv.z - uv.x) * t, uv.y + (uv.w - uv.y) * (e * 0.5 + 0.5), sway(t), phase)))
                }
            }
            for k in 0..<UInt32(pts.count - 1) {
                let a = base + k * 2
                i += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
            }
        }

        /// A flat quad centred on c with axes ex / ey (half sizes included), atlas rect uv.
        func quad(_ c: SIMD3<Float>, _ ex: SIMD3<Float>, _ ey: SIMD3<Float>, uv: SIMD4<Float>, n: SIMD3<Float>, ao: Float, sway: Float, phase: Float,
                  tint: Float = 0) {
            let base = UInt32(v.count - start)
            for (sx, sy) in [(Float(-1), Float(-1)), (1, -1), (-1, 1), (1, 1)] {
                let p = c + ex * sx + ey * sy
                v.append(Vertex(p: SIMD4(p, 1 + tint), n: SIMD4(n, ao),
                                u: SIMD4(sx < 0 ? uv.x : uv.z, sy < 0 ? uv.y : uv.w, sway, phase)))
            }
            i += [base, base + 1, base + 2, base + 1, base + 3, base + 2]
        }

        func end(_ indexStart: inout Int) -> Part {
            let p = Part(baseVertex: start, indexStart: indexStart, indexCount: i.count - indexStart)
            indexStart = i.count
            return p
        }
    }

    /// Spruce and broadleaf, four levels of detail each: parts[species * 4 + lod] = [bark, leaves].
    static func treeMeshes() -> (vertices: [Vertex], indices: [UInt32], parts: [[Part]]) {
        let b = Builder()
        var parts: [[Part]] = []
        var idx = 0
        let frondUV = SIMD4<Float>(0.0, 0.08, 0.5, 0.92)
        let leafUV = SIMD4<Float>(0.52, 0.02, 0.98, 0.98)
        // spruce
        for lod in 0..<4 {
            var rng = SplitMix(seed: 0x5970_0CE)        // the same seed for every LOD: the same tree, simplified
            b.begin()
            b.tube(SIMD3(0, -0.08, 0), SIMD3(0, 0.9, 0), 0.02, 0.003, sides: [8, 6, 5, 3][lod], rings: [8, 4, 2, 1][lod], sway0: 0, sway1: 0.2)
            let bark = b.end(&idx)
            b.begin()
            let whorls = [44, 18, 8, 4][lod], per = [8, 6, 4, 3][lod], cards = [2, 1, 1, 1][lod], segs = [3, 2, 1, 1][lod]
            let widen: Float = [1.0, 1.45, 2.1, 2.8][lod]
            for w in 0..<whorls {
                let y = 0.1 + 0.88 * (Float(w) + Float(rng.unit()) * 0.6) / Float(whorls)
                let L = 0.34 * pow(max(0, 1 - y), 0.85) + 0.03
                for k in 0..<per {
                    let ang = Float(k) / Float(per) * 2 * .pi + Float(w) * 2.4 + Float(rng.unit()) * 0.5
                    let dir = SIMD3<Float>(cos(ang), 0, sin(ang))
                    let base = SIMD3<Float>(0, y, 0) + dir * 0.012
                    let droop = Float(0.35 + rng.unit() * 0.25) * (0.6 + 0.6 * (1 - y))
                    var pts: [SIMD3<Float>] = [], tans: [SIMD3<Float>] = []
                    for s in 0...segs {
                        let t = Float(s) / Float(segs)
                        pts.append(base + dir * (L * t) + SIMD3(0, L * (0.12 * t - droop * t * t), 0))
                        tans.append(simd_normalize(dir + SIMD3(0, 0.12 - 2 * droop * t, 0)))
                    }
                    for cdx in 0..<cards {
                        let roll: Float = cards == 1 ? 0 : (cdx == 0 ? 0.6 : -0.6)
                        let sides = tans.map { tg -> SIMD3<Float> in
                            let s = simd_normalize(simd_cross(SIMD3(0, 1, 0), tg))
                            return s * cos(roll) + simd_cross(tg, s) * sin(roll)
                        }
                        let crownAxisY = y
                        b.strip(pts, sides, width: L * 0.62 * widen, uv: frondUV,
                                normal: { q, nc in
                                    let rad = simd_normalize(SIMD3(q.x, (q.y - crownAxisY) * 0.5 + 0.25, q.z))
                                    return simd_normalize(rad * 0.7 + nc * (simd_dot(nc, rad) < 0 ? -0.3 : 0.3))
                                },
                                ao: { q in 0.4 + 0.6 * min(1, (q.x * q.x + q.z * q.z).squareRoot() / max(L, 0.05)) * (0.7 + 0.3 * q.y) },
                                sway: { t in t * (0.5 + 0.5 * y) }, phase: Float(rng.unit()))
                    }
                }
            }
            let leaves = b.end(&idx)
            parts.append([bark, leaves])
        }
        // broadleaf
        for lod in 0..<4 {
            var rng = SplitMix(seed: 0xB20AD)
            let C = SIMD3<Float>(0, 0.64, 0), R = SIMD3<Float>(0.33, 0.3, 0.33)
            b.begin()
            b.tube(SIMD3(0, -0.08, 0), SIMD3(0, 0.5, 0), 0.03, 0.02, sides: [8, 6, 5, 3][lod], rings: [5, 2, 1, 1][lod], sway0: 0, sway1: 0.1)
            let limbs = [6, 4, 0, 0][lod]
            var limbTips: [SIMD3<Float>] = []
            for k in 0..<limbs {
                let ang = Float(k) / Float(limbs) * 2 * .pi + Float(rng.unit()) * 0.6
                let start = SIMD3<Float>(0, 0.42 + Float(rng.unit()) * 0.12, 0)
                let tip = C + SIMD3(cos(ang) * R.x * 0.45, Float(rng.unit() * 0.4 - 0.15) * R.y, sin(ang) * R.z * 0.45)
                b.tube(start, tip, 0.016, 0.005, sides: lod == 0 ? 5 : 4, rings: 1, sway0: 0.1, sway1: 0.4)
                limbTips.append(tip)
                if lod == 0 {
                    for _ in 0..<2 {
                        let mid = start + (tip - start) * Float(0.5 + rng.unit() * 0.3)
                        let off = SIMD3<Float>(Float(rng.unit() - 0.5), Float(rng.unit() * 0.6), Float(rng.unit() - 0.5)) * 0.2
                        b.tube(mid, mid + off, 0.008, 0.003, sides: 4, rings: 1, sway0: 0.3, sway1: 0.6)
                    }
                }
            }
            let bark = b.end(&idx)
            b.begin()
            let clusters = [130, 42, 14, 6][lod]
            let size: Float = [0.115, 0.19, 0.31, 0.42][lod]
            for _ in 0..<clusters {
                var d: SIMD3<Float>
                repeat { d = SIMD3(Float(rng.unit()), Float(rng.unit()), Float(rng.unit())) * 2 - 1 } while simd_length_squared(d) > 1 || simd_length_squared(d) < 0.05
                d = simd_normalize(d)
                let r = Float(0.5 + 0.5 * rng.unit().squareRoot())
                let p = C + d * R * r
                let sn = simd_normalize(d / R)
                let ao = 0.35 + 0.65 * r * (0.75 + 0.25 * max(0, d.y))
                let a0 = Float(rng.unit() * 2 * .pi)
                let tint = Float(rng.unit())          // each cluster its own shade (kind 1 + tint)
                // two crossed cards, each turned at random
                for k in 0..<2 {
                    let a = a0 + Float(k) * .pi / 2
                    let ex = SIMD3<Float>(cos(a), Float(rng.unit() - 0.5) * 0.6, sin(a))
                    let ey = simd_normalize(simd_cross(ex, SIMD3(Float(rng.unit() - 0.5), 1, Float(rng.unit() - 0.5))))
                    let s = size * Float(0.8 + 0.4 * rng.unit())
                    b.quad(p, simd_normalize(ex) * s, ey * s, uv: leafUV, n: sn, ao: ao, sway: 0.6 + 0.4 * r, phase: Float(rng.unit()), tint: tint)
                }
            }
            _ = limbTips
            let leaves = b.end(&idx)
            parts.append([bark, leaves])
        }
        return (b.v, b.i, parts)
    }

    // MARK: - Rock

    /// A boulder: an icosphere (2 subdivisions) pushed in and out by a few random lumps and flattened underneath.
    /// pos.w unused, normal.w = ambient occlusion (dark at the base).
    static func rockMesh() -> (vertices: [SIMD4<Float>], indices: [UInt32]) {
        let t = Float((1 + 5.0.squareRoot()) / 2)
        var v: [SIMD3<Float>] = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
                                 (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)].map { simd_normalize(SIMD3<Float>($0.0, $0.1, $0.2)) }
        var f: [(Int, Int, Int)] = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6),
                                    (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10),
                                    (8, 6, 7), (9, 8, 1)]
        for _ in 0..<2 {
            var cache: [Int: Int] = [:]
            func mid(_ a: Int, _ b: Int) -> Int {
                let k = min(a, b) * 10000 + max(a, b)
                if let m = cache[k] { return m }
                v.append(simd_normalize(v[a] + v[b])); cache[k] = v.count - 1
                return v.count - 1
            }
            var nf: [(Int, Int, Int)] = []
            for (a, b, c) in f {
                let ab = mid(a, b), bc = mid(b, c), ca = mid(c, a)
                nf += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
            f = nf
        }
        var rng = SplitMix(seed: 0x20C4)
        // big lumps, then flat cuts (fractured faces), then small bumps: a weathered boulder, not a pebble
        let lumps: [(SIMD3<Float>, Float)] = (0..<9).map { _ in
            (simd_normalize(SIMD3(Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.5)), Float(rng.unit()) * 0.5 - 0.22)
        }
        let cuts: [(SIMD3<Float>, Float)] = (0..<7).map { _ in
            (simd_normalize(SIMD3(Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.3, Float(rng.unit()) - 0.5)), Float(0.72 + rng.unit() * 0.2))
        }
        let bumps: [(SIMD3<Float>, Float)] = (0..<24).map { _ in
            (simd_normalize(SIMD3(Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.5)), Float(rng.unit()) * 0.08 - 0.03)
        }
        let pos: [SIMD3<Float>] = v.map { d in
            var r: Float = 1
            for (c, a) in lumps { r += a * max(0, simd_dot(d, c) - 0.55) * 2.2 }
            for (c, a) in bumps { r += a * max(0, simd_dot(d, c) - 0.85) * 6.0 }
            for (c, k) in cuts { let dc = simd_dot(d, c); if dc > 0.01 { r = min(r, k / dc) } }
            var p = d * r
            if p.y < -0.25 { p.y = -0.25 + (p.y + 0.25) * 0.3 }      // a flat-ish base sunk into the ground
            p.y *= 0.72
            return p
        }
        var nrm = [SIMD3<Float>](repeating: .zero, count: pos.count)
        for (a, b, c) in f {
            let n = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
            nrm[a] += n; nrm[b] += n; nrm[c] += n
        }
        var verts: [SIMD4<Float>] = []
        for i in pos.indices {
            let n = simd_normalize(nrm[i])
            verts.append(SIMD4(pos[i], 0))
            verts.append(SIMD4(n, 0.45 + 0.55 * min(1, max(0, (pos[i].y + 0.2) / 0.6))))
        }
        var idx: [UInt32] = []
        for (a, b, c) in f { idx += [UInt32(a), UInt32(b), UInt32(c)] }
        return (verts, idx)
    }
}
