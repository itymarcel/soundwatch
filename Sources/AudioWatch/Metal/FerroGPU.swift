import Foundation
import Metal
import simd

/// What Real Metaballs hands the renderer each frame.
struct FerroInput {
    /// Coil currents (one per magnet, 3…13), after the dial.
    var currents: [Float]
    /// Amount of fluid (1 = default).
    var fluid: Float
    var dt: Float
    var frozen: Bool
    /// Music hits, 0…2 (× Burst strength): the liquid briefly wants more room and bursts apart (like adding fluid inside it).
    var burst: Float = 0
    /// Pull back to the centre, 0…1 (the Centre pull setting).
    var home: Float = 0.5
    /// At rest, 0…1 (no coil current for a while): the liquid is pulled into a ball and drawn as a perfect sphere.
    var rest: Float = 0
}

/// Real Metaballs on the GPU: ferrofluid in water inside a glass sphere, with electromagnets spread over a sphere
/// around it. A position-based fluid (Macklin & Müller 2013) of ~20–80k particles:
/// - **Liquid:** incompressible (density constraint, solved in a few Jacobi iterations per substep), viscosity (XSPH),
///   surface tension (Akinci cohesion), gravity after buoyancy, drag from the water, the glass wall.
/// - **Magnetism:** each coil is a dipole on the outer sphere pointing at the centre; the fluid is magnetised along the
///   local field, M = Langevin (saturating), and pulled towards stronger field (Kelvin force M ∇|H|). Magnetised
///   neighbours interact as dipoles: head-to-tail they attract, side by side they repel, so the fluid lines up along
///   the field lines and its surface breaks into spikes pointing at the coils (the Rosensweig instability), and a
///   magnetised blob spreads sideways.
/// - **Drawing:** the particles are splatted into a 128³ density volume (fixed-point atomics), which `metaballsFrag`
///   raymarches. Everything stays on the GPU.
///
/// Units: glass radius ≈ 1, y up, seconds. Tunables can be overridden for tests with
/// `AUDIOWATCH_FERRO='{"kelvin":1.5,…}'`.
final class FerroGPU {
    static let maxN = 100_000
    static let volN = 128
    static let gridCap = 16

    // tuning
    var d0: Float = 0.017          // particle spacing
    var gravity: Float = 0.08     // after buoyancy: the ferrofluid is only a little denser than the water around it
    var drag: Float = 1.5
    var visc: Float = 0.3
    var cohesion: Float = 15
    var kelvin: Float = 0.6
    var dipole: Float = 0.25
    var home: Float = 3            // pull back to the centre (∝ distance): the fluid hangs in the middle of the water
    var maxAccel: Float = 10       // stabilisers: the pull right next to a coil is far stronger than the solver can take
    var maxVel: Float = 4
    var tension: Float = 0.7       // surface tension inside the pressure solve: under-dense (surface) particles pull
    var xi: Float = 3
    var coilR: Float = 1.6         // radius of the sphere the coils sit on
    var coilW: Float = 0.5        // the coil's size (softens its field close up)
    var iterations = 2
    var substepDt: Float = 1.0 / 120
    var scorrK: Float = 0.1
    var relaxFactor: Float = 0.05
    var splatR: Float = 2.8        // voxels
    var wall: Float = 0.97
    var testPattern: Float = 0
    var curvature: Float = 1       // surface tension's curvature part (Akinci): presses bumps flat
    var blurPasses = 2             // 2 = the wide blur (9 taps): a tight, smooth surface; 1 = the narrow one
    var smooth: Float = 0.6       // drawing: how far each particle is pulled to its neighbours' mean
    private var homeOverride: Float?
    private var burst: Float = 0
    /// Dead band (speed below which a particle's move is cancelled): `stillBase` always, + `stillRest` once it's quiet.
    private var still: Float = 0, stillOverride: Float?
    private var stillBase: Float = 0
    /// At rest: the drawn sphere's radius and centre height (the liquid's volume as a ball, where it hangs).
    private(set) var restRadius: Float = 0, restY: Float = 0
    /// Calibrates the ball's radius to the drawn surface of the particles (iso 0.5 of the splatted, blurred volume).
    private var restScale: Float = 1.02
    /// Debug (`restDraw` 0): physics of rest only, no sphere drawn - to check the ball's radius against the particles.
    private(set) var restDraw: Float = 1

    private let device: MTLDevice
    private let pipes: [String: MTLComputePipelineState]
    private var pos, vel, posS, velS, dip, dipS: MTLBuffer
    private let pred, delta, lambda, mag, force, spos, nrm, cnt, slots, vol, offs, blockSums, rank, cid: MTLBuffer
    /// The density volume the raymarcher draws (after the blur), and the scratch one the blur passes ping-pong with.
    let texture: MTLTexture
    private let texRaw: MTLTexture
    /// The coils' field on a coarse grid (built once per frame): H.xyz + |H|, and ∇|H|.
    private let fieldTex: MTLTexture, gradTex: MTLTexture
    static let fieldN = 32
    /// Which 16³ blocks of the sphere's cube hold any fluid: the raymarcher jumps over the empty ones.
    let occupancy: MTLBuffer
    static let occN = 16
    private(set) var n = 0
    private var fluid: Float = -1
    private var lastCB: MTLCommandBuffer?
    private var rng = SplitMix(seed: 0xFE77)
    private var rho0: Float = 1, relax: Float = 1, volScale: Float = 1, lamScale: Float = 1
    private var G = 1
    private var time: Float = 0
    private var frameNo = 0
    private var pending: Float = 0
    private static let debug = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private let lock = NSLock()
    private var gpuMsShared: Double = 0
    /// GPU time of the last simulation pass (ms).
    var gpuMs: Double { lock.lock(); defer { lock.unlock() }; return gpuMsShared }

