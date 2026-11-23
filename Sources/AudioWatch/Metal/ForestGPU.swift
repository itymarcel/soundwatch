import Foundation
import Metal
import simd

/// What the Forest mode hands the renderer each frame (built by ForestViz).
struct ForestInput {
    /// Camera position in the world (z wrapped into 0…8192) and its forward / up directions.
    var camPos: SIMD3<Float>
    var forward: SIMD3<Float>
    var up: SIMD3<Float>
    var fovY: Float
    var time: Float
    var sunDir: SIMD3<Float>
    var sunCol: SIMD3<Float>
    var sunI: Float
    var zenith: SIMD3<Float>
    var horizon: SIMD3<Float>
    var mist: Float
    var clouds: Float
    /// Bass gusts bending the trees, treble making leaves flutter, overall level, how much trees glow with their band.
    var gust: Float
    var shimmer: Float
    var level: Float
    var bandLight: Float
    var beat: Float
    var windDir: SIMD2<Float>
    var wind: Float
    var density: Float
    var exposure: Float
    var bands: [Float]
    /// Birds: two float4 each (world position + wingbeat phase, velocity + size).
    var birds: [SIMD4<Float>] = []
    /// Season (see ForestSeason / ForestU): snow, foliage, autumn, fresh; flowers, blossom, dry grass, ice;
    /// late flowers, temperature, rain wetness, leaf litter; falling rain, snow, leaves, petals; wind drift + velocity.
    var seasonA = SIMD4<Float>(0, 1, 0, 0)
    var seasonB = SIMD4<Float>()
    var seasonC = SIMD4<Float>()
    var precip = SIMD4<Float>()
    var drift = SIMD4<Float>()
    var camVel = SIMD3<Float>()
    /// Night (0 day … 1 night) and the fireflies: two float4 each (world position + brightness, palette colour).
    var night: Float = 0
    var fireflies: [SIMD4<Float>] = []
    /// Global illumination intensity (0 = off; see LandGI).
    var gi: Float = 0
}

/// Debug aid for exact A/B stills of the Forest: AUDIOWATCH_FOREST_DUMP=/path.json writes the ForestInput of the
/// Forest's N-th frame (N = the first AUDIOWATCH_SNAPSHOT_FRAMES number); AUDIOWATCH_FOREST_LOAD=/path.json draws every
/// frame from it (the GPU frame is a pure function of the input: same camera, time, music, birds, fireflies).
extension ForestInput: Codable {}
enum ForestReplay {
    private static let env = ProcessInfo.processInfo.environment
    private static let dump = env["AUDIOWATCH_FOREST_DUMP"], load = env["AUDIOWATCH_FOREST_LOAD"]
    private static let dumpFrame = Int(env["AUDIOWATCH_SNAPSHOT_FRAMES"]?.split(separator: ",").first ?? "") ?? 0
    private static var frame = 0
    private static var loaded: ForestInput?
    static func apply(_ F: inout ForestInput) {
        frame += 1
        if let load {
            if loaded == nil, let d = FileManager.default.contents(atPath: load) { loaded = try? JSONDecoder().decode(ForestInput.self, from: d) }
            if let loaded { let gi = F.gi; F = loaded; F.gi = gi }     // (GI on / off stays live: A/B stills)
        } else if let dump, frame == dumpFrame, let d = try? JSONEncoder().encode(F) {
            FileManager.default.createFile(atPath: dump, contents: d)
        }
    }
}

/// Debug: AUDIOWATCH_FOREST_PROFILE=1 times every pass of the forest frame on the GPU (stage-boundary timestamps)
/// and prints the medians over 60 frames: `FORESTPROF compute= shadow0=v/f shadow1= main=v/f shafts=` (ms).
final class ForestProfiler {
    static let on = ProcessInfo.processInfo.environment["AUDIOWATCH_FOREST_PROFILE"] != nil
    private let buf: MTLCounterSampleBuffer
    private var names: [String] = []
    private var hist: [String: [Double]] = [:]
    private var frames = 0
    private let lock = NSLock()
    static let slots = 64

    init?(device: MTLDevice) {
        guard Self.on, device.supportsCounterSampling(.atStageBoundary),
              let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else { return nil }
        let d = MTLCounterSampleBufferDescriptor()
        d.counterSet = set; d.sampleCount = Self.slots; d.storageMode = .shared
        guard let b = try? device.makeCounterSampleBuffer(descriptor: d) else { return nil }
        buf = b
    }
    func begin() { names.removeAll() }
    /// 4 slots per render pass: vertex start / end, fragment start / end.
    func render(_ rp: MTLRenderPassDescriptor, _ name: String) {
        let i = names.count * 4
        guard i + 4 <= Self.slots else { return }
        names.append(name)
        let a = rp.sampleBufferAttachments[0]!
        a.sampleBuffer = buf
        a.startOfVertexSampleIndex = i; a.endOfVertexSampleIndex = i + 1
        a.startOfFragmentSampleIndex = i + 2; a.endOfFragmentSampleIndex = i + 3
    }
    func compute(_ cp: MTLComputePassDescriptor, _ name: String) {
        let i = names.count * 4
        guard i + 4 <= Self.slots else { return }
        names.append(name)
        let a = cp.sampleBufferAttachments[0]!
        a.sampleBuffer = buf
        a.startOfEncoderSampleIndex = i + 2; a.endOfEncoderSampleIndex = i + 3
    }
    func finish(_ cmd: MTLCommandBuffer) {
        let n = names
        cmd.addCompletedHandler { [weak self] _ in
            guard let self, let data = try? self.buf.resolveCounterRange(0..<(n.count * 4)) else { return }
            let t = data.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
            self.lock.lock(); defer { self.lock.unlock() }
            func ms(_ a: Int, _ b: Int) -> Double { t[b] > t[a] ? Double(t[b] - t[a]) / 1e6 : 0 }
            for (k, name) in n.enumerated() {
                let i = k * 4
                if t[i] != 0 || t[i + 1] != 0 { self.hist[name + ".v", default: []].append(ms(i, i + 1)) }
                self.hist[name, default: []].append(ms(i + 2, i + 3))
            }
            self.frames += 1
            if self.frames % 60 == 0 {
                let line = self.hist.keys.sorted().map { k -> String in
                    let v = self.hist[k]!.sorted(); return "\(k)=" + String(format: "%.2f", v[v.count / 2])
                }.joined(separator: " ")
                print("FORESTPROF " + line)
                self.hist.removeAll()
            }
        }
    }
}

