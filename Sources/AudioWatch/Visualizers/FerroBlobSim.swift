import Foundation
import simd

/// Real Metaballs: a blob of ferrofluid in water inside a round glass cell, with an electromagnet (or several) behind
/// the back glass, like the ferrofluid speaker. The coil currents come from the caller (band envelope → PWM duty →
/// current with τ = L/R, see `MetaballsViz`).
///
/// The fluid is one big 3D drop plus a few small ones. Each drop is described by its centre, its mean radius, its
/// thickness (volume is conserved) and the shape of its outline (surface modes), and these follow the physics of a
/// ferrofluid drop in a field that is mostly perpendicular to the glass:
/// - **Magnetisation:** Langevin M = L(ξH) (saturating); the magnetic pressure ∝ M·H drives everything below.
/// - **Spreading:** magnetised side by side the fluid repels itself, so the drop spreads out flat and gets thinner
///   (volume kept); surface tension pulls it back into a thick round blob when the field goes, more slowly.
/// - **Rosensweig / labyrinthine instability:** past a critical field the rim breaks up into a ring of spikes (the
///   "sun"); more field = more and longer spikes. They grow fast and sink back when the field drops.
/// - **Surface modes** n = 2…7 (stretching, triangles, crosses, arms): z̈ = −γż − kₙz + Fₙ with the surface tension
///   stiffness kₙ ∝ σ(n³ − n)/R³ minus a magnetic part ∝ M·H·n²/R² (a spread drop in a strong field is unstable to
///   fingering: arms grow). Fₙ = the coils' pull on the rim (Kelvin force, ∝ M ∇|H|): an off-centre drop stretches
///   towards the coil. Sudden changes of the current surge the fluid unevenly (random kicks to the modes).
/// - **Motion:** Kelvin pull towards the coils, gravity after buoyancy (the drop sinks when the coil lets go), strong
///   drag from the water and the glass (moves in jumps that ease out). Magnetised drops repel each other side by side;
///   drops touching while the field is weak merge. A long arm whose field collapses can pinch off a small drop.
///
/// Units: cell radius 1, y up, z towards the viewer, seconds. `render` turns the drops into a density volume for the
/// raymarcher: each drop is a rounded lens of height h(x, y), smoothly merged with the others.
final class FerroBlobSim {
    let depth: Float = 0.7
    static let modes = 6                 // n = 2…7
    static let table = 512               // outline samples

    struct Drop {
        var c: SIMD2<Float>
        var v = SIMD2<Float>.zero
        var vol: Float                   // R_rest³
        var R: Float                     // mean radius now
        var z = [SIMD2<Float>](repeating: .zero, count: FerroBlobSim.modes)
        var zd = [SIMD2<Float>](repeating: .zero, count: FerroBlobSim.modes)
        var spike: Float = 0             // spike amplitude (× R)
        var spikeN: Float = 20
        var spikePh: Float = 0
        var seed: UInt64 = 1
        var mag: Float = 0               // M·H at the drop (0…~1.5)
        var hSlow: Float = 0             // recent level of the field at the drop (1.2 s)
        var rRest: Float { cbrt(vol) }
    }

    // tuning
    var restR: Float = 0.38              // main drop radius at Fluid 1
    var spread: Float = 0.6              // R grows to (1 + spread·M·H) × rest
    var sigma: Float = 0.12              // surface tension in the mode stiffness
    var fingering: Float = 1           // magnetic destabilisation of the modes
    var damping: Float = 9
    var kelvin: Float = 8
    var rimPull: Float = 7
    var gravity: Float = 0.35
    var dragC: Float = 6
    var surge: Float = 15                 // mode kick per unit of current change
    var xi: Float = 3
    var coilW: Float = 0.45              // coil field width (≈ coil radius)

    var currents: [Float] = [0]
    private(set) var coilXY: [SIMD2<Float>] = [.zero]
    private(set) var drops: [Drop] = []
    private var fluid: Float = -1
    private var rng = SplitMix(seed: 0xB10B)
    private var lastI: [Float] = [], slowI: [Float] = [], turnI: [Float] = [], dirI: [Float] = []
    private var t: Float = 0

