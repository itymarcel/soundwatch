import Foundation
import Metal
import simd

/// Matches GIView in `landGICoreSource`.
struct GIViewU {
    /// Camera in GI space (metres from the anchor), w = intensity (0 = GI off).
    var cam = SIMD4<Float>()
    /// Anchor in 16 m units (the City's camera lot; 0 for the Forest), w = frame number (≥ 1).
    var anchor = SIMD4<Int32>()
    /// Fallback environment (no probe there yet): sky above, horizon, ground below. zenith.w = the world's period in z
    /// (Forest 8192 m, 0 = none); horizon.w = how the scene scales E/π into its own ambient term; ground.w unused.
    var zenith = SIMD4<Float>()
    var horizon = SIMD4<Float>()
    var ground = SIMD4<Float>()
    /// x = history decay per frame, y = point lights, z = point light strength, w = probe max age (frames).
    var misc = SIMD4<Float>()
}

/// Global illumination for the Landscape scenes: **split radiance cascades** (after Jack Tollenaar's write-up
/// "Split radiance cascades", a 3D, world-space, sparse take on Alexander Sannikov's radiance cascades).
///
/// - **Probes** live in world space, only where the camera sees surfaces: a hash table per cascade (bucketed, 8 slots)
///   maps a cell (+ its level of detail) to a probe; probes persist while they're seen and are freed after
///   `maxAge` frames unseen (free list). Level of detail = a clipmap: level L has cells of 0.25·2^L m and covers
///   ±28 cells around the camera, so probes are about the same size on screen everywhere.
/// - **Cascades** 0…3: cell × 2 and directions × 4 per cascade (octahedral 4², 8², 16², 32² bins), the ray interval
///   × 4 (cascade 0 = up to 1.6 cells, as in the article: √(2·4²/(4π))).
/// - **Rays:** every frame each scene traces one ray from a jittered pixel of each 4 × 4 block (cosine around its
///   normal, against its own world: the Forest's height field + canopy volume, the City's lot grid), and *splits*
///   it by distance: the interval of each cascade gets what the ray met inside it (radiance relative to entering it,
///   its transmittance and the weight it entered with), deposited (fixed-point atomics) into the bin of its
///   direction in the probe of the pixel's cell at that cascade. Rays that end early say nothing about later
///   intervals; that's how a probe knows its near field from its far field without tracing them separately.
/// - **History:** the deposits decay by `misc.x` per frame instead of being cleared (temporal accumulation).
/// - **Merge** top-down: bin = own radiance + own transmittance × the 4 matching finer bins of the parent cascade,
///   trilinear over the 8 parent probes (missing ones skipped); the top cascade continues into the environment.
/// - **Bake:** cascade 0's merged bins → L1 spherical harmonics (irradiance, per colour) into a 64 × 32 × 64 clipmap
///   per level (4 rgba16Float 3D textures, levels stacked in z, toroidal addressing), plus point lights (fireflies).
///   The scenes' shaders sample it next frame instead of their flat ambient term. Ray hits read it too (light keeps
///   bouncing over the frames).
final class LandGI {
    static let caps = [32768, 8192, 2048, 512]
    static let sides = [4, 8, 16, 32]
    static let probeTotal = 43520, slotTotal = 87040, binsPerCascade = 524288
    static let levels = 9, nx = 64, ny = 32
    /// Rays: one per `rayStep` × `rayStep` pixels (a probe still gets ~100+ rays a frame).
    static let rayStep = 6

    private let device: MTLDevice
    let keys, slotProbe, probes, tops, stack, acc, accW, merged: MTLBuffer
    /// The irradiance clipmap: (L0 rgb, weight), L1 of red, green, blue (all × weight); point lights' irradiance (rgb).
    let tex: [MTLTexture]
    private let beginPipe, maintainPipe, cleanupPipe, argsPipe, mergePipe, mergeTopPipe, clearPipe, bakePipe: MTLComputePipelineState
    private let unbakePipe, bakeResetPipe: MTLComputePipelineState
    /// The texels the last bake wrote (count, then packed coordinates), cleared before the next bake.
    let baked: MTLBuffer
    private var needsFullClear = true
    /// Live probes per cascade (counts, list at each cascade's probe offset) and the indirect dispatch sizes
    /// (merge per cascade, then the bake).
    let activeCount, activeList, args: MTLBuffer
    private(set) var frame: Int32 = 0

    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil

