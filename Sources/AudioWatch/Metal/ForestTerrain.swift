import Foundation
import simd

/// The Forest's terrain on the CPU: the same noise the GPU samples (made here once, uploaded by ForestAssets) and the
/// same river and ground functions as ForestShaders.swift, so the camera can follow the river and the birds can keep
/// clear of the hills. Keep the formulas in step with the shader.
enum ForestTerrain {
    static let size = 1024
    static let cells = 32
    static let period: Float = 8192

    /// size² × (value, d/dx, d/dy per cell, a second noise): periodic Perlin noise, 32 cells per tile.
    static let noise: [Float] = {
        let n = size
        var rng = SplitMix(seed: 0x5F0_2E57)
        func grads() -> [SIMD2<Float>] {
            (0..<(cells * cells)).map { _ in
                let a = Float(rng.unit() * 2 * .pi)
                return SIMD2(cos(a), sin(a))
            }
        }
        let g1 = grads(), g2 = grads()
        let per = Float(n) / Float(cells)
        func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
        func fadeD(_ t: Float) -> Float { 30 * t * t * (t * (t - 2) + 1) }
        func perlin(_ g: [SIMD2<Float>], _ x: Float, _ y: Float) -> SIMD3<Float> {
            let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
            let fx = x - Float(ix), fy = y - Float(iy)
            func G(_ i: Int, _ j: Int) -> SIMD2<Float> { g[((j % cells + cells) % cells) * cells + (i % cells + cells) % cells] }
            let ga = G(ix, iy), gb = G(ix + 1, iy), gc = G(ix, iy + 1), gd = G(ix + 1, iy + 1)
            let va = simd_dot(ga, SIMD2(fx, fy)), vb = simd_dot(gb, SIMD2(fx - 1, fy))
            let vc = simd_dot(gc, SIMD2(fx, fy - 1)), vd = simd_dot(gd, SIMD2(fx - 1, fy - 1))
            let ux = fade(fx), uy = fade(fy), dux = fadeD(fx), duy = fadeD(fy)
            let k = va - vb - vc + vd
            let v = va + ux * (vb - va) + uy * (vc - va) + ux * uy * k
            let gab: SIMD2<Float> = (gb - ga) * ux
            let gac: SIMD2<Float> = (gc - ga) * uy
            let gk: SIMD2<Float> = (ga - gb - gc + gd) * (ux * uy)
            let dd = SIMD2<Float>(dux * (uy * k + vb - va), duy * (ux * k + vc - va))
            let d: SIMD2<Float> = ga + gab + gac + gk + dd
            return SIMD3(v, d.x, d.y)
        }
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: n * n * 4)
        defer { buf.deallocate() }
        DispatchQueue.concurrentPerform(iterations: n) { j in
            for i in 0..<n {
                let x = (Float(i) + 0.5) / per, y = (Float(j) + 0.5) / per
                let a = perlin(g1, x, y), b = perlin(g2, x + 7.3, y + 2.9)
                let o = (j * n + i) * 4
                buf[o] = a.x * 1.4; buf[o + 1] = a.y * 1.4; buf[o + 2] = a.z * 1.4; buf[o + 3] = b.x * 1.4
            }
        }
        return Array(buf)
    }()

    /// Bilinear, repeating, like the GPU's sampler: p in noise cells (1 tile = 32 cells).
    static func nz(_ p: SIMD2<Float>) -> SIMD4<Float> {
        let u = p / Float(cells) * Float(size) - 0.5
        let fl = SIMD2<Float>(u.x.rounded(.down), u.y.rounded(.down))
        let f = u - fl
        func at(_ i: Int, _ j: Int) -> SIMD4<Float> {
            let ii = (i % size + size) % size, jj = (j % size + size) % size
            let o = (jj * size + ii) * 4
            return noise.withUnsafeBufferPointer { SIMD4($0[o], $0[o + 1], $0[o + 2], $0[o + 3]) }
        }
        let i = Int(fl.x), j = Int(fl.y)
        let a = at(i, j), b = at(i + 1, j), c = at(i, j + 1), d = at(i + 1, j + 1)
        return (a * (1 - f.x) + b * f.x) * (1 - f.y) + (c * (1 - f.x) + d * f.x) * f.y
    }

    static func valley(_ z: Float) -> Float {
        let k = 2 * Float.pi / period
        return 45 * sin(z * k * 3) + 22 * sin(z * k * 7 + 1) + 9 * sin(z * k * 17 + 2)
    }

    /// The river's middle line (it wanders off the valley's line) and its width.
    static func riverCenter(_ z: Float) -> Float { valley(z) + 6 * nz(SIMD2(z / 160, 3.3)).x }
    static func riverWidth(_ z: Float) -> Float { 6.5 + 3.5 * nz(SIMD2(z / 110, 7.7)).w }

    /// Ground height (8 octaves, like the GPU's vertices).
    static func height(_ xz: SIMD2<Float>) -> Float {
        var p = xz / 256, a: Float = 0, b: Float = 0.5, f: Float = 1, d = SIMD2<Float>()
        for i in 0..<8 {
            let n = nz(p * f + SIMD2(0.37, 0.71) * Float(i))
            d += SIMD2(n.y, n.z)
            a += b * n.x / (1 + simd_dot(d, d))
            b *= 0.5; f *= 2
        }
        _ = p; p = .zero
        let u = min(1.5, max(0, a + 0.42))
        let hh = 180 * u * u
        let ax = abs(xz.x - riverCenter(xz.y))
        let width = riverWidth(xz.y)
        let ae = ax + 2 * nz(xz / 7 + 2.1).x + 0.6 * nz(xz / 2.3 + 5.7).x
        func ss(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t) }
        let m = -2.4 + 3.4 * ss(width * 0.5, width * 1.35, ae) + 7 * a * ss(width * 1.6, 45, ax)
        let axv = abs(xz.x - valley(xz.y))
        return m + hh * ss(30, 150, axv)
    }
}
