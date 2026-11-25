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
    /// The composite with every effect compiled in (used until the variant for the current effects is ready).
    private var compositeAll: MTLRenderPipelineState!
    /// Composite variants specialised to the effects in use (function constants CF_*), compiled in the background.
    private var compositePipes: [Int: MTLRenderPipelineState] = [:]
    private var compositePending: Set<Int> = []
    private var drawableFormat: MTLPixelFormat = .bgra8Unorm
    private var bandKernel: MTLComputePipelineState!
    private var pushKernel: MTLComputePipelineState!
    private var cymaticsKernel: MTLComputePipelineState!
    private var flowKernel: MTLComputePipelineState!
    private var partPipe: MTLRenderPipelineState!
    private var partDotPipe: MTLRenderPipelineState!
    private var sphereDotPipe: MTLRenderPipelineState!
    private var spherePrepKernel: MTLComputePipelineState!
    private var fieldKernel: MTLComputePipelineState!
    /// Field (Points style): the dots the GPU made this frame (per slot, like the uploaded splat lists)
    private var fieldSegBufs: [MTLBuffer?] = .init(repeating: nil, count: Renderer.inFlight)
    /// Spikes: every sphere point computed once per frame (SpikeP, 32 bytes each)
    private var spikeBuf: MTLBuffer?
    private var triOverPipe: MTLRenderPipelineState!
    private var triAddPipe: MTLRenderPipelineState!
    private var membranePipe: MTLRenderPipelineState!
    private var fanPipe: MTLRenderPipelineState!
    private var glassPipe: MTLRenderPipelineState!
    private var diamondPipe: MTLRenderPipelineState!
    private var orbsPipe: MTLRenderPipelineState!
    private var ferroPipe: MTLRenderPipelineState!
    private var metaballsPipe: MTLRenderPipelineState!
    /// Infinity's pipelines, specialised per structure / surface / speakers (function constants, see the shader),
    /// made on first use. The pre-pass (how far each block of pixels can skip) only depends on structure + speakers.
    private var infinityPipes: [Int: MTLRenderPipelineState] = [:]
    private var lib: MTLLibrary!
    private var infPreTex: MTLTexture?
    private var volTex: [MTLTexture?] = .init(repeating: nil, count: Renderer.inFlight)
    /// Real Metaballs' particle fluid (made on first use).
    private var ferroGPU: FerroGPU?
    /// The Forest's renderer (made on first use).
    private var forestGPU: ForestGPU?
    /// The Landscape's City scene renderer (made on first use).
    private var cityGPU: CityGPU?
    private var dreamcastGPU: DreamcastGPU?
    /// Scene-pass pipelines without the depth attachment (see `pipe(…)`), keyed by the pipeline with it.
    private var noDepth: [ObjectIdentifier: MTLRenderPipelineState] = [:]
    /// This frame's passes carry the depth target (Depth focus on).
    private var depthOn = false
    /// The pipeline matching this frame's passes: with or without the depth attachment.
    private func dz(_ p: MTLRenderPipelineState) -> MTLRenderPipelineState { depthOn ? p : noDepth[ObjectIdentifier(p)] ?? p }
    /// AUDIOWATCH_PROF=1: per-pass GPU times of the main frame (`FRAMEPROF`)
    fileprivate lazy var prof = GPUProfiler(device: device, on: GPUProfiler.frameOn, label: "FRAMEPROF")
    private lazy var zeroOcc: MTLBuffer = device.makeBuffer(length: 16 * 16 * 16 * 4, options: .storageModeShared)!
    private var copyAddPipe: MTLRenderPipelineState!
    /// Plain copy (bicubic) into a scene target: carries the trails over when the targets change size.
    private var copyScenePipe: MTLRenderPipelineState?
    /// 4× multisampled variants for frames with shaded surfaces (their triangle edges are otherwise stair-stepped).
    private var triOverPipe4: MTLRenderPipelineState!, triAddPipe4: MTLRenderPipelineState!
    private var segMaxPipe4: MTLRenderPipelineState!, segAddPipe4: MTLRenderPipelineState!, fadePipe4: MTLRenderPipelineState!
    private var msaaTex: MTLTexture?
    private var box4Pipe: MTLRenderPipelineState!
    /// Post-processing Distort: the displacement field (screen heights) at ¼ size; it's smooth, so the composite samples it.
    private var distortPipe: MTLRenderPipelineState!
    private var distTex: MTLTexture?
    /// Full-size field for Rain on glass: its drops can be a few pixels small, too fine for the ¼-size field.
    private var distTexHi: MTLTexture?
    private var bloomDownPipe: MTLRenderPipelineState!
    /// Depth of field (Camera group): half-size mipmapped copy → bokeh gather (half size) → blend over the sharp scene.
    private var dofDownPipe: MTLRenderPipelineState!, dofGatherPipe: MTLRenderPipelineState!, dofCombinePipe: MTLRenderPipelineState!
    private var dofSrc: MTLTexture?, dofBlur: MTLTexture?, dofBlurQ: MTLTexture?, dofOut: MTLTexture?
    /// Depth focus: the passes, half-size signed blur radii, 16 px tiles (max radius, dilated), how much nearer blur
    /// spills over each pixel (half / quarter size).
    private var dofPrepPipe: MTLRenderPipelineState!, dofTilePipe: MTLRenderPipelineState!, dofDilatePipe: MTLRenderPipelineState!
    private var dofDepthGatherPipe: MTLRenderPipelineState!, dofDepthCombinePipe: MTLRenderPipelineState!
    private var forestDepthPipe: MTLRenderPipelineState!, cityDepthPipe: MTLRenderPipelineState!
    private var dofCoc: MTLTexture?, dofTileA: MTLTexture?, dofTileB: MTLTexture?, dofMixH: MTLTexture?, dofMixQ: MTLTexture?
    private var dofBlurE: MTLTexture?, dofMixE: MTLTexture?, dofLit: MTLTexture?
    /// Depth: blur radii (full-size px) where the quarter-size gather hands over to the eighth-size one (= DOF_SPLIT_C/D).
    private static let dofSplitE = SIMD2<Float>(70, 90)
    /// The depth targets (scene, off-screen, big-dot splat): attachment 1 of those passes. Real textures while the Depth
    /// focus is on; else memoryless stand-ins (the scene pipelines always declare attachment 1).
    static let depthFormat: MTLPixelFormat = .rg16Float
    private var depthTargets: [String: MTLTexture] = [:]
    /// Blur radii (full-size px) where the half-size gather hands over to the quarter-size one (= DOF_SPLIT_A/B in the shader).
    private static let dofSplit = SIMD2<Float>(22, 36)
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
    /// Post-processing Distort: its own clock (runs faster with the bass) and a smoothed beat push.
    private var distortPhase: Double = 0, distortPush: Float = 0
    private var rmKind: ShaderModeKind?
    /// Infinity's surface (solid / reflective / glass): each costs differently, so the adaptive scale starts over when it changes.
    private var rmVariant: Float = -1
    private var rmFast = true      // aiming for the display's full 120 Hz (else 60)
    private var rmHold = 0         // frames to wait before the next change
    private var rmCalm = 0         // frames in a row with room to raise the scale
    private var rmCeil: Float = 1  // a scale that recently proved too expensive
    private var rmCeilAge = 0
    private var gpuEMA: Double = 0
    /// GPU time of the rest of the frame after the off-screen pass (scene, depth of field, bloom, composite): the
    /// adaptive scale's budget is the display's frame time minus this.
    private var restMsShared: Double = 0
    private var restEMA: Double = 0
    private final class TimeBox { var t: Double = 0 }
    private let gpuLock = NSLock()
    private var gpuMsShared: Double = 0
    /// The off-screen (ray-marched) pass waits on the GPU until the previous frame's main command buffer is done:
    /// otherwise, with two frames in flight, that frame's scene / depth of field / bloom / composite ran alongside it and
    /// its measured time (what the adaptive scale follows) grew with them: depth of field made Infinity's pass look
    /// 75 % slower and the scale dropped for nothing. Throughput: 0 … −3 % (the Forest −10 %: it keeps overlapping).
    /// (AUDIOWATCH_NOSERIAL=1: off, for A/B)
    /// (Shared, so a failed frame can still release the wait from the CPU.)
    private lazy var frameEvent: MTLSharedEvent? = ProcessInfo.processInfo.environment["AUDIOWATCH_NOSERIAL"] == nil ? device.makeSharedEvent() : nil
    private var frameSerial: UInt64 = 0
    private var rmStartShared: Double = 0

    // UI interaction throttle: while the settings / node editor / other panels are being used (clicks, drags, scrolling,
    // typing outside the canvas), heavy scenes render the whole frame at ⅓ resolution (the drawable shrinks, the layer
    // scales it up), so the picture keeps moving at full rate while the GPU leaves room for the UI. Otherwise a GPU kept
    // busy with 20-35 ms frames (two always queued) makes the UI's own drawing wait behind them (laggy sidebar).
    // (Was: 30 fps + half raymarch scale — the user found the near-stop annoying while changing values.)
    private weak var mtkView: MTKView?
    private var eventMonitor: Any?
    /// Main thread only. Static so UI code that swallows its events (the node editor's scroll pan) can mark itself.
    private static var uiActiveUntil: Double = 0
    static func markUIActive() { uiActiveUntil = CACurrentMediaTime() + uiGrace }
    private var uiDragOutside = false
    /// Whole-frame GPU ms of normal (not throttled) frames, written by the completion handler, smoothed in draw().
    private var frameGpuShared: Double = 0
    private var frameGpuEMA: Double = 0
    private var lastDrawStart: Double = 0
    private var wasInteracting = false
    /// The drawable is at the reduced UI size (autoResizeDrawable off) right now.
    private var uiLowRes = false
    /// Whole-frame GPU ms of the reduced (UI) frames: if even those are heavy, they're capped at 30 fps as before.
    private var uiGpuShared: Double = 0
    private var uiGpuEMA: Double = 0
    static let uiGrace = 0.6               // seconds the throttle stays on after the last UI event
    static let uiHeavyMs = 10.0            // only scenes heavier than this (whole-frame GPU ms) are throttled
    static let uiFrameInterval = 1.0 / 30
    /// Linear resolution divisor while the UI is used (3 = ⅓ width and height, 1/9 of the pixels).
    static let uiResDiv: CGFloat = 3
    /// Debug: AUDIOWATCH_UIBUSY=1 acts as if the UI were always being used (harness check of the throttle);
    /// AUDIOWATCH_UIBUSY=2,5 only between 2 and 5 s after launch (checks the switch in and out).
    private static let uiBusyEnv = ProcessInfo.processInfo.environment["AUDIOWATCH_UIBUSY"]
    private static let uiBusyWindow: (Double, Double)? = uiBusyEnv.flatMap { e in
        let p = e.split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }
    private static let launchTime = CACurrentMediaTime()
    static var forceUIBusy: Bool {
        guard uiBusyEnv != nil else { return false }
        guard let (a, b) = uiBusyWindow else { return true }
        let t = CACurrentMediaTime() - launchTime
        return t >= a && t < b
    }
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
    // (profiling runs keep one frame in flight, so passes of two frames don't overlap and inflate each other's times)
    private let semaphore = DispatchSemaphore(value: GPUProfiler.frameOn ? 1 : Renderer.inFlight)
    private var frameSlot = 0
    private var addBufs: [MTLBuffer?] = .init(repeating: nil, count: Renderer.inFlight)
    private var splatBufs: [MTLBuffer?] = .init(repeating: nil, count: Renderer.inFlight)
    /// Big dots drawn at ½ or ¼ size (`FrameBuilder.splat`); made on first use.
    private var splatTex: MTLTexture?
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
        mtkView = view
        installUIMonitor()
    }

    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }

    /// Marks UI interaction: mouse / scroll events anywhere but on the canvas (sidebar, node panel, HUD buttons,
    /// detached panels, popovers), and typing in text fields. Never consumes the event.
    private func installUIMonitor() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged,
                                           .otherMouseDown, .otherMouseDragged, .scrollWheel, .magnify, .keyDown]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            guard let self else { return e }
            let now = CACurrentMediaTime()
            switch e.type {
            case .keyDown:
                if self.app.textEditing { Renderer.uiActiveUntil = now + Renderer.uiGrace }
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                self.uiDragOutside = !self.onCanvas(e)
                if self.uiDragOutside { Renderer.uiActiveUntil = now + Renderer.uiGrace }
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp:
                // a drag belongs to where it started (a slider dragged over the canvas is still the UI)
                if self.uiDragOutside { Renderer.uiActiveUntil = now + Renderer.uiGrace }
            default:
                if !self.onCanvas(e) { Renderer.uiActiveUntil = now + Renderer.uiGrace }
            }
            return e
        }
    }

    /// The event is over the Metal canvas itself (not over SwiftUI drawn on top of it, nor another window).
    private func onCanvas(_ e: NSEvent) -> Bool {
        guard let v = mtkView, let w = v.window, e.window === w, let cv = w.contentView else { return false }
        let p = cv.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow
        guard let hit = cv.hitTest(p) else { return false }
        return hit === v || hit.isDescendant(of: v)
    }

    // MARK: - Setup

    private func buildPipelines(_ drawableFormat: MTLPixelFormat) throws {
        let opts = MTLCompileOptions()
        // debug: AUDIOWATCH_SHADER_DEFS=A,B defines preprocessor macros (A/B timing of compiled-out code)
        var defs: [String: NSObject] = [:]
        for d in (ProcessInfo.processInfo.environment["AUDIOWATCH_SHADER_DEFS"] ?? "").split(separator: ",") { defs[String(d)] = NSNumber(value: 1) }
        opts.preprocessorMacros = defs
        let lib = try device.makeLibrary(source: shaderSource, options: opts)
        self.lib = lib
        func fn(_ n: String) -> MTLFunction { lib.makeFunction(name: n)! }
        enum Blend { case none, add, max, over }
        /// Attachment 1 (depth of field's depth, rg16Float): none = not there (post passes); off = there, never written
        /// (flat content: its pixels take the scene plane's depth); add / over = blended like light / shaded surfaces;
        /// write = replaced (the off-screen ray-marched passes).
        enum DepthOut { case none, off, add, over, write }
        func pipe(_ v: String, _ f: String, _ fmt: MTLPixelFormat, _ blend: Blend, points: Bool = false, samples: Int = 1,
                  depth: DepthOut = .none) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            if depth != .none {
                let da = d.colorAttachments[1]!
                da.pixelFormat = Renderer.depthFormat
                switch depth {
                case .off: da.writeMask = []
                case .add, .over:
                    da.isBlendingEnabled = true
                    da.rgbBlendOperation = .add; da.alphaBlendOperation = .add
                    da.sourceRGBBlendFactor = .one; da.sourceAlphaBlendFactor = .one
                    da.destinationRGBBlendFactor = depth == .over ? .oneMinusSourceAlpha : .one
                    da.destinationAlphaBlendFactor = depth == .over ? .oneMinusSourceAlpha : .one
                default: break
                }
            }
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
            let main = try device.makeRenderPipelineState(descriptor: d)
            if depth != .none {
                // twin without attachment 1, for frames without Depth focus (the pass then has no depth target at all:
                // blending a second target nobody reads cost ~10 % in blend-heavy scenes)
                d.colorAttachments[1] = nil
                noDepth[ObjectIdentifier(main)] = try device.makeRenderPipelineState(descriptor: d)
            }
            return main
        }
        segAddPipe = try pipe("segVert", "segFrag", sceneFormat, .add, depth: .add)
        segMaxPipe = try pipe("segVert", "segFrag", sceneFormat, .max, depth: .add)
        spherePipe = try pipe("sphereVert", "segFrag", sceneFormat, .add, depth: .add)
        spectroPipe = try pipe("fsVert", "spectroFrag", sceneFormat, .add, depth: .off)
        fadePipe = try pipe("fsVert", "fadeFrag", sceneFormat, .max, depth: .off)
        blurPipe = try pipe("fsVert", "blurFrag", sceneFormat, .none)
        padPipe = try pipe("fsVert", "padFrag", sceneFormat, .none)
        self.drawableFormat = drawableFormat
        compositeAll = try compositeDescriptor(mask: Renderer.compositeAllMask).map { try device.makeRenderPipelineState(descriptor: $0) }
        bandKernel = try device.makeComputePipelineState(function: fn("bandKernel"))
        pushKernel = try device.makeComputePipelineState(function: fn("pushKernel"))
        spherePrepKernel = try device.makeComputePipelineState(function: fn("spherePrepKernel"))
        fieldKernel = try device.makeComputePipelineState(function: fn("fieldKernel"))
        cymaticsKernel = try device.makeComputePipelineState(function: fn("cymaticsKernel"))
        flowKernel = try device.makeComputePipelineState(function: fn("flowKernel"))
        partPipe = try pipe("partVert", "streakFrag", sceneFormat, .add, depth: .off)
        partDotPipe = try pipe("partDotVert", "dotFrag", sceneFormat, .add, points: true, depth: .off)
        sphereDotPipe = try pipe("sphereDotVert", "dotFrag", sceneFormat, .add, points: true, depth: .add)
        triOverPipe = try pipe("triVert", "triFrag", sceneFormat, .over, depth: .over)
        triAddPipe = try pipe("triVert", "triFrag", sceneFormat, .add, depth: .add)
        membranePipe = try pipe("fsVert", "membraneFrag", sceneFormat, .add, depth: .off)
        fanPipe = try pipe("fsVert", "fanFrag", sceneFormat, .add, depth: .off)
        glassPipe = try pipe("fsVert", "glassFrag", sceneFormat, .none, depth: .write)
        diamondPipe = try pipe("fsVert", "diamondFrag", sceneFormat, .none, depth: .write)
        orbsPipe = try pipe("fsVert", "orbsFrag", sceneFormat, .none, depth: .write)
        ferroPipe = try pipe("fsVert", "ferroFrag", sceneFormat, .none, depth: .write)
        metaballsPipe = try pipe("fsVert", "metaballsFrag", sceneFormat, .none, depth: .write)
        copyAddPipe = try pipe("fsVert", "copyFrag", sceneFormat, .add, depth: .add)
        copyScenePipe = try pipe("fsVert", "copyFrag", sceneFormat, .none)
        triOverPipe4 = try pipe("triVert", "triFrag", sceneFormat, .over, samples: 4, depth: .over)
        triAddPipe4 = try pipe("triVert", "triFrag", sceneFormat, .add, samples: 4, depth: .add)
        segMaxPipe4 = try pipe("segVert", "segFrag", sceneFormat, .max, samples: 4, depth: .add)
        segAddPipe4 = try pipe("segVert", "segFrag", sceneFormat, .add, samples: 4, depth: .add)
        fadePipe4 = try pipe("fsVert", "fadeFrag", sceneFormat, .max, samples: 4, depth: .off)
        box4Pipe = try pipe("fsVert", "box4Frag", sceneFormat, .none)
        distortPipe = try pipe("fsVert", "distortFrag", .rgba16Float, .none)
        bloomDownPipe = try pipe("fsVert", "bloomDownFrag", sceneFormat, .none)
        bloomUpPipe = try pipe("fsVert", "bloomUpFrag", sceneFormat, .add)
        bloomTopPipe = try pipe("fsVert", "bloomTopFrag", sceneFormat, .none)
        dofDownPipe = try pipe("fsVert", "dofDownFrag", sceneFormat, .none)
        dofGatherPipe = try pipe("fsVert", "dofGatherFrag", sceneFormat, .none)
        dofCombinePipe = try pipe("fsVert", "dofCombineFrag", sceneFormat, .none)
        func mrt(_ f: String, _ fmts: [MTLPixelFormat]) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = fn("fsVert")
            d.fragmentFunction = fn(f)
            for (i, fmt) in fmts.enumerated() { d.colorAttachments[i].pixelFormat = fmt }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        dofPrepPipe = try mrt("dofPrepFrag", [sceneFormat, .r16Float, .r16Float])
        dofTilePipe = try mrt("dofTileFrag", [.r16Float])
        dofDilatePipe = try mrt("dofDilateFrag", [.r16Float])
        dofDepthGatherPipe = try mrt("dofDepthGatherFrag", [sceneFormat, .r16Float])
        dofDepthCombinePipe = try mrt("dofDepthCombineFrag", [sceneFormat])
        forestDepthPipe = try mrt("forestDepthFrag", [Renderer.depthFormat])
        cityDepthPipe = try mrt("cityDepthFrag", [Renderer.depthFormat])
    }

    /// Infinity's pipeline for these uniforms (pre = the quarter-size pre-pass), compiled the first time it's needed.
    private func infinityPipe(_ u: ShaderModeUniforms, pre: Bool) -> MTLRenderPipelineState? {
        let kind = Int32(u.p2.w.rounded()), spk = u.p1.z > 0.5
        let surf = pre ? 0 : Int32(u.p1.y.rounded()), dbg = pre ? 0 : Int32(u.p1.w.rounded())
        let key = ((((Int(kind) * 4 + Int(surf)) * 2 + (spk ? 1 : 0)) * 8 + Int(dbg)) * 2 + (pre ? 1 : 0)) * 2 + (depthOn ? 1 : 0)
        if let p = infinityPipes[key] { return p }
        let cv = MTLFunctionConstantValues()
        var k = kind, sf = surf, sp = spk, db = dbg
        cv.setConstantValue(&k, type: .int, index: 0)
        cv.setConstantValue(&sf, type: .int, index: 1)
        cv.setConstantValue(&sp, type: .bool, index: 2)
        cv.setConstantValue(&db, type: .int, index: 3)
        do {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fsVert")
            d.fragmentFunction = try lib.makeFunction(name: pre ? "infinityPreFrag" : "infinityFrag", constantValues: cv)
            d.colorAttachments[0].pixelFormat = pre ? .r32Float : sceneFormat
            if !pre && depthOn { d.colorAttachments[1].pixelFormat = Renderer.depthFormat }
            let t0 = CACurrentMediaTime()
            let p = try device.makeRenderPipelineState(descriptor: d)
            if Renderer.perf { print(String(format: "PIPE infinity key=%d %.0f ms", key, (CACurrentMediaTime() - t0) * 1000)) }
            infinityPipes[key] = p
            return p
        } catch {
            NSLog("soundwatch: infinity pipeline error \(error)")
            return nil
        }
    }

    private static let compositeFlags = 11
    private static let compositeAllMask = (1 << compositeFlags) - 1

    private func compositeDescriptor(mask: Int) throws -> MTLRenderPipelineDescriptor? {
        let cv = MTLFunctionConstantValues()
        for i in 0..<Renderer.compositeFlags {
            var on = mask & (1 << i) != 0
            cv.setConstantValue(&on, type: .bool, index: 10 + i)
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "fsVert")
        d.fragmentFunction = try lib.makeFunction(name: "compositeFrag", constantValues: cv)
        d.colorAttachments[0].pixelFormat = drawableFormat
        return d
    }

    /// Which composite effects this frame uses (bit i = function constant 10 + i in the shader).
    private static func compositeMask(_ C: CompositeUniforms) -> Int {
        let flags = [C.glow > 0, C.media.x >= 0, C.media.x >= 0 && C.media.z > 0, C.dist.x > 0.5 && C.dist.y > 0,
                     C.fx.x > 0, C.fx2.z > 0, C.fx2.x > 0, C.fx2.y > 0,
                     C.grade.y != 1 || C.grade.w != 0 || C.fx.z >= 2 || C.fx.w > 0,
                     C.fx2.w > 0,
                     C.fx.y > 1 || C.flicker != 0 || C.scan != 0 || C.flickerRand != 0 || C.vignette != 0 || C.cornerR != 0]
        return flags.enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) }
    }

    /// The composite pipeline for these effects; the all-effects one while that variant is still compiling.
    private func compositePipe(_ C: CompositeUniforms) -> MTLRenderPipelineState {
        let mask = Renderer.compositeMask(C)
        if let p = compositePipes[mask] { return p }
        if !compositePending.contains(mask), let d = try? compositeDescriptor(mask: mask) {
            compositePending.insert(mask)
            device.makeRenderPipelineState(descriptor: d) { [weak self] p, err in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let p { self.compositePipes[mask] = p } else { NSLog("soundwatch: composite variant error \(String(describing: err))") }
                }
            }
        }
        return compositeAll
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        makeTargets(size)
    }

    /// While the UI is used, heavy scenes draw into a drawable of ⅓ the size (the layer scales it up); afterwards it
    /// follows the view again. Called once per frame; does nothing in the normal state.
    private func applyUIResolution(_ view: MTKView, low: Bool) {
        guard low || uiLowRes else { return }
        let full = view.convertToBacking(view.bounds).size
        guard full.width > 0, full.height > 0 else { return }
        if low != uiLowRes {
            uiLowRes = low
            view.autoResizeDrawable = !low
        }
        let want = low ? CGSize(width: max(16, (full.width / Renderer.uiResDiv).rounded()),
                                height: max(16, (full.height / Renderer.uiResDiv).rounded())) : full
        if view.drawableSize != want { view.drawableSize = want }   // → drawableSizeWillChange → makeTargets
    }

    private func makeTargets(_ size: CGSize) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        if let t = scenes.first, t.width == w, t.height == h { return }
        // the last finished frame (it's next frame's `prev`): scaled into the new targets so trails carry on
        let carry = scenes.count == 2 ? scenes[1 - sceneIndex] : nil
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
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, w / 4), height: max(1, h / 4), mipmapped: false)
        dd.usage = [.renderTarget, .shaderRead]
        dd.storageMode = .private
        distTex = device.makeTexture(descriptor: dd)
        dd.width = w; dd.height = h
        distTexHi = device.makeTexture(descriptor: dd)
        rmTex = nil
        msaaTex = nil
        splatTex = nil
        dofSrc = nil; dofBlur = nil; dofBlurQ = nil; dofOut = nil
        bloomMips = []
        var mw = max(1, w / 4), mh = max(1, h / 4)
        while bloomMips.count < 5 && min(mw, mh) >= 16 {
            mw = max(1, mw / 2); mh = max(1, mh / 2)
            bloomMips.append(tex(mw, mh))
        }
        // Fresh GPU memory is garbage (often NaN in half floats): clear every target once so nothing stale leaks into
        // trails, bloom or the composite before it's first written.
        if let cmd = queue.makeCommandBuffer() {
            if let carry, let copyScenePipe {
                for t in scenes {
                    let rp = MTLRenderPassDescriptor()
                    rp.colorAttachments[0].texture = t
                    rp.colorAttachments[0].loadAction = .dontCare
                    rp.colorAttachments[0].storeAction = .store
                    guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { continue }
                    enc.setRenderPipelineState(copyScenePipe)
                    enc.setFragmentTexture(carry, index: 0)
                    enc.setFragmentTexture(carry, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
            for t in (carry != nil && copyScenePipe != nil ? [] : scenes) + bloomMips + [bloomA!, bloomB!, softA!, softB!, streakA!, streakB!] {
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
        let key = s.palette.rawValue
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

    /// A 3D half-float texture per in-flight frame, refilled from the CPU (Real Metaballs' density field).
    private func uploadVolume(_ v: [UInt16], size: SIMD3<Int>, slot: Int) -> MTLTexture? {
        guard v.count == size.x * size.y * size.z, v.count > 0 else { return nil }
        var t = volTex[slot]
        if t == nil || t!.width != size.x || t!.height != size.y || t!.depth != size.z {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = .r16Float
            d.width = size.x; d.height = size.y; d.depth = size.z
            d.usage = .shaderRead
            d.storageMode = .shared
            t = device.makeTexture(descriptor: d)
            volTex[slot] = t
        }
        guard let t else { return nil }
        v.withUnsafeBytes { b in
            t.replace(region: MTLRegionMake3D(0, 0, 0, size.x, size.y, size.z), mipmapLevel: 0, slice: 0,
                      withBytes: b.baseAddress!, bytesPerRow: size.x * 2, bytesPerImage: size.x * size.y * 2)
        }
        return t
    }

    /// Field on the GPU: (re)fills its buffers from the CPU arrays when they're newer, then steps the particles and
    /// writes their dots into this slot's list (drawn by the splat path like an uploaded list).
    private func encodeField(_ ce: MTLComputeCommandEncoder, _ fd: FieldGPUDraw, slot: Int) {
        let st = fd.state, n = Int(fd.u.count)
        guard st.pos.count == n, st.home.count == n, st.vel.count == n else { return }
        if st.bufVersion != st.version || (st.posBuf?.length ?? 0) < n * 16 {
            st.homeBuf = device.makeBuffer(length: n * 16, options: .storageModeShared)
            st.posBuf = device.makeBuffer(length: n * 16, options: .storageModeShared)
            st.velBuf = device.makeBuffer(length: n * 16, options: .storageModeShared)
            st.bufVersion = st.version
            st.gpu = false
        }
        guard let hb = st.homeBuf, let pb = st.posBuf, let vb = st.velBuf else { return }
        if !st.gpu {   // the CPU arrays hold the state (new particles, or the Lines path ran): hand it over
            st.home.withUnsafeBytes { hb.contents().copyMemory(from: $0.baseAddress!, byteCount: n * 16) }
            st.pos.withUnsafeBytes { pb.contents().copyMemory(from: $0.baseAddress!, byteCount: n * 16) }
            st.vel.withUnsafeBytes { vb.contents().copyMemory(from: $0.baseAddress!, byteCount: n * 16) }
            st.gpu = true
        }
        if (fieldSegBufs[slot]?.length ?? 0) < n * MemoryLayout<Seg>.stride {
            fieldSegBufs[slot] = device.makeBuffer(length: n * MemoryLayout<Seg>.stride * 5 / 4, options: .storageModePrivate)
        }
        guard let out = fieldSegBufs[slot] else { return }
        var u = fd.u
        ce.setComputePipelineState(fieldKernel)
        ce.setBuffer(hb, offset: 0, index: 0)
        ce.setBuffer(pb, offset: 0, index: 1)
        ce.setBuffer(vb, offset: 0, index: 2)
        ce.setBuffer(out, offset: 0, index: 3)
        ce.setBytes(&u, length: MemoryLayout<FieldUniforms>.stride, index: 4)
        fd.bodies.withUnsafeBytes { ce.setBytes($0.baseAddress!, length: $0.count, index: 5) }
        fd.stops.withUnsafeBytes { ce.setBytes($0.baseAddress!, length: max(16, $0.count), index: 6) }
        ce.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: min(256, fieldKernel.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
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
    /// With Anti-aliasing on, the scale may go above 1 (supersampling, enlarged → reduced by `copyFrag`) when the budget allows.
    private func updateRaymarchScale(_ kind: ShaderModeKind, maxFPS: Int, maxScale: Float) {
        // Dreamcast: its CRT pass is cheap and needs the full output resolution (its pixelation is a setting)
        if kind == .dreamcast { rmKind = kind; rmScale = 1; return }
        if let fixed = Renderer.fixedScale { rmKind = kind; rmScale = fixed; return }
        // Real Metaballs shares the GPU with its fluid simulation, which makes its pass look slower than it is: never
        // below half resolution there (at 0.2 its edges were visibly stair-stepped)
        defer { if kind == .metaballs { rmScale = max(rmScale, min(maxScale, 0.5)) } }
        // Infinity's fractal is all fine edges, which turn to stair-steps when enlarged a lot (user: "quite jaggy"):
        // rather a lower frame rate than less than 0.4 of the resolution (0.3 for the much heavier glass surfaces)
        defer { if kind == .infinity { rmScale = max(rmScale, min(maxScale, rmVariant < 1.5 ? 0.4 : 0.3)) } }
        // the Forest is drawn with 4× MSAA: never above 1 (supersampling on top would be wasted), never below 0.5
        defer { if kind == .forest { rmScale = min(1, max(rmScale, min(maxScale, 0.5))) } }
        // the City is all straight edges and small windows: rather a lower frame rate than less than 0.45
        defer { if kind == .city { rmScale = max(rmScale, min(maxScale, 0.45)) } }
        if rmScale > maxScale { rmScale = maxScale; rmCeil = maxScale }
        if rmKind != kind {
            rmKind = kind; rmScale = 0.5; rmHold = 12; rmCalm = 0; gpuEMA = 0; rmFast = true; rmCeil = maxScale; rmCeilAge = 0
            restEMA = 0
            gpuLock.lock(); gpuMsShared = 0; restMsShared = 0; gpuLock.unlock()
            return
        }
        gpuLock.lock(); let g = gpuMsShared, rest = restMsShared; gpuLock.unlock()
        guard g > 0 else { return }
        gpuEMA = gpuEMA == 0 ? g : gpuEMA * 0.75 + g * 0.25
        if rest > 0 && rest < 200 { restEMA = restEMA == 0 ? rest : restEMA * 0.9 + rest * 0.1 }
        if rmHold > 0 { rmHold -= 1; return }
        func fit(_ budget: Double) -> Float { rmScale * Float((budget / max(gpuEMA, 0.05)).squareRoot()) }
        // The pass's budget: the frame time (with a little slack) minus what the rest of the frame takes on the GPU, kept
        // within 0.6 … 1.6× of the old fixed budgets (which assumed ~6 ms / ~4 ms for the rest). Depth of field, bloom
        // etc. on a big window take more than that (frames missed the display's rate), a light frame leaves more.
        func budget(_ periodMs: Double, _ old: Double) -> Double {
            restEMA > 0 ? min(max(periodMs * 0.92 - restEMA, old * 0.6), old * 1.6) : old
        }
        var target = fit(budget(1000 / 60, 9.5))                  // 60 fps
        if maxFPS >= 100 {
            let fast = fit(budget(1000 / 120, 3.3))               // 120 fps
            if rmFast { if fast < 0.5 { rmFast = false } } else if fast > 0.68 { rmFast = true }
            if rmFast { target = fast }
        }
        target = min(maxScale, max(0.2, target))
        // After a drop, the scale that proved too expensive is remembered as a ceiling for ~10 s, so the scale
        // settles just under it instead of creeping back up and dropping again (visible as wobbling sharpness).
        rmCeilAge += 1
        if rmCeilAge > 1200 { rmCeil = maxScale }
        if target < rmScale * 0.9 {
            rmCeil = rmScale; rmCeilAge = 0
            rmScale = max(0.2, target * 0.95); rmHold = 12; rmCalm = 0
        } else if rmScale < maxScale {
            let goal = min(maxScale, min(target * 0.9, rmCeil * 0.9))
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
    /// Debug: AUDIOWATCH_CAMERA='{"yaw":0.5,"pitch":0.6,"zoom":1}' pins the orbit (harness stills of tilted / turned views).
    static let debugCamera: CameraState? = ProcessInfo.processInfo.environment["AUDIOWATCH_CAMERA"]
        .flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(DebugCam.self, from: $0) }
        .map { CameraState(yaw: $0.yaw ?? 0, pitch: $0.pitch ?? 0, zoom: $0.zoom ?? 1) }
    private struct DebugCam: Decodable { var yaw: Float?; var pitch: Float?; var zoom: Float? }
    /// Debug aid: AUDIOWATCH_RMSCALE=0.5 pins the resolution scale of the raymarched modes (for comparing timings).
    static let fixedScale = ProcessInfo.processInfo.environment["AUDIOWATCH_RMSCALE"].flatMap { Float($0) }

    func draw(in view: MTKView) {
        // Rendering runs on the main thread: if the GPU still has both frames in flight, skip this tick instead of
        // blocking (blocking here froze sidebar scrolling and other UI in heavy modes). The display link retries next vsync.
        let tick = CACurrentMediaTime()
        // While the UI is being used, heavy scenes leave the GPU room for it: the whole frame at ⅓ resolution
        // (and at most 30 fps only if even that is still heavy).
        let interacting = (Renderer.forceUIBusy || tick < Renderer.uiActiveUntil) && frameGpuEMA > Renderer.uiHeavyMs
        if interacting && uiGpuEMA > Renderer.uiHeavyMs && tick - lastDrawStart < Renderer.uiFrameInterval - 0.003 { return }
        guard semaphore.wait(timeout: DebugSnapshot.enabled ? .distantFuture : .now()) == .success else { return }
        applyUIResolution(view, low: interacting)
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { semaphore.signal(); return }
        // Keep targets exactly the drawable size (the size-change callback can lag behind the first frames).
        if scenes.isEmpty || scenes[0].width != Int(view.drawableSize.width) || scenes[0].height != Int(view.drawableSize.height) {
            makeTargets(view.drawableSize)
        }
        lastDrawStart = tick
        if wasInteracting && !interacting { rmHold = max(rmHold, 6) }   // let the reduced frames' timings drain first
        if interacting && !wasInteracting { uiGpuEMA = 0 }
        wasInteracting = interacting
        gpuLock.lock(); let fg = frameGpuShared, ug = uiGpuShared; uiGpuShared = 0; gpuLock.unlock()
        if fg > 0 { frameGpuEMA = frameGpuEMA == 0 ? fg : frameGpuEMA * 0.9 + fg * 0.1 }
        if interacting && ug > 0 { uiGpuEMA = uiGpuEMA == 0 ? ug : uiGpuEMA * 0.8 + ug * 0.2 }
        // Take the drawable before analysing the audio: if this has to wait for a free one, the audio read afterwards
        // is that much fresher when the frame reaches the screen.
        guard let drawable = view.currentDrawable else { semaphore.signal(); return }
        // Right after a size change (the UI's reduced resolution in / out) the view can still hand out a drawable of the
        // old size for one frame: drawn into, the picture would sit in a corner. Skip that frame.
        if drawable.texture.width != scenes[0].width || drawable.texture.height != scenes[0].height { semaphore.signal(); return }

        let frozen = app.frozen
        let now = DebugClock.fps != nil ? DebugClock.step() : CACurrentMediaTime()
        if startTime == nil { startTime = now }
        let elapsed = now - startTime!
        let dt = min(max(lastTime.map { now - $0 } ?? 1 / 60, 1e-4), 0.1)
        lastTime = now
        frame += 1
        fps = fps * 0.95 + (1 / dt) * 0.05
        engine.fps = fps

        // pixels per point of the drawable: the backing scale, or ⅓ of it while the UI runs at reduced resolution
        let scale = Float(view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : view.window?.backingScaleFactor ?? 2)
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
        if let dc = Renderer.debugCamera { cam.yaw = dc.yaw; cam.pitch = dc.pitch; if dc.zoom != 1 { cam.zoom = dc.zoom } }
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
        let rmEnd = TimeBox()   // this frame's off-screen pass: when it ended on the GPU
        let rmKindNow = builder.shaderMode.flatMap { [.glass, .diamond, .orbs, .ferro, .metaballs, .infinity, .forest, .city, .dreamcast].contains($0.kind) ? $0.kind : nil }
        let variant = rmKindNow == .infinity ? (builder.shaderMode?.u.p1.y ?? 0) : 0   // Infinity's surface: each costs differently
        if variant != rmVariant { rmVariant = variant; rmKind = nil }
        if let rmKindNow {
            // while interacting, the adaptive scale is frozen (its timings would be the reduced-resolution ones)
            if !interacting { updateRaymarchScale(rmKindNow, maxFPS: view.window?.screen?.maximumFramesPerSecond ?? 60,
                                                  maxScale: s.antialias ? 1.5 : 1) }
        } else { rmKind = nil }
        // While interacting px itself is ⅓: the raymarched pass keeps the absolute resolution it had under the old
        // throttle (half its scale of the full size), since at ⅓ × scale Infinity's cone hits turned the empty gap into haze.
        let rmScaleNow = interacting && rmKindNow != .dreamcast ? min(1.5, max(0.15, rmScale * 0.5) * Float(Renderer.uiResDiv)) : rmScale
        let perfScale = rmKindNow == nil ? -1 : rmScaleNow
        cmd.addCompletedHandler { [weak self] cb in
            if let e = cb.error { NSLog("soundwatch: GPU frame failed: \(e)") }
            // gpu = the whole frame; rm = the off-screen raymarch pass, which runs in its own command buffer just
            // before this one (so the frame is timed from that pass's start)
            lock.lock(); let rm = self?.gpuMsShared ?? 0, rmStart = self?.rmStartShared ?? 0; lock.unlock()
            let start = perfScale < 0 || rmStart <= 0 ? cb.gpuStartTime : min(cb.gpuStartTime, rmStart)
            let frameMs = (cb.gpuEndTime - start) * 1000
            if frameMs > 0, frameMs < 1000 {
                lock.lock()
                if interacting { self?.uiGpuShared = frameMs } else { self?.frameGpuShared = frameMs }
                lock.unlock()
            }
            lock.lock()
            if !interacting, perfScale >= 0, rmEnd.t > 0, cb.gpuEndTime >= rmEnd.t { self?.restMsShared = (cb.gpuEndTime - rmEnd.t) * 1000 }
            lock.unlock()
            if Renderer.perf {
                print(String(format: "PERF cpu=%.2f gpu=%.2f rm=%.2f scale=%.2f fluid=%.2f t=%.4f%@", cpuMs, frameMs,
                             perfScale < 0 ? 0 : rm, abs(perfScale), self?.ferroGPU?.gpuMs ?? 0, cb.gpuEndTime,
                             (interacting ? " ui" : "") as NSString))
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
        prof?.begin()
        let cpd = MTLComputePassDescriptor()
        prof?.compute(cpd, "compute")
        if let ce = cmd.makeComputeCommandEncoder(descriptor: cpd) {
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
            // Sphere spikes: each point once (after the history push, which it reads)
            if let sp = builder.sphere, sp.spikes, let unitBuf, let valsBuf {
                if (spikeBuf?.length ?? 0) < sp.n * 32 { spikeBuf = device.makeBuffer(length: sp.n * 32, options: .storageModePrivate) }
                if let spikeBuf {
                    var u = sp.u
                    u.mode = 1; u.histCols = UInt32(histCols); u.head = UInt32(histHead)
                    ce.setComputePipelineState(spherePrepKernel)
                    ce.setBuffer(unitBuf, offset: 0, index: 0)
                    ce.setBuffer(valsBuf, offset: 0, index: 1)
                    ce.setBytes(&u, length: MemoryLayout<SphereUniforms>.stride, index: 2)
                    ce.setBuffer(histBuf ?? valsBuf, offset: 0, index: 4)
                    ce.setBuffer(spikeBuf, offset: 0, index: 5)
                    ce.setTexture(paletteTex, index: 0)
                    ce.dispatchThreads(MTLSize(width: sp.n, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: min(256, spherePrepKernel.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
                }
            } else if spikeBuf != nil { spikeBuf = nil }
            // Field (Points style): step the particles and make their dots
            if let fd = builder.field, fd.u.count > 0 { encodeField(ce, fd, slot: slot) }
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
            prof?.render(p, "blur")
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
                prof?.render(p, "mediaPad")
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
            glow: s.glow > 0.01 ? Float(s.glow) * (1 + 1.5 * rc.beat) : 0, scan: s.mode == .dreamcast ? 0 : Float(s.scanlines),   // Dreamcast: its CRT style draws its own
            vignette: Float(s.vignette),
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
        if s.distort != .none && s.distortAmt > 0.001 {
            if !frozen {
                let bass = Double(min(1.2, engine.analyzer.level(20, 140, s: s)))
                let speed = max(0, s.distortSpeed)
                distortPhase += dt * speed * (0.5 + 1.5 * bass)
                distortPush = max(rc.beat, distortPush * Float(exp(-dt * 4)))
            }
            C.dist = SIMD4(s.distort.shaderIndex, Float(s.distortAmt), Float(distortPhase.truncatingRemainder(dividingBy: 4096)), distortPush)
            C.dist2 = SIMD4(Float(min(4, max(0.25, s.distortScale))), 0, 0, 0)
        }
        if let k = builder.shaderMode?.kind, k == .metaballs || k == .ferro || k == .infinity || k == .forest || k == .city || k == .dreamcast { C.mediaKal.z = 1 }
        if builder.shaderMode?.kind == .forest {
            // The Forest is a whole lit daylight picture with its own tone mapping: Brightness goes into its exposure
            // (ForestViz) instead of multiplying the finished picture, and Glow (which adds the blurred picture back
            // on top) is scaled down. With looks made for dark scenes (Brightness 0.9 + Glow 0.75) it was pure white.
            C.grade.x = 0
            C.glow *= 0.2
        }
        // Dreamcast is a whole bright picture too, and its CRT pass has its own halation: Glow is toned down
        if builder.shaderMode?.kind == .dreamcast { C.glow *= 0.3 }

        // Depth of field with the Depth focus: the scene pass (and the off-screen / splat passes feeding it) keep a depth target
        let depthDOF = s.dofAmount > 0.001 && s.dofFocusMode == .depth
        depthOn = depthDOF
        var rmDepth: MTLTexture?

        // Glass Stack, Orbs and Diamond are raytraced off-screen at an adaptive resolution, then added into the scene
        var offscreen: MTLTexture?
        if let sm = builder.shaderMode, rmKindNow != nil {
            let w = max(16, Int((px.x * rmScaleNow).rounded())), h = max(16, Int((px.y * rmScaleNow).rounded()))
            if rmTex?.width != w || rmTex?.height != h {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: sceneFormat, width: w, height: h, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                rmTex = device.makeTexture(descriptor: d)
            }
            offscreen = rmTex
            var u = sm.u
            var smData = sm.data
            DebugReplay.apply(&u, &smData)
            u.p2.x = Float(w) / sizePt.x
            if let fin = sm.ferro, let fg = ferroGPU, fg.restRadius > 0 {
                // Real Metaballs at rest: blend the drawn surface into a perfect sphere of the liquid's volume
                u.p2.y = fin.rest * fg.restDraw; u.p2.z = fg.restRadius; u.p2.w = fg.restY
            }
            let data = smData.isEmpty ? [Float(0)] : smData
            let hp = MTLRenderPassDescriptor()
            hp.colorAttachments[0].texture = offscreen
            hp.colorAttachments[0].loadAction = .clear
            hp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            hp.colorAttachments[0].storeAction = .store
            let rmD = depthTarget("rm", w, h, keep: depthDOF)
            attachDepth(hp, rmD, keep: depthDOF)
            if depthDOF { rmDepth = rmD }
            // Its own command buffer, so its GPU time can be measured by itself (that's what the scale adapts to).
            if offscreen != nil, let rmCmd = queue.makeCommandBuffer(), let buf = upload(data, into: &shaderBufs[slot]) {
                // (not the Forest: its geometry gains ~10 % from overlapping the previous frame's full-screen passes, and
                // its scale is clamped to 0.5 … 1 anyway; the others lose 0 … 3 % and get honest timings)
                if let frameEvent, frameSerial > 0, sm.forest == nil { rmCmd.encodeWaitForEvent(frameEvent, value: frameSerial) }
                if sm.kind == .infinity {
                    // quarter-size pre-pass first (same command buffer, so the measured time covers both)
                    let pw = max(4, w / 4), ph = max(4, h / 4)
                    if infPreTex?.width != pw || infPreTex?.height != ph {
                        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: pw, height: ph, mipmapped: false)
                        d.usage = [.renderTarget, .shaderRead]
                        d.storageMode = .private
                        infPreTex = device.makeTexture(descriptor: d)
                    }
                    let pp = MTLRenderPassDescriptor()
                    pp.colorAttachments[0].texture = infPreTex
                    pp.colorAttachments[0].loadAction = .dontCare
                    pp.colorAttachments[0].storeAction = .store
                    if infPreTex != nil, let prePipe = infinityPipe(u, pre: true), let pe = rmCmd.makeRenderCommandEncoder(descriptor: pp) {
                        var pu = u
                        pu.p2.x = Float(pw) / sizePt.x
                        pe.setRenderPipelineState(prePipe)
                        pe.setFragmentBytes(&pu, length: MemoryLayout<ShaderModeUniforms>.stride, index: 0)
                        pe.setFragmentBuffer(buf, offset: 0, index: 2)
                        pe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        pe.endEncoding()
                    }
                } else {
                    infPreTex = nil
                }
                if let fin = sm.forest, let target = offscreen {
                    // the Forest draws itself (shadow maps, terrain, trees, water) into the off-screen target
                    if forestGPU == nil { forestGPU = ForestGPU(device: device, queue: queue) }
                    rmCmd.addCompletedHandler { [weak self] cb in
                        lock.lock(); self?.gpuMsShared = (cb.gpuEndTime - cb.gpuStartTime) * 1000; self?.rmStartShared = cb.gpuStartTime; rmEnd.t = cb.gpuEndTime; lock.unlock()
                    }
                    forestGPU?.keepDepth = depthDOF
                    forestGPU?.encode(cmd: rmCmd, target: target, input: fin, bands: buf, slot: slot)
                    if depthDOF, let dt = forestGPU?.depthTexture, let rmD {
                        // its depth buffer → inverse depth (near plane 0.25 m; 25 m counts as the subject)
                        depthConvert(rmCmd, forestDepthPipe, dt, into: rmD, k: SIMD2(ForestGPU.near, 25))
                    }
                    rmCmd.commit()
                } else if let din = sm.dreamcast, let target = offscreen {
                    // Dreamcast: the layer stack at console resolution, then the CRT pass into the off-screen target
                    if dreamcastGPU == nil { dreamcastGPU = DreamcastGPU(device: device) }
                    rmCmd.addCompletedHandler { [weak self] cb in
                        lock.lock(); self?.gpuMsShared = (cb.gpuEndTime - cb.gpuStartTime) * 1000; self?.rmStartShared = cb.gpuStartTime; rmEnd.t = cb.gpuEndTime; lock.unlock()
                    }
                    dreamcastGPU?.encode(cmd: rmCmd, target: target, input: din)
                    rmDepth = nil   // no depth: the scene plane stands in for it
                    rmCmd.commit()
                } else if let cin = sm.city, let target = offscreen {
                    // the City scene: one ray-traced full-screen pass into the off-screen target
                    if cityGPU == nil { cityGPU = CityGPU(device: device) }
                    rmCmd.addCompletedHandler { [weak self] cb in
                        lock.lock(); self?.gpuMsShared = (cb.gpuEndTime - cb.gpuStartTime) * 1000; self?.rmStartShared = cb.gpuStartTime; rmEnd.t = cb.gpuEndTime; lock.unlock()
                    }
                    cityGPU?.encode(cmd: rmCmd, target: target, input: cin)
                    if depthDOF, let gt = cityGPU?.distanceTexture, let rmD {
                        depthConvert(rmCmd, cityDepthPipe, gt, into: rmD, k: SIMD2(0, 60))   // 60 m counts as the subject
                    }
                    rmCmd.commit()
                } else if let e = rmCmd.makeRenderCommandEncoder(descriptor: hp) {
                rmCmd.addCompletedHandler { [weak self] cb in
                    lock.lock(); self?.gpuMsShared = (cb.gpuEndTime - cb.gpuStartTime) * 1000; self?.rmStartShared = cb.gpuStartTime; rmEnd.t = cb.gpuEndTime; lock.unlock()
                }
                defer { rmCmd.commit() }
                let rmPipe = sm.kind == .infinity ? infinityPipe(u, pre: false) : sm.kind == .glass ? glassPipe : sm.kind == .orbs ? orbsPipe
                        : sm.kind == .ferro ? ferroPipe : sm.kind == .metaballs ? metaballsPipe : diamondPipe
                if let rmPipe { e.setRenderPipelineState(sm.kind == .infinity ? rmPipe : dz(rmPipe)) }
                e.setFragmentBytes(&u, length: MemoryLayout<ShaderModeUniforms>.stride, index: 0)
                e.setFragmentBuffer(buf, offset: 0, index: 2)
                e.setFragmentTexture(paletteTex, index: 0)
                if sm.kind == .orbs || sm.kind == .ferro || sm.kind == .metaballs || sm.kind == .infinity {
                    e.setFragmentTexture(envMaps.texture(for: s.chromeEnv) ?? blankTex, index: 1)
                }
                if let vol = sm.volume, let vt = uploadVolume(vol, size: sm.volumeSize, slot: slot) { e.setFragmentTexture(vt, index: 2) }
                if sm.ferro != nil {
                    if ferroGPU == nil { ferroGPU = FerroGPU(device: device) }
                    // last frame's fluid (this frame's runs after this pass, so the pass is timed on its own)
                    if let t = ferroGPU?.texture { e.setFragmentTexture(t, index: 2) }
                    // where the fluid is (16³ blocks): the raymarcher skips the empty ones
                    if let o = ferroGPU?.occupancy { e.setFragmentBuffer(o, offset: 0, index: 3) } else { e.setFragmentBuffer(zeroOcc, offset: 0, index: 3) }
                }
                if sm.kind == .infinity { e.setFragmentTexture(infPreTex ?? blankTex, index: 2) }
                if rmPipe != nil { e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3) }
                e.endEncoding()
                }
            }
        } else if rmTex != nil {
            rmTex = nil
        }
        // Real Metaballs' fluid: its own command buffer, after the raymarch (the next frame draws its volume)
        if let fin = builder.shaderMode?.ferro { _ = ferroGPU?.encode(queue: queue, input: fin) }


        let cur = scenes[sceneIndex], prev = scenes[1 - sceneIndex]
        sceneIndex = 1 - sceneIndex

        // 1. Scene
        // Anti-aliasing: shaded surfaces (Mushrooms / Primitives in Chrome or Fresnel look) are plain triangles: draw
        // those frames with 4× multisampling so their outlines are smooth. Lines and dots have soft edges in their own
        // shaders already (and the passes with other pipelines have no 4× variants).
        var msaa = s.antialias && !(builder.trisOver.isEmpty && builder.trisAdd.isEmpty) && builder.shaderMode == nil
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
        // Big dots (Field / Image Particles at a large Size): their overlapping fragments are the frame's cost (Image
        // Particles at Size 4: 150k dots of 42 px radius = 70 ms). Drawn at ½ size from 12 px radius (¼ of the fragments)
        // and at ¼ size from 32 px when they overlap ≥ 16 deep on average (1/16), then added back through the bicubic
        // copyFrag. A ½-size dot's edge is 2 px soft instead of 1; under that radius (or with MSAA) they're drawn as before.
        var splatSrc: MTLTexture?, splatDepth: MTLTexture?
        var splatFull: MTLBuffer?
        let splatCount = builder.field.map { Int($0.u.count) } ?? builder.splat.count
        let splatList = builder.field != nil ? fieldSegBufs[slot] : upload(builder.splat, into: &splatBufs[slot])
        if splatCount > 0, let sbuf = splatList {
            let rPx = builder.splatR * scale * cam.zoom
            let cover = Float(splatCount) * .pi * rPx * rPx / max(1, px.x * px.y)
            var div = rPx >= 32 && cover >= 16 ? 4 : rPx >= 12 ? 2 : 1
            if msaa { div = 1 }
            let w = max(1, cur.width / div), h = max(1, cur.height / div)
            if div > 1, splatTex?.width != w || splatTex?.height != h {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: sceneFormat, width: w, height: h, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                splatTex = device.makeTexture(descriptor: d)
            }
            if div > 1, let st = splatTex {
                let p = MTLRenderPassDescriptor()
                p.colorAttachments[0].texture = st
                p.colorAttachments[0].loadAction = .clear
                p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                p.colorAttachments[0].storeAction = .store
                let sd = depthTarget("splat", w, h, keep: depthDOF)
                attachDepth(p, sd, keep: depthDOF)
                if depthDOF { splatDepth = sd }
                prof?.render(p, "splat")
                if let e = cmd.makeRenderCommandEncoder(descriptor: p) {
                    // the same geometry at 1/div resolution: positions and widths are pixels = points × pxScale
                    var Us = U
                    Us.viewPx = SIMD2(Float(w), Float(h))
                    Us.pxScale = scale * Float(w) / max(1, px.x)
                    e.setRenderPipelineState(dz(segAddPipe))
                    e.setVertexBuffer(sbuf, offset: 0, index: 0)
                    e.setVertexBytes(&Us, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCount)
                    e.endEncoding()
                    splatSrc = st
                }
            }
            if splatSrc == nil { splatFull = sbuf }
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if msaa {
            rp.colorAttachments[0].texture = msaaTex
            rp.colorAttachments[0].resolveTexture = cur
            rp.colorAttachments[0].storeAction = .multisampleResolve
            attachDepth(rp, depthTarget("msaa", cur.width, cur.height, keep: depthDOF, samples: 4), keep: depthDOF,
                        resolve: depthDOF ? depthTarget("scene", cur.width, cur.height, keep: true) : nil)
        } else {
            rp.colorAttachments[0].texture = cur
            rp.colorAttachments[0].storeAction = .store
            attachDepth(rp, depthTarget("scene", cur.width, cur.height, keep: depthDOF), keep: depthDOF)
        }
        let sceneDepth = depthDOF ? depthTargets["scene"] : nil
        prof?.render(rp, "scene")
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            if let sm = builder.shaderMode {
                if let offscreen {
                    enc.setRenderPipelineState(dz(copyAddPipe))
                    enc.setFragmentTexture(offscreen, index: 0)
                    enc.setFragmentTexture(rmDepth ?? blankTex, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                } else if let buf = upload(sm.data.isEmpty ? [Float(0)] : sm.data, into: &shaderBufs[slot]) {
                    var u = sm.u
                    u.p2.x = scale
                    enc.setRenderPipelineState(dz(sm.kind == .membrane ? membranePipe : fanPipe))
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
                enc.setRenderPipelineState(dz(spectroPipe))
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
                enc.setRenderPipelineState(dz(msaa ? triOverPipe4 : triOverPipe))
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.setFragmentBytes(&chromeU, length: MemoryLayout<ChromeUniforms>.stride, index: 0)
                enc.setFragmentTexture(envTex ?? blankTex, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: builder.trisOver.count)
            }
            if let buf = upload(builder.trisAdd, into: &triAddBufs[slot]) {
                enc.setRenderPipelineState(dz(msaa ? triAddPipe4 : triAddPipe))
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.setFragmentBytes(&chromeU, length: MemoryLayout<ChromeUniforms>.stride, index: 0)
                enc.setFragmentTexture(envTex ?? blankTex, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: builder.trisAdd.count)
            }
            if let buf = upload(builder.lines, into: &lineBufs[slot]) {
                enc.setRenderPipelineState(dz(msaa ? segMaxPipe4 : segMaxPipe))
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: builder.lines.count)
            }
            if let buf = upload(builder.add, into: &addBufs[slot]) {
                enc.setRenderPipelineState(dz(msaa ? segAddPipe4 : segAddPipe))
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: builder.add.count)
            }
            if let splatSrc {
                enc.setRenderPipelineState(dz(copyAddPipe))
                enc.setFragmentTexture(splatSrc, index: 0)
                enc.setFragmentTexture(splatDepth ?? blankTex, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            } else if let splatFull {
                enc.setRenderPipelineState(dz(msaa ? segAddPipe4 : segAddPipe))
                enc.setVertexBuffer(splatFull, offset: 0, index: 0)
                enc.setVertexBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCount)
            }
            if let sp = builder.sphere, let unitBuf, let valsBuf {
                // spikes are quads; dots and base dots are point sprites (a quarter of the vertex work)
                for (on, mode) in [(sp.spikes, UInt32(1)), (sp.baseDots, 2), (sp.dots, 0)] where on {
                    if mode == 1 && spikeBuf == nil { continue }
                    enc.setRenderPipelineState(dz(mode == 1 ? spherePipe : sphereDotPipe))
                    enc.setVertexBuffer(mode == 1 ? spikeBuf : unitBuf, offset: 0, index: 0)
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
                enc.setRenderPipelineState(dz(dots ? partDotPipe : partPipe))
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
                enc.setRenderPipelineState(dz(msaa ? fadePipe4 : fadePipe))
                enc.setFragmentTexture(prev, index: 0)
                enc.setFragmentBytes(&W, length: MemoryLayout<WarpUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }

        // 1b. Depth of field: the rest of the frame (bloom, soft focus, composite) reads the defocused copy; `cur`
        // itself stays sharp (next frame's trails / warp feedback read it).
        let sceneTex = s.dofAmount > 0.001
            ? (depthOfField(cmd, cur, s, scale: scale, time: Float(elapsed), U: U, depth: sceneDepth) ?? cur) : cur
        if s.dofAmount <= 0.001, dofOut != nil {
            dofSrc = nil; dofBlur = nil; dofBlurQ = nil; dofOut = nil
            dofCoc = nil; dofTileA = nil; dofTileB = nil; dofMixH = nil; dofMixQ = nil; dofBlurE = nil; dofMixE = nil; dofLit = nil
        }
        if !depthDOF, depthTargets.values.contains(where: { $0.storageMode != .memoryless && device.hasUnifiedMemory }) {
            depthTargets = depthTargets.filter { $0.value.storageMode == .memoryless }   // free the real ones
        }

        // 2. Bloom, soft focus, streak: all start from the scene averaged down to ¼ size
        func pass(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, _ a: MTLTexture, _ b: MTLTexture? = nil, k: Float = 1, load: Bool = false) {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = dst
            p.colorAttachments[0].loadAction = load ? .load : .dontCare
            p.colorAttachments[0].storeAction = .store
            prof?.render(p, pipe === box4Pipe ? "box4" : "bloom")
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
        if bloomOn || softOn || streakOn { pass(bloomA, box4Pipe, sceneTex) }
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

        // 3b. Distort field (¼ size; full size for Rain on glass)
        let distField = s.distort == .rain ? (distTexHi ?? distTex) : distTex
        if C.dist.x > 0.5, C.dist.y > 0, let distTex = distField {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = distTex
            p.colorAttachments[0].loadAction = .dontCare
            p.colorAttachments[0].storeAction = .store
            prof?.render(p, "distort")
            if let e = cmd.makeRenderCommandEncoder(descriptor: p) {
                var tsz = SIMD2<Float>(Float(distTex.width), Float(distTex.height))
                e.setRenderPipelineState(distortPipe)
                e.setFragmentBytes(&C, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
                e.setFragmentBytes(&tsz, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
            }
        } else {
            C.dist.x = 0
        }

        // 4. Composite + CRT
        let fp = MTLRenderPassDescriptor()
        fp.colorAttachments[0].texture = drawable.texture
        fp.colorAttachments[0].loadAction = .dontCare
        fp.colorAttachments[0].storeAction = .store
        prof?.render(fp, "composite")
        if let enc = cmd.makeRenderCommandEncoder(descriptor: fp) {
            enc.setFragmentTexture(mediaTex ?? blankTex, index: 2)
            enc.setFragmentTexture(softB, index: 3)
            enc.setFragmentTexture(streakB, index: 4)
            enc.setFragmentTexture(distField ?? streakB, index: 5)
            enc.setRenderPipelineState(compositePipe(C))
            enc.setFragmentTexture(sceneTex, index: 0)
            enc.setFragmentTexture(bloomB, index: 1)
            enc.setFragmentBytes(&C, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if DebugSnapshot.enabled { DebugSnapshot.capture(drawable.texture, frame: frame, time: elapsed, cmd: cmd, device: device) }
        prof?.finish(cmd)
        if let frameEvent {
            frameSerial += 1
            let serial = frameSerial
            cmd.encodeSignalEvent(frameEvent, value: serial)
            // a frame that failed on the GPU may never signal: release the next frame's wait from here
            cmd.addCompletedHandler { cb in if cb.error != nil, frameEvent.signaledValue < serial { frameEvent.signaledValue = serial } }
        }
        cmd.present(drawable)
        cmd.commit()
    }
}

extension Renderer {
    /// Depth of field (Camera group): returns the defocused copy of `scene` (full size), or nil if a target is missing.
    fileprivate func depthOfField(_ cmd: MTLCommandBuffer, _ scene: MTLTexture, _ s: VizSettings, scale: Float, time: Float,
                                  U: GPUUniforms, depth: MTLTexture?) -> MTLTexture? {
        let w = scene.width, h = scene.height, hw = max(1, (w + 1) / 2), hh = max(1, (h + 1) / 2)
        func tex(_ w: Int, _ h: Int, mips: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: sceneFormat, width: w, height: h, mipmapped: mips)
            if mips { d.mipmapLevelCount = min(d.mipmapLevelCount, 7) }
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        if dofSrc?.width != hw || dofSrc?.height != hh {
            dofSrc = tex(hw, hh, mips: true); dofBlur = tex(hw, hh, mips: false)
            dofBlurQ = tex(max(1, (hw + 1) / 2), max(1, (hh + 1) / 2), mips: false)
        }
        if dofOut?.width != w || dofOut?.height != h { dofOut = tex(w, h, mips: false) }
        guard let src = dofSrc, let blurT = dofBlur, let blurQ = dofBlurQ, let out = dofOut else { return nil }
        var D = DofUniforms(a: SIMD4(Float(min(1, max(0, s.dofAmount))) * 0.06 * Float(h), s.dofBokeh.shaderIndex,
                                     Float(min(1, max(0, s.dofNoise))), time.truncatingRemainder(dividingBy: 4096)),
                            b: SIMD4(Float(w), Float(h), scale, 0))
        D.e.y = Float(min(1, max(0, s.dofRange)))
        func run(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, _ a: MTLTexture, _ b: MTLTexture? = nil, _ c: MTLTexture? = nil) {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = dst
            p.colorAttachments[0].loadAction = .dontCare
            p.colorAttachments[0].storeAction = .store
            prof?.render(p, pipe === dofDownPipe ? "dof.down" : pipe === dofGatherPipe ? "dof.gather\(dst.width)" : "dof.combine")
            guard let e = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            e.setRenderPipelineState(pipe)
            e.setFragmentTexture(a, index: 0)
            if let b { e.setFragmentTexture(b, index: 1) }
            if let c { e.setFragmentTexture(c, index: 2) }
            e.setFragmentBytes(&D, length: MemoryLayout<DofUniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        if s.dofFocusMode == .depth {
            return depthOfFieldDepth(cmd, scene, s, D: D, U: U, depth: depth, src: src, blurH: blurT, blurQ: blurQ, out: out)
        }
        run(src, dofDownPipe, scene)
        let bpd = MTLBlitPassDescriptor()
        prof?.blit(bpd, "dof.mips")
        if let b = cmd.makeBlitCommandEncoder(descriptor: bpd) { b.generateMipmaps(for: src); b.endEncoding() }
        let split = Renderer.dofSplit
        let maxCoc = D.a.x * 1.5   // ≥ dofCoc's largest value (corners; d ≤ 1.3)
        if maxCoc > split.x {   // the quarter-size pass only when some blur is that big
            D.c = SIMD4(split.x, 1e9, 0, 0)
            run(blurQ, dofGatherPipe, src)
        }
        D.c = SIMD4(0, split.y, 0, 0)
        run(blurT, dofGatherPipe, src)
        run(out, dofCombinePipe, scene, blurT, blurQ)
        return out
    }

    /// Depth focus: real depth of field from the scene's depth target (see the shaders' "Depth focus" section).
    fileprivate func depthOfFieldDepth(_ cmd: MTLCommandBuffer, _ scene: MTLTexture, _ s: VizSettings, D base: DofUniforms,
                                       U: GPUUniforms, depth: MTLTexture?, src: MTLTexture, blurH: MTLTexture,
                                       blurQ: MTLTexture, out: MTLTexture) -> MTLTexture? {
        let w = scene.width, h = scene.height
        func tex(_ w: Int, _ h: Int, _ old: MTLTexture?, mips: Bool = false, format: MTLPixelFormat = .r16Float) -> MTLTexture? {
            if let old, old.width == w, old.height == h { return old }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, w), height: max(1, h), mipmapped: mips)
            if mips { d.mipmapLevelCount = min(d.mipmapLevelCount, 7) }
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let tw = (src.width + 7) / 8, th = (src.height + 7) / 8
        dofCoc = tex(src.width, src.height, dofCoc, mips: true)
        dofMixH = tex(src.width, src.height, dofMixH)
        dofMixQ = tex(blurQ.width, blurQ.height, dofMixQ)
        let ew = (blurQ.width + 1) / 2, eh = (blurQ.height + 1) / 2
        dofBlurE = tex(ew, eh, dofBlurE, format: sceneFormat)
        dofMixE = tex(ew, eh, dofMixE)
        dofLit = tex(src.width, src.height, dofLit)
        dofTileA = tex(tw, th, dofTileA)
        dofTileB = tex(tw, th, dofTileB)
        guard let coc = dofCoc, let mixH = dofMixH, let mixQ = dofMixQ, let tileA = dofTileA, let tileB = dofTileB,
              let blurE = dofBlurE, let mixE = dofMixE, let lit = dofLit, let blank = blankTex else { return nil }
        let amount = Float(min(1, max(0, s.dofAmount)))
        let f = Float(min(1, max(0.02, s.dofFocus)))
        let maxR = max(2, 0.1 * Float(h) * amount)
        var D = base
        D.a.x = 0.07 * Float(h) * amount                      // blur px per unit of inverse depth (the subject, focused at ∞: 7 % of the height)
        D.b.w = s.isVolumetric ? 1 : 0                         // 3D modes: empty pixels are infinitely far
        D.c = SIMD4(0, 1e9, (1 - f) / f, maxR)                 // focus: ½ = the subject (inverse depth 1), 1 = infinity
        var U = U
        func run(_ targets: [MTLTexture], _ pipe: MTLRenderPipelineState, _ texs: [MTLTexture], _ D: inout DofUniforms,
                 extra: ((MTLRenderCommandEncoder) -> Void)? = nil) {
            let p = MTLRenderPassDescriptor()
            for (i, t) in targets.enumerated() {
                p.colorAttachments[i].texture = t
                p.colorAttachments[i].loadAction = .dontCare
                p.colorAttachments[i].storeAction = .store
            }
            prof?.render(p, pipe === dofPrepPipe ? "dof.prep" : pipe === dofTilePipe ? "dof.tile" : pipe === dofDilatePipe ? "dof.dilate"
                         : pipe === dofDepthGatherPipe ? "dof.gather\(targets[0].width)" : "dof.combine")
            guard let e = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            e.setRenderPipelineState(pipe)
            for (i, t) in texs.enumerated() { e.setFragmentTexture(t, index: i) }
            e.setFragmentBytes(&D, length: MemoryLayout<DofUniforms>.stride, index: 0)
            e.setFragmentBytes(&U, length: MemoryLayout<GPUUniforms>.stride, index: 1)
            extra?(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        run([src, coc, lit], dofPrepPipe, [scene, depth ?? blank], &D)
        let bpd = MTLBlitPassDescriptor()
        prof?.blit(bpd, "dof.mips")
        if let b = cmd.makeBlitCommandEncoder(descriptor: bpd) { b.generateMipmaps(for: src); b.generateMipmaps(for: coc); b.endEncoding() }
        run([tileA], dofTilePipe, [lit], &D)
        var Dd = D
        Dd.c.x = (maxR / 16).rounded(.up) + 1                  // how many tiles a blur can reach
        for (dst, srcT, dir) in [(tileB, tileA, SIMD2<Int32>(1, 0)), (tileA, tileB, SIMD2<Int32>(0, 1))] {
            var dir = dir
            run([dst], dofDilatePipe, [srcT], &Dd) { $0.setFragmentBytes(&dir, length: 8, index: 1) }
        }
        let split = Renderer.dofSplit
        // three sizes by the reach: half (≤ 36 px), quarter (22 … 90), eighth (≥ 70); taps ∝ the reach in their own pixels
        let splitE = Renderer.dofSplitE
        if maxR > splitE.x {
            D.c.x = splitE.x; D.c.y = 1e9; D.e.x = 0.6
            run([blurE, mixE], dofDepthGatherPipe, [src, coc, tileA], &D)
        }
        if maxR > split.x {
            D.c.x = split.x; D.c.y = splitE.y; D.e.x = 1.2
            run([blurQ, mixQ], dofDepthGatherPipe, [src, coc, tileA], &D)
        }
        D.c.x = 0; D.c.y = split.y; D.e.x = 2.4
        run([blurH, mixH], dofDepthGatherPipe, [src, coc, tileA], &D)
        run([out], dofDepthCombinePipe, [scene, blurH, blurQ, mixH, mixQ, tileA, depth ?? blank, blurE, mixE], &D)
        return out
    }

    /// A depth target (see `depthTargets`): `keep` = it will be read (Depth focus on), else a memoryless stand-in.
    fileprivate func depthTarget(_ role: String, _ w: Int, _ h: Int, keep: Bool, samples: Int = 1) -> MTLTexture? {
        let memoryless = device.hasUnifiedMemory && (!keep || samples > 1)
        if let t = depthTargets[role], t.width == w, t.height == h, (t.storageMode == .memoryless) == memoryless { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.depthFormat, width: max(1, w), height: max(1, h), mipmapped: false)
        if samples > 1 { d.textureType = .type2DMultisample; d.sampleCount = samples }
        d.usage = memoryless ? .renderTarget : [.renderTarget, .shaderRead]
        d.storageMode = memoryless ? .memoryless : .private
        let t = device.makeTexture(descriptor: d)
        depthTargets[role] = t
        return t
    }

    /// Attachment 1 of a pass = its depth target, cleared; stored (or resolved) only when it will be read.
    fileprivate func attachDepth(_ rp: MTLRenderPassDescriptor, _ t: MTLTexture?, keep: Bool, resolve: MTLTexture? = nil) {
        guard keep else { return }      // no depth target: the pipelines' no-depth twins are used (`dz`)
        let a = rp.colorAttachments[1]!
        a.texture = t
        a.loadAction = .clear
        a.clearColor = MTLClearColorMake(0, 0, 0, 0)
        if keep, let resolve { a.resolveTexture = resolve; a.storeAction = .multisampleResolve }
        else { a.storeAction = keep ? .store : .dontCare }
    }

    /// Forest / City: their own depth (depth buffer / ray distance) → inverse depth in the off-screen depth target.
    fileprivate func depthConvert(_ cmd: MTLCommandBuffer, _ pipe: MTLRenderPipelineState, _ src: MTLTexture,
                                  into dst: MTLTexture, k: SIMD2<Float>) {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = dst
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        guard let e = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
        var k = k
        e.setRenderPipelineState(pipe)
        e.setFragmentTexture(src, index: 0)
        e.setFragmentBytes(&k, length: 8, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }
}

/// Small deterministic RNG for layouts.
struct SplitMix: RandomNumberGenerator {
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