    var count: Int { drops.count }

    init() {}

    /// Places `n` coils (1…5) behind the back glass: one in the middle, more on a ring.
    func setCoils(_ n: Int) {
        let n = max(1, min(5, n))
        guard n != coilXY.count else { return }
        if n == 1 {
            coilXY = [.zero]; coilW = 0.45
        } else {
            let ring: Float = n == 2 ? 0.42 : 0.48
            coilXY = (0..<n).map { k in
                let a = Float.pi / 2 + 2 * Float.pi * Float(k) / Float(n)
                return SIMD2(cos(a), sin(a)) * ring
            }
            coilW = n == 2 ? 0.34 : 0.28
        }
        if currents.count != n { currents = [Float](repeating: 0, count: n) }
    }

    /// Amount of fluid (1 = default). A fresh fluid is one big blob low in the glass and two small drops; changing
    /// the amount later scales the drops.
    func setFluid(_ f: Float) {
        let f = max(0.1, f)
        if drops.isEmpty {
            let v = pow(restR, 3) * pow(f, 0.75)
            drops = [Drop(c: SIMD2(0, -0.3), vol: v * 0.9, R: cbrt(v * 0.9), seed: 11),
                     Drop(c: SIMD2(-0.55, 0.4), vol: v * 0.06, R: cbrt(v * 0.06), seed: 12),
                     Drop(c: SIMD2(0.6, 0.25), vol: v * 0.04, R: cbrt(v * 0.04), seed: 13)]
        } else if abs(f - fluid) > 1e-3 && fluid > 0 {
            let s = pow(f / fluid, 0.75)
            for k in drops.indices { drops[k].vol *= s; drops[k].R *= cbrt(s) }
        }
        fluid = f
    }

    // MARK: field

    /// |H| of all coils at a point of the fluid (1 = full current on a coil's axis) and its gradient.
    private func field(_ p: SIMD2<Float>) -> (h: Float, g: SIMD2<Float>) {
        var h: Float = 0, g = SIMD2<Float>.zero
        let w2 = coilW * coilW
        for k in coilXY.indices where k < currents.count && currents[k] > 0 {
            let d = p - coilXY[k]
            let u = 1 + simd_length_squared(d) / w2
            let s = 1 / (u * sqrt(u))
            h += currents[k] * s
            g += currents[k] * (-3 * s / u / w2) * d
        }
        return (h, g)
    }

    @inline(__always) static func langevin(_ x: Float) -> Float { x < 1e-3 ? x / 3 : 1 / tanh(x) - 1 / x }
    /// Magnetisation 0…1 (saturates above |H| ≈ 1).
    private func magnetisation(_ h: Float) -> Float { Self.langevin(xi * h) / Self.langevin(xi) }

    /// The drop's outline radius at angle θ.
    @inline(__always) private static func outline(_ d: Drop, _ th: Float) -> Float {
        var r: Float = 1
        for m in 0..<modes {
            let n = Float(m + 2)
            r += d.z[m].x * cos(n * th) + d.z[m].y * sin(n * th)
        }
        let low = r - 1                                  // the big shape here (> 0 = an arm)
        if d.spike > 1e-3 {
            // a ring of teeth, pointed tips and shallow valleys, each tooth its own length
            let x = d.spikeN * th + d.spikePh
            let idx = Int((x / (2 * .pi)).rounded())
            var hs = UInt64(bitPattern: Int64(idx &* 2_654_435_761)) ^ d.seed
            hs = (hs ^ (hs >> 29)) &* 0xBF58_476D_1CE4_E5B9
            let jit = 0.7 + 0.6 * Float(hs >> 40) / Float(1 << 24)
            // triangular teeth with slightly rounded valleys
            let fr = x / (2 * .pi) - Float(idx)          // −0.5…0.5, 0 = tip
            let tri = 1 - 2 * abs(fr)
            let tooth = tri * tri * 1.1 - 0.25
            // arms stay smooth and round (like the video); the spikes stand on the body of the drop
            let onBody = max(0, min(1, 1 - 2.5 * low))
            r += d.spike * tooth * jit * onBody * (1 + 0.3 * cos(3 * th + Float(d.seed % 7)))
        }
        return max(0.25, r) * d.R
    }