    struct Params {
        var n: UInt32, G: UInt32, cap: UInt32, V: UInt32
        var dt: Float, h: Float, rho0: Float, d0: Float
        var R: Float, gravity: Float, drag: Float, visc: Float
        var cohesion: Float, kelvin: Float, dipole: Float, xi: Float
        var relax: Float, scorrK: Float, splatR: Float, volScale: Float
        var coilW: Float, fieldScale: Float, coils: Float, langXi: Float
        var maxAccel: Float, maxVel: Float, tension: Float, home: Float
        var expand: Float, smooth: Float, curv: Float, still: Float
        var poly6K: Float, spikyK: Float, scorrW: Float, lamScale: Float
    }

    init?(device: MTLDevice) {
        self.device = device
        do {
            let lib = try device.makeLibrary(source: FerroGPU.source, options: nil)
            var p: [String: MTLComputePipelineState] = [:]
            for name in ["fe_clearGrid", "fe_insert", "fe_field", "fe_predict", "fe_lambda", "fe_delta", "fe_apply",
                         "fe_final", "fe_clearVol", "fe_splat", "fe_toTex", "fe_fieldGrid", "fe_blur",
                         "fe_scanBlocks", "fe_scanTop", "fe_scanAdd", "fe_reorder"] {
                p[name] = try device.makeComputePipelineState(function: lib.makeFunction(name: name)!)
            }
            pipes = p
        } catch {
            NSLog("soundwatch: ferro GPU pipeline error \(error)")
            return nil
        }
        let N = Self.maxN
        func b(_ bytes: Int) -> MTLBuffer { device.makeBuffer(length: bytes, options: .storageModeShared)! }
        pos = b(N * 16); vel = b(N * 16); posS = b(N * 16); velS = b(N * 16); dip = b(N * 16); dipS = b(N * 16)
        spos = b(N * 16); nrm = b(N * 16); pred = b(N * 16); delta = b(N * 16); rank = b(N * 4); cid = b(N * 4)
        lambda = b(N * 4); mag = b(N * 16); force = b(N * 16)
        let h = 2 * 0.017 as Float
        let g = Int((2 / h).rounded(.up))
        cnt = b(g * g * g * 4); slots = b(g * g * g * Self.gridCap * 4); offs = b(g * g * g * 4); blockSums = b(4096 * 4)
        let V = Self.volN
        vol = device.makeBuffer(length: V * V * V * 4, options: .storageModePrivate)!
        let td = MTLTextureDescriptor()
        td.textureType = .type3D; td.pixelFormat = .r16Float
        td.width = V; td.height = V; td.depth = V
        td.usage = [.shaderRead, .shaderWrite]; td.storageMode = .private
        texture = device.makeTexture(descriptor: td)!
        texRaw = device.makeTexture(descriptor: td)!
        let fd = MTLTextureDescriptor()
        fd.textureType = .type3D; fd.pixelFormat = .rgba16Float
        fd.width = Self.fieldN; fd.height = Self.fieldN; fd.depth = Self.fieldN
        fd.usage = [.shaderRead, .shaderWrite]; fd.storageMode = .private
        fieldTex = device.makeTexture(descriptor: fd)!
        gradTex = device.makeTexture(descriptor: fd)!
        occupancy = b(Self.occN * Self.occN * Self.occN * 4)
        applyOverrides()
        precompute()
    }