/// Matches ForestU in ForestShaders.swift.
struct ForestUniforms {
    var viewProj = matrix_identity_float4x4
    var shadow0 = matrix_identity_float4x4
    var shadow1 = matrix_identity_float4x4
    var cam = SIMD4<Float>()
    var sun = SIMD4<Float>()
    var sunCol = SIMD4<Float>()
    var zenith = SIMD4<Float>()
    var horizon = SIMD4<Float>()
    var music = SIMD4<Float>()
    var wind = SIMD4<Float>()
    var planes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.init(), .init(), .init(), .init())
    var cfg = SIMD4<Float>()
    var lod = SIMD4<Float>()
    var fwd = SIMD4<Float>()
    var cell = SIMD4<Int32>()
    var seasonA = SIMD4<Float>()
    var seasonB = SIMD4<Float>()
    var seasonC = SIMD4<Float>()
    var precip = SIMD4<Float>()
    var drift = SIMD4<Float>()
    var vel = SIMD4<Float>()
    var night = SIMD4<Float>()
}

/// The Forest mode on the GPU, drawn the way games draw landscapes (not raymarched):
/// - **Terrain:** an endless height field (eroded fbm from a periodic noise texture that also stores the noise's
///   derivatives, so normals come out exact and smooth), drawn as CDLOD patches chosen on the CPU each frame: 0.5 m
///   vertex spacing near the camera, doubling with every distance ring, morphing between rings so there are no cracks.
/// - **Trees:** placed on the GPU every frame (one compute thread per 4 m cell around the camera: density noise,
///   slope, the river, species by height), culled to the view and sorted into three levels of detail, then drawn with
///   indirect instanced draws. The meshes are grown procedurally at start (`ForestAssets`): spruces of drooping needle
///   fronds, broadleaf trees of limbs and leaf clusters, as alpha-to-coverage cards over 4× MSAA.
/// - **Light:** a sun with two shadow cascades, sky light, light through the leaves, a sky with clouds, height mist
///   that glows towards the sun, a river reflecting the sky, filmic tone mapping.
/// Music: bass gusts roll across the canopy, treble makes the leaves flutter and the water ripple, every tree glows
/// with its own frequency band (Band light).
final class ForestGPU {
    static let caps = [4000, 12000, 20000, 60000]
    static var capSum: Int { caps.reduce(0, +) }
    static let shadowSize = 2048
    static let cell: Float = 4
    static let viewFar: Float = 900
    static let leafNode: Float = 16
    static let baseRange: Float = 40

    private let device: MTLDevice
    private let skyPipe, terrainPipe, barkPipe, leafPipe, waterPipe: MTLRenderPipelineState
    private let terrainShadowPipe, barkShadowPipe, leafShadowPipe: MTLRenderPipelineState
    private let grassPipe, birdPipe, precipPipe, fireflyPipe: MTLRenderPipelineState
    private var fireflyBufs: [MTLBuffer] = []
    static let fireflyCap = 1200
    /// Falling things around the camera: rain / snow near (32 m box) and far (128 m), leaves / petals (32 m).
    static let precipNear = 14000, precipFar = 10000, precipLeaves = 3000
    private let shaftMaskPipe, shaftBlurPipe, shaftAddPipe: MTLRenderPipelineState
    private var shaftA: MTLTexture?, shaftB: MTLTexture?
    private let rockPipe, rockShadowPipe: MTLRenderPipelineState
    private let rockKernel, rockFinalizeKernel: MTLComputePipelineState
    private let rockVB, rockIB: MTLBuffer
    private let rockIndexCount: Int
    private var rockCount: [MTLBuffer] = [], rockArgs: [MTLBuffer] = [], rockInst: [MTLBuffer] = []
    private let scatterKernel, finalizeKernel, grassKernel, grassFinalizeKernel: MTLComputePipelineState
    // global illumination (LandGI): made when it's switched on, dropped when it's off
    private let lib: MTLLibrary
    private let giTreesKernel, giFieldKernel, giTraceKernel: MTLComputePipelineState
    private var gi: LandGI?
    private var giTrees: MTLBuffer?, giField0: MTLTexture?, giField1: MTLTexture?
    private var giFieldOrigin: SIMD2<Float>?
    /// A frame's GI work, encoded at the start of the next frame's command buffer: it reads that frame's depth and
    /// shadow map, which the next frame overwrites. Encoded at the end of its own frame instead, the next frame's
    /// shadow pass had to wait for it (resources shared across command buffers): the measured frame time (which drives
    /// the adaptive scale) went up by ~10 ms instead of the ~4 ms of work.
    private struct GIPending {
        var U: ForestUniforms, invVP: simd_float4x4, GV: GIViewU, fieldOrigin: SIMD2<Float>, fieldNow: Bool
        var w: Int, h: Int, nFly: Int, flySlot: Int, bands: [Float]
    }
    private var giPending: GIPending?
    private lazy var giDummy = LandGI.dummyTexture(device: device)
    static let giFieldSize = 512, giFieldTexel: Float = 2
    private static let giFly = Float(ProcessInfo.processInfo.environment["AUDIOWATCH_GI_FLY"] ?? "") ?? 3
    private static let giDebug = Float(ProcessInfo.processInfo.environment["AUDIOWATCH_GI_DEBUG"] ?? "") ?? 0
    private var grassCount: [MTLBuffer] = [], grassArgs: [MTLBuffer] = [], grassInst: [MTLBuffer] = [], birdBufs: [MTLBuffer] = []
    static let grassCap = 60000, birdCap = 800
    private let dsMain, dsSky, dsWater, dsShadow: MTLDepthStencilState
    private let noiseTex: MTLTexture
    private let atlasTex: MTLTexture
    private let shadowTex: MTLTexture
    private let treeVB, treeIB: MTLBuffer
    /// Terrain patch grids (32² and 16² quads), indexed so each grid point runs the vertex shader once.
    private let gridIB32, gridIB16: MTLBuffer
    private let parts: [[ForestAssets.Part]]       // [species * 4 + lod] = [bark, leaves]
    private var counts: [MTLBuffer] = [], args: [MTLBuffer] = [], inst: [MTLBuffer] = []
    private var nodeBufs: [MTLBuffer] = []
    private var msaaColor: MTLTexture?, msaaDepth: MTLTexture?
    /// Depth of field (Depth focus) reads the depth after the frame: the MSAA depth is resolved (sample 0) into this
    /// single-sample texture (storing the whole 4× buffer cost several ms).
    var keepDepth = false
    private var resolvedDepth: MTLTexture?
    var depthTexture: MTLTexture? { keepDepth ? resolvedDepth : nil }
    /// The projection's near plane (reversed-Z, infinite: depth = near / distance).
    static let near: Float = 0.25
    private(set) var lastTrees = 0
    private lazy var prof = ForestProfiler(device: device)
    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var traceFrame = 0
    /// Debug: AUDIOWATCH_FOREST_SKIP=shadow,terrain,bark,leaves,water,sky leaves those passes out (timing A/B).
    private static let skip = Set((ProcessInfo.processInfo.environment["AUDIOWATCH_FOREST_SKIP"] ?? "").split(separator: ",").map(String.init))