    // MARK: step

    func step(_ dt: Float) {
        guard !drops.isEmpty else { return }
        let sub = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Float(sub)
        // sudden current changes surge the fluid unevenly: random kicks to the surface modes and the drop's position.
        // Measured against the current's recent level, so a loud, steady signal still moves the fluid.
        // Each swing of a coil current (trough → peak or peak → trough, found at its turning points) kicks the fluid
        // once, sized by the whole swing relative to the current's recent level: a slow coil (long Coil lag) ramps
        // smoothly, and per-frame changes would only give many tiny kicks.
        if lastI.count != currents.count {
            lastI = currents; slowI = currents; turnI = currents; dirI = [Float](repeating: 0, count: currents.count)
        }
        var jump: Float = 0
        for k in currents.indices {
            slowI[k] += (currents[k] - slowI[k]) * (1 - exp(-dt / 1.2))
            let d = currents[k] - lastI[k]
            if abs(d) > 0.004 {
                let dir: Float = d > 0 ? 1 : -1
                if dir != dirI[k] {
                    // turning point at lastI: the swing since the previous turning point is over
                    jump = max(jump, abs(lastI[k] - turnI[k]) / max(0.5, slowI[k]))
                    turnI[k] = lastI[k]; dirI[k] = dir
                }
            }
            lastI[k] = currents[k]
        }
        if jump > 0.15 {
            let j = min(1.2, jump)
            for k in drops.indices {
                for m in 0..<Self.modes {
                    let a = Float(rng.unit()) * 2 * .pi
                    drops[k].zd[m] += SIMD2(cos(a), sin(a)) * (surge * j * (0.3 + 0.7 * Float(rng.unit())) / sqrt(Float(m + 2)))
                }
                let a = Float(rng.unit()) * 2 * .pi
                drops[k].v += SIMD2(cos(a), sin(a)) * (0.8 * j * Float(rng.unit()))
            }
        }
        for _ in 0..<sub { substep(h) }
        t += dt
    }