    private func applyOverrides() {
        guard let s = ProcessInfo.processInfo.environment["AUDIOWATCH_FERRO"], let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double] else { return }
        func f(_ k: String, _ v: inout Float) { if let x = o[k] { v = Float(x) } }
        f("gravity", &gravity); f("drag", &drag); f("visc", &visc); f("cohesion", &cohesion); f("kelvin", &kelvin)
        f("dipole", &dipole); f("xi", &xi); f("coilR", &coilR); f("coilW", &coilW)
        f("maxAccel", &maxAccel); f("maxVel", &maxVel); f("test", &testPattern); f("tension", &tension); f("smooth", &smooth); f("curv", &curvature)
        if let x = o["blur"] { blurPasses = Int(x) }
        if let x = o["home"] { homeOverride = Float(x); home = Float(x) }
        if let x = o["still"] { stillOverride = Float(x) }
        if let x = o["stillBase"] { stillBase = Float(x) }
        if let x = o["restScale"] { restScale = Float(x) }
        if let x = o["restDraw"] { restDraw = Float(x) }
        f("scorrK", &scorrK); f("relaxFactor", &relaxFactor); f("splatR", &splatR); f("substepDt", &substepDt)
        if let x = o["iterations"] { iterations = Int(x) }
    }

    private var h: Float { 2 * d0 }

    /// Rest density (poly6, mass 1), the constraint's relaxation, and the splat sum of a rest lattice.
    private func precompute() {
        let h = h, h2 = h * h
        let k6 = 315 / (64 * Float.pi * pow(h, 9)), ks = -45 / (Float.pi * pow(h, 6))
        var rho: Float = 0
        var gsum = SIMD3<Float>.zero, g2: Float = 0
        let m = Int((h / d0).rounded(.up))
        for z in -m...m { for y in -m...m { for x in -m...m {
            let r = SIMD3<Float>(Float(x), Float(y), Float(z)) * d0
            let r2 = simd_length_squared(r)
            guard r2 < h2 else { continue }
            let dd = h2 - r2
            rho += k6 * dd * dd * dd
            if r2 > 1e-12 {
                let rl = sqrt(r2)
                let gr = ks * (h - rl) * (h - rl) * (r / rl)
                gsum += gr; g2 += simd_length_squared(gr)
            }
        } } }
        rho0 = rho
        let gc = (simd_length_squared(gsum) + g2) / (rho * rho)    // Σ|∇C|² at rest
        relax = relaxFactor * gc
        lamScale = 1 / gc
        G = Int((2 / h).rounded(.up))
        // splat sum at a voxel inside a rest lattice
        let vox = 2 / Float(Self.volN)
        let R = splatR
        var s: Float = 0
        let mm = Int((R * vox / d0).rounded(.up)) + 1
        for z in -mm...mm { for y in -mm...mm { for x in -mm...mm {
            let r = SIMD3<Float>(Float(x), Float(y), Float(z)) * d0 / vox + 0.31
            let q = simd_length_squared(r) / (R * R)
            if q < 1 { s += pow(1 - q, 3) }
        } } }
        volScale = s
    }

    /// Spreads `k` coils evenly over the outer sphere (Fibonacci sphere).
    private func coilPositions(_ k: Int) -> [SIMD3<Float>] {
        (0..<k).map { i in
            let y = 1 - 2 * (Float(i) + 0.5) / Float(k)
            let r = sqrt(max(0, 1 - y * y))
            let a = Float(i) * 2.399963
            return SIMD3(r * cos(a), y, r * sin(a)) * coilR
        }
    }

    /// Fills the glass with one round blob of `count` particles in the middle.
    private func seed(count: Int) {
        let rb = cbrt(Float(count) * d0 * d0 * d0 * 3 / (4 * .pi))
        let c = SIMD3<Float>(0, -0.1, 0)      // floating in the middle (it sinks only slowly)
        var pts: [SIMD3<Float>] = []
        let m = Int((rb / d0).rounded(.up)) + 1
        for z in -m...m { for y in -m...m { for x in -m...m {
            let p = SIMD3<Float>(Float(x), Float(y), Float(z)) * d0
            if simd_length(p) <= rb { pts.append(c + p) }
        } } }
        pts.shuffle(using: &rng)
        let P = pos.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxN)
        let Vb = vel.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxN)
        n = min(Self.maxN, pts.count)
        for i in 0..<n {
            let j = SIMD3<Float>(Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.5) * (0.1 * d0)
            P[i] = SIMD4(pts[i] + j, 0); Vb[i] = .zero
        }
        syncExtras(from: 0)
    }

    /// New particles: drawn where they are, no dipole force yet.
    private func syncExtras(from: Int) {
        guard n > from else { return }
        let P = pos.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxN)
        let S = spos.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxN)
        let D = dip.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxN)
        for i in from..<n { S[i] = P[i]; D[i] = .zero }
    }

    /// Amount of fluid: volume ∝ Fluid^0.75 (a blob of radius 0.3 at 1). More fluid = new particles next to random
    /// existing ones (they push apart); less = the newest go.
    private func setFluid(_ f: Float) {
        let f = max(0.1, f)
        guard abs(f - fluid) > 1e-3 else { return }
        let vol = 4 / 3 * Float.pi * 0.027 * pow(f, 0.75)
        let target = min(Self.maxN, Int(vol / (d0 * d0 * d0)))
        lastCB?.waitUntilCompleted()
        if fluid < 0 || n == 0 {
            seed(count: target)
        } else if target > n {
            let P = pos.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxN)
            let Vb = vel.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxN)
            for i in n..<target {
                let j = Int(rng.next() % UInt64(n))
                let o = SIMD3<Float>(Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.5, Float(rng.unit()) - 0.5) * (0.4 * d0)
                P[i] = P[j] + SIMD4(o, 0); Vb[i] = Vb[j]
            }
            let old = n
            n = target
            syncExtras(from: old)
        } else {
            n = max(100, target)
        }
        fluid = f
    }

    private func params(dt: Float, coils: Int) -> Params {
        let h = h
        let lx = 1 / tanh(xi) - 1 / xi
        let k6 = 315 / (64 * Float.pi * pow(h, 9))
        let dq = 0.2 * h
        let wq = k6 * pow(h * h - dq * dq, 3)
        return Params(n: UInt32(n), G: UInt32(G), cap: UInt32(Self.gridCap), V: UInt32(Self.volN),
                      dt: dt, h: h, rho0: rho0, d0: d0,
                      R: wall - 0.5 * d0, gravity: gravity, drag: drag, visc: visc,
                      cohesion: cohesion, kelvin: kelvin, dipole: dipole, xi: xi,
                      relax: relax, scorrK: scorrK, splatR: splatR, volScale: volScale,
                      // one coil at full current: |H| = 1 at the centre of the sphere
                      coilW: coilW, fieldScale: pow(coilR * coilR + coilW * coilW, 1.5) / 2, coils: Float(coils), langXi: lx,
                      maxAccel: maxAccel, maxVel: maxVel, tension: tension, home: home,
                      expand: 1 + 0.22 * pow(min(burst, 1), 4), smooth: smooth, curv: curvature, still: still,   // burst: a short kick at the start of the pulse
                      poly6K: k6, spikyK: -45 / (Float.pi * pow(h, 6)), scorrW: wq, lamScale: lamScale)
    }

    /// Runs this frame's substeps and refreshes the density volume, in its own command buffer (committed now, so it
    /// runs before the raymarch on the same queue). Returns the volume texture.
    func encode(queue: MTLCommandQueue, input: FerroInput) -> MTLTexture? {
        setFluid(input.fluid)
        guard n > 0, let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return texture }
        let k = max(1, min(13, input.currents.count))
        let cp = coilPositions(k)
        var I = input.currents
        if testPattern > 0 {   // debug: one coil at a time, each for `testPattern` seconds
            let on = Int(time / testPattern) % k
            I = (0..<k).map { $0 == on ? 1 : 0 }
        }
        var coils = (0..<16).map { i -> SIMD4<Float> in i < k ? SIMD4(cp[i], max(0, I[i])) : .zero }
        // fixed substeps (PBF's velocity = Δx / dt: a tiny or uneven dt blows it up); time that doesn't fill a step
        // waits for the next frame, more than 8 steps' worth is dropped
        if !input.frozen { pending += input.dt }
        let steps = min(8, Int(pending / substepDt))
        pending = steps == 8 ? 0 : pending - Float(steps) * substepDt
        if homeOverride == nil { home = 6 * max(0, input.home) }
        burst = max(0, min(2, input.burst))
        still = stillOverride ?? stillBase
        var P = params(dt: substepDt, coils: k)
        // at rest: a much stronger pull to the centre and thick damping gather the liquid into a calm ball
        let rest = max(0, min(1, input.rest))
        P.home = home * (1 + 4 * rest)
        P.drag = drag + 8 * rest
        restRadius = cbrt(3 * Float(n) / (4 * .pi)) * d0 * restScale
        restY = -gravity / max(P.home, 0.1)
        let cells = G * G * G
        func run(_ name: String, _ count: Int, _ bufs: [MTLBuffer], _ texs: [MTLTexture] = []) {
            let p = pipes[name]!
            e.setComputePipelineState(p)
            for (i, b) in bufs.enumerated() { e.setBuffer(b, offset: 0, index: i) }
            for (i, t) in texs.enumerated() { e.setTexture(t, index: i) }
            e.setBytes(&P, length: MemoryLayout<Params>.stride, index: bufs.count)
            e.setBytes(&coils, length: 16 * 16, index: bufs.count + 1)
            let w = min(256, p.maxTotalThreadsPerThreadgroup)
            e.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        }
        func grid(_ x: MTLBuffer) {
            run("fe_clearGrid", cells, [cnt])
            run("fe_insert", n, [x, cnt, slots, rank, cid])
        }
        func run3D(_ name: String, _ size: Int, _ texs: [MTLTexture], _ bufs: [MTLBuffer] = []) {
            e.setComputePipelineState(pipes[name]!)
            for (i, b) in bufs.enumerated() { e.setBuffer(b, offset: 0, index: i) }
            e.setBytes(&P, length: MemoryLayout<Params>.stride, index: bufs.count)
            e.setBytes(&coils, length: 16 * 16, index: bufs.count + 1)
            for (i, t) in texs.enumerated() { e.setTexture(t, index: i) }
            e.dispatchThreads(MTLSize(width: size, height: size, depth: size), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        }
        if steps > 0 {
            // the coils' field, once per frame (the currents don't change within it)
            run3D("fe_fieldGrid", Self.fieldN, [fieldTex, gradTex])
            // sort the particles by grid cell once per frame (counting sort: scan of the cell counts, then scatter):
            // neighbours then sit next to each other in memory
            grid(pos)
            let nb = (cells + 511) / 512
            e.setComputePipelineState(pipes["fe_scanBlocks"]!)
            e.setBuffer(cnt, offset: 0, index: 0); e.setBuffer(offs, offset: 0, index: 1); e.setBuffer(blockSums, offset: 0, index: 2)
            e.setBytes(&P, length: MemoryLayout<Params>.stride, index: 3)
            e.dispatchThreadgroups(MTLSize(width: nb, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 512, height: 1, depth: 1))
            e.setComputePipelineState(pipes["fe_scanTop"]!)
            e.setBuffer(blockSums, offset: 0, index: 0)
            e.setBytes(&P, length: MemoryLayout<Params>.stride, index: 1)
            e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
            run("fe_scanAdd", cells, [offs, blockSums])
            run("fe_reorder", n, [pos, vel, posS, velS, offs, cid, rank, dip, dipS])
            swap(&pos, &posS); swap(&vel, &velS); swap(&dip, &dipS)
            for _ in 0..<steps {
                run("fe_field", n, [pos, mag, force, dip], [fieldTex, gradTex])
                run("fe_predict", n, [pos, vel, force, pred])
                grid(pred)
                for _ in 0..<iterations {
                    run("fe_lambda", n, [pred, lambda, cnt, slots, nrm])
                    run("fe_delta", n, [pred, lambda, delta, cnt, slots])
                    run("fe_apply", n, [pred, delta])
                }
                // velocities, viscosity, surface tension, the dipole forces for the next substep, the smoothed positions
                // for drawing; the new positions go to posS (others still read the old ones)
                run("fe_final", n, [pos, pred, vel, posS, mag, dip, spos, cnt, slots, nrm])
                swap(&pos, &posS)
            }
        }
        // the density volume
        let V = Self.volN
        run("fe_clearVol", V * V * V, [vol, occupancy])
        run("fe_splat", n, [spos, vol, occupancy])
        run3D("fe_toTex", V, [texRaw], [vol])
        // a separable binomial blur (x, y, z): a smooth surface and smooth normals
        var axis: UInt32 = 0
        for (k, (src, dst)) in [(texRaw, texture), (texture, texRaw), (texRaw, texture)].enumerated() {
            axis = UInt32(k) | (blurPasses > 1 ? 16 : 0)     // bit 4: the wide (9-tap) kernel
            e.setComputePipelineState(pipes["fe_blur"]!)
            e.setTexture(src, index: 0); e.setTexture(dst, index: 1)
            e.setBytes(&axis, length: 4, index: 0)
            e.dispatchThreads(MTLSize(width: V, height: V, depth: V), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        }
        e.endEncoding()
        cb.addCompletedHandler { [weak self] c in
            guard let self else { return }
            self.lock.lock(); self.gpuMsShared = (c.gpuEndTime - c.gpuStartTime) * 1000; self.lock.unlock()
        }
        cb.commit()
        lastCB = cb
        time += input.dt
        frameNo += 1
        if Self.debug && frameNo % 20 == 1 {
            cb.waitUntilCompleted()
            let Pp = pos.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
            let Vp = vel.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
            var mean = SIMD3<Float>.zero, vmax: Float = 0, rmax: Float = 0, nan = 0, vsum: Float = 0
            for i in 0..<n {
                let p = SIMD3(Pp[i].x, Pp[i].y, Pp[i].z)
                if p.x.isNaN { nan += 1; continue }
                let sp = simd_length(SIMD3(Vp[i].x, Vp[i].y, Vp[i].z))
                mean += p; vmax = max(vmax, sp); vsum += sp
                rmax = max(rmax, simd_length(p))
            }
            mean /= Float(max(1, n - nan))
            var sd: Float = 0
            for i in 0..<n where !Pp[i].x.isNaN { sd += simd_length_squared(SIMD3(Pp[i].x, Pp[i].y, Pp[i].z) - mean) }
            print(String(format: "FERRO f=%d n=%d steps=%d mean=(%.2f,%.2f,%.2f) spread=%.3f vmean=%.3f vmax=%.2f rmax=%.2f still=%.2f nan=%d rho0=%.1f relax=%.3g vs=%.2f",
                         frameNo, n, steps, mean.x, mean.y, mean.z, sqrt(sd / Float(max(1, n))), vsum / Float(max(1, n - nan)), vmax, rmax, still, nan, rho0, relax, volScale))
        }
        return texture
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FP {
        uint n; uint G; uint cap; uint V;
        float dt; float h; float rho0; float d0;
        float R; float gravity; float drag; float visc;
        float cohesion; float kelvin; float dipole; float xi;
        float relax; float scorrK; float splatR; float volScale;
        float coilW; float fieldScale; float coils; float langXi;
        float maxAccel; float maxVel; float tension; float home;
        float expand; float smooth; float curv; float still;
        float poly6K; float spikyK; float scorrW; float lamScale;
    };

    static inline int3 cellOf(float3 p, constant FP& P) {
        return clamp(int3((p + 1.0) / P.h), int3(0), int3(int(P.G) - 1));
    }
    static inline uint cellIndex(int3 c, constant FP& P) { return (uint(c.z) * P.G + uint(c.y)) * P.G + uint(c.x); }
    static inline float3 bound(float3 p, constant FP& P) {
        float r = length(p);
        return r > P.R ? p * (P.R / r) : p;
    }

    #define FOR_NEIGHBORS(p, BODY...) { \\
        int3 c0 = cellOf(p, P); \\
        for (int dz = -1; dz <= 1; dz++) for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { \\
            int3 c = c0 + int3(dx, dy, dz); \\
            if (any(c < int3(0)) || any(c >= int3(int(P.G)))) continue; \\
            uint ci = cellIndex(c, P); \\
            uint m = min(cnt[ci], P.cap); \\
            for (uint s = 0; s < m; s++) { uint j = slots[ci * P.cap + s]; BODY } \\
        } }

    // ---- neighbour grid
    kernel void fe_clearGrid(device atomic_uint* cnt [[buffer(0)]], constant FP& P [[buffer(1)]], uint id [[thread_position_in_grid]]) {
        if (id < P.G * P.G * P.G) atomic_store_explicit(&cnt[id], 0u, memory_order_relaxed);
    }
    kernel void fe_insert(device const float4* x [[buffer(0)]], device atomic_uint* cnt [[buffer(1)]], device uint* slots [[buffer(2)]],
                          device uint* rank [[buffer(3)]], device uint* cid [[buffer(4)]],
                          constant FP& P [[buffer(5)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        uint ci = cellIndex(cellOf(x[i].xyz, P), P);
        uint s = atomic_fetch_add_explicit(&cnt[ci], 1u, memory_order_relaxed);
        if (s < P.cap) slots[ci * P.cap + s] = i;
        rank[i] = s; cid[i] = ci;
    }

    // ---- counting sort by cell: exclusive scan of the counts (blocks of 512, then the block sums), then scatter
    kernel void fe_scanBlocks(device const uint* cnt [[buffer(0)]], device uint* offs [[buffer(1)]], device uint* blockSums [[buffer(2)]],
                              constant FP& P [[buffer(3)]], uint gid [[thread_position_in_grid]],
                              uint lid [[thread_position_in_threadgroup]], uint bid [[threadgroup_position_in_grid]]) {
        threadgroup uint tmp[512];
        uint total = P.G * P.G * P.G;
        uint v = gid < total ? cnt[gid] : 0u;
        tmp[lid] = v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint o = 1; o < 512; o <<= 1) {
            uint add = lid >= o ? tmp[lid - o] : 0u;
            threadgroup_barrier(mem_flags::mem_threadgroup);
            tmp[lid] += add;
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (gid < total) offs[gid] = tmp[lid] - v;
        if (lid == 511) blockSums[bid] = tmp[511];
    }
    kernel void fe_scanTop(device uint* blockSums [[buffer(0)]], constant FP& P [[buffer(1)]], uint lid [[thread_position_in_threadgroup]]) {
        threadgroup uint tmp[1024];
        uint nb = (P.G * P.G * P.G + 511) / 512;
        uint v = lid < nb ? blockSums[lid] : 0u;
        tmp[lid] = v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint o = 1; o < 1024; o <<= 1) {
            uint add = lid >= o ? tmp[lid - o] : 0u;
            threadgroup_barrier(mem_flags::mem_threadgroup);
            tmp[lid] += add;
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (lid < nb) blockSums[lid] = tmp[lid] - v;
    }
    kernel void fe_scanAdd(device uint* offs [[buffer(0)]], device const uint* blockSums [[buffer(1)]],
                           constant FP& P [[buffer(2)]], constant float4* coils [[buffer(3)]], uint gid [[thread_position_in_grid]]) {
        if (gid < P.G * P.G * P.G) offs[gid] += blockSums[gid / 512];
    }
    kernel void fe_reorder(device const float4* pos [[buffer(0)]], device const float4* vel [[buffer(1)]],
                           device float4* posS [[buffer(2)]], device float4* velS [[buffer(3)]],
                           device const uint* offs [[buffer(4)]], device const uint* cid [[buffer(5)]], device const uint* rank [[buffer(6)]],
                           device const float4* dip [[buffer(7)]], device float4* dipS [[buffer(8)]],
                           constant FP& P [[buffer(9)]], constant float4* coils [[buffer(10)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        uint j = offs[cid[i]] + rank[i];
        posS[j] = pos[i]; velS[j] = vel[i]; dipS[j] = dip[i];
    }

    // ---- the coils' field: each a dipole on the outer sphere pointing at the centre (|H| = 1 at fieldAt on its axis)
    static float3 coilField(float3 p, constant FP& P, constant float4* coils) {
        float3 H = 0;
        for (int k = 0; k < int(P.coils); k++) {
            float I = coils[k].w;
            if (I <= 0.0) continue;
            float3 c = coils[k].xyz;
            float3 m = -normalize(c) * I;
            float3 r = p - c;
            float d2 = dot(r, r) + P.coilW * P.coilW;
            float d = sqrt(d2);
            float3 rh = r / d;
            H += (3.0 * dot(m, rh) * rh - m) / (d2 * d);
        }
        return H * P.fieldScale;
    }
    static inline float langevin(float x) { return x < 1e-3 ? x / 3.0 : 1.0 / tanh(x) - 1.0 / x; }

    // the field on a coarse grid over the sphere's cube, once per frame: H.xyz + |H|, and ∇|H| (numerically)
    kernel void fe_fieldGrid(constant FP& P [[buffer(0)]], constant float4* coils [[buffer(1)]],
                             texture3d<half, access::write> fieldTex [[texture(0)]], texture3d<half, access::write> gradTex [[texture(1)]],
                             uint3 g [[thread_position_in_grid]]) {
        uint N = fieldTex.get_width();
        if (any(g >= uint3(N))) return;
        float3 p = (float3(g) + 0.5) / float(N) * 2.0 - 1.0;
        float3 H = coilField(p, P, coils);
        const float e = 0.02;
        float3 gr = float3(length(coilField(p + float3(e, 0, 0), P, coils)) - length(coilField(p - float3(e, 0, 0), P, coils)),
                           length(coilField(p + float3(0, e, 0), P, coils)) - length(coilField(p - float3(0, e, 0), P, coils)),
                           length(coilField(p + float3(0, 0, e), P, coils)) - length(coilField(p - float3(0, 0, e), P, coils))) / (2.0 * e);
        fieldTex.write(half4(half3(H), half(length(H))), g);
        gradTex.write(half4(half3(gr), 0.0h), g);
    }

    // per particle: magnetisation (Langevin, along H) and the Kelvin pull M ∇|H|, + the dipole forces from last substep
    kernel void fe_field(device const float4* pos [[buffer(0)]], device float4* mag [[buffer(1)]], device float4* force [[buffer(2)]],
                         device const float4* dip [[buffer(3)]], constant FP& P [[buffer(4)]], constant float4* coils [[buffer(5)]],
                         texture3d<float> fieldTex [[texture(0)]], texture3d<float> gradTex [[texture(1)]],
                         uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        constexpr sampler ls(filter::linear, address::clamp_to_edge);
        float3 uvw = pos[i].xyz * 0.5 + 0.5;
        float3 H = fieldTex.sample(ls, uvw).xyz;
        float3 g = gradTex.sample(ls, uvw).xyz;
        float hm = length(H);
        float M = langevin(P.xi * hm) / P.langXi;
        mag[i] = float4(hm > 1e-6 ? H / hm * M : float3(0), M);
        force[i] = float4(P.kelvin * M * g + dip[i].xyz, 0);
    }

    kernel void fe_predict(device const float4* pos [[buffer(0)]], device const float4* vel [[buffer(1)]], device const float4* force [[buffer(2)]],
                           device float4* pred [[buffer(3)]], constant FP& P [[buffer(4)]], constant float4* coils [[buffer(5)]],
                           uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        float3 a = force[i].xyz;
        float al = length(a);
        if (al > P.maxAccel) a *= P.maxAccel / al;
        if (!all(isfinite(a))) a = 0;
        // back to the centre: grows with the distance, so the coils win only while they're strong
        a -= P.home * pos[i].xyz;
        float3 v = vel[i].xyz + P.dt * (float3(0, -P.gravity, 0) + a);
        v /= 1.0 + P.drag * P.dt;
        float vl = length(v);
        if (vl > P.maxVel) v *= P.maxVel / vl;
        pred[i] = float4(bound(pos[i].xyz + P.dt * v, P), 0);
    }

    // ---- density constraint (PBF)
    kernel void fe_lambda(device const float4* pred [[buffer(0)]], device float* lambda [[buffer(1)]],
                          device const uint* cnt [[buffer(2)]], device const uint* slots [[buffer(3)]], device float4* nrm [[buffer(4)]],
                          constant FP& P [[buffer(5)]], constant float4* coils [[buffer(6)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        float3 pi = pred[i].xyz;
        float h = P.h, h2 = h * h;
        float rho = 0, g2 = 0;
        float3 gi = 0;
        FOR_NEIGHBORS(pi,
            float3 r = pi - pred[j].xyz;
            float d2 = dot(r, r);
            if (d2 >= h2) continue;
            float dd = h2 - d2;
            rho += P.poly6K * dd * dd * dd;
            if (j != i && d2 > 1e-12) {
                float d = sqrt(d2);
                float3 g = P.spikyK * (h - d) * (h - d) * (r / d) / P.rho0;
                gi += g; g2 += dot(g, g);
            }
        )
        float C = rho * P.expand / P.rho0 - 1.0;   // expand > 1 (a burst): the liquid wants more room
        if (C < 0.0) C *= P.tension;     // the surface pulls inwards (surface tension), within the solve
        lambda[i] = -C / (dot(gi, gi) + g2 + P.relax);
        nrm[i] = float4(gi * h, 0);     // the surface normal (Akinci): ~0 inside, points inwards at the surface
    }

    kernel void fe_delta(device const float4* pred [[buffer(0)]], device const float* lambda [[buffer(1)]], device float4* delta [[buffer(2)]],
                         device const uint* cnt [[buffer(3)]], device const uint* slots [[buffer(4)]],
                         constant FP& P [[buffer(5)]], constant float4* coils [[buffer(6)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        float3 pi = pred[i].xyz;
        float h = P.h, h2 = h * h;
        float li = lambda[i];
        float3 D = 0;
        FOR_NEIGHBORS(pi,
            if (j == i) continue;
            float3 r = pi - pred[j].xyz;
            float d2 = dot(r, r);
            if (d2 >= h2 || d2 < 1e-12) continue;
            float d = sqrt(d2);
            float dd = h2 - d2;
            float w = P.poly6K * dd * dd * dd / P.scorrW;
            float sc = -P.scorrK * P.lamScale * w * w * w * w;   // in λ's units
            D += (li + lambda[j] + sc) * P.spikyK * (h - d) * (h - d) * (r / d);
        )
        delta[i] = float4(D / P.rho0, 0);
    }

    kernel void fe_apply(device float4* pred [[buffer(0)]], device const float4* delta [[buffer(1)]],
                         constant FP& P [[buffer(2)]], constant float4* coils [[buffer(3)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        pred[i] = float4(bound(pred[i].xyz + delta[i].xyz, P), 0);
    }


    // ---- velocity from the solve, viscosity (XSPH), surface tension (Akinci cohesion), the dipole forces of the
    // magnetised neighbours (head-to-tail attract, side by side repel; used next substep) and a smoothed position for
    // drawing (Laplacian smoothing of the particles: takes the per-particle bumpiness out of the surface)
    kernel void fe_final(device const float4* pos [[buffer(0)]], device const float4* pred [[buffer(1)]], device float4* vel [[buffer(2)]],
                         device float4* posN [[buffer(3)]], device const float4* mag [[buffer(4)]], device float4* dip [[buffer(5)]],
                         device float4* spos [[buffer(6)]], device const uint* cnt [[buffer(7)]], device const uint* slots [[buffer(8)]],
                         device const float4* nrm [[buffer(9)]],
                         constant FP& P [[buffer(10)]], constant float4* coils [[buffer(11)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        float3 pi = pred[i].xyz, vi = (pi - pos[i].xyz) / P.dt;
        float3 mi = mag[i].xyz;
        bool magnetised = mag[i].w > 1e-3 && P.dipole > 0.0;
        float h = P.h, h2 = h * h, h6 = h2 * h2 * h2;
        float w0 = P.poly6K * h6;
        float3 dv = 0, coh = 0, F = 0, wp = pi * w0, curv = 0, ni = nrm[i].xyz;
        float ws = w0;
        FOR_NEIGHBORS(pi,
            if (j == i) continue;
            float3 pj = pred[j].xyz;
            float3 r = pi - pj;
            float d2 = dot(r, r);
            if (d2 >= h2 || d2 < 1e-12) continue;
            float d = sqrt(d2);
            float dd = h2 - d2;
            float w = P.poly6K * dd * dd * dd;
            float3 vj = (pj - pos[j].xyz) / P.dt;
            dv += (vj - vi) * (w / P.rho0);
            wp += pj * w; ws += w;
            float c = (h - d) * (h - d) * (h - d) * d2 * d * 64.0 / h6;
            float C = 2.0 * d > h ? c : 2.0 * c - 1.0;
            float3 rh = r / d;
            coh -= C * rh;
            curv += ni - nrm[j].xyz;      // differing normals = a bump: pressed flat
            if (magnetised) {
                float3 mj = mag[j].xyz;
                float a = dot(mi, rh), b = dot(mj, rh);
                float3 br = a * mj + b * mi + dot(mi, mj) * rh - 5.0 * a * b * rh;
                float q = d2 / h2;
                F += br * (1.0 - q) * (1.0 - q) / ((q + 0.05) * (q + 0.05));
            }
        )
        float3 v = vi + P.visc * dv + P.dt * (P.cohesion * coh - P.curv * curv);
        // dead band: moves slower than `still` are cancelled (velocity 0 and the particle stays where it was), so the
        // solver's leftover jitter can't keep the liquid crawling; in between it fades in. Loose drops (few neighbours)
        // are exempt, or they'd hang frozen in mid-air on their way back
        float keep = P.still > 0.0 ? smoothstep(P.still, 2.0 * P.still, length(v)) : 1.0;
        keep = max(keep, 1.0 - smoothstep(0.35, 0.6, ws / P.rho0));
        float3 pf = mix(pos[i].xyz, pi, keep);
        vel[i] = float4(v * keep, 0);
        posN[i] = float4(pf, 0);
        dip[i] = float4(P.dipole * F, 0);
        spos[i] = float4(mix(pf, wp / ws + (pf - pi), P.smooth), 0);
    }

    // ---- density volume for the raymarcher
    kernel void fe_clearVol(device atomic_int* vol [[buffer(0)]], device uint* occ [[buffer(1)]],
                            constant FP& P [[buffer(2)]], constant float4* coils [[buffer(3)]], uint id [[thread_position_in_grid]]) {
        if (id < P.V * P.V * P.V) atomic_store_explicit(&vol[id], 0, memory_order_relaxed);
        if (id < 16 * 16 * 16) occ[id] = 0;
    }
    kernel void fe_splat(device const float4* pos [[buffer(0)]], device atomic_int* vol [[buffer(1)]], device uint* occ [[buffer(2)]],
                         constant FP& P [[buffer(3)]], constant float4* coils [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        int V = int(P.V);
        float3 f = (pos[i].xyz + 1.0) * 0.5 * float(V) - 0.5;
        float R = P.splatR, R2 = R * R;
        // mark the 16³ blocks this splat (+ the blur's reach) touches
        {
            float pad = (R + 3.0) / float(V) * 2.0;
            int3 olo = clamp(int3(floor((pos[i].xyz - pad + 1.0) * 8.0)), int3(0), int3(15));
            int3 ohi = clamp(int3(floor((pos[i].xyz + pad + 1.0) * 8.0)), int3(0), int3(15));
            for (int z = olo.z; z <= ohi.z; z++) for (int y = olo.y; y <= ohi.y; y++) for (int x = olo.x; x <= ohi.x; x++)
                occ[(z * 16 + y) * 16 + x] = 1u;
        }
        int3 lo = max(int3(ceil(f - R)), int3(0)), hi = min(int3(floor(f + R)), int3(V - 1));
        for (int z = lo.z; z <= hi.z; z++) for (int y = lo.y; y <= hi.y; y++) for (int x = lo.x; x <= hi.x; x++) {
            float3 d = float3(x, y, z) - f;
            float q = dot(d, d) / R2;
            if (q >= 1.0) continue;
            float w = (1.0 - q) * (1.0 - q) * (1.0 - q);
            atomic_fetch_add_explicit(&vol[(z * V + y) * V + x], int(w * 1024.0), memory_order_relaxed);
        }
    }
    kernel void fe_toTex(device const int* vol [[buffer(0)]], constant FP& P [[buffer(1)]], constant float4* coils [[buffer(2)]],
                         texture3d<half, access::write> tex [[texture(0)]], uint3 g [[thread_position_in_grid]]) {
        int V = int(P.V);
        if (any(g >= uint3(V))) return;
        float v = float(vol[(int(g.z) * V + int(g.y)) * V + int(g.x)]) / 1024.0 / P.volScale;
        tex.write(half4(half(min(v, 4.0))), g);
    }
    // separable binomial blur [1 4 6 4 1] / 16 along one axis
    kernel void fe_blur(texture3d<half, access::read> src [[texture(0)]], texture3d<half, access::write> dst [[texture(1)]],
                        constant uint& axis [[buffer(0)]], uint3 g [[thread_position_in_grid]]) {
        int V = int(src.get_width());
        if (any(g >= uint3(V))) return;
        uint ax = axis & 3u;
        int3 d = ax == 0 ? int3(1, 0, 0) : ax == 1 ? int3(0, 1, 0) : int3(0, 0, 1);
        int3 c = int3(g);
        if (axis & 16u) {    // wide: [1 8 28 56 70 56 28 8 1] / 256
            const float w[5] = {70.0, 56.0, 28.0, 8.0, 1.0};
            float acc = w[0] * float(src.read(uint3(c)).r);
            for (int k = 1; k <= 4; k++)
                acc += w[k] * (float(src.read(uint3(clamp(c - k * d, 0, V - 1))).r) + float(src.read(uint3(clamp(c + k * d, 0, V - 1))).r));
            dst.write(half4(half(acc / 256.0)), g);
            return;
        }
        float acc = 6.0 * float(src.read(uint3(c)).r);
        acc += 4.0 * (float(src.read(uint3(clamp(c - d, 0, V - 1))).r) + float(src.read(uint3(clamp(c + d, 0, V - 1))).r));
        acc += float(src.read(uint3(clamp(c - 2 * d, 0, V - 1))).r) + float(src.read(uint3(clamp(c + 2 * d, 0, V - 1))).r);
        dst.write(half4(half(acc / 16.0)), g);
    }
    """
}