    /// `library` = the scene's library (its source includes `landGICoreSource`).
    init?(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        func k(_ n: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: n) else { throw NSError(domain: "LandGI", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(n)"]) }
            return try device.makeComputePipelineState(function: f)
        }
        do {
            beginPipe = try k("giBegin"); maintainPipe = try k("giMaintain"); cleanupPipe = try k("giCleanup"); argsPipe = try k("giArgs")
            unbakePipe = try k("giUnbake"); bakeResetPipe = try k("giBakeReset")
            mergePipe = try k("giMerge"); mergeTopPipe = try k("giMergeTop"); clearPipe = try k("giClear"); bakePipe = try k("giBake")
        } catch {
            NSLog("soundwatch: GI pipeline error \(error)")
            return nil
        }
        let bins = Self.binsPerCascade * 4
        func buf(_ n: Int) -> MTLBuffer? { device.makeBuffer(length: n, options: .storageModeShared) }
        guard let keys = buf(Self.slotTotal * 4), let slotProbe = buf(Self.slotTotal * 4), let probes = buf(Self.probeTotal * 32),
              let tops = buf(16), let stack = buf(Self.probeTotal * 4),
              let acc = device.makeBuffer(length: bins * 16, options: .storageModePrivate),
              let accW = device.makeBuffer(length: bins * 4, options: .storageModePrivate),
              let merged = device.makeBuffer(length: bins * 8, options: .storageModePrivate),
              let activeCount = device.makeBuffer(length: 16, options: .storageModePrivate),
              let activeList = device.makeBuffer(length: Self.probeTotal * 4, options: .storageModePrivate),
              let args = device.makeBuffer(length: 5 * 12, options: .storageModePrivate),
              let baked = device.makeBuffer(length: (Self.caps[0] + 1) * 4, options: .storageModePrivate) else { return nil }
        self.baked = baked
        self.activeCount = activeCount; self.activeList = activeList; self.args = args
        self.keys = keys; self.slotProbe = slotProbe; self.probes = probes; self.tops = tops; self.stack = stack
        self.acc = acc; self.accW = accW; self.merged = merged
        memset(keys.contents(), 0, keys.length)
        memset(slotProbe.contents(), 0xFF, slotProbe.length)
        memset(probes.contents(), 0, probes.length)
        // every cascade's free list holds all its probes
        let tp = tops.contents().bindMemory(to: Int32.self, capacity: 4)
        let sp = stack.contents().bindMemory(to: UInt32.self, capacity: Self.probeTotal)
        var off = 0
        for c in 0..<4 {
            tp[c] = Int32(Self.caps[c])
            for i in 0..<Self.caps[c] { sp[off + i] = UInt32(Self.caps[c] - 1 - i) }
            off += Self.caps[c]
        }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = Self.nx; d.height = Self.ny; d.depth = Self.nx * Self.levels
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        var t: [MTLTexture] = []
        for _ in 0..<5 { guard let x = device.makeTexture(descriptor: d) else { return nil }; t.append(x) }
        tex = t
        // the private buffers start at zero
        guard let q = device.makeCommandQueue(), let cb = q.makeCommandBuffer(), let bl = cb.makeBlitCommandEncoder() else { return nil }
        bl.fill(buffer: acc, range: 0..<acc.length, value: 0)
        bl.fill(buffer: accW, range: 0..<accW.length, value: 0)
        bl.fill(buffer: merged, range: 0..<merged.length, value: 0)
        bl.fill(buffer: activeCount, range: 0..<16, value: 0)
        bl.fill(buffer: args, range: 0..<args.length, value: 0)
        bl.fill(buffer: baked, range: 0..<baked.length, value: 0)
        bl.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// A 1×1×1 stand-in for the clipmap textures while GI is off (the shaders' GI branch never runs then).
    static func dummyTexture(device: MTLDevice) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D; d.pixelFormat = .rgba16Float
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = .shaderRead; d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    /// Next frame: the frame number and the history / age settings go into `v`.
    func nextFrame(_ v: inout GIViewU) {
        frame += 1
        v.anchor.w = frame
        v.misc.x = 0.82
        v.misc.w = 30
    }

    /// The GI buffers at indices 1…8 (keys, slot → probe, probes, free-list tops, free list, deposits, weights, merged).
    func bind(_ e: MTLComputeCommandEncoder) {
        for (i, b) in [keys, slotProbe, probes, tops, stack, acc, accW, merged].enumerated() { e.setBuffer(b, offset: 0, index: i + 1) }
    }

    /// Before the rays: free probes not seen for a while, clear table slots whose insert failed, list the live probes
    /// (merge and bake only run over those: ~1/5 of the capacity) and size the indirect dispatches.
    func encodeMaintain(_ e: MTLComputeCommandEncoder, view: GIViewU) {
        var v = view
        e.setBytes(&v, length: MemoryLayout<GIViewU>.stride, index: 0)
        bind(e)
        e.setBuffer(activeCount, offset: 0, index: 11)
        e.setBuffer(activeList, offset: 0, index: 12)
        e.setBuffer(args, offset: 0, index: 13)
        func run(_ p: MTLComputePipelineState, _ n: Int) {
            e.setComputePipelineState(p)
            e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(n, 256), height: 1, depth: 1))
        }
        run(beginPipe, 1)
        run(maintainPipe, Self.probeTotal)
        run(cleanupPipe, Self.slotTotal)
        run(argsPipe, 1)
        if Self.trace && frame % 60 == 0 {
            let tp = tops.contents().bindMemory(to: Int32.self, capacity: 4)
            print("LANDGI frame=\(frame) probes=\((0..<4).map { Self.caps[$0] - Int(tp[$0]) }) of \(Self.caps)")
        }
    }