    private func substep(_ h: Float) {
        let main = drops.indices.max(by: { drops[$0].vol < drops[$1].vol }) ?? 0
        for k in drops.indices {
            var d = drops[k]
            let f = field(d.c)
            let M = magnetisation(f.h)
            d.mag = M * min(f.h, 1.6)
            d.hSlow += (f.h - d.hSlow) * (1 - exp(-h / 1.2))
            // how far the field is above / below its recent level (the field, not M: M saturates in a strong field,
            // which flattened every change): the fluid reacts to changes more than to a level
            let tr = max(-0.6, min(0.6, 1.5 * (f.h - d.hSlow) / max(0.3, d.hSlow)))
            let r0 = d.rRest
            // spread flat in the field, round up again without it (slower: surface tension against the drag)
            // (capped so a lot of fluid doesn't spread into the wall and get stuck there)
            let target = min(max(r0, 0.68), r0 * (1 + spread * min(1.3, d.mag) * (0.75 + 0.6 * tr)))
            d.R += (target - d.R) * (1 - exp(-h * (target > d.R ? 14 : 7)))
            // Rosensweig spikes on the rim past the critical field
            let big = r0 > 0.12
            let sTarget: Float = big ? 0.24 * max(0, min(1.2, (d.mag - 0.22) / 0.5)) * max(0.2, 0.7 + 1.2 * tr) : 0
            if d.spike < 0.01 && sTarget > 0.01 {
                d.spikeN = (20 + 14 * min(1, d.mag)) * (d.R / 0.55)
                d.spikeN = max(10, min(44, d.spikeN.rounded()))
                d.spikePh = Float(rng.unit()) * 2 * .pi
                d.seed = rng.next()
            }
            d.spike += (sTarget - d.spike) * (1 - exp(-h * (sTarget > d.spike ? 20 : 9)))
            // surface modes: tension vs magnetic fingering, pulled by the coils' field over the rim
            let R3 = d.R * d.R * d.R
            var rimH = [Float](repeating: 0, count: 16)
            var mean: Float = 0
            for s in 0..<16 {
                let th = Float(s) * 2 * .pi / 16
                rimH[s] = field(d.c + SIMD2(cos(th), sin(th)) * d.R).h
                mean += rimH[s] / 16
            }
            for m in 0..<Self.modes {
                let n = Float(m + 2)
                // fingering mostly while the field is rising: a steady field leaves the sun, a change throws out arms
                let fing = fingering * (0.3 * min(1, d.mag) + 3 * max(0, tr))
                var k2 = sigma * (n * n * n - n) / R3 - fing * n * n / (d.R * d.R)
                k2 += 150 * n * simd_length_squared(d.z[m])            // saturation of large shapes
                var F = SIMD2<Float>.zero
                for s in 0..<16 {
                    let th = Float(s) * 2 * .pi / 16
                    F += SIMD2(cos(n * th), sin(n * th)) * (rimH[s] - mean)
                }
                F *= rimPull * M / 8
                d.zd[m] += (F - k2 * d.z[m] - damping * d.zd[m]) * h
                d.z[m] += d.zd[m] * h
                let lim = 0.9 / sqrt(n) * min(1, r0 / 0.25)
                let l = simd_length(d.z[m])
                if l > lim { d.z[m] *= lim / l }
            }
            // centre: Kelvin pull, gravity, drag, the glass wall
            var a = f.g * (kelvin * M) + SIMD2(0, -gravity) - d.v * dragC
            let rc = simd_length(d.c)
            let reach = max(0, 1 - 1.05 * d.R)
            if rc > reach { a -= d.c / max(rc, 1e-4) * (rc - reach) * 60 }
            // other drops: magnetised side by side they repel
            for j in drops.indices where j != k {
                let e = d.c - drops[j].c
                let dist = max(0.05, simd_length(e))
                let both = d.mag * drops[j].mag
                if both > 0.02 {
                    a += e / dist * (0.004 * both * drops[j].vol / (pow(dist, 4) * max(d.vol, 1e-5)))
                }
            }
            d.v += a * h
            d.c += d.v * h
            drops[k] = d
        }
        // pinch-off: a long arm of the main drop whose field is collapsing leaves a small drop behind
        if drops.count < 5, drops[main].mag < 0.25 || drops[main].hSlow > 0.3 && field(drops[main].c).h < drops[main].hSlow * 0.6, drops[main].vol > 0.02 {
            let d = drops[main]
            var best: Float = 0, bt: Float = 0
            for s in 0..<32 {
                let th = Float(s) * 2 * .pi / 32
                let r = Self.outline(d, th)
                if r > best { best = r; bt = th }
            }
            if best > 1.9 * d.R && rng.unit() < 0.004 {
                let v = d.vol * 0.05
                let dir = SIMD2(cos(bt), sin(bt))
                drops[main].vol -= v
                drops.append(Drop(c: d.c + dir * best * 0.92, v: dir * 0.4 + d.v, vol: v, R: cbrt(v), seed: rng.next()))
            }
        }
        // merging: drops that touch while the field is weak flow together
        var k = 0
        while k < drops.count {
            var merged = false
            for j in drops.indices where j != k {
                let a = drops[k], b = drops[j]
                let dist = simd_length(a.c - b.c)
                if dist < 0.85 * (a.R + b.R) && min(a.mag, b.mag) < 0.35 {
                    let (big, small) = a.vol >= b.vol ? (k, j) : (j, k)
                    let vb = drops[big].vol, vs = drops[small].vol
                    drops[big].v = (drops[big].v * vb + drops[small].v * vs) / (vb + vs)
                    drops[big].c += (drops[small].c - drops[big].c) * (vs / (vb + vs))
                    drops[big].vol += vs
                    drops.remove(at: small)
                    merged = true
                    break
                }
            }
            if !merged { k += 1 }
        }
    }

    // MARK: rendering