    init?(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        do {
            let lib = try device.makeLibrary(source: forestShaderSource.replacingOccurrences(of: "//@GI_CORE@", with: landGICoreSource)
                                             + forestGIShaderSource, options: nil)
            self.lib = lib
            func fn(_ n: String) -> MTLFunction? { lib.makeFunction(name: n) }
            func pipe(_ v: String, _ f: String?, a2c: Bool = false, blend: Bool = false, add: Bool = false, shadow: Bool = false) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = fn(v)
                d.fragmentFunction = f.flatMap { fn($0) }
                d.depthAttachmentPixelFormat = .depth32Float
                if shadow {
                    d.rasterSampleCount = 1
                    d.inputPrimitiveTopology = .triangle
                } else {
                    d.rasterSampleCount = 4
                    d.colorAttachments[0].pixelFormat = .rgba16Float
                    d.isAlphaToCoverageEnabled = a2c
                    d.isAlphaToOneEnabled = a2c      // coverage from alpha, but the stored alpha stays 1 (the sky mask reads it)
                    if blend {
                        let ca = d.colorAttachments[0]!
                        ca.isBlendingEnabled = true
                        ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    }
                    if add {     // glow added on top; the stored alpha (sky mask) stays
                        let ca = d.colorAttachments[0]!
                        ca.isBlendingEnabled = true
                        ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
                        ca.sourceAlphaBlendFactor = .zero; ca.destinationAlphaBlendFactor = .one
                    }
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            skyPipe = try pipe("forestSkyVert", "forestSkyFrag")
            terrainPipe = try pipe("terrainVert", "terrainFrag")
            barkPipe = try pipe("treeVert", "barkFrag", a2c: true)
            leafPipe = try pipe("treeVert", "leafFrag", a2c: true)
            waterPipe = try pipe("waterVert", "waterFrag", blend: true)
            terrainShadowPipe = try pipe("terrainShadowVert", nil, shadow: true)
            barkShadowPipe = try pipe("treeShadowVert", nil, shadow: true)
            leafShadowPipe = try pipe("treeShadowVert", "leafShadowFrag", shadow: true)
            grassPipe = try pipe("grassVert", "grassFrag")
            func post(_ f: String, add: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = fn("postVert"); d.fragmentFunction = fn(f)
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = .rgba16Float
                if add {
                    ca.isBlendingEnabled = true
                    ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
                    ca.writeMask = [.red, .green, .blue]
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            rockPipe = try pipe("rockVert", "rockFrag", a2c: true)
            rockShadowPipe = try pipe("rockShadowVert", nil, shadow: true)
            rockKernel = try device.makeComputePipelineState(function: fn("rockScatter")!)
            rockFinalizeKernel = try device.makeComputePipelineState(function: fn("rockFinalize")!)
            shaftMaskPipe = try post("shaftMaskFrag", add: false)
            shaftBlurPipe = try post("shaftBlurFrag", add: false)
            shaftAddPipe = try post("shaftAddFrag", add: true)
            birdPipe = try pipe("birdVert", "birdFrag")
            precipPipe = try pipe("precipVert", "precipFrag", blend: true)
            fireflyPipe = try pipe("fireflyVert", "fireflyFrag", add: true)
            grassKernel = try device.makeComputePipelineState(function: fn("grassScatter")!)
            grassFinalizeKernel = try device.makeComputePipelineState(function: fn("grassFinalize")!)
            scatterKernel = try device.makeComputePipelineState(function: fn("forestScatter")!)
            finalizeKernel = try device.makeComputePipelineState(function: fn("forestFinalize")!)
            giTreesKernel = try device.makeComputePipelineState(function: fn("giForestTrees")!)
            giFieldKernel = try device.makeComputePipelineState(function: fn("giForestField")!)
            giTraceKernel = try device.makeComputePipelineState(function: fn("giForestTrace")!)
        } catch {
            NSLog("soundwatch: forest pipeline error \(error)")
            return nil
        }
        func ds(_ f: MTLCompareFunction, _ write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = f
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        dsMain = ds(.greater, true); dsSky = ds(.greaterEqual, false); dsWater = ds(.greater, false); dsShadow = ds(.lessEqual, true)

        noiseTex = ForestAssets.noiseTexture(device: device)
        atlasTex = ForestAssets.leafAtlas(device: device, queue: queue)
        let sd = MTLTextureDescriptor()
        sd.textureType = .type2DArray
        sd.pixelFormat = .depth32Float
        sd.width = Self.shadowSize; sd.height = Self.shadowSize; sd.arrayLength = 2
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        shadowTex = device.makeTexture(descriptor: sd)!

        func grid(_ q: Int) -> MTLBuffer {
            var idx: [UInt16] = []
            for y in 0..<q { for x in 0..<q {
                let a = UInt16(y * (q + 1) + x), b = a + 1, c = a + UInt16(q + 1), d = c + 1
                idx += [a, b, c, b, d, c]
            } }
            return device.makeBuffer(bytes: idx, length: idx.count * 2, options: .storageModeShared)!
        }
        gridIB32 = grid(32); gridIB16 = grid(16)
        let rock = ForestAssets.rockMesh()
        rockVB = device.makeBuffer(bytes: rock.vertices, length: rock.vertices.count * 16, options: .storageModeShared)!
        rockIB = device.makeBuffer(bytes: rock.indices, length: rock.indices.count * 4, options: .storageModeShared)!
        rockIndexCount = rock.indices.count
        let mesh = ForestAssets.treeMeshes()
        treeVB = device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<ForestAssets.Vertex>.stride, options: .storageModeShared)!
        treeIB = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 4, options: .storageModeShared)!
        parts = mesh.parts
        for _ in 0..<2 {
            counts.append(device.makeBuffer(length: 8 * 4, options: .storageModeShared)!)
            let a = device.makeBuffer(length: 16 * 5 * 4, options: .storageModeShared)!
            let p = a.contents().bindMemory(to: UInt32.self, capacity: 80)
            for k in 0..<8 {
                for j in 0..<2 {
                    let part = parts[k][j], e = (k * 2 + j) * 5
                    p[e] = UInt32(part.indexCount); p[e + 1] = 0; p[e + 2] = UInt32(part.indexStart)
                    p[e + 3] = UInt32(bitPattern: Int32(part.baseVertex)); p[e + 4] = 0
                }
            }
            args.append(a)
            inst.append(device.makeBuffer(length: 2 * Self.capSum * 48, options: .storageModePrivate)!)
            nodeBufs.append(device.makeBuffer(length: 4096 * 16 * 3, options: .storageModeShared)!)
            grassCount.append(device.makeBuffer(length: 4, options: .storageModeShared)!)
            let ga = device.makeBuffer(length: 16, options: .storageModeShared)!
            let gp = ga.contents().bindMemory(to: UInt32.self, capacity: 4)
            gp[0] = 33; gp[1] = 0; gp[2] = 0; gp[3] = 0      // 3 blades × 9 vertices per clump + a flower head (6)
            grassArgs.append(ga)
            grassInst.append(device.makeBuffer(length: Self.grassCap * 32, options: .storageModePrivate)!)
            birdBufs.append(device.makeBuffer(length: Self.birdCap * 32, options: .storageModeShared)!)
            fireflyBufs.append(device.makeBuffer(length: Self.fireflyCap * 32, options: .storageModeShared)!)
            rockCount.append(device.makeBuffer(length: 4, options: .storageModePrivate)!)
            let ra = device.makeBuffer(length: 20, options: .storageModeShared)!
            let rp = ra.contents().bindMemory(to: UInt32.self, capacity: 5)
            rp[0] = UInt32(rockIndexCount); rp[1] = 0; rp[2] = 0; rp[3] = 0; rp[4] = 0
            rockArgs.append(ra)
            rockInst.append(device.makeBuffer(length: 8000 * 32, options: .storageModePrivate)!)
        }
    }

    // MARK: - Terrain patches (CDLOD selection)

    private struct Node { var x: Float, z: Float, size: Float, level: Float }

    /// Picks the terrain patches for this frame: fine near the camera, coarser with every ring (each level's range
    /// is twice the one before). A child that is out of its own range is drawn by its parent at the parent's
    /// spacing (16 × 16 quads over the quarter). `planes` = camera-relative frustum planes, nil = no culling (shadows).
    private func selectNodes(cam: SIMD3<Float>, planes: [SIMD4<Float>]?, maxDist: Float, baseRange: Float) -> (full: [Node], half: [Node]) {
        var full: [Node] = [], half: [Node] = []
        let maxL = 8
        func range(_ l: Int) -> Float { baseRange * Float(1 << l) }
        func dist(_ x: Float, _ z: Float, _ s: Float) -> Float {
            let dx = max(x - cam.x, 0, cam.x - (x + s)), dz = max(z - cam.z, 0, cam.z - (z + s))
            return (dx * dx + dz * dz).squareRoot()
        }
        func visible(_ x: Float, _ z: Float, _ s: Float) -> Bool {
            guard let planes else { return true }
            let lo = SIMD3<Float>(x, -12, z) - cam, hi = SIMD3<Float>(x + s, 330, z + s) - cam
            for p in planes {
                let v = SIMD3<Float>(p.x >= 0 ? hi.x : lo.x, p.y >= 0 ? hi.y : lo.y, p.z >= 0 ? hi.z : lo.z)
                if simd_dot(SIMD3(p.x, p.y, p.z), v) + p.w < 0 { return false }
            }
            return true
        }
        @discardableResult
        func select(_ x: Float, _ z: Float, _ s: Float, _ l: Int) -> Bool {
            let d = dist(x, z, s)
            if d > range(l) || d > maxDist { return false }
            if !visible(x, z, s) { return true }
            if l == 0 || d > range(l - 1) { full.append(Node(x: x, z: z, size: s, level: Float(l))); return true }
            let h = s / 2
            for (cx, cz) in [(x, z), (x + h, z), (x, z + h), (x + h, z + h)] where !select(cx, cz, h, l - 1) {
                if dist(cx, cz, h) <= maxDist && visible(cx, cz, h) { half.append(Node(x: cx, z: cz, size: h, level: Float(l))) }
            }
            return true
        }
        let root = Self.leafNode * Float(1 << maxL)
        let rx = (cam.x / root).rounded(.down) * root, rz = (cam.z / root).rounded(.down) * root
        for i in -1...1 { for j in -1...1 { select(rx + Float(i) * root, rz + Float(j) * root, root, maxL) } }
        return (full, half)
    }

    // MARK: - Matrices

    private static func lookRows(_ f: SIMD3<Float>, _ upHint: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let b = -simd_normalize(f)
        let r = simd_normalize(simd_cross(upHint, b))
        let u = simd_cross(b, r)
        return (r, u, b)
    }

    private static func viewMatrix(_ r: SIMD3<Float>, _ u: SIMD3<Float>, _ b: SIMD3<Float>, eye: SIMD3<Float> = .zero) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(r.x, u.x, b.x, 0), SIMD4(r.y, u.y, b.y, 0), SIMD4(r.z, u.z, b.z, 0),
                                SIMD4(-simd_dot(r, eye), -simd_dot(u, eye), -simd_dot(b, eye), 1)))
    }

    /// One shadow cascade: an orthographic view along the sun, `R` metres to each side of `center` (camera-relative),
    /// its centre snapped to whole shadow texels in world space so the shadows don't crawl as the camera moves.
    private static func shadowMatrix(center: SIMD3<Float>, R: Float, sun: SIMD3<Float>, camW: SIMD3<Float>) -> simd_float4x4 {
        let up: SIMD3<Float> = abs(sun.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let (r, u, b) = lookRows(-sun, up)
        let texel = 2 * R / Float(shadowSize)
        let w = center + camW
        let sx = (simd_dot(w, r) / texel).rounded() * texel - simd_dot(w, r)
        let sy = (simd_dot(w, u) / texel).rounded() * texel - simd_dot(w, u)
        let c = center + r * sx + u * sy
        let depth = max(6 * R, 1200)
        let eye = c + sun * depth * 0.5
        let v = viewMatrix(r, u, b, eye: eye)
        let o = simd_float4x4(columns: (SIMD4(1 / R, 0, 0, 0), SIMD4(0, 1 / R, 0, 0), SIMD4(0, 0, -1 / depth, 0), SIMD4(0, 0, 0, 1)))
        return o * v
    }

    /// GI of a finished frame: maintenance, the field its rays march, one ray per 4 × 4 pixels from its depth split
    /// over the cascades, then merge and bake (the fireflies are point lights) for the frame being drawn now.
    private func encodeGITail(_ cmd: MTLCommandBuffer, _ p: GIPending) {
        guard let gi, let giTrees, let giField0, let giField1, let rd = resolvedDepth else { return }
        var U = p.U, GV = p.GV, bandArr = p.bands
        let cpd = MTLComputePassDescriptor()
        prof?.compute(cpd, "gi")
        guard let ce = cmd.makeComputeCommandEncoder(descriptor: cpd) else { return }
        defer { ce.endEncoding() }
        if !Self.skip.contains("gimaint") { gi.encodeMaintain(ce, view: GV) }
        if p.fieldNow, !Self.skip.contains("gifield") {
            ce.setComputePipelineState(giTreesKernel)
            ce.setBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 10)
            ce.setBuffer(giTrees, offset: 0, index: 11)
            ce.setTexture(noiseTex, index: 0)
            ce.dispatchThreads(MTLSize(width: 256, height: 256, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            ce.setComputePipelineState(giFieldKernel)
            var FO = SIMD4<Float>(p.fieldOrigin.x, p.fieldOrigin.y, Self.giFieldTexel, Float(Self.giFieldSize))
            ce.setBytes(&FO, length: 16, index: 12)
            ce.setBytes(&bandArr, length: bandArr.count * 4, index: 13)
            ce.setTexture(giField0, index: 1); ce.setTexture(giField1, index: 2)
            ce.dispatchThreads(MTLSize(width: Self.giFieldSize, height: Self.giFieldSize, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        if !Self.skip.contains("gitrace") {
            ce.setComputePipelineState(giTraceKernel)
            ce.setBytes(&GV, length: MemoryLayout<GIViewU>.stride, index: 0)
            gi.bind(ce)
            ce.setBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 10)
            let st = LandGI.rayStep
            var R = (p.invVP, SIMD4<Float>(p.fieldOrigin.x, p.fieldOrigin.y, Self.giFieldTexel, Float(Self.giFieldSize)),
                     SIMD4<UInt32>(UInt32(p.w), UInt32(p.h), UInt32(st), 0))
            ce.setBytes(&R, length: 96, index: 11)
            ce.setTexture(rd, index: 0); ce.setTexture(noiseTex, index: 1); ce.setTexture(shadowTex, index: 2)
            ce.setTexture(giField0, index: 3); ce.setTexture(giField1, index: 4)
            for i in 0..<4 { ce.setTexture(gi.tex[i], index: 5 + i) }
            ce.dispatchThreads(MTLSize(width: (p.w + st - 1) / st, height: (p.h + st - 1) / st, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        }
        if !Self.skip.contains("giresolve") {
            gi.encodeResolve(ce, view: GV, lights: p.nFly > 0 ? fireflyBufs[p.flySlot] : nil, lightCount: p.nFly)
        }
    }

    // MARK: - Frame

    /// Encodes the whole forest frame into `cmd`, resolved into `target`. `bands` = per-band levels (buffer of floats).
    func encode(cmd: MTLCommandBuffer, target: MTLTexture, input: ForestInput, bands: MTLBuffer, slot: Int) {
        var F = input
        ForestReplay.apply(&F)
        let w = target.width, h = target.height
        // global illumination: on → its probes, field and the resolved depth (the rays start from the depth buffer)
        let giOn = F.gi > 0
        if giOn && gi == nil {
            gi = LandGI(device: device, library: lib)
            giTrees = device.makeBuffer(length: 256 * 256 * 32, options: .storageModePrivate)
            func ftex(_ f: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: Self.giFieldSize, height: Self.giFieldSize, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            giField0 = ftex(.rgba32Float); giField1 = ftex(.rgba16Float)
        } else if !giOn && gi != nil {
            gi = nil; giTrees = nil; giField0 = nil; giField1 = nil; giFieldOrigin = nil; giPending = nil
        }
        let needDepth = keepDepth || gi != nil
        if needDepth && (resolvedDepth?.width != w || resolvedDepth?.height != h) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            resolvedDepth = device.makeTexture(descriptor: d)
        }
        if !needDepth { resolvedDepth = nil }
        let depthMemoryless = device.hasUnifiedMemory && prof == nil
        if msaaColor?.width != w || msaaColor?.height != h {
            let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            c.textureType = .type2DMultisample; c.sampleCount = 4; c.usage = .renderTarget
            c.storageMode = device.hasUnifiedMemory && prof == nil ? .memoryless : .private
            msaaColor = device.makeTexture(descriptor: c)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            d.textureType = .type2DMultisample; d.sampleCount = 4; d.usage = .renderTarget
            d.storageMode = depthMemoryless ? .memoryless : .private
            msaaDepth = device.makeTexture(descriptor: d)
        }
        guard let msaaColor, let msaaDepth else { return }
        if Self.trace {
            // last time this slot ran: instances per species × LOD (before the caps) and grass clumps
            traceFrame += 1
            if traceFrame % 30 == 0 {
                let c = counts[slot].contents().bindMemory(to: UInt32.self, capacity: 8)
                let g = grassCount[slot].contents().bindMemory(to: UInt32.self, capacity: 1)
                print("FORESTGPU trees=\((0..<8).map { c[$0] }) caps=\(Self.caps) grass=\(g[0])")
            }
        }

        // camera
        let (r, u, b) = Self.lookRows(F.forward, F.up)
        let view = Self.viewMatrix(r, u, b)
        let aspect = Float(w) / Float(h), near = Self.near
        let fy = 1 / tan(F.fovY / 2)
        let proj = simd_float4x4(columns: (SIMD4(fy / aspect, 0, 0, 0), SIMD4(0, fy, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
        var U = ForestUniforms()
        U.viewProj = proj * view
        let m = U.viewProj
        func row(_ i: Int) -> SIMD4<Float> { SIMD4(m[0][i], m[1][i], m[2][i], m[3][i]) }
        var planes = [row(3) + row(0), row(3) - row(0), row(3) + row(1), row(3) - row(1)]
        planes = planes.map { p in p / simd_length(SIMD3(p.x, p.y, p.z)) }
        // the trees' list is widened so trees just outside the view still cast their shadows into it
        let wide = planes.map { p in SIMD4(p.x, p.y, p.z, p.w + 25) }
        U.planes = (wide[0], wide[1], wide[2], wide[3])
        U.cam = SIMD4(F.camPos, F.time)
        U.sun = SIMD4(F.sunDir, F.sunI)
        U.sunCol = SIMD4(F.sunCol, F.beat)
        U.zenith = SIMD4(F.zenith, F.mist)
        U.horizon = SIMD4(F.horizon, F.clouds)
        U.music = SIMD4(F.gust, F.shimmer, F.level, F.bandLight)
        U.wind = SIMD4(F.windDir.x, F.windDir.y, F.wind, 0)
        U.cfg = SIMD4(F.density, Self.viewFar, Self.cell, Float(max(1, F.bands.count)))
        U.lod = SIMD4(45, 160, 45, 420)
        U.fwd = SIMD4(simd_normalize(F.forward), F.exposure)
        let grid = Int32(Self.viewFar / Self.cell)
        U.seasonA = F.seasonA; U.seasonB = F.seasonB; U.seasonC = F.seasonC; U.precip = F.precip; U.drift = F.drift
        U.vel = SIMD4(F.camVel, 2 * tan(F.fovY / 2) / Float(h))
        U.night = SIMD4(F.night, 0, 0, 0)
        U.cell = SIMD4(Int32((F.camPos.x / Self.cell).rounded(.down)), Int32((F.camPos.z / Self.cell).rounded(.down)), grid, 0)
        let fflat = simd_normalize(SIMD3(F.forward.x, 0, F.forward.z))
        U.shadow0 = Self.shadowMatrix(center: fflat * 38 + SIMD3(0, -2, 0), R: U.lod.z, sun: F.sunDir, camW: F.camPos)
        U.shadow1 = Self.shadowMatrix(center: fflat * 360, R: U.lod.w, sun: F.sunDir, camW: F.camPos)
        var invVP = simd_inverse(U.viewProj)

        // GI: this frame's view of it (the shaders sample last frame's result), maintenance before this frame's rays
        prof?.begin()
        var GV = GIViewU()
        GV.ground.w = Self.giDebug
        if let gi {
            var cw = F.camPos
            cw.z -= 8192 * (cw.z / 8192).rounded(.down)
            GV.cam = SIMD4(cw, F.gi)
            GV.zenith = SIMD4(F.zenith, 8192)
            GV.horizon = SIMD4(F.horizon, 0.5 * F.gi)
            GV.ground = SIMD4(SIMD3<Float>(0.09, 0.1, 0.06) * (0.3 + F.sunI * 0.2) * pow(0.12, F.night), Self.giDebug)
            GV.misc.z = Self.giFly
            GV.misc.y = Float(min(F.fireflies.count / 2, Self.fireflyCap))      // (fireflies: the shaders only look when there are some)
            gi.nextFrame(&GV)
        }
        // last frame's GI rays (from its depth and shadow map, before this frame's passes overwrite them)
        if let p = giPending, gi != nil, resolvedDepth?.width == p.w, resolvedDepth?.height == p.h { encodeGITail(cmd, p) }
        giPending = nil
        // the field is rebuilt every third frame (the rays use the origin it was built with)
        let giFieldNow = gi != nil && (gi!.frame % 3 == 1 || giFieldOrigin == nil)
        if giFieldNow {
            giFieldOrigin = SIMD2<Float>((F.camPos.x / Self.giFieldTexel).rounded(.down), (F.camPos.z / Self.giFieldTexel).rounded(.down))
                * Self.giFieldTexel - Float(Self.giFieldSize / 2) * Self.giFieldTexel
        }

        // terrain patches: culled for the view, all around for the shadows
        let main = selectNodes(cam: F.camPos, planes: planes, maxDist: Self.viewFar * 1.6, baseRange: Self.baseRange)
        // the far cascade's terrain: much coarser (a shadow map texel there is ~0.4 m; cracks between patches don't show)
        let shadowRange = Self.baseRange * 0.25
        let shadowNodes = selectNodes(cam: F.camPos, planes: nil, maxDist: U.lod.w * 1.6, baseRange: shadowRange)
        let nb = nodeBufs[slot]
        let np = nb.contents().bindMemory(to: SIMD4<Float>.self, capacity: 4096 * 3)
        var lists: [(offset: Int, count: Int, quads: Float, range: Float)] = []
        var at = 0
        for (list, q) in [(main.full, 32), (main.half, 16), (shadowNodes.full, 32), (shadowNodes.half, 16)] {
            let n = min(list.count, 3000 - at)
            for i in 0..<n { let o = list[i]; np[at + i] = SIMD4(o.x, o.z, o.size, o.level) }
            lists.append((at, n, Float(q), lists.count < 2 ? Self.baseRange : shadowRange))
            at += n
        }
        if Self.trace && traceFrame % 30 == 0 { print("FORESTGPU patches=\(lists.map { $0.count })") }

        // trees: count, place, cull and sort on the GPU
        if let bl = cmd.makeBlitCommandEncoder() {
            bl.fill(buffer: counts[slot], range: 0..<32, value: 0)
            bl.fill(buffer: grassCount[slot], range: 0..<4, value: 0)
            bl.fill(buffer: rockCount[slot], range: 0..<4, value: 0)
            bl.endEncoding()
        }
        let cpd = MTLComputePassDescriptor()
        prof?.compute(cpd, "compute")
        if let ce = cmd.makeComputeCommandEncoder(descriptor: cpd) {
            ce.setComputePipelineState(scatterKernel)
            ce.setBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 0)
            ce.setBuffer(counts[slot], offset: 0, index: 1)
            ce.setBuffer(inst[slot], offset: 0, index: 2)
            ce.setTexture(noiseTex, index: 0)
            let n = Int(2 * grid)
            ce.dispatchThreads(MTLSize(width: n, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            ce.setComputePipelineState(finalizeKernel)
            ce.setBuffer(counts[slot], offset: 0, index: 0)
            ce.setBuffer(args[slot], offset: 0, index: 1)
            ce.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            // grass clumps on the banks around the camera
            ce.setComputePipelineState(grassKernel)
            ce.setBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 0)
            ce.setBuffer(grassCount[slot], offset: 0, index: 1)
            ce.setBuffer(grassInst[slot], offset: 0, index: 2)
            let gn = 2 * Int(38 / 0.32)
            ce.dispatchThreads(MTLSize(width: gn, height: gn, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            ce.setComputePipelineState(rockKernel)
            ce.setBuffer(rockCount[slot], offset: 0, index: 1)
            ce.setBuffer(rockInst[slot], offset: 0, index: 2)
            ce.dispatchThreads(MTLSize(width: 80, height: 80, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            ce.setComputePipelineState(rockFinalizeKernel)
            ce.setBuffer(rockCount[slot], offset: 0, index: 0)
            ce.setBuffer(rockArgs[slot], offset: 0, index: 1)
            ce.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            ce.setComputePipelineState(grassFinalizeKernel)
            ce.setBuffer(grassCount[slot], offset: 0, index: 0)
            ce.setBuffer(grassArgs[slot], offset: 0, index: 1)
            ce.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            ce.endEncoding()
        }
        var bandArr = F.bands.isEmpty ? [Float(0)] : F.bands
        _ = bands

        func drawTerrain(_ e: MTLRenderCommandEncoder, _ idx: [Int]) {
            for i in idx where lists[i].count > 0 {
                var G = SIMD4<Float>(lists[i].quads, lists[i].range, 0, 0)
                e.setVertexBuffer(nb, offset: lists[i].offset * 16, index: 0)
                e.setVertexBytes(&G, length: 16, index: 2)
                let ib = lists[i].quads > 20 ? gridIB32 : gridIB16
                e.drawIndexedPrimitives(type: .triangle, indexCount: ib.length / 2, indexType: .uint16, indexBuffer: ib,
                                        indexBufferOffset: 0, instanceCount: lists[i].count)
            }
        }
        // near trees first (lod-major), so the far ones behind them fail the depth test early
        func drawTrees(_ e: MTLRenderCommandEncoder, leaves: Bool, lods: [Int]) {
            for lod in lods {
                for sp in 0..<2 {
                    let k = sp * 4 + lod
                    let base = sp * Self.capSum + Self.caps[..<lod].reduce(0, +)
                    e.setVertexBuffer(inst[slot], offset: base * 48, index: 1)
                    e.drawIndexedPrimitives(type: .triangle, indexType: .uint32, indexBuffer: treeIB, indexBufferOffset: 0,
                                            indirectBuffer: args[slot], indirectBufferOffset: (k * 2 + (leaves ? 1 : 0)) * 20)
                }
            }
        }

        // sun shadows: two cascades
        for c in 0..<2 where !Self.skip.contains("shadow") && !Self.skip.contains("shadow\(c)") {
            let sp = MTLRenderPassDescriptor()
            sp.depthAttachment.texture = shadowTex
            sp.depthAttachment.slice = c
            sp.depthAttachment.loadAction = .clear
            sp.depthAttachment.clearDepth = 1
            sp.depthAttachment.storeAction = .store
            sp.renderTargetWidth = Self.shadowSize; sp.renderTargetHeight = Self.shadowSize
            prof?.render(sp, "shadow\(c)")
            guard let e = cmd.makeRenderCommandEncoder(descriptor: sp) else { continue }
            var L = c == 0 ? U.shadow0 : U.shadow1
            e.setDepthStencilState(dsShadow)
            e.setDepthBias(c == 0 ? 2 : 4, slopeScale: 2.5, clamp: 0.02)
            e.setCullMode(.none)
            e.setRenderPipelineState(terrainShadowPipe)
            e.setVertexBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 1)
            e.setVertexBytes(&L, length: 64, index: 3)
            e.setVertexTexture(noiseTex, index: 0)
            // the near cascade covers ~90 m: the ground's own shadows don't matter there, only the far one draws it
            if c == 1 { drawTerrain(e, [2, 3]) }
            e.setVertexBuffer(treeVB, offset: 0, index: 0)
            e.setVertexBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 2)
            e.setVertexBytes(&bandArr, length: bandArr.count * 4, index: 3)
            e.setVertexBytes(&L, length: 64, index: 4)
            e.setFragmentTexture(atlasTex, index: 0)
            if c == 0 {
                e.setRenderPipelineState(rockShadowPipe)
                e.setVertexBuffer(rockVB, offset: 0, index: 0)
                e.setVertexBuffer(rockInst[slot], offset: 0, index: 1)
                e.drawIndexedPrimitives(type: .triangle, indexType: .uint32, indexBuffer: rockIB, indexBufferOffset: 0,
                                        indirectBuffer: rockArgs[slot], indirectBufferOffset: 0)
                e.setVertexBuffer(treeVB, offset: 0, index: 0)
                e.setRenderPipelineState(barkShadowPipe)
                drawTrees(e, leaves: false, lods: [0])
                e.setRenderPipelineState(leafShadowPipe)
                drawTrees(e, leaves: true, lods: [0, 1])
            } else {
                // far away: the leaf cards cast as solid cards (no per-pixel alpha test: far cheaper), no trunks
                e.setRenderPipelineState(leafShadowPipe)
                drawTrees(e, leaves: true, lods: [1])
                e.setRenderPipelineState(barkShadowPipe)
                drawTrees(e, leaves: true, lods: [2, 3])
            }
            e.endEncoding()
        }

        // the picture
        // (profiling: the pass is split into separately timed segments, which needs a stored MSAA target)
        let split = prof != nil
        func mainPass(_ name: String, first: Bool, last: Bool) -> MTLRenderCommandEncoder? {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = msaaColor
            rp.colorAttachments[0].loadAction = first ? .clear : .load
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            rp.colorAttachments[0].storeAction = last ? .multisampleResolve : .store
            if last { rp.colorAttachments[0].resolveTexture = target }
            rp.depthAttachment.texture = msaaDepth
            rp.depthAttachment.loadAction = first ? .clear : .load
            rp.depthAttachment.clearDepth = 0
            rp.depthAttachment.storeAction = last ? .dontCare : .store
            if last, needDepth, let rd = resolvedDepth {
                rp.depthAttachment.resolveTexture = rd
                rp.depthAttachment.depthResolveFilter = .sample0
                rp.depthAttachment.storeAction = .multisampleResolve
            }
            prof?.render(rp, name)
            guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return nil }
            e.setCullMode(.none)
            e.setFragmentBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 0)
            e.setFragmentTexture(noiseTex, index: 0)
            e.setFragmentTexture(shadowTex, index: 1)
            e.setFragmentTexture(atlasTex, index: 2)
            e.setFragmentBytes(&invVP, length: 64, index: 1)
            var GVs = GV
            if Self.skip.contains("gisample") { GVs.cam.w = 0 }
            e.setFragmentBytes(&GVs, length: MemoryLayout<GIViewU>.stride, index: 2)
            e.setVertexBytes(&GVs, length: MemoryLayout<GIViewU>.stride, index: 4)
            for i in 0..<5 {
                e.setFragmentTexture(gi?.tex[i] ?? giDummy, index: 3 + i)
                e.setVertexTexture(gi?.tex[i] ?? giDummy, index: 1 + i)
            }
            e.setDepthStencilState(dsMain)
            e.setVertexTexture(noiseTex, index: 0)
            return e
        }
        defer { prof?.finish(cmd) }
        guard var e = mainPass(split ? "m1trees" : "main", first: true, last: !split) else { return }
        func next(_ name: String, last: Bool = false) {
            guard split else { return }
            e.endEncoding()
            if let n = mainPass(name, first: false, last: last) { e = n }
        }
        // trees first, then the ground and the sky: what they hide is never shaded (early depth test)
        e.setVertexBuffer(treeVB, offset: 0, index: 0)
        e.setVertexBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 2)
        e.setVertexBytes(&bandArr, length: bandArr.count * 4, index: 3)
        e.setRenderPipelineState(barkPipe)
        if !Self.skip.contains("bark") { drawTrees(e, leaves: false, lods: [0, 1, 2]) }
        next("m2leaves")
        e.setVertexBuffer(treeVB, offset: 0, index: 0)
        e.setVertexBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 2)
        e.setVertexBytes(&bandArr, length: bandArr.count * 4, index: 3)
        e.setRenderPipelineState(leafPipe)
        if !Self.skip.contains("leaves") { drawTrees(e, leaves: true, lods: [0, 1, 2, 3].filter { !Self.skip.contains("leaf\($0)") }) }
        next("m3small")
        // rocks, grass and birds, then the ground they hide
        e.setVertexBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 2)
        if !Self.skip.contains("rocks") {
            e.setRenderPipelineState(rockPipe)
            e.setVertexBuffer(rockVB, offset: 0, index: 0)
            e.setVertexBuffer(rockInst[slot], offset: 0, index: 1)
            e.drawIndexedPrimitives(type: .triangle, indexType: .uint32, indexBuffer: rockIB, indexBufferOffset: 0,
                                    indirectBuffer: rockArgs[slot], indirectBufferOffset: 0)
        }
        e.setVertexBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 1)
        if !Self.skip.contains("grass") {
            e.setRenderPipelineState(grassPipe)
            e.setVertexBuffer(grassInst[slot], offset: 0, index: 0)
            e.drawPrimitives(type: .triangle, indirectBuffer: grassArgs[slot], indirectBufferOffset: 0)
        }
        let nBirds = min(F.birds.count / 2, Self.birdCap)
        if nBirds > 0 {
            F.birds.withUnsafeBytes { birdBufs[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: nBirds * 32) }
            e.setRenderPipelineState(birdPipe)
            e.setVertexBuffer(birdBufs[slot], offset: 0, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 21, instanceCount: nBirds)
        }
        next("m4terrain")
        e.setVertexBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 1)
        e.setRenderPipelineState(terrainPipe)
        if !Self.skip.contains("terrain") { drawTerrain(e, [0, 1]) }
        next("m5sky")
        // the sky only where nothing was drawn (depth still at the cleared "infinitely far")
        e.setDepthStencilState(dsSky)
        e.setRenderPipelineState(skyPipe)
        if !Self.skip.contains("sky") { e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3) }
        next("m6water", last: true)
        // river
        e.setDepthStencilState(dsWater)
        e.setRenderPipelineState(waterPipe)
        e.setVertexBytes(&U, length: MemoryLayout<ForestUniforms>.stride, index: 0)
        if !Self.skip.contains("water") { e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 16 * 16 * 6) }
        // rain, snowfall, falling leaves and petals (blended over everything, behind what's nearer)
        if F.precip.x + F.precip.y + F.precip.z + F.precip.w > 0.002 && !Self.skip.contains("precip") {
            e.setRenderPipelineState(precipPipe)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                             instanceCount: Self.precipNear + Self.precipFar + Self.precipLeaves)
        }
        // fireflies: glowing points added on top (depth-tested, so trees and hills hide them)
        let nFly = min(F.fireflies.count / 2, Self.fireflyCap)
        if nFly > 0 && !Self.skip.contains("fireflies") {
            F.fireflies.withUnsafeBytes { fireflyBufs[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: nFly * 32) }
            e.setRenderPipelineState(fireflyPipe)
            e.setVertexBuffer(fireflyBufs[slot], offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: nFly)
        }
        e.endEncoding()

        // GI: one ray per 4 × 4 pixels from this frame's depth, split over the cascades; then merge and bake (the
        // fireflies are its point lights) for the next frame
        // GI: this frame's rays etc. run at the start of the next frame's command buffer (see encodeGITail)
        if gi != nil, let giFieldOrigin, resolvedDepth != nil {
            if nFly > 0 && F.fireflies.count >= nFly * 2 && Self.skip.contains("fireflies") {
                F.fireflies.withUnsafeBytes { fireflyBufs[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: nFly * 32) }
            }
            giPending = GIPending(U: U, invVP: invVP, GV: GV, fieldOrigin: giFieldOrigin, fieldNow: giFieldNow, w: w, h: h,
                                  nFly: nFly, flySlot: slot, bands: bandArr)
            if Self.trace && traceFrame % 30 == 0, nFly > 0 {
                let fp = F.fireflies
                let near = stride(from: 0, to: nFly * 2, by: 2).filter { simd_length(SIMD3(fp[$0].x, fp[$0].y, fp[$0].z) - F.camPos) < 15 }
                print("FORESTGI flies=\(nFly) within15m=\(near.count) bright=\(near.prefix(5).map { fp[$0].w }) cam=\(F.camPos) fly0=\(fp[0])")
            }
        }

        // light shafts: where the sun shines through the trees (strongest with a low sun in view)
        let sc = U.viewProj * SIMD4(F.sunDir * 1000, 1)
        guard sc.w > 0, !Self.skip.contains("shafts") else { return }
        let ndc = SIMD2(sc.x, sc.y) / sc.w
        let low = 1 - min(1, max(0, (F.sunDir.y - 0.05) / 0.5))
        let facing = 1 - min(1, max(0, (simd_length(ndc) - 0.9) / 1.2))
        var S = (sun: SIMD2<Float>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5), aspect: aspect,
                 strength: (0.25 + 0.55 * low) * facing * (1 + 0.4 * F.beat) * (1 - 0.85 * F.night), col: F.sunCol, pad: Float(0))
        guard S.strength > 0.01 else { return }
        let qw = max(8, w / 4), qh = max(8, h / 4)
        if shaftA?.width != qw || shaftA?.height != qh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: qw, height: qh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            shaftA = device.makeTexture(descriptor: d); shaftB = device.makeTexture(descriptor: d)
        }
        guard let shaftA, let shaftB else { return }
        func pass(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, _ src: MTLTexture, load: Bool) {
            let p = MTLRenderPassDescriptor()
            prof?.render(p, pipe === shaftMaskPipe ? "shaftM" : pipe === shaftBlurPipe ? "shaftB" : "shaftA")
            p.colorAttachments[0].texture = dst
            p.colorAttachments[0].loadAction = load ? .load : .dontCare
            p.colorAttachments[0].storeAction = .store
            guard let pe = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            pe.setRenderPipelineState(pipe)
            pe.setFragmentTexture(src, index: 0)
            pe.setFragmentBytes(&S, length: 32, index: 0)
            pe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            pe.endEncoding()
        }
        pass(shaftA, shaftMaskPipe, target, load: false)
        pass(shaftB, shaftBlurPipe, shaftA, load: false)
        pass(target, shaftAddPipe, shaftB, load: true)
    }
}
