import AppKit
import Metal
import MetalKit
import simd

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let store: SettingsStore
    private let app: AppState
    private let engine: VizEngine

    private var segAddPipe: MTLRenderPipelineState!
    private var segMaxPipe: MTLRenderPipelineState!
    private var spherePipe: MTLRenderPipelineState!
    private var spectroPipe: MTLRenderPipelineState!
    private var fadePipe: MTLRenderPipelineState!
    private var blurPipe: MTLRenderPipelineState!
    private var padPipe: MTLRenderPipelineState!
    private var compositePipe: MTLRenderPipelineState!
    private var bandKernel: MTLComputePipelineState!
    private var pushKernel: MTLComputePipelineState!
    private var cymaticsKernel: MTLComputePipelineState!
    private var flowKernel: MTLComputePipelineState!
    private var partPipe: MTLRenderPipelineState!
    private var partDotPipe: MTLRenderPipelineState!
    private var sphereDotPipe: MTLRenderPipelineState!
    private var triOverPipe: MTLRenderPipelineState!
    private var triAddPipe: MTLRenderPipelineState!
    private var membranePipe: MTLRenderPipelineState!
    private var fanPipe: MTLRenderPipelineState!
    private var glassPipe: MTLRenderPipelineState!
    private var diamondPipe: MTLRenderPipelineState!
    private var orbsPipe: MTLRenderPipelineState!
    private var copyAddPipe: MTLRenderPipelineState!
    /// 4× multisampled variants for frames with shaded surfaces (their triangle edges are otherwise stair-stepped).
    private var triOverPipe4: MTLRenderPipelineState!, triAddPipe4: MTLRenderPipelineState!
    private var segMaxPipe4: MTLRenderPipelineState!, segAddPipe4: MTLRenderPipelineState!, fadePipe4: MTLRenderPipelineState!
    private var msaaTex: MTLTexture?
    private var box4Pipe: MTLRenderPipelineState!
    private var bloomDownPipe: MTLRenderPipelineState!
    private var bloomUpPipe: MTLRenderPipelineState!
    private var bloomTopPipe: MTLRenderPipelineState!
    private var shaderBufs: [MTLBuffer?] = .init(repeating: nil, count: Renderer.inFlight)
    /// Quarter-res blur chains for soft focus / edge fringe and the vertical streak.
    private var softA: MTLTexture?, softB: MTLTexture?, streakA: MTLTexture?, streakB: MTLTexture?
    /// Off-screen target for the raymarched modes (Glass Stack, Diamond, Orbs), `rmScale` × the drawable size.
    /// The scale adapts to the measured GPU time: full resolution when the scene is cheap (small objects), lower
    /// when it's heavy (zoomed in, many orbs, lots of blur), so the frame rate holds either way.
    private var rmTex: MTLTexture?
    private var rmScale: Float = 0.5
    private var rmKind: ShaderModeKind?
    private var rmFast = true      // aiming for the display's full 120 Hz (else 60)
    private var rmHold = 0         // frames to wait before the next change
    private var rmCalm = 0         // frames in a row with room to raise the scale
    private var rmCeil: Float = 1  // a scale that recently proved too expensive
    private var rmCeilAge = 0
    private var gpuEMA: Double = 0
    private let gpuLock = NSLock()
    private var gpuMsShared: Double = 0
    private var rmStartShared: Double = 0
    private var triOverBufs: [MTLBuffer?] = .init(repeating: nil, count: Renderer.inFlight)
    private var triAddBufs: [MTLBuffer?] = .init(repeating: nil, count: Renderer.inFlight)
    private var partBuf: MTLBuffer?
    private var partCount = 0
    private var partKind: ParticleKind?
    private var histBuf: MTLBuffer?
    private var histBands = 0
    private let histCols = 360
    private var histHead = 0
    private var histAcc: Double = 0
    private var unitLayout: SphereLayout?

    private let sceneFormat: MTLPixelFormat = .rgba16Float
    private var scenes: [MTLTexture] = []
    /// bloomA = the scene at ¼ size (also the source of the soft-focus and streak blurs), bloomB = the finished glow,
    /// bloomMips = the pyramid's smaller levels (⅛, 1/16, …).
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var bloomMips: [MTLTexture] = []
    private var sceneIndex = 0

    /// Frames the CPU may prepare ahead of the GPU. Each one queued is a frame of delay between sound and picture
    /// whenever the GPU is the bottleneck, so keep it at the minimum that still lets CPU and GPU overlap.
    private static let inFlight = 2
    private let semaphore = DispatchSemaphore(value: Renderer.inFlight)
    private var frameSlot = 0
    private var addBufs: [MTLBuffer?] = .init(repeating: nil, count: Renderer.inFlight)
    private var lineBufs: [MTLBuffer?] = .init(repeating: nil, count: Renderer.inFlight)
    private var pyrBufs: [MTLBuffer] = []
    private let pyrCapacity = 65_536 + 64

    private var unitBuf: MTLBuffer?
    private var unitCount = 0
    private var valsBuf: MTLBuffer?
    private var valsCount = 0

    private var spectroTex: MTLTexture?
    private let spectroRows = 512
    private var spectroHead = 0

    private var paletteTex: MTLTexture?
    private lazy var media = MediaLayer(device: device)
    private var mediaBlurA: MTLTexture?, mediaBlurB: MTLTexture?
    private lazy var envMaps = EnvMaps(device: device, queue: queue)
    private lazy var blankTex: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        return device.makeTexture(descriptor: d)
    }()
    private var paletteKey: String?


    private let builder = FrameBuilder()
    private var lastTime: Double?
    private var startTime: Double?
    private var frame = 0
    private var fps: Double = 60

    init?(view: MTKView, store: SettingsStore, app: AppState, engine: VizEngine) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.store = store
        self.app = app
        self.engine = engine
        super.init()
        do { try buildPipelines(view.colorPixelFormat) } catch {
            NSLog("soundwatch: pipeline error \(error)")
            return nil
        }
        for _ in 0..<Renderer.inFlight {
            pyrBufs.append(device.makeBuffer(length: pyrCapacity * 4, options: .storageModeShared)!)
        }
        view.delegate = self
    }

    // MARK: - Setup

    private func buildPipelines(_ drawableFormat: MTLPixelFormat) throws {
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        func fn(_ n: String) -> MTLFunction { lib.makeFunction(name: n)! }
        enum Blend { case none, add, max, over }
        func pipe(_ v: String, _ f: String, _ fmt: MTLPixelFormat, _ blend: Blend, points: Bool = false, samples: Int = 1) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.rasterSampleCount = samples
            if points { d.inputPrimitiveTopology = .point }
            d.vertexFunction = fn(v)
            d.fragmentFunction = fn(f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = fmt
            if blend != .none {
                ca.isBlendingEnabled = true
                let op: MTLBlendOperation = blend == .max ? .max : .add
                ca.rgbBlendOperation = op; ca.alphaBlendOperation = op
                ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .one; ca.destinationAlphaBlendFactor = .one
                if blend == .over {
                    ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        segAddPipe = try pipe("segVert", "segFrag", sceneFormat, .add)
        segMaxPipe = try pipe("segVert", "segFrag", sceneFormat, .max)
        spherePipe = try pipe("sphereVert", "segFrag", sceneFormat, .add)
        spectroPipe = try pipe("fsVert", "spectroFrag", sceneFormat, .add)
        fadePipe = try pipe("fsVert", "fadeFrag", sceneFormat, .max)
        blurPipe = try pipe("fsVert", "blurFrag", sceneFormat, .none)
        padPipe = try pipe("fsVert", "padFrag", sceneFormat, .none)
        compositePipe = try pipe("fsVert", "compositeFrag", drawableFormat, .none)
        bandKernel = try device.makeComputePipelineState(function: fn("bandKernel"))
        pushKernel = try device.makeComputePipelineState(function: fn("pushKernel"))
        cymaticsKernel = try device.makeComputePipelineState(function: fn("cymaticsKernel"))
        flowKernel = try device.makeComputePipelineState(function: fn("flowKernel"))
        partPipe = try pipe("partVert", "streakFrag", sceneFormat, .add)
        partDotPipe = try pipe("partDotVert", "dotFrag", sceneFormat, .add, points: true)
        sphereDotPipe = try pipe("sphereDotVert", "dotFrag", sceneFormat, .add, points: true)
        triOverPipe = try pipe("triVert", "triFrag", sceneFormat, .over)
        triAddPipe = try pipe("triVert", "triFrag", sceneFormat, .add)
        membranePipe = try pipe("fsVert", "membraneFrag", sceneFormat, .add)
        fanPipe = try pipe("fsVert", "fanFrag", sceneFormat, .add)
        glassPipe = try pipe("fsVert", "glassFrag", sceneFormat, .none)
        diamondPipe = try pipe("fsVert", "diamondFrag", sceneFormat, .none)
        orbsPipe = try pipe("fsVert", "orbsFrag", sceneFormat, .none)
        copyAddPipe = try pipe("fsVert", "copyFrag", sceneFormat, .add)
        triOverPipe4 = try pipe("triVert", "triFrag", sceneFormat, .over, samples: 4)
        triAddPipe4 = try pipe("triVert", "triFrag", sceneFormat, .add, samples: 4)
        segMaxPipe4 = try pipe("segVert", "segFrag", sceneFormat, .max, samples: 4)
        segAddPipe4 = try pipe("segVert", "segFrag", sceneFormat, .add, samples: 4)
        fadePipe4 = try pipe("fsVert", "fadeFrag", sceneFormat, .max, samples: 4)
        box4Pipe = try pipe("fsVert", "box4Frag", sceneFormat, .none)
        bloomDownPipe = try pipe("fsVert", "bloomDownFrag", sceneFormat, .none)
        bloomUpPipe = try pipe("fsVert", "bloomUpFrag", sceneFormat, .add)
        bloomTopPipe = try pipe("fsVert", "bloomTopFrag", sceneFormat, .none)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        makeTargets(size)
    }

    private func makeTargets(_ size: CGSize) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        func tex(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: sceneFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        scenes = [tex(w, h), tex(w, h)]
        bloomA = tex(max(1, w / 4), max(1, h / 4))
        bloomB = tex(max(1, w / 4), max(1, h / 4))
        softA = tex(max(1, w / 4), max(1, h / 4))
        softB = tex(max(1, w / 4), max(1, h / 4))
        streakA = tex(max(1, w / 4), max(1, h / 4))
        streakB = tex(max(1, w / 4), max(1, h / 4))
        rmTex = nil
        msaaTex = nil
        bloomMips = []
        var mw = max(1, w / 4), mh = max(1, h / 4)
        while bloomMips.count < 5 && min(mw, mh) >= 16 {
            mw = max(1, mw / 2); mh = max(1, mh / 2)
            bloomMips.append(tex(mw, mh))
        }
        // Fresh GPU memory is garbage (often NaN in half floats): clear every target once so nothing stale leaks into
        // trails, bloom or the composite before it's first written.
        if let cmd = queue.makeCommandBuffer() {
            for t in scenes + bloomMips + [bloomA!, bloomB!, softA!, softB!, streakA!, streakB!] {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = t
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                rp.colorAttachments[0].storeAction = .store
                cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            }
            cmd.commit()
        }
    }

    private func ensurePalette(_ s: VizSettings) {
        let key = "\(s.palette.rawValue)/\(Int((s.paletteMix * 1000).rounded()))"
        guard key != paletteKey || paletteTex == nil else { return }
        paletteKey = key
        let p = s.effectivePalette
        var px = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            let c = p.rgb(Float(i) / 255)
            px[i * 4] = UInt8(c.x * 255); px[i * 4 + 1] = UInt8(c.y * 255); px[i * 4 + 2] = UInt8(c.z * 255)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: px, bytesPerRow: 256 * 4)
        paletteTex = t
    }

    private func upload<T>(_ segs: [T], into slot: inout MTLBuffer?) -> MTLBuffer? {
        guard !segs.isEmpty else { return nil }
        let bytes = segs.count * MemoryLayout<T>.stride
        if slot == nil || slot!.length < bytes {
            slot = device.makeBuffer(length: max(bytes * 3 / 2, 4096), options: .storageModeShared)
        }
        segs.withUnsafeBytes { slot!.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        return slot
    }

    /// Point positions (xyz) + spectrum position (w) for each layout. Rebuilt only when count or layout changes.
    private func ensureSphere(_ n: Int, _ layout: SphereLayout, bandCount: Int) {
        if unitCount != n || unitLayout != layout {
            unitCount = n
            unitLayout = layout
            let buf = device.makeBuffer(length: n * 16, options: .storageModeShared)!
            let p = buf.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
            Self.fillLayout(p, n: n, layout: layout)
            if layout == .terrain { Self.equaliseRanks(p, n: n) }
            unitBuf = buf
        }
        if valsCount < bandCount || valsBuf == nil {
            valsCount = bandCount
            valsBuf = zeroedBuffer(bandCount)
        }
        if layout.usesHistory && (histBuf == nil || histBands != bandCount) {
            histBands = bandCount
            histBuf = zeroedBuffer(bandCount * histCols)
            histHead = 0
        }
    }

    /// Random initial particle positions in [0,1]², zero velocity.
    private func ensureParticles(_ n: Int, _ kind: ParticleKind) {
        guard partCount != n || partKind != kind || partBuf == nil else { return }
        partCount = n
        partKind = kind
        let buf = device.makeBuffer(length: n * 16, options: .storageModeShared)!
        let p = buf.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        DispatchQueue.concurrentPerform(iterations: 32) { chunk in
            var rng = SplitMix(seed: UInt64(chunk + 1) &* 0x2545_F491_4F6C_DD1D)
            for i in (chunk * n / 32)..<((chunk + 1) * n / 32) {
                p[i] = SIMD4(Float(rng.unit()), Float(rng.unit()), 0, 0)
            }
        }
        partBuf = buf
    }

    private func ensureVals(_ count: Int) {
        if valsCount < count || valsBuf == nil {
            valsCount = count
            valsBuf = zeroedBuffer(count)
        }
    }

    private func zeroedBuffer(_ floats: Int) -> MTLBuffer? {
        let buf = device.makeBuffer(length: max(4, floats * 4), options: .storageModePrivate)
        if let buf, let cb = queue.makeCommandBuffer(), let enc = cb.makeBlitCommandEncoder() {
            enc.fill(buffer: buf, range: 0..<buf.length, value: 0)
            enc.endEncoding()
            cb.commit()
        }
        return buf
    }

    private static func fillLayout(_ p: UnsafeMutablePointer<SIMD4<Float>>, n: Int, layout: SphereLayout) {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        func lattice(_ i: Int, _ count: Int) -> SIMD3<Double> {
            let y = -1 + 2 * (Double(i) + 0.5) / Double(count)
            let r = (1 - y * y).squareRoot()
            let th = (golden * Double(i)).truncatingRemainder(dividingBy: 2 * .pi)
            return SIMD3(cos(th) * r, y, sin(th) * r)
        }
        // Cell centres for the "cells" layout
        let k = min(64, max(6, n / 400))
        let centres = (0..<k).map { lattice($0, k) }
        let cellArea = 2.0 / Double(k)   // (1 - cos r) of a cap with area 4π/k

        DispatchQueue.concurrentPerform(iterations: 32) { chunk in
            let lo = chunk * n / 32, hi = (chunk + 1) * n / 32
            for i in lo..<hi {
                let v = lattice(i, n)
                let frac: Double
                switch layout {
                case .ripples:
                    // Frequency runs around each ring, mirrored so the ring has no seam: bass at the back, treble at the front.
                    let az = atan2(v.z, v.x) / (2 * .pi) + 0.5
                    frac = 1 - abs(2 * az - 1)
                case .cells:
                    var best = -2.0
                    for c in centres { best = max(best, c.x * v.x + c.y * v.y + c.z * v.z) }
                    frac = min(1, (1 - best) / cellArea)
                case .terrain: frac = Self.terrainNoise(v)
                default: frac = (v.y + 1) / 2   // poles, time globe, harmonics
                }
                p[i] = SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(min(max(frac, 0), 0.99999)))
            }
        }
    }

    /// Terrain: equalise the noise heights by rank so every band gets an equal share of the surface.
    private static func equaliseRanks(_ p: UnsafeMutablePointer<SIMD4<Float>>, n: Int) {
        var order = Array(0..<n)
        order.sort { p[$0].w < p[$1].w }
        for (rank, i) in order.enumerated() { p[i].w = min(0.99999, (Float(rank) + 0.5) / Float(n)) }
    }

    /// Smooth fractal value noise on the unit sphere (a few large "continents" plus finer relief).
    private static func terrainNoise(_ v: SIMD3<Double>) -> Double {
        func hash(_ x: Int, _ y: Int, _ z: Int) -> Double {
            var h = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ z &* 83_492_791))
            h = (h ^ (h >> 33)) &* 0xFF51_AFD7_ED55_8CCD
            h = (h ^ (h >> 33)) &* 0xC4CE_B9FE_1A85_EC53
            return Double((h ^ (h >> 33)) >> 11) / Double(1 << 53)
        }
        func noise(_ q: SIMD3<Double>) -> Double {
            let f = q.rounded(.down)
            let x = Int(f.x), y = Int(f.y), z = Int(f.z)
            let d = q - f
            let s = d * d * (3 - 2 * d)
            func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
            let x00 = lerp(hash(x, y, z), hash(x + 1, y, z), s.x)
            let x10 = lerp(hash(x, y + 1, z), hash(x + 1, y + 1, z), s.x)
            let x01 = lerp(hash(x, y, z + 1), hash(x + 1, y, z + 1), s.x)
            let x11 = lerp(hash(x, y + 1, z + 1), hash(x + 1, y + 1, z + 1), s.x)
            return lerp(lerp(x00, x10, s.y), lerp(x01, x11, s.y), s.z)
        }
        var sum = 0.0, amp = 1.0, freq = 1.6, norm = 0.0
        for o in 0..<4 {
            sum += amp * noise(v * freq + SIMD3(17.3, 5.1, 9.7) * Double(o + 1))
            norm += amp
            amp *= 0.5
            freq *= 2.1
        }
        return sum / norm
    }

    private func writeSpectroRows(_ d: SpectroDraw) {
        if spectroTex == nil || spectroTex!.width != d.bands {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: d.bands, height: spectroRows, mipmapped: false)
            desc.usage = .shaderRead
            desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
            spectroTex = device.makeTexture(descriptor: desc)
            let zeros = [Float](repeating: 0, count: d.bands * spectroRows)
            spectroTex!.replace(region: MTLRegionMake2D(0, 0, d.bands, spectroRows), mipmapLevel: 0, withBytes: zeros, bytesPerRow: d.bands * 4)
            spectroHead = 0
        }
        for row in d.newRows where row.count == d.bands {
            spectroHead = (spectroHead + 1) % spectroRows
            spectroTex!.replace(region: MTLRegionMake2D(0, spectroHead, d.bands, 1), mipmapLevel: 0, withBytes: row, bytesPerRow: d.bands * 4)
        }
    }

    /// Per-frame warp parameters (frame-rate independent, driven by bass + beat).
    private func warpUniforms(_ s: VizSettings, dt: Double, time: Double, aspect: Float, beat: Float) -> WarpUniforms {
        let k = Float(dt * 60)
        let A = Float(s.warp)
        let bass = min(1.2, engine.analyzer.level(20, 140, s: s))
        var zoom: Float = 0, rot: Float = 0, swirl: Float = 0, ripple: Float = 0, kaleido: Float = 0
        switch s.warpStyle {
        case .tunnel: zoom = 0.006 + 0.03 * bass + 0.05 * beat; rot = 0.002
        case .vortex: zoom = 0.003 + 0.01 * bass; swirl = 0.02 + 0.06 * bass + 0.05 * beat
        case .ripple: zoom = 0.002 + 0.02 * beat; ripple = 0.5 + 2.5 * bass
        case .spin: zoom = 0.004 + 0.02 * beat; rot = 0.01 + 0.035 * bass
        case .kaleido: zoom = 0.004 + 0.02 * bass + 0.03 * beat; rot = 0.003; kaleido = 6
        case .implode: zoom = -(0.006 + 0.02 * bass + 0.04 * beat); rot = -0.002
        }
        var decay = Float(pow(0.55 + 0.43 * s.persistence, dt * 60))
        if A > 0.01 { decay = max(decay, Float(pow(0.86 + 0.1 * Double(A), dt * 60))) }
        return WarpUniforms(decay: decay, zoom: pow(1 + A * zoom, k), rot: A * rot * k, swirl: A * swirl * k,
                            ripple: A * ripple, kaleido: A > 0.01 ? kaleido : 0, time: Float(time), aspect: aspect)
    }

    /// Picks the resolution of the raymarched modes from the measured GPU time of their pass (≈ k · scale², so the
    /// scale that just fits a time budget follows directly). On a 120 Hz display it holds 120 fps as long as that
    /// leaves at least about half resolution, otherwise it settles for 60 fps and spends the time on sharpness.
    /// Drops are immediate, rises wait for a calm stretch, so the picture doesn't pump with the music.
    private func updateRaymarchScale(_ kind: ShaderModeKind, maxFPS: Int) {
        if let fixed = Renderer.fixedScale { rmKind = kind; rmScale = fixed; return }
        if rmKind != kind {
            rmKind = kind; rmScale = 0.5; rmHold = 12; rmCalm = 0; gpuEMA = 0; rmFast = true; rmCeil = 1; rmCeilAge = 0
            gpuLock.lock(); gpuMsShared = 0; gpuLock.unlock()
            return
        }
        gpuLock.lock(); let g = gpuMsShared; gpuLock.unlock()
        guard g > 0 else { return }
        gpuEMA = gpuEMA == 0 ? g : gpuEMA * 0.75 + g * 0.25
        if rmHold > 0 { rmHold -= 1; return }
        func fit(_ budget: Double) -> Float { rmScale * Float((budget / max(gpuEMA, 0.05)).squareRoot()) }
        var target = fit(9.5)                                    // 60 fps: ~16.7 ms minus the rest of the frame
        if maxFPS >= 100 {
            let fast = fit(3.3)                                  // 120 fps: ~8.3 ms minus the rest of the frame
            if rmFast { if fast < 0.5 { rmFast = false } } else if fast > 0.68 { rmFast = true }
            if rmFast { target = fast }
        }
        target = min(1, max(0.2, target))
        // After a drop, the scale that proved too expensive is remembered as a ceiling for ~10 s, so the scale
        // settles just under it instead of creeping back up and dropping again (visible as wobbling sharpness).
        rmCeilAge += 1
        if rmCeilAge > 1200 { rmCeil = 1 }
        if target < rmScale * 0.9 {
            rmCeil = rmScale; rmCeilAge = 0
            rmScale = max(0.2, target * 0.95); rmHold = 12; rmCalm = 0
        } else if rmScale < 1 {
            let goal = min(1, min(target * 0.9, rmCeil * 0.9))
            if goal > rmScale * 1.12 {
                rmCalm += 1
                if rmCalm > 45 { rmScale = min(goal, rmScale * 1.5); rmHold = 12; rmCalm = 0 }
            } else {
                rmCalm = 0
            }
        }
    }

    // MARK: - Frame

    static let perf = ProcessInfo.processInfo.environment["AUDIOWATCH_PERF"] != nil
    /// Debug aid: AUDIOWATCH_RMSCALE=0.5 pins the resolution scale of the raymarched modes (for comparing timings).
    static let fixedScale = ProcessInfo.processInfo.environment["AUDIOWATCH_RMSCALE"].flatMap { Float($0) }

    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        // Keep targets exactly the drawable size (the size-change callback can lag behind the first frames).
        if scenes.isEmpty || scenes[0].width != Int(view.drawableSize.width) || scenes[0].height != Int(view.drawableSize.height) {
            makeTargets(view.drawableSize)
        }
        _ = semaphore.wait(timeout: .distantFuture)
        // Take the drawable before analysing the audio: if this has to wait for a free one, the audio read afterwards
        // is that much fresher when the frame reaches the screen.
        guard let drawable = view.currentDrawable else { semaphore.signal(); return }

        let frozen = app.frozen
        let now = CACurrentMediaTime()
        if startTime == nil { startTime = now }
        let elapsed = now - startTime!
        let dt = min(max(lastTime.map { now - $0 } ?? 1 / 60, 1e-4), 0.1)
        lastTime = now
        frame += 1
        fps = fps * 0.95 + (1 / dt) * 0.05
        engine.fps = fps

        let scale = Float(view.window?.backingScaleFactor ?? 2)
        let px = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        let sizePt = px / scale

        // CPU: analysis + primitive building
        let cpu0 = CACurrentMediaTime()
        builder.reset()
        if !frozen {   // auto-loop through presets: may switch the look on this frame's beat
            let step = store.presetLoopStep(beatCount: engine.analyzer.beatCount)
            if step.switched, let cam = step.camera { app.camera.set(cam, for: store.s.mode) }
        }
        var rc = engine.prepare(size: sizePt, settings: store.s, dt: dt, time: elapsed, frozen: frozen)
        let s = rc.s   // with the node patch applied
        var cam = app.camera.step(s.mode, dt: dt)
        cam.yaw += engine.nodes.camYaw
        cam.pitch = min(1.5, max(-1.5, cam.pitch + engine.nodes.camPitch))
        cam.zoom *= engine.nodes.camZoom
        rc.camera = cam
        engine.visualizer(for: s.mode).build(builder, rc)
        ensurePalette(s)
        let cpuMs = (CACurrentMediaTime() - cpu0) * 1000

        guard let cmd = queue.makeCommandBuffer(), scenes.count == 2,
              let bloomA, let bloomB, let paletteTex, let softA, let softB, let streakA, let streakB
        else { semaphore.signal(); return }
        let sem = semaphore, lock = gpuLock
        let rmKindNow = builder.shaderMode.flatMap { [.glass, .diamond, .orbs].contains($0.kind) ? $0.kind : nil }
        if let rmKindNow { updateRaymarchScale(rmKindNow, maxFPS: view.window?.screen?.maximumFramesPerSecond ?? 60) } else { rmKind = nil }
        let perfScale = rmKindNow == nil ? -1 : rmScale
        cmd.addCompletedHandler { [weak self] cb in
            if let e = cb.error { NSLog("soundwatch: GPU frame failed: \(e)") }
            if Renderer.perf {
                // gpu = the whole frame; rm = the off-screen raymarch pass, which runs in its own command buffer just
                // before this one (so the frame is timed from that pass's start)
                lock.lock(); let rm = self?.gpuMsShared ?? 0, rmStart = self?.rmStartShared ?? 0; lock.unlock()
                let start = perfScale < 0 || rmStart <= 0 ? cb.gpuStartTime : min(cb.gpuStartTime, rmStart)
                print(String(format: "PERF cpu=%.2f gpu=%.2f rm=%.2f scale=%.2f", cpuMs, (cb.gpuEndTime - start) * 1000,
                             perfScale < 0 ? 0 : rm, abs(perfScale)))
            }
            sem.signal()
        }

        var U = GPUUniforms(viewPx: px, pxScale: scale, time: Float(elapsed))
        U.center = sizePt / 2
        U.pan = cam.pan
        U.zoom = cam.zoom
        U.persp = 2.5 * min(sizePt.x, sizePt.y)
        if !s.isVolumetric {
            // 2D modes: tilt the whole scene plane; the sphere applies the orbit to its own geometry instead.
            let r = cam.rotation.transpose
            U.cam0 = SIMD4(r[0], 0); U.cam1 = SIMD4(r[1], 0); U.cam2 = SIMD4(r[2], 0)
        }
        let slot = frameSlot
        frameSlot = (frameSlot + 1) % Renderer.inFlight

        // GPU spectrum bands (sphere points / flow particles)
        if let sp = builder.sphere { ensureSphere(sp.n, sp.layout, bandCount: sp.bandCount) }
        if let pd = builder.particles {
            ensureParticles(pd.count, pd.kind)
            if pd.bandCount > 0 { ensureVals(pd.bandCount) }
        }
        let gpuBands = builder.sphere?.bandCount ?? (builder.particles.map { $0.bandCount } ?? 0)
        if let ce = cmd.makeComputeCommandEncoder() {
            if gpuBands > 0 {
                let pyr = pyrBufs[slot].contents().bindMemory(to: Float.self, capacity: pyrCapacity)
                var offs = [UInt32](repeating: 0, count: 16)
                let levels = engine.analyzer.buildPyramid(into: pyr, capacity: pyrCapacity, offsets: &offs)
                let half = engine.analyzer.fftSize / 2
                let fMin = Float(max(10, s.minFreq))
                let fMax = max(fMin * 1.5, Float(min(s.maxFreq, engine.analyzer.sampleRate / 2 - 1)))
                let env = Envelope.coeffs(smoothing: s.smoothing, dt: dt)
                var B = BandUniforms(fMin: fMin, ratio: fMax / fMin, binHz: Float(engine.analyzer.sampleRate) / Float(engine.analyzer.fftSize),
                                     floorDB: Float(s.floorDB), gain: Float(s.gain), tilt: Float(s.tilt),
                                     release: env.fall, attack: env.rise,
                                     count: UInt32(gpuBands), halfBins: UInt32(half), levels: UInt32(levels), frozen: frozen ? 1 : 0)
                ce.setComputePipelineState(bandKernel)
                ce.setBuffer(valsBuf, offset: 0, index: 0)
                ce.setBuffer(pyrBufs[slot], offset: 0, index: 1)
                ce.setBytes(offs, length: offs.count * 4, index: 2)
                ce.setBytes(&B, length: MemoryLayout<BandUniforms>.stride, index: 3)
                ce.dispatchThreads(MTLSize(width: gpuBands, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: min(bandKernel.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1))
            }
            // Time globe / ripples: append the new spectrum as a history column ~40×/s
            if let sp = builder.sphere, sp.layout.usesHistory, let histBuf, !frozen {
                histAcc += dt * 40
                let pushes = min(Int(histAcc), 4)
                histAcc -= Double(Int(histAcc))
                for _ in 0..<pushes {
                    histHead = (histHead + 1) % histCols
                    var P = SIMD2<UInt32>(UInt32(histBands), UInt32(histHead * histBands))
                    ce.setComputePipelineState(pushKernel)
                    ce.setBuffer(histBuf, offset: 0, index: 0)
                    ce.setBuffer(valsBuf, offset: 0, index: 1)
                    ce.setBytes(&P, length: 8, index: 2)
                    ce.dispatchThreads(MTLSize(width: histBands, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: min(256, pushKernel.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
                }
            }
            // Particle simulation step
            if let pd = builder.particles, let partBuf, !frozen {
                var sim = pd.sim
                let kernel = pd.kind == .cymatics ? cymaticsKernel! : flowKernel!
                ce.setComputePipelineState(kernel)
                ce.setBuffer(partBuf, offset: 0, index: 0)
                if pd.kind == .cymatics {
                    ce.setBytes(&sim, length: MemoryLayout<SimUniforms>.stride, index: 1)
                } else {
                    ce.setBuffer(valsBuf, offset: 0, index: 1)
                    ce.setBytes(&sim, length: MemoryLayout<SimUniforms>.stride, index: 2)
                }
                ce.dispatchThreads(MTLSize(width: pd.count, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: min(kernel.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1))
            }
            ce.endEncoding()
        }
        if let sd = builder.spectro { writeSpectroRows(sd) }

        func blur(_ src: MTLTexture, _ dst: MTLTexture, _ dir: SIMD2<Float>) {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = dst
            p.colorAttachments[0].loadAction = .dontCare
            p.colorAttachments[0].storeAction = .store
            guard let e = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            var step = dir
            e.setRenderPipelineState(blurPipe)
            e.setFragmentTexture(src, index: 0)
            e.setFragmentBytes(&step, length: 8, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        // Media layer (before the scene: Membrane can read it) (optionally blurred: downsample + two separable passes; smaller = blurrier)
        media.update(path: s.mediaPath, speed: s.mediaSpeed)
        var mediaTex: MTLTexture? = s.mediaPath.isEmpty ? nil : media.texture
        var mediaPad = SIMD2<Float>()
        if let src = mediaTex, s.mediaBlur > 0.005 {
            let k = 1 + 7 * s.mediaBlur
            let iw = max(16, min(1024, Int(Double(src.width) / k))), ih = max(16, Int(Double(iw) / Double(max(media.aspect, 0.01))))
            // transparent margin wide enough for the blur to spread into
            let padPx = Int((4 * (0.5 + 1.5 * s.mediaBlur) * 2.6).rounded(.up)) + 2
            let w = iw + 2 * padPx, h = ih + 2 * padPx
            mediaPad = SIMD2(Float(padPx) / Float(w), Float(padPx) / Float(h))
            if mediaBlurA?.width != w || mediaBlurA?.height != h {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: sceneFormat, width: w, height: h, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                mediaBlurA = device.makeTexture(descriptor: d)
                mediaBlurB = device.makeTexture(descriptor: d)
            }
            if let a = mediaBlurA, let b = mediaBlurB {
                let spread = Float(0.5 + 1.5 * s.mediaBlur)
                let p = MTLRenderPassDescriptor()
                p.colorAttachments[0].texture = b
                p.colorAttachments[0].loadAction = .dontCare
                p.colorAttachments[0].storeAction = .store
                if let e = cmd.makeRenderCommandEncoder(descriptor: p) {
                    var pad = mediaPad
                    e.setRenderPipelineState(padPipe)
                    e.setFragmentTexture(src, index: 0)
                    e.setFragmentBytes(&pad, length: 8, index: 0)
                    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    e.endEncoding()
                }
                blur(b, a, SIMD2(spread / Float(w), 0))
                blur(a, b, SIMD2(0, spread / Float(h)))
                blur(b, a, SIMD2(spread * 1.6 / Float(w), 0))
                blur(a, b, SIMD2(0, spread * 1.6 / Float(h)))
                mediaTex = b
            }
        }

        // Composite uniforms (the Membrane pass reads the media mapping from them too)
        var C = CompositeUniforms(
            ink: SIMD4(s.effectiveInk, 1),
            bg: SIMD4(Float(s.bgRed), Float(s.bgGreen), Float(s.bgBlue), 1),
            glow: s.glow > 0.01 ? Float(s.glow) * (1 + 1.5 * rc.beat) : 0, scan: Float(s.scanlines), vignette: Float(s.vignette),
            flicker: Float(s.flicker), bandY: Float((elapsed * 0.06).truncatingRemainder(dividingBy: 1.4) - 0.2),
            bgOpacity: Float(s.bgOpacity),
            sceneGain: 1,
            cornerR: Float(34 * s.vignette) * scale, time: Float(elapsed), pxScale: scale,
            flickerRand: Float.random(in: 0...0.06) * Float(s.flicker), grainSize: Float(s.grainSize))
        C.grade = SIMD4(Float(s.brightness), Float(max(0.2, s.contrast)), Float(s.saturation), Float(s.hueRotate))
        let pixel = 1 + Float(s.pixelate * s.pixelate) * 47 * scale
        C.fx = SIMD4(Float(s.aberration) * 24 * scale, pixel > 1.5 ? pixel : 0,
                     s.posterize > 0.01 ? Float((24 - 22 * s.posterize).rounded()) : 0, Float(s.invert))
        if let tex = mediaTex {
            let op = min(1, s.mediaOpacity + s.mediaPulse * Double(engine.analyzer.beatPulse))
            C.media = SIMD4(s.mediaBlend.shaderIndex, Float(op), Float(s.mediaDisplace) * 140 * scale, s.mediaFit.shaderIndex)
            C.media2 = SIMD4(media.aspect, mediaPad.x > 0 ? 1 : 0, mediaPad.x, mediaPad.y)
            C.mediaXf = media.motion(s, analyzer: engine.analyzer, dt: dt, frozen: frozen, reset: app.mediaMotionReset)
            C.mediaKal = SIMD4(s.mediaKaleido >= 1.5 ? Float(s.mediaKaleido.rounded()) : 0, s.mediaTile.shaderIndex, 0, 0)
        }

        // Glass Stack, Orbs and Diamond are raytraced off-screen at an adaptive resolution, then added into the scene
        var offscreen: MTLTexture?
        if let sm = builder.shaderMode, rmKindNow != nil {
            let w = max(16, Int((px.x * rmScale).rounded())), h = max(16, Int((px.y * rmScale).rounded()))
            if rmTex?.width != w || rmTex?.height != h {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: sceneFormat, width: w, height: h, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                rmTex = device.makeTexture(descriptor: d)
            }
            offscreen = rmTex
            var u = sm.u
            u.p2.x = Float(w) / sizePt.x
            let data = sm.data.isEmpty ? [Float(0)] : sm.data
            let hp = MTLRenderPassDescriptor()
            hp.colorAttachments[0].texture = offscreen
            hp.colorAttachments[0].loadAction = .clear
            hp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            hp.colorAttachments[0].storeAction = .store
            // Its own command buffer, so its GPU time can be measured by itself (that's what the scale adapts to).
            if offscreen != nil, let rmCmd = queue.makeCommandBuffer(), let e = rmCmd.makeRenderCommandEncoder(descriptor: hp),
               let buf = upload(data, into: &shaderBufs[slot]) {
                rmCmd.addCompletedHandler { [weak self] cb in
                    lock.lock(); self?.gpuMsShared = (cb.gpuEndTime - cb.gpuStartTime) * 1000; self?.rmStartShared = cb.gpuStartTime; lock.unlock()
                }
                defer { rmCmd.commit() }
                e.setRenderPipelineState(sm.kind == .glass ? glassPipe : sm.kind == .orbs ? orbsPipe : diamondPipe)
                e.setFragmentBytes(&u, length: MemoryLayout<ShaderModeUniforms>.stride, index: 0)
                e.setFragmentBuffer(buf, offset: 0, index: 2)
                e.setFragmentTexture(paletteTex, index: 0)
                if sm.kind == .orbs { e.setFragmentTexture(envMaps.texture(for: s.chromeEnv) ?? blankTex, index: 1) }
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
            }
        } else if rmTex != nil {
            rmTex = nil
        }

        let cur = scenes[sceneIndex], prev = scenes[1 - sceneIndex]
        sceneIndex = 1 - sceneIndex

        // 1. Scene
        // Shaded surfaces (Mushrooms / Primitives in Chrome or Fresnel look) are plain triangles: draw those frames
        // with 4× multisampling so their outlines are smooth. Nothing else that shares the pass needs it.
        var msaa = !(builder.trisOver.isEmpty && builder.trisAdd.isEmpty) && builder.shaderMode == nil
            && builder.spectro == nil && builder.sphere == nil && builder.particles == nil
        if msaa && (msaaTex == nil || msaaTex!.width != cur.width || msaaTex!.height != cur.height) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: sceneFormat, width: cur.width, height: cur.height, mipmapped: false)
            d.textureType = .type2DMultisample
            d.sampleCount = 4
            d.usage = .renderTarget
            d.storageMode = device.hasUnifiedMemory ? .memoryless : .private   // only the resolved picture is kept
            msaaTex = device.makeTexture(descriptor: d)
        }
        if !msaa { msaaTex = nil } else if msaaTex == nil { msaa = false }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if msaa {
            rp.colorAttachments[0].texture = msaaTex
            rp.colorAttachments[0].resolveTexture = cur
            rp.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            rp.colorAttachments[0].texture = cur
            rp.colorAttachments[0].storeAction = .store
        }
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            if let sm = builder.shaderMode {
                if let offscreen {
                    enc.setRenderPipelineState(copyAddPipe)
                    enc.setFragmentTexture(offscreen, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                } else if let buf = upload(sm.data.isEmpty ? [Float(0)] : sm.data, into: &shaderBufs[slot]) {
                    var u = sm.u
                    u.p2.x = scale
                    enc.setRenderPipelineState(sm.kind == .membrane ? membranePipe : fanPipe)
                    enc.setFragmentBytes(&u, length: MemoryLayout<ShaderModeUniforms>.stride, index: 0)
                    enc.setFragmentBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                    enc.setFragmentBuffer(buf, offset: 0, index: 2)
                    enc.setFragmentBytes(&C, length: MemoryLayout<CompositeUniforms>.stride, index: 3)
                    enc.setFragmentTexture(paletteTex, index: 0)
                    enc.setFragmentTexture(mediaTex ?? blankTex, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }
            if var sd = builder.spectro, let tex = spectroTex {
                sd.u.head = Float(spectroHead)
                sd.u.rows = Float(spectroRows)
                sd.u.cellPx = px.x / Float(sd.bands)
                enc.setRenderPipelineState(spectroPipe)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentTexture(paletteTex, index: 1)
                enc.setFragmentBytes(&sd.u, length: MemoryLayout<SpectroUniforms>.stride, index: 0)
                enc.setFragmentBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            // surfaces first, so outlines and dots sit on top
            var chromeU = ChromeUniforms(turn: Float(s.chromeTurn), blur: Float(s.chromeBlur), tint: Float(s.chromeTint),
                                         exposure: s.chromeEnv.exposure)
            let envTex = builder.trisOver.isEmpty && builder.trisAdd.isEmpty ? nil : envMaps.texture(for: s.chromeEnv)
            if let buf = upload(builder.trisOver, into: &triOverBufs[slot]) {
                enc.setRenderPipelineState(msaa ? triOverPipe4 : triOverPipe)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.setFragmentBytes(&chromeU, length: MemoryLayout<ChromeUniforms>.stride, index: 0)
                enc.setFragmentTexture(envTex ?? blankTex, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: builder.trisOver.count)
            }
            if let buf = upload(builder.trisAdd, into: &triAddBufs[slot]) {
                enc.setRenderPipelineState(msaa ? triAddPipe4 : triAddPipe)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.setFragmentBytes(&chromeU, length: MemoryLayout<ChromeUniforms>.stride, index: 0)
                enc.setFragmentTexture(envTex ?? blankTex, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: builder.trisAdd.count)
            }
            if let buf = upload(builder.lines, into: &lineBufs[slot]) {
                enc.setRenderPipelineState(msaa ? segMaxPipe4 : segMaxPipe)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: builder.lines.count)
            }
            if let buf = upload(builder.add, into: &addBufs[slot]) {
                enc.setRenderPipelineState(msaa ? segAddPipe4 : segAddPipe)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: builder.add.count)
            }
            if let sp = builder.sphere, let unitBuf, let valsBuf {
                // spikes are quads; dots and base dots are point sprites (a quarter of the vertex work)
                for (on, mode) in [(sp.spikes, UInt32(1)), (sp.baseDots, 2), (sp.dots, 0)] where on {
                    enc.setRenderPipelineState(mode == 1 ? spherePipe : sphereDotPipe)
                    enc.setVertexBuffer(unitBuf, offset: 0, index: 0)
                    enc.setVertexBuffer(valsBuf, offset: 0, index: 1)
                    enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 3)
                    enc.setVertexBuffer(histBuf ?? valsBuf, offset: 0, index: 4)
                    enc.setVertexTexture(paletteTex, index: 0)
                    var u = sp.u
                    u.mode = mode
                    u.histCols = UInt32(histCols)
                    u.head = UInt32(histHead)
                    enc.setVertexBytes(&u, length: MemoryLayout<SphereUniforms>.stride, index: 2)
                    if mode == 1 {
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: sp.n)
                    } else {
                        var square = u.square
                        enc.setFragmentBytes(&square, length: 4, index: 0)
                        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: sp.n)
                    }
                }
            }
            if let pd = builder.particles, let partBuf {
                var d = pd.draw
                let dots = d.streak <= 0
                enc.setRenderPipelineState(dots ? partDotPipe : partPipe)
                enc.setVertexBuffer(partBuf, offset: 0, index: 0)
                enc.setVertexBuffer(valsBuf ?? partBuf, offset: 0, index: 1)
                enc.setVertexBytes(&d, length: MemoryLayout<PartDrawUniforms>.stride, index: 2)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 3)
                enc.setVertexTexture(paletteTex, index: 0)
                if dots {
                    var square = d.square
                    enc.setFragmentBytes(&square, length: 4, index: 0)
                    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pd.count)
                } else {
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pd.count)
                }
            }
            // Trails + warp feedback: keep the brighter of (previous frame, warped × decay) and the new frame
            if s.mode.uses(.persistence) && (s.persistence > 0.01 || s.warp > 0.01) {
                var W = warpUniforms(s, dt: dt, time: elapsed, aspect: px.x / max(px.y, 1), beat: rc.beat)
                enc.setRenderPipelineState(msaa ? fadePipe4 : fadePipe)
                enc.setFragmentTexture(prev, index: 0)
                enc.setFragmentBytes(&W, length: MemoryLayout<WarpUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }

        // 2. Bloom, soft focus, streak: all start from the scene averaged down to ¼ size
        func pass(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, _ a: MTLTexture, _ b: MTLTexture? = nil, k: Float = 1, load: Bool = false) {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = dst
            p.colorAttachments[0].loadAction = load ? .load : .dontCare
            p.colorAttachments[0].storeAction = .store
            guard let e = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            var k = k
            e.setRenderPipelineState(pipe)
            e.setFragmentTexture(a, index: 0)
            if let b { e.setFragmentTexture(b, index: 1) }
            e.setFragmentBytes(&k, length: 4, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        let bloomOn = s.glow > 0.01
        let softOn = s.softFocus > 0.005 || s.fringe > 0.005, streakOn = s.streak > 0.005
        if bloomOn || softOn || streakOn { pass(bloomA, box4Pipe, cur) }
        if bloomOn {
            // Pyramid: halve down, then add each level back onto the one above. `wide` weights the wider levels:
            // more Glow = a wider halo (as before); the total is normalised so the glow's overall energy is unchanged.
            let wide = Float(0.5 + 0.35 * s.glow)
            var src = bloomA
            for m in bloomMips { pass(m, bloomDownPipe, src); src = m }
            if bloomMips.count > 1 {
                for i in stride(from: bloomMips.count - 2, through: 0, by: -1) { pass(bloomMips[i], bloomUpPipe, bloomMips[i + 1], k: wide, load: true) }
            }
            if let first = bloomMips.first {
                pass(bloomB, bloomTopPipe, first, bloomA, k: wide)
                C.glow /= (0...bloomMips.count).reduce(Float(0)) { $0 + pow(wide, Float($1)) }
            } else {
                pass(bloomB, bloomDownPipe, bloomA)
            }
        }
        // Soft focus / fringe: a much wider blur. Streak: vertical only, growing steps.
        let qw = Float(softA.width), qh = Float(softA.height)
        if softOn {
            blur(bloomA, softA, SIMD2(2.5 / qw, 0))
            blur(softA, softB, SIMD2(0, 2.5 / qh))
            blur(softB, softA, SIMD2(6 / qw, 0))
            blur(softA, softB, SIMD2(0, 6 / qh))
        }
        if streakOn {
            blur(bloomA, streakA, SIMD2(0, 3 / qh))
            blur(streakA, streakB, SIMD2(0, 9 / qh))
            blur(streakB, streakA, SIMD2(0, 27 / qh))
            blur(streakA, streakB, SIMD2(0, 60 / qh))
        }
        C.fx2 = SIMD4(Float(s.softFocus), Float(s.streak), Float(s.fringe) * 14 * scale, Float(s.filmGrain))

        // 4. Composite + CRT
        let fp = MTLRenderPassDescriptor()
        fp.colorAttachments[0].texture = drawable.texture
        fp.colorAttachments[0].loadAction = .dontCare
        fp.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: fp) {
            enc.setFragmentTexture(mediaTex ?? blankTex, index: 2)
            enc.setFragmentTexture(softB, index: 3)
            enc.setFragmentTexture(streakB, index: 4)
            enc.setRenderPipelineState(compositePipe)
            enc.setFragmentTexture(cur, index: 0)
            enc.setFragmentTexture(bloomB, index: 1)
            enc.setFragmentBytes(&C, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if DebugSnapshot.enabled { DebugSnapshot.capture(drawable.texture, frame: frame, cmd: cmd, device: device) }
        cmd.present(drawable)
        cmd.commit()
    }
}

/// Small deterministic RNG for layouts.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