    /// Fills a density volume (nx × ny × nz over x, y ∈ ±1, z ∈ ±depth/2; x fastest) with the drops: each is a lens of
    /// height h = H·√(1 − (ρ/r(θ))⁴) (H from the volume: a spread drop is thin, a round one thick), with the fine
    /// Rosensweig bumps on top while the field is strong; the drops are merged with a smooth maximum (necks) and the
    /// density is iso + slope·(h − |z|), so the raymarched surface sits at |z| = h.
    func render(into grid: inout [Float], nx: Int, ny: Int, nz: Int, iso: Float) {
        let total = nx * ny * nz
        if grid.count != total { grid = [Float](repeating: 0, count: total) }
        let T = Self.table
        // per drop: outline table, centre, lens height
        var tabs = [Float](repeating: 0, count: drops.count * T)
        var cs: [SIMD2<Float>] = [], H: [Float] = [], spk: [Float] = []
        for (k, d) in drops.enumerated() {
            for s in 0..<T { tabs[k * T + s] = Self.outline(d, Float(s) * 2 * .pi / Float(T)) }
            cs.append(d.c)
            let r0 = d.rRest
            let h0 = min(0.3, r0 * (0.95 - 0.9 * r0))
            H.append(max(0.02, h0 * (r0 / d.R) * (r0 / d.R)))
            spk.append(d.spike)
        }
        var plane = [Float](repeating: -1, count: nx * ny)
        let sx = 2 / Float(nx)
        let nd = drops.count
        let kS: Float = 0.05
        let tt = t
        tabs.withUnsafeBufferPointer { TB in plane.withUnsafeMutableBufferPointer { PL in
            DispatchQueue.concurrentPerform(iterations: 8) { b in
                for y in (ny * b / 8)..<(ny * (b + 1) / 8) {
                    let py = (Float(y) + 0.5) * sx - 1
                    for x in 0..<nx {
                        let px = (Float(x) + 0.5) * sx - 1
                        var hv: Float = -1
                        for k in 0..<nd {
                            let rx = px - cs[k].x, ry = py - cs[k].y
                            let rho = sqrt(rx * rx + ry * ry)
                            var th = atan2(ry, rx)
                            if th < 0 { th += 2 * .pi }
                            let fi = th / (2 * .pi) * Float(T)
                            let i0 = Int(fi) % T, i1 = (i0 + 1) % T, fr = fi - Float(Int(fi))
                            let r = TB[k * T + i0] * (1 - fr) + TB[k * T + i1] * fr
                            var hk: Float
                            if rho < r {
                                let u = rho / r, u2 = u * u
                                hk = H[k] * sqrt(1 - u2 * u2)
                                if spk[k] > 0.02 {
                                    // the hexagonal Rosensweig bumps on the top surface
                                    let q: Float = 2 * .pi / 0.09
                                    let b1 = cos(q * px + tt * 0.3), b2 = cos(q * (-0.5 * px + 0.866 * py))
                                    let b3 = cos(q * (-0.5 * px - 0.866 * py))
                                    hk += spk[k] * 0.02 * (b1 + b2 + b3 + 1.5) * (1 - u2)
                                }
                            } else {
                                hk = -(rho - r) * 2
                            }
                            // smooth maximum: necks between drops that come close
                            let df = abs(hv - hk)
                            hv = max(hv, hk) + (df < kS ? (kS - df) * (kS - df) / (4 * kS) : 0)
                        }
                        // the glass wall flattens the fluid
                        let pr = sqrt(px * px + py * py)
                        PL[y * nx + x] = min(hv, (1 - pr) * 2)
                    }
                }
            }
        } }
        let sz = depth / Float(nz)
        let slope: Float = 6
        grid.withUnsafeMutableBufferPointer { G in plane.withUnsafeBufferPointer { PL in
            DispatchQueue.concurrentPerform(iterations: nz) { z in
                let az = abs((Float(z) + 0.5) * sz - depth / 2)
                let base = z * nx * ny
                for k in 0..<(nx * ny) { G[base + k] = max(0, min(2, iso + slope * (PL[k] - az))) }
            }
        } }
    }
}