    /// After the rays: merge the cascades top-down, then bake cascade 0 (+ point lights) into the clipmap.
    /// `lights` = 2 float4 per light (GI-space position + brightness, colour).
    func encodeResolve(_ e: MTLComputeCommandEncoder, view: GIViewU, lights: MTLBuffer?, lightCount: Int) {
        var v = view
        v.misc.y = Float(lights == nil ? 0 : lightCount)
        e.setBytes(&v, length: MemoryLayout<GIViewU>.stride, index: 0)
        bind(e)
        e.setBuffer(activeCount, offset: 0, index: 11)
        e.setBuffer(activeList, offset: 0, index: 12)
        let tg = MTLSize(width: 256, height: 1, depth: 1)
        e.setComputePipelineState(mergeTopPipe)
        e.dispatchThreadgroups(indirectBuffer: args, indirectBufferOffset: 3 * 12, threadsPerThreadgroup: tg)
        e.setComputePipelineState(mergePipe)
        for c in stride(from: 2, through: 0, by: -1) {
            var cc = UInt32(c)
            e.setBytes(&cc, length: 4, index: 9)
            e.dispatchThreadgroups(indirectBuffer: args, indirectBufferOffset: c * 12, threadsPerThreadgroup: tg)
        }
        for (i, t) in tex.enumerated() { e.setTexture(t, index: i) }
        // last frame's texels → 0 (only those: clearing the whole clipmap cost ~2.4 ms); the whole of it once at the start
        e.setBuffer(baked, offset: 0, index: 14)
        if needsFullClear {
            e.setComputePipelineState(clearPipe)
            e.dispatchThreads(MTLSize(width: Self.nx, height: Self.ny, depth: Self.nx * Self.levels),
                              threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
            needsFullClear = false
        } else {
            e.setComputePipelineState(unbakePipe)
            e.dispatchThreads(MTLSize(width: Self.caps[0], height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        e.setComputePipelineState(bakeResetPipe)
        e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        e.setComputePipelineState(bakePipe)
        if let lights { e.setBuffer(lights, offset: 0, index: 10) } else { e.setBuffer(merged, offset: 0, index: 10) }
        e.dispatchThreadgroups(indirectBuffer: args, indirectBufferOffset: 4 * 12, threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }
}

/// MSL shared by the Landscape scenes' libraries (pasted into each after its `#include`s): the GI's data layout,
/// lookups, the deposit of a traced ray, the maintenance / merge / bake kernels, and sampling the result.
let landGICoreSource = #"""
// ---------------------------------------------------------------- global illumination (split radiance cascades)

#define GI_NX 64
#define GI_NY 32
#define GI_LEVELS 9
constant uint GI_CAP[4]  = { 32768u, 8192u, 2048u, 512u };
constant uint GI_SIDE[4] = { 4u, 8u, 16u, 32u };
constant uint GI_POFF[4] = { 0u, 32768u, 40960u, 43008u };    // probe offsets (43520 probes)
constant uint GI_TOFF[4] = { 0u, 65536u, 81920u, 86016u };    // table slot offsets (2 slots per probe, 87040)
constant uint GI_BINS = 524288u;                               // bins per cascade (CAP × SIDE²)
constant uint GI_INVALID = 0xffffffffu;
constant float GI_K0 = 1.5958;     // cascade 0's interval in cells (× 4 per cascade)
constant float GI_FIX = 4096.0;    // fixed point of the deposits
constant float GI_REACH = 28.0;    // a level is used up to this many cells from the camera (horizontally; half that vertically)

struct GIView {
    float4 cam;        // camera in GI space, w = intensity (0 = off)
    int4 anchor;       // anchor (16 m units), w = frame
    float4 zenith;     // w = z period (m, 0 = none)
    float4 horizon;    // w = E/π → the scene's ambient scale
    float4 ground;
    float4 misc;       // decay, point lights, point light strength, max age
};
struct GIProbe { int4 cell; uint seen; uint slot; uint pad0; uint pad1; };   // cell xyz + level; frame last seen (0 = free)

struct GIBufs {
    device atomic_uint* keys;
    device atomic_uint* sp;
    device GIProbe* probes;
    device atomic_int* tops;
    device uint* stack;
    device atomic_uint* acc;
    device atomic_uint* accW;
};
#define GI_BUF_PARAMS device atomic_uint* giKeys [[buffer(1)]], device atomic_uint* giSp [[buffer(2)]], \
    device GIProbe* giProbes [[buffer(3)]], device atomic_int* giTops [[buffer(4)]], device uint* giStack [[buffer(5)]], \
    device atomic_uint* giAcc [[buffer(6)]], device atomic_uint* giAccW [[buffer(7)]], device half4* giMerged [[buffer(8)]]
#define GI_BUFS GIBufs{ giKeys, giSp, giProbes, giTops, giStack, giAcc, giAccW }

/// Cell of a GI-space point at cell size 2^e m (A = anchor in 16 m units: exact for any distance from the origin).
static int3 giCellOf(float3 p, int3 A, int e) {
    float s = exp2(-float(e));
    if (e <= 4) return A * (1 << (4 - e)) + int3(floor(p * s));
    int sh = e - 4;
    int3 hi = A >> sh;
    int3 lo = A - (hi << sh);
    return hi + int3(floor((float3(lo) * 16.0 + p) * s));
}
/// The same as a continuous coordinate in cells, wrapped into the clipmap's 64 × 32 × 64 torus.
static float3 giCoordOf(float3 p, int3 A, int e) {
    float s = exp2(-float(e));
    int3 base; float3 f;
    if (e <= 4) { base = A * (1 << (4 - e)); f = p * s; }
    else { int sh = e - 4; int3 hi = A >> sh; int3 lo = A - (hi << sh); base = hi; f = (float3(lo) * 16.0 + p) * s; }
    float3 fi = floor(f);
    int3 m = int3(GI_NX, GI_NY, GI_NX);
    int3 bi = base + int3(fi);
    bi = ((bi % m) + m) % m;
    return float3(bi) + (f - fi);
}
/// Level of detail (fractional) of a point at `rel` from the camera: level L holds it while this is ≤ L.
static float giLodF(float3 rel) {
    float m = max(max(abs(rel.x), abs(rel.z)), 2.0 * abs(rel.y));
    return log2(max(m, 1e-4) / (GI_REACH * 0.25));
}

static float2 giOct(float3 d) {
    d /= (abs(d.x) + abs(d.y) + abs(d.z));
    float2 o = d.y >= 0.0 ? d.xz : (1.0 - abs(d.zx)) * select(float2(-1.0), float2(1.0), d.xz >= 0.0);
    return o * 0.5 + 0.5;
}
/// Direction of an octahedral coordinate; w = its texel's solid angle (relative, ∝ 1 / |q|³).
static float3 giOctDir(float2 u, thread float& w) {
    float2 o = u * 2.0 - 1.0;
    float3 q = float3(o.x, 1.0 - abs(o.x) - abs(o.y), o.y);
    if (q.y < 0.0) q.xz = (1.0 - abs(q.zx)) * select(float2(-1.0), float2(1.0), q.xz >= 0.0);
    float l = length(q);
    w = 1.0 / (l * l * l);
    return q / l;
}

static uint giKey(int3 c, int L) {
    uint h = uint(c.x) * 0x8da6b343u ^ uint(c.y) * 0xd8163841u ^ uint(c.z) * 0xcb1ab31fu ^ uint(L + 1) * 0x9e3779b9u;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    return max(h, 1u);
}
static uint giBucket(uint c, uint key) {
    uint nb = GI_CAP[c] / 4u;           // 2 slots per probe, 8 per bucket
    uint h = (key ^ (key >> 13)) * 0x2c1b3c6du;
    return GI_TOFF[c] + ((h >> 9) & (nb - 1u)) * 8u;
}

/// The probe of `cell` in cascade c (GI_INVALID if there is none / no room). `insert` makes it if needed.
static uint giFind(GIBufs B, uint c, int3 cell, int L, bool insert, uint frame) {
    uint key = giKey(cell, L);
    uint base = giBucket(c, key);
    // plain loads for the look-up (atomic loads were measurably slower; a slot being written meanwhile just reads as
    // empty / not yet set up, which the insert below and the callers handle)
    const device uint* K = reinterpret_cast<const device uint*>(B.keys);
    const device uint* SP = reinterpret_cast<const device uint*>(B.sp);
    for (uint i = 0; i < 8u; i++) if (K[base + i] == key) return SP[base + i];
    if (!insert) return GI_INVALID;
    for (uint i = 0; i < 8u; i++) {
        uint s = base + i;
        for (int tries = 0; tries < 4; tries++) {          // (the weak exchange may fail spuriously)
            uint ex = 0u;
            if (atomic_compare_exchange_weak_explicit(&B.keys[s], &ex, key, memory_order_relaxed, memory_order_relaxed)) {
                int t = atomic_fetch_sub_explicit(&B.tops[c], 1, memory_order_relaxed);
                if (t <= 0) { atomic_fetch_add_explicit(&B.tops[c], 1, memory_order_relaxed); return GI_INVALID; }   // full (giCleanup frees the slot)
                uint p = B.stack[GI_POFF[c] + uint(t - 1)];
                GIProbe pr; pr.cell = int4(cell, L); pr.seen = frame; pr.slot = s; pr.pad0 = 0u; pr.pad1 = 0u;
                B.probes[GI_POFF[c] + p] = pr;
                atomic_store_explicit(&B.sp[s], p, memory_order_relaxed);
                return p;
            }
            if (ex == key) return atomic_load_explicit(&B.sp[s], memory_order_relaxed);
            if (ex != 0u) break;
        }
    }
    return GI_INVALID;
}

/// The split: a ray from the surface point p (GI space, level L) in direction dir, cut into the cascades' intervals.
/// iv[c] = (radiance met inside interval c relative to entering it, its transmittance), P[c] = transmittance before
/// it (the weight it enters with); n = intervals the ray reached (one that ended early says nothing about the later
/// ones). Each goes to the bin of dir in the probe of p's cell at cascade c.
/// Done for a whole SIMD group at once (every lane must call it; `valid` = this lane has a ray). Neighbouring
/// pixels' rays land in the same probes and mostly the same bins: deposited one by one, hundreds of atomic adds hit
/// the same addresses every frame and serialise (the trace cost 3× more). Here the lanes aiming at the same bin are
/// summed first (simd_sum), and one lane per distinct bin deposits.
static void giSplatSimd(GIBufs B, bool valid, float3 p, int3 A, int L, float3 dir, thread float4* iv, thread float* P, int n,
                        uint frame, uint lane) {
    int3 cell0 = valid ? giCellOf(p, A, L - 2) : int3(0);
    for (int c = 0; c < 4; c++) {
        bool act = valid && c < n && P[c] >= 0.01;
        if (!simd_any(act)) break;
        // the probe: looked up once per distinct cell in the SIMD group (neighbouring rays share a few probes)
        uint ck = act ? giKey(cell0 >> c, L) : 0u;
        uint pi = GI_INVALID;
        bool need = act;
        while (simd_any(need)) {
            uint lead = simd_max(need ? ck : 0u);
            bool m = need && ck == lead;
            uint first = simd_min(m ? lane : 255u);
            uint r = GI_INVALID;
            if (lane == first) r = giFind(B, uint(c), cell0 >> c, L, true, frame);
            r = simd_broadcast(r, ushort(first));
            if (m) pi = r;
            need = need && !m;
        }
        act = act && pi != GI_INVALID;
        uint S = GI_SIDE[c];
        uint key = GI_INVALID;
        float4 val = float4(0.0);
        float w = 0.0;
        if (act) {
            uint2 b = min(uint2(giOct(dir) * float(S)), uint2(S - 1u));
            key = pi * S * S + b.y * S + b.x;
            w = P[c];
            val = float4(clamp(iv[c].rgb, float3(0.0), float3(16.0)), clamp(iv[c].a, 0.0, 1.0)) * w;
        }
        bool pending = act;
        while (simd_any(pending)) {
            uint lead = simd_min(pending ? key : GI_INVALID);
            bool m = pending && key == lead;
            float4 sv = simd_sum(m ? val : float4(0.0));
            float sw = simd_sum(m ? w : 0.0);
            uint first = simd_min(m ? lane : 255u);
            if (lane == first) {
                uint bin = uint(c) * GI_BINS + lead;
                atomic_fetch_add_explicit(&B.acc[bin * 4u + 0u], uint(sv.r * GI_FIX + 0.5), memory_order_relaxed);
                atomic_fetch_add_explicit(&B.acc[bin * 4u + 1u], uint(sv.g * GI_FIX + 0.5), memory_order_relaxed);
                atomic_fetch_add_explicit(&B.acc[bin * 4u + 2u], uint(sv.b * GI_FIX + 0.5), memory_order_relaxed);
                atomic_fetch_add_explicit(&B.acc[bin * 4u + 3u], uint(sv.a * GI_FIX + 0.5), memory_order_relaxed);
                atomic_fetch_add_explicit(&B.accW[bin], uint(sw * GI_FIX + 0.5), memory_order_relaxed);
                B.probes[GI_POFF[c] + lead / (S * S)].seen = frame;
            }
            pending = pending && !m;
        }
    }
}

/// Interval of a hit at distance t from a level-L surface (0…3).
static int giCascadeOf(float t, int L) {
    float v = 0.25 * exp2(float(L));
    return clamp(int(ceil(0.5 * log2(max(t, 1e-4) / (GI_K0 * v)))), 0, 3);
}
/// Interval ends of cascades 0…2 for level L (cascade 3 runs on to infinity).
static float giBound(int c, int L) { return GI_K0 * 0.25 * exp2(float(L)) * exp2(2.0 * float(c)); }

/// Level for a ray's deposit: the point's level, or (near its outer edge, by chance) the next one, so both levels
/// get probes where the shaders blend them.
static int giPickLevel(float3 rel, float rnd) {
    float lam = giLodF(rel);
    if (lam > float(GI_LEVELS - 1)) return -1;
    int L = clamp(int(ceil(lam)), 0, GI_LEVELS - 1);
    float t = L < GI_LEVELS - 1 ? smoothstep(float(L) - 0.4, float(L), lam) : 0.0;
    return rnd < t ? L + 1 : L;
}

static float3 giEnv(float3 d, constant GIView& V) {
    if (d.y >= 0.0) return mix(V.horizon.rgb, V.zenith.rgb, pow(d.y, 0.45));
    return mix(V.horizon.rgb, V.ground.rgb, smoothstep(0.0, 0.3, -d.y));
}

static uint giHash(uint a) { a ^= a >> 16; a *= 0x7feb352du; a ^= a >> 15; a *= 0x846ca68bu; a ^= a >> 16; return a; }
static float giRand(thread uint& s) { s = giHash(s + 0x9e3779b9u); return float(s >> 8) * (1.0 / 16777216.0); }
/// Cosine-weighted direction around n.
static float3 giCosDir(float3 n, float u1, float u2) {
    float r = sqrt(u1), a = 6.2831853 * u2;
    float3 t = normalize(abs(n.y) < 0.9 ? cross(n, float3(0, 1, 0)) : cross(n, float3(1, 0, 0)));
    float3 b = cross(n, t);
    return normalize(t * (r * cos(a)) + b * (r * sin(a)) + n * sqrt(max(0.0, 1.0 - u1)));
}

// ---- maintenance (before the rays)

kernel void giBegin(device atomic_uint* cnt [[buffer(11)]]) {
    for (uint c = 0; c < 4u; c++) atomic_store_explicit(&cnt[c], 0u, memory_order_relaxed);
}

kernel void giMaintain(uint i [[thread_position_in_grid]], constant GIView& V [[buffer(0)]], GI_BUF_PARAMS,
                       device atomic_uint* cnt [[buffer(11)]], device uint* list [[buffer(12)]]) {
    if (i >= 43520u) return;
    GIProbe pr = giProbes[i];
    if (pr.seen == 0u) return;
    uint frame = uint(V.anchor.w);
    uint c = i < 32768u ? 0u : (i < 40960u ? 1u : (i < 43008u ? 2u : 3u));
    if (frame - pr.seen <= uint(V.misc.w)) {
        // alive: on the list for the merge and the bake
        uint k = atomic_fetch_add_explicit(&cnt[c], 1u, memory_order_relaxed);
        list[GI_POFF[c] + k] = i - GI_POFF[c];
        return;
    }
    atomic_store_explicit(&giSp[pr.slot], GI_INVALID, memory_order_relaxed);
    atomic_store_explicit(&giKeys[pr.slot], 0u, memory_order_relaxed);
    giProbes[i].seen = 0u;
    uint local = i - GI_POFF[c], S2 = GI_SIDE[c] * GI_SIDE[c];
    for (uint b = 0; b < S2; b++) {
        uint k = c * GI_BINS + local * S2 + b;
        for (uint j = 0; j < 4u; j++) atomic_store_explicit(&giAcc[k * 4u + j], 0u, memory_order_relaxed);
        atomic_store_explicit(&giAccW[k], 0u, memory_order_relaxed);
    }
    int t = atomic_fetch_add_explicit(&giTops[c], 1, memory_order_relaxed);
    giStack[GI_POFF[c] + uint(t)] = local;
}

/// Indirect dispatch sizes: merge of cascade c (256 threads per group, one per bin), then the bake (64 per group).
kernel void giArgs(const device uint* cnt [[buffer(11)]], device uint* args [[buffer(13)]]) {
    for (uint c = 0; c < 4u; c++) {
        uint n = cnt[c] * GI_SIDE[c] * GI_SIDE[c];
        args[c * 3u] = max(1u, (n + 255u) / 256u); args[c * 3u + 1u] = 1u; args[c * 3u + 2u] = 1u;
    }
    args[12] = max(1u, (cnt[0] + 63u) / 64u); args[13] = 1u; args[14] = 1u;
}

/// Table slots claimed by an insert that found no free probe: free them again.
kernel void giCleanup(uint i [[thread_position_in_grid]], GI_BUF_PARAMS) {
    if (i >= 87040u) return;
    if (atomic_load_explicit(&giKeys[i], memory_order_relaxed) != 0u && atomic_load_explicit(&giSp[i], memory_order_relaxed) == GI_INVALID)
        atomic_store_explicit(&giKeys[i], 0u, memory_order_relaxed);
}

// ---- merge (top-down) and bake

static float3 giBinDir(uint bin, uint S) {
    float w;
    return giOctDir((float2(bin % S, bin / S) + 0.5) / float(S), w);
}
/// A bin's own average (radiance, transmittance, weight); then its history fades by `decay` for the next frame's rays
/// (temporal accumulation: the deposits are never cleared).
static void giOwn(GIBufs B, uint k, float decay, thread float3& own, thread float& T, thread float& w) {
    uint wi = atomic_load_explicit(&B.accW[k], memory_order_relaxed);
    w = float(wi);
    own = float3(0.0); T = 1.0;
    if (wi == 0u) return;
    uint4 a = uint4(atomic_load_explicit(&B.acc[k * 4u], memory_order_relaxed), atomic_load_explicit(&B.acc[k * 4u + 1u], memory_order_relaxed),
                    atomic_load_explicit(&B.acc[k * 4u + 2u], memory_order_relaxed), atomic_load_explicit(&B.acc[k * 4u + 3u], memory_order_relaxed));
    own = float3(a.xyz) / w;
    T = float(a.w) / w;
    for (uint j = 0; j < 4u; j++) atomic_store_explicit(&B.acc[k * 4u + j], uint(float(a[j]) * decay), memory_order_relaxed);
    atomic_store_explicit(&B.accW[k], uint(w * decay), memory_order_relaxed);
}

kernel void giMergeTop(uint gid [[thread_position_in_grid]], constant GIView& V [[buffer(0)]], GI_BUF_PARAMS,
                       const device uint* cnt [[buffer(11)]], const device uint* list [[buffer(12)]]) {
    uint S = GI_SIDE[3], S2 = S * S;
    if (gid / S2 >= cnt[3]) return;
    uint local = list[GI_POFF[3] + gid / S2];
    if (giProbes[GI_POFF[3] + local].seen == 0u) return;
    uint i = local * S2 + gid % S2;
    uint k = 3u * GI_BINS + i;
    float3 own; float T, w;
    giOwn(GI_BUFS, k, V.misc.x, own, T, w);
    giMerged[k] = half4(half3(own + T * giEnv(giBinDir(i % S2, S), V)), 1.0h);
}

/// Cascade c (< 3): every bin = own + transmittance × the parent cascade's 4 bins of the same direction,
/// trilinear over the 8 parent probes around this one (missing ones skipped, weights renormalised).
kernel void giMerge(uint gid [[thread_position_in_grid]], uint lid [[thread_position_in_threadgroup]],
                    constant GIView& V [[buffer(0)]], GI_BUF_PARAMS, constant uint& c [[buffer(9)]],
                    const device uint* cnt [[buffer(11)]], const device uint* list [[buffer(12)]]) {
    threadgroup uint par[16][8];
    threadgroup float parW[16][8];
    uint S = GI_SIDE[c], S2 = S * S;
    uint li = gid / S2, bin = gid % S2, slot = lid / S2;
    bool listed = li < cnt[c];
    uint local = listed ? list[GI_POFF[c] + li] : 0u;
    GIProbe pr = giProbes[GI_POFF[c] + local];
    bool alive = listed && pr.seen != 0u;
    GIBufs B = GI_BUFS;
    if (bin == 0u) {
        for (int k = 0; k < 8; k++) { par[slot][k] = GI_INVALID; parW[slot][k] = 0.0; }
        if (alive) {
            int3 cell = pr.cell.xyz;
            int3 base = (cell - 1) >> 1;
            float3 wb = select(float3(0.75), float3(0.25), (cell & 1) == 0);
            for (int k = 0; k < 8; k++) {
                int3 o = int3(k & 1, (k >> 1) & 1, k >> 2);
                float3 ww = select(wb, 1.0 - wb, o == 1);
                uint pp = giFind(B, c + 1u, base + o, pr.cell.w, false, 0u);
                par[slot][k] = pp;
                parW[slot][k] = pp == GI_INVALID ? 0.0 : ww.x * ww.y * ww.z;
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (!alive) return;
    uint k = c * GI_BINS + local * S2 + bin;
    float3 own; float T, w;
    giOwn(B, k, V.misc.x, own, T, w);
    uint S1 = S * 2u;
    uint2 b2 = uint2(bin % S, bin / S) * 2u;
    float3 sum = float3(0.0); float ws = 0.0;
    for (int j = 0; j < 8; j++) {
        float pw = parW[slot][j];
        if (pw <= 0.0) continue;
        uint pb = (c + 1u) * GI_BINS + par[slot][j] * S1 * S1;
        float3 m = float3(giMerged[pb + b2.y * S1 + b2.x].rgb) + float3(giMerged[pb + b2.y * S1 + b2.x + 1u].rgb)
                 + float3(giMerged[pb + (b2.y + 1u) * S1 + b2.x].rgb) + float3(giMerged[pb + (b2.y + 1u) * S1 + b2.x + 1u].rgb);
        sum += m * (0.25 * pw); ws += pw;
    }
    float3 far = ws > 0.0 ? sum / ws : giEnv(giBinDir(bin, S), V);
    giMerged[k] = half4(half3(min(own + T * far, float3(60000.0))), 1.0h);
}

kernel void giClear(uint3 g [[thread_position_in_grid]], texture3d<float, access::write> g0 [[texture(0)]],
                    texture3d<float, access::write> g1 [[texture(1)]], texture3d<float, access::write> g2 [[texture(2)]],
                    texture3d<float, access::write> g3 [[texture(3)]], texture3d<float, access::write> g4 [[texture(4)]]) {
    g0.write(float4(0.0), g); g1.write(float4(0.0), g); g2.write(float4(0.0), g); g3.write(float4(0.0), g); g4.write(float4(0.0), g);
}

/// Zeroes the texels the last bake wrote (baked[0] = count, then x | y << 8 | z << 16).
kernel void giUnbake(uint i [[thread_position_in_grid]], const device uint* baked [[buffer(14)]],
                     texture3d<float, access::write> g0 [[texture(0)]], texture3d<float, access::write> g1 [[texture(1)]],
                     texture3d<float, access::write> g2 [[texture(2)]], texture3d<float, access::write> g3 [[texture(3)]],
                     texture3d<float, access::write> g4 [[texture(4)]]) {
    if (i >= min(baked[0], GI_CAP[0])) return;
    uint k = baked[1u + i];
    uint3 g = uint3(k & 0xffu, (k >> 8) & 0xffu, k >> 16);
    g0.write(float4(0.0), g); g1.write(float4(0.0), g); g2.write(float4(0.0), g); g3.write(float4(0.0), g); g4.write(float4(0.0), g);
}
kernel void giBakeReset(device uint* baked [[buffer(14)]]) { baked[0] = 0u; }

/// Camera-relative offset of two GI-space positions' difference with the world's z period.
static float3 giWrapRel(float3 d, constant GIView& V) {
    float P = V.zenith.w;
    if (P > 0.0) d.z -= P * floor(d.z / P + 0.5);
    return d;
}

/// Cascade 0 → the irradiance clipmap: L1 spherical harmonics of the merged radiance (+ point lights).
kernel void giBake(uint gi [[thread_position_in_grid]], constant GIView& V [[buffer(0)]], GI_BUF_PARAMS,
                   const device float4* lights [[buffer(10)]],
                   texture3d<float, access::write> g0 [[texture(0)]], texture3d<float, access::write> g1 [[texture(1)]],
                   texture3d<float, access::write> g2 [[texture(2)]], texture3d<float, access::write> g3 [[texture(3)]],
                   texture3d<float, access::write> g4 [[texture(4)]], const device uint* cnt [[buffer(11)]],
                   const device uint* list [[buffer(12)]], device atomic_uint* baked [[buffer(14)]]) {
    if (gi >= cnt[0]) return;
    uint i = list[gi];
    GIProbe pr = giProbes[i];
    if (pr.seen == 0u) return;
    int L = pr.cell.w, e = L - 2;
    int3 A = V.anchor.xyz;
    int3 cc = giCellOf(V.cam.xyz, A, e);
    int3 d = pr.cell.xyz - cc;
    if (V.zenith.w > 0.0) { int P = int(V.zenith.w * exp2(-float(e))); d.z -= P * int(floor(float(d.z) / float(P) + 0.5)); }
    if (d.x < -32 || d.x > 31 || d.z < -32 || d.z > 31 || d.y < -16 || d.y > 15) return;
    float3 a = float3(0.0), bR = float3(0.0), bG = float3(0.0), bB = float3(0.0);
    float ws = 0.0;
    for (uint b = 0; b < 16u; b++) {
        float w;
        float3 dir = giOctDir((float2(b % 4u, b / 4u) + 0.5) / 4.0, w);
        float3 Lr = float3(giMerged[i * 16u + b].rgb);
        a += Lr * w; bR += dir * (Lr.r * w); bG += dir * (Lr.g * w); bB += dir * (Lr.b * w);
        ws += w;
    }
    a /= ws; bR *= 3.0 / ws; bG *= 3.0 / ws; bB *= 3.0 / ws;
    // point lights (fireflies): each a small source, no shadows, softened within about a cell, reaching 5 m (pools of
    // light, not a wash: there are hundreds); their own texture, so the scene can keep their colour
    float3 fl = float3(0.0);
    int nl = int(V.misc.y);
    if (nl > 0) {
        float v = exp2(float(e));
        float3 camF = giCoordOf(V.cam.xyz, A, e);
        float3 rel = (float3(d) + 0.5 - fract(camF)) * v;        // probe centre − camera
        float r0 = max(0.35, 0.7 * v);
        for (int j = 0; j < nl; j++) {
            float4 lp = lights[2 * j];
            if (lp.w <= 0.0) continue;
            float3 dl = giWrapRel(lp.xyz - V.cam.xyz, V) - rel;
            float d2 = dot(dl, dl);
            if (d2 > 25.0) continue;
            float f = 1.0 - d2 / 25.0;
            fl += lights[2 * j + 1].rgb * (lp.w * V.misc.z * f * f / (d2 + r0 * r0));
        }
    }
    int3 m = int3(GI_NX, GI_NY, GI_NX);
    int3 t = ((pr.cell.xyz % m) + m) % m;
    uint3 tc = uint3(t.x, t.y, L * GI_NX + t.z);
    uint slot = atomic_fetch_add_explicit(&baked[0], 1u, memory_order_relaxed);
    if (slot < GI_CAP[0]) atomic_store_explicit(&baked[1u + slot], tc.x | (tc.y << 8) | (tc.z << 16), memory_order_relaxed);
    g0.write(float4(a, 1.0), tc);
    g1.write(float4(bR, 0.0), tc); g2.write(float4(bG, 0.0), tc); g3.write(float4(bB, 0.0), tc);
    g4.write(float4(fl * (1.0 / 6.2831853), 0.0), tc);
}

// ---- sampling (scene shaders)

constexpr sampler giSmp(coord::normalized, filter::linear, address::repeat);

/// One clipmap level at GI-space point p: (E/π × weight, weight), trilinear (weights renormalise over missing probes).
static float4 giSampleLevel(float3 p, int3 A, int L, float3 N, texture3d<float> g0, texture3d<float> g1,
                            texture3d<float> g2, texture3d<float> g3) {
    float3 u = giCoordOf(p, A, L - 2);
    float zc = u.z - 0.5, z0 = floor(zc), fz = zc - z0;
    int i0 = (int(z0) + GI_NX) % GI_NX, i1 = (i0 + 1) % GI_NX;
    float2 uv = float2(u.x / float(GI_NX), u.y / float(GI_NY));
    float D = float(GI_NX * GI_LEVELS);
    float za = (float(L * GI_NX + i0) + 0.5) / D, zb = (float(L * GI_NX + i1) + 0.5) / D;
    float4 s0 = mix(g0.sample(giSmp, float3(uv, za)), g0.sample(giSmp, float3(uv, zb)), fz);
    float4 s1 = mix(g1.sample(giSmp, float3(uv, za)), g1.sample(giSmp, float3(uv, zb)), fz);
    float4 s2 = mix(g2.sample(giSmp, float3(uv, za)), g2.sample(giSmp, float3(uv, zb)), fz);
    float4 s3 = mix(g3.sample(giSmp, float3(uv, za)), g3.sample(giSmp, float3(uv, zb)), fz);
    float3 E = s0.rgb + (2.0 / 3.0) * float3(dot(s1.xyz, N), dot(s2.xyz, N), dot(s3.xyz, N));
    return float4(max(E, float3(0.0)), s0.a);
}
/// Point lights' irradiance at p (no direction), renormalised like giIrradiance.
static float3 giPointLevel(float3 p, int3 A, int L, texture3d<float> g0, texture3d<float> g4, thread float& w) {
    float3 u = giCoordOf(p, A, L - 2);
    float zc = u.z - 0.5, z0 = floor(zc), fz = zc - z0;
    int i0 = (int(z0) + GI_NX) % GI_NX, i1 = (i0 + 1) % GI_NX;
    float2 uv = float2(u.x / float(GI_NX), u.y / float(GI_NY));
    float D = float(GI_NX * GI_LEVELS);
    float za = (float(L * GI_NX + i0) + 0.5) / D, zb = (float(L * GI_NX + i1) + 0.5) / D;
    w = mix(g0.sample(giSmp, float3(uv, za)).a, g0.sample(giSmp, float3(uv, zb)).a, fz);
    return mix(g4.sample(giSmp, float3(uv, za)).rgb, g4.sample(giSmp, float3(uv, zb)).rgb, fz);
}
static float3 giPointLight(float3 p, float3 rel, constant GIView& V, texture3d<float> g0, texture3d<float> g4) {
    float lam = giLodF(rel);
    if (lam > float(GI_LEVELS - 1)) return float3(0.0);
    int L = clamp(int(ceil(lam)), 0, GI_LEVELS - 1);
    float t = L < GI_LEVELS - 1 ? smoothstep(float(L) - 0.4, float(L), lam) : 0.0;
    float w;
    float3 c = giPointLevel(p, V.anchor.xyz, L, g0, g4, w);
    if (t > 0.0) { float w2; float3 c2 = giPointLevel(p, V.anchor.xyz, L + 1, g0, g4, w2); c = mix(c, c2, t); w = mix(w, w2, t); }
    return w > 1e-4 ? c / w : float3(0.0);
}

/// Irradiance / π at GI-space point p (rel = from the camera) for normal N: rgb, a = how much of it is known (0…1).
static float4 giIrradiance(float3 p, float3 rel, float3 N, constant GIView& V, texture3d<float> g0, texture3d<float> g1,
                           texture3d<float> g2, texture3d<float> g3) {
    float lam = giLodF(rel);
    if (lam > float(GI_LEVELS - 1)) return float4(0.0);
    int L = clamp(int(ceil(lam)), 0, GI_LEVELS - 1);
    float t = L < GI_LEVELS - 1 ? smoothstep(float(L) - 0.4, float(L), lam) : 0.0;
    int3 A = V.anchor.xyz;
    float4 s = giSampleLevel(p, A, L, N, g0, g1, g2, g3);
    if (t > 0.0) s = mix(s, giSampleLevel(p, A, L + 1, N, g0, g1, g2, g3), t);
    return s.a > 1e-4 ? float4(s.rgb / s.a, min(s.a * 1.5, 1.0)) : float4(0.0);
}
"""#
