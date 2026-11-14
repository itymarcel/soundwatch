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
    /// Pull back to the centre, 0…1 (the Centre pull setting).
    var home: Float = 0.5
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
    var d0: Float = 0.015          // particle spacing
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
    var substepDt: Float = 1.0 / 180
    var scorrK: Float = 0.1
    var relaxFactor: Float = 0.05
    var splatR: Float = 2.8        // voxels
    var wall: Float = 0.97
    var testPattern: Float = 0
    private var homeOverride: Float?

    private let device: MTLDevice
    private let pipes: [String: MTLComputePipelineState]
    private var pos, vel, posS, velS: MTLBuffer
    private let velT, pred, delta, lambda, mag, force, cnt, slots, vol, offs, blockSums, rank, cid: MTLBuffer
    let texture: MTLTexture
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
        var poly6K: Float, spikyK: Float, scorrW: Float, lamScale: Float
    }

    init?(device: MTLDevice) {
        self.device = device
        do {
            let lib = try device.makeLibrary(source: FerroGPU.source, options: nil)
            var p: [String: MTLComputePipelineState] = [:]
            for name in ["fe_clearGrid", "fe_insert", "fe_field", "fe_dipole", "fe_predict", "fe_lambda", "fe_delta", "fe_apply",
                         "fe_vel", "fe_final", "fe_clearVol", "fe_splat", "fe_toTex",
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
        pos = b(N * 16); vel = b(N * 16); posS = b(N * 16); velS = b(N * 16)
        velT = b(N * 16); pred = b(N * 16); delta = b(N * 16); rank = b(N * 4); cid = b(N * 4)
        lambda = b(N * 4); mag = b(N * 16); force = b(N * 16)
        let h = 2 * 0.015 as Float
        let g = Int((2 / h).rounded(.up))
        cnt = b(g * g * g * 4); slots = b(g * g * g * Self.gridCap * 4); offs = b(g * g * g * 4); blockSums = b(4096 * 4)
        let V = Self.volN
        vol = device.makeBuffer(length: V * V * V * 4, options: .storageModePrivate)!
        let td = MTLTextureDescriptor()
        td.textureType = .type3D; td.pixelFormat = .r16Float
        td.width = V; td.height = V; td.depth = V
        td.usage = [.shaderRead, .shaderWrite]; td.storageMode = .private
        texture = device.makeTexture(descriptor: td)!
        applyOverrides()
        precompute()
    }

    private func applyOverrides() {
        guard let s = ProcessInfo.processInfo.environment["AUDIOWATCH_FERRO"], let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double] else { return }
        func f(_ k: String, _ v: inout Float) { if let x = o[k] { v = Float(x) } }
        f("gravity", &gravity); f("drag", &drag); f("visc", &visc); f("cohesion", &cohesion); f("kelvin", &kelvin)
        f("dipole", &dipole); f("xi", &xi); f("coilR", &coilR); f("coilW", &coilW)
        f("maxAccel", &maxAccel); f("maxVel", &maxVel); f("test", &testPattern); f("tension", &tension)
        if let x = o["home"] { homeOverride = Float(x); home = Float(x) }
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
            n = target
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
        var P = params(dt: substepDt, coils: k)
        let cells = G * G * G
        func run(_ name: String, _ count: Int, _ bufs: [MTLBuffer]) {
            let p = pipes[name]!
            e.setComputePipelineState(p)
            for (i, b) in bufs.enumerated() { e.setBuffer(b, offset: 0, index: i) }
            e.setBytes(&P, length: MemoryLayout<Params>.stride, index: bufs.count)
            e.setBytes(&coils, length: 16 * 16, index: bufs.count + 1)
            let w = min(256, p.maxTotalThreadsPerThreadgroup)
            e.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        }
        func grid(_ x: MTLBuffer) {
            run("fe_clearGrid", cells, [cnt])
            run("fe_insert", n, [x, cnt, slots, rank, cid])
        }
        if steps > 0 {
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
            run("fe_reorder", n, [pos, vel, posS, velS, offs, cid, rank])
            swap(&pos, &posS); swap(&vel, &velS)
            grid(pos)
            for _ in 0..<steps {
                run("fe_field", n, [pos, mag, force])
                run("fe_dipole", n, [pos, mag, force, cnt, slots])
                run("fe_predict", n, [pos, vel, force, pred])
                grid(pred)
                for _ in 0..<iterations {
                    run("fe_lambda", n, [pred, lambda, cnt, slots])
                    run("fe_delta", n, [pred, lambda, delta, cnt, slots])
                    run("fe_apply", n, [pred, delta])
                }
                run("fe_vel", n, [pos, pred, velT])
                run("fe_final", n, [pos, pred, velT, vel, cnt, slots])
            }
        }
        // the density volume
        let V = Self.volN
        run("fe_clearVol", V * V * V, [vol])
        run("fe_splat", n, [pos, vol])
        e.setComputePipelineState(pipes["fe_toTex"]!)
        e.setBuffer(vol, offset: 0, index: 0)
        e.setBytes(&P, length: MemoryLayout<Params>.stride, index: 1)
        e.setTexture(texture, index: 0)
        e.dispatchThreads(MTLSize(width: V, height: V, depth: V), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
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
            var mean = SIMD3<Float>.zero, vmax: Float = 0, rmax: Float = 0, nan = 0
            for i in 0..<n {
                let p = SIMD3(Pp[i].x, Pp[i].y, Pp[i].z)
                if p.x.isNaN { nan += 1; continue }
                mean += p; vmax = max(vmax, simd_length(SIMD3(Vp[i].x, Vp[i].y, Vp[i].z)))
                rmax = max(rmax, simd_length(p))
            }
            mean /= Float(max(1, n - nan))
            var sd: Float = 0
            for i in 0..<n where !Pp[i].x.isNaN { sd += simd_length_squared(SIMD3(Pp[i].x, Pp[i].y, Pp[i].z) - mean) }
            print(String(format: "FERRO f=%d n=%d steps=%d mean=(%.2f,%.2f,%.2f) spread=%.3f vmax=%.2f rmax=%.2f nan=%d rho0=%.1f relax=%.3g vs=%.2f",
                         frameNo, n, steps, mean.x, mean.y, mean.z, sqrt(sd / Float(max(1, n))), vmax, rmax, nan, rho0, relax, volScale))
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
                           constant FP& P [[buffer(7)]], constant float4* coils [[buffer(8)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        uint j = offs[cid[i]] + rank[i];
        posS[j] = pos[i]; velS[j] = vel[i];
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

    kernel void fe_field(device const float4* pos [[buffer(0)]], device float4* mag [[buffer(1)]], device float4* force [[buffer(2)]],
                         constant FP& P [[buffer(3)]], constant float4* coils [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        float3 p = pos[i].xyz;
        float3 H = coilField(p, P, coils);
        float hm = length(H);
        const float e = 0.01;
        float3 g = float3(length(coilField(p + float3(e, 0, 0), P, coils)) - length(coilField(p - float3(e, 0, 0), P, coils)),
                          length(coilField(p + float3(0, e, 0), P, coils)) - length(coilField(p - float3(0, e, 0), P, coils)),
                          length(coilField(p + float3(0, 0, e), P, coils)) - length(coilField(p - float3(0, 0, e), P, coils))) / (2.0 * e);
        float M = langevin(P.xi * hm) / P.langXi;
        mag[i] = float4(hm > 1e-6 ? H / hm * M : float3(0), M);
        force[i] = float4(P.kelvin * M * g, 0);
    }

    // ---- magnetised neighbours as dipoles: head-to-tail attract, side by side repel
    kernel void fe_dipole(device const float4* pos [[buffer(0)]], device const float4* mag [[buffer(1)]], device float4* force [[buffer(2)]],
                          device const uint* cnt [[buffer(3)]], device const uint* slots [[buffer(4)]],
                          constant FP& P [[buffer(5)]], constant float4* coils [[buffer(6)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        float4 mi4 = mag[i];
        if (mi4.w < 1e-3) return;
        float3 mi = mi4.xyz, pi = pos[i].xyz;
        float h2 = P.h * P.h;
        float3 F = 0;
        FOR_NEIGHBORS(pi,
            if (j == i) continue;
            float3 r = pi - pos[j].xyz;
            float d2 = dot(r, r);
            if (d2 >= h2 || d2 < 1e-12) continue;
            float3 rh = r * rsqrt(d2);
            float3 mj = mag[j].xyz;
            float a = dot(mi, rh), b = dot(mj, rh);
            float3 br = a * mj + b * mi + dot(mi, mj) * rh - 5.0 * a * b * rh;
            float q = d2 / h2;
            float t = (1.0 - q) * (1.0 - q);
            F += br * t / ((q + 0.05) * (q + 0.05));
        )
        force[i].xyz += P.dipole * F;
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
                          device const uint* cnt [[buffer(2)]], device const uint* slots [[buffer(3)]],
                          constant FP& P [[buffer(4)]], constant float4* coils [[buffer(5)]], uint i [[thread_position_in_grid]]) {
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
        float C = rho / P.rho0 - 1.0;
        if (C < 0.0) C *= P.tension;     // the surface pulls inwards (surface tension), within the solve
        lambda[i] = -C / (dot(gi, gi) + g2 + P.relax);
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

    kernel void fe_vel(device const float4* pos [[buffer(0)]], device const float4* pred [[buffer(1)]], device float4* velT [[buffer(2)]],
                       constant FP& P [[buffer(3)]], constant float4* coils [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        velT[i] = float4((pred[i].xyz - pos[i].xyz) / P.dt, 0);
    }

    // ---- viscosity (XSPH) + surface tension (Akinci cohesion), then commit the positions
    kernel void fe_final(device float4* pos [[buffer(0)]], device const float4* pred [[buffer(1)]], device const float4* velT [[buffer(2)]],
                         device float4* vel [[buffer(3)]], device const uint* cnt [[buffer(4)]], device const uint* slots [[buffer(5)]],
                         constant FP& P [[buffer(6)]], constant float4* coils [[buffer(7)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        float3 pi = pred[i].xyz, vi = velT[i].xyz;
        float h = P.h, h2 = h * h, h6 = h2 * h2 * h2;
        float3 dv = 0, coh = 0;
        FOR_NEIGHBORS(pi,
            if (j == i) continue;
            float3 r = pi - pred[j].xyz;
            float d2 = dot(r, r);
            if (d2 >= h2 || d2 < 1e-12) continue;
            float d = sqrt(d2);
            float dd = h2 - d2;
            dv += (velT[j].xyz - vi) * (P.poly6K * dd * dd * dd / P.rho0);
            float c = (h - d) * (h - d) * (h - d) * d2 * d * 64.0 / h6;
            float C = 2.0 * d > h ? c : 2.0 * c - 1.0;
            coh -= C * (r / d);
        )
        float3 v = vi + P.visc * dv + P.dt * P.cohesion * coh;
        vel[i] = float4(v, 0);
        pos[i] = pred[i];
    }

    // ---- density volume for the raymarcher
    kernel void fe_clearVol(device atomic_int* vol [[buffer(0)]], constant FP& P [[buffer(1)]], constant float4* coils [[buffer(2)]],
                            uint id [[thread_position_in_grid]]) {
        if (id < P.V * P.V * P.V) atomic_store_explicit(&vol[id], 0, memory_order_relaxed);
    }
    kernel void fe_splat(device const float4* pos [[buffer(0)]], device atomic_int* vol [[buffer(1)]],
                         constant FP& P [[buffer(2)]], constant float4* coils [[buffer(3)]], uint i [[thread_position_in_grid]]) {
        if (i >= P.n) return;
        int V = int(P.V);
        float3 f = (pos[i].xyz + 1.0) * 0.5 * float(V) - 0.5;
        float R = P.splatR, R2 = R * R;
        int3 lo = max(int3(ceil(f - R)), int3(0)), hi = min(int3(floor(f + R)), int3(V - 1));
        for (int z = lo.z; z <= hi.z; z++) for (int y = lo.y; y <= hi.y; y++) for (int x = lo.x; x <= hi.x; x++) {
            float3 d = float3(x, y, z) - f;
            float q = dot(d, d) / R2;
            if (q >= 1.0) continue;
            float w = (1.0 - q) * (1.0 - q) * (1.0 - q);
            atomic_fetch_add_explicit(&vol[(z * V + y) * V + x], int(w * 1024.0), memory_order_relaxed);
        }
    }
    kernel void fe_toTex(device const int* vol [[buffer(0)]], constant FP& P [[buffer(1)]],
                         texture3d<half, access::write> tex [[texture(0)]], uint3 g [[thread_position_in_grid]]) {
        int V = int(P.V);
        if (any(g >= uint3(V))) return;
        float v = float(vol[(int(g.z) * V + int(g.y)) * V + int(g.x)]) / 1024.0 / P.volScale;
        tex.write(half4(half(min(v, 4.0))), g);
    }
    """
}
