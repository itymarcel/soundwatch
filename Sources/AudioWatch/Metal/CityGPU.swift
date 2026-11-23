import Foundation
import Metal
import simd

/// What the City scene hands the renderer each frame (built by CityViz).
struct CityInput {
    var u: CityUniforms
    /// Kick waves (4), drones (2 × 10, the last ones fly-bys), searchlights (2 × 4): see the light buffer layout in CityShaders.swift.
    var lights: [SIMD4<Float>]
}

/// Matches CityU in CityShaders.swift.
struct CityUniforms {
    var right = SIMD4<Float>(), up = SIMD4<Float>(), fwd = SIMD4<Float>()
    var cam = SIMD4<Float>()
    var cell = SIMD4<Int32>()
    var cfg = SIMD4<Float>(), cfg2 = SIMD4<Float>()
    var music = SIMD4<Float>(), music2 = SIMD4<Float>()
    var traffic = SIMD4<Float>()
    var flash = SIMD4<Float>()
    var colA = SIMD4<Float>(), colB = SIMD4<Float>(), colC = SIMD4<Float>()
    var bands0 = SIMD4<Float>(), bands1 = SIMD4<Float>()
    var cfg3 = SIMD4<Float>()
    var cfg4 = SIMD4<Float>()
}

/// The Landscape's City scene: ray-traced full-screen passes into the off-screen target (see CityShaders.swift):
/// the primary rays' walk → its shading → reflection + haze + tone mapping.
final class CityGPU {
    static let lightCount = 32
    /// GI irradiance (E/π) → this scene's lighting units: at intensity 1 the City is about as bright as with its old
    /// bounce stand-ins (measured mean luma 74.6 off, 66.4 with 1.0), but lit by what's really around.
    static let giScale: Float = 2.2
    /// One GI ray per 8 × 8 pixels (the City's hits are shaded with the whole facade: dearer than the Forest's).
    static let giRayStep = 8
    private static let giDebug = Float(ProcessInfo.processInfo.environment["AUDIOWATCH_GI_DEBUG"] ?? "") ?? 0
    /// G-buffer formats (colour + distance, reflection origin, direction, weight): match CityG in CityShaders.swift.
    private static let gFormats: [MTLPixelFormat] = [.rgba16Float, .rgba32Float, .rgba32Float, .rgba16Float]
    private let device: MTLDevice
    private let lib: MTLLibrary
    private var walkPipe: MTLRenderPipelineState?, reflWalkPipe: MTLRenderPipelineState?, mainPipe: MTLRenderPipelineState?
    private var reflShadePipe: MTLRenderPipelineState?, finalPipe: MTLRenderPipelineState?
    private var walkTex: MTLTexture?, reflTex: MTLTexture?
    private var pipeFormat: MTLPixelFormat = .invalid
    private var gTex: [MTLTexture] = []
    // global illumination (LandGI): made when it's switched on (cfg4.y > 0), dropped when it's off
    private var gi: LandGI?
    private var giTracePipe: MTLComputePipelineState?
    private lazy var giDummy = LandGI.dummyTexture(device: device)

    init?(device: MTLDevice) {
        self.device = device
        do {
            let o = MTLCompileOptions()
            // debug: AUDIOWATCH_SHADER_DEFS=A,B defines macros (for A/B timing of compiled-out code)
            var m: [String: NSObject] = [:]
            for d in (ProcessInfo.processInfo.environment["AUDIOWATCH_SHADER_DEFS"] ?? "").split(separator: ",") { m[String(d)] = NSNumber(value: 1) }
            o.preprocessorMacros = m
            lib = try device.makeLibrary(source: cityShaderSource.replacingOccurrences(of: "//@GI_CORE@", with: landGICoreSource)
                                         + cityGIShaderSource, options: o)
        } catch {
            NSLog("soundwatch: city shader error \(error)")
            return nil
        }
    }

    private func makePipes(_ format: MTLPixelFormat) {
        func pipe(_ frag: String, _ formats: [MTLPixelFormat]) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "cityVert")
            d.fragmentFunction = lib.makeFunction(name: frag)
            for (i, f) in formats.enumerated() { d.colorAttachments[i].pixelFormat = f }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                NSLog("soundwatch: city pipeline error \(error)"); return nil
            }
        }
        walkPipe = pipe("cityWalk", [.rgba32Float])
        reflWalkPipe = pipe("cityReflWalk", [.rgba32Float])
        mainPipe = pipe("cityFrag", Self.gFormats)
        reflShadePipe = pipe("cityReflShade", [.rgba16Float])
        finalPipe = pipe("cityFinal", [format])
        pipeFormat = format
    }

    /// Depth of field (Depth focus): the G-buffer's colour target, whose alpha is each pixel's ray distance (< 0 = sky).
    var distanceTexture: MTLTexture? { gTex.first }

    func encode(cmd: MTLCommandBuffer, target: MTLTexture, input: CityInput) {
        if walkPipe == nil || reflWalkPipe == nil || mainPipe == nil || reflShadePipe == nil || finalPipe == nil || pipeFormat != target.pixelFormat {
            makePipes(target.pixelFormat)
        }
        guard let walkPipe, let reflWalkPipe, let mainPipe, let reflShadePipe, let finalPipe else { return }
        if gTex.first?.width != target.width || gTex.first?.height != target.height {
            func tex(_ f: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: target.width, height: target.height, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            gTex = Self.gFormats.compactMap(tex)
            walkTex = tex(.rgba32Float)
            reflTex = tex(.rgba16Float)
        }
        guard gTex.count == Self.gFormats.count, let walkTex, let reflTex else { return }
        var U = input.u
        U.right.w = U.up.w * Float(target.width) / Float(target.height)
        U.fwd.w = 2 * U.up.w / Float(target.height)       // radians per pixel (for antialiasing fine detail)
        var L = input.lights
        if L.count < Self.lightCount { L += Array(repeating: SIMD4<Float>(), count: Self.lightCount - L.count) }
        CityDebugIO.apply(&U, &L)

        // GI: this frame's view (the shading samples last frame's result); rays after the shading
        let giAmount = U.cfg4.y
        if giAmount > 0 && gi == nil {
            gi = LandGI(device: device, library: lib)
            if let f = lib.makeFunction(name: "giCityTrace") { giTracePipe = try? device.makeComputePipelineState(function: f) }
        } else if giAmount <= 0 && gi != nil {
            gi = nil; giTracePipe = nil
        }
        var GV = GIViewU()
        GV.ground.w = Self.giDebug
        if let gi {
            GV.cam = SIMD4(U.cam.x, U.cam.y, U.cam.z, giAmount)
            GV.anchor = SIMD4(U.cell.x, 0, U.cell.y, 0)
            GV.zenith = SIMD4(0.004, 0.004, 0.012, 0)
            GV.horizon = SIMD4(0.05, 0.035, 0.045, Self.giScale * giAmount)
            GV.ground = SIMD4(0.01, 0.01, 0.012, Self.giDebug)
            gi.nextFrame(&GV)
        }

        // 1. the primary rays' walk
        let wp = MTLRenderPassDescriptor()
        wp.colorAttachments[0].texture = walkTex
        wp.colorAttachments[0].loadAction = .dontCare
        wp.colorAttachments[0].storeAction = .store
        guard let ew = cmd.makeRenderCommandEncoder(descriptor: wp) else { return }
        ew.setRenderPipelineState(walkPipe)
        ew.setFragmentBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 0)
        ew.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        ew.endEncoding()
        // 2. their shading → G-buffer
        let rp = MTLRenderPassDescriptor()
        for (i, t) in gTex.enumerated() {
            rp.colorAttachments[i].texture = t
            rp.colorAttachments[i].loadAction = .dontCare
            rp.colorAttachments[i].storeAction = .store
        }
        guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setRenderPipelineState(mainPipe)
        e.setFragmentBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 0)
        e.setFragmentBytes(&L, length: Self.lightCount * 16, index: 1)
        e.setFragmentTexture(walkTex, index: 0)
        e.setFragmentBytes(&GV, length: MemoryLayout<GIViewU>.stride, index: 2)
        for i in 0..<4 { e.setFragmentTexture(gi?.tex[i] ?? giDummy, index: 1 + i) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        // GI rays from the primary hits (before the reflection walk reuses walkTex), merge, bake
        if let gi, let giTracePipe, let ce = cmd.makeComputeCommandEncoder() {
            gi.encodeMaintain(ce, view: GV)
            ce.setComputePipelineState(giTracePipe)
            ce.setBytes(&GV, length: MemoryLayout<GIViewU>.stride, index: 0)
            gi.bind(ce)
            ce.setBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 10)
            ce.setBytes(&L, length: Self.lightCount * 16, index: 14)
            let st = Self.giRayStep
            var R = SIMD4<UInt32>(UInt32(target.width), UInt32(target.height), UInt32(st), 0)
            ce.setBytes(&R, length: 16, index: 15)
            ce.setTexture(walkTex, index: 0)
            ce.dispatchThreads(MTLSize(width: (target.width + st - 1) / st, height: (target.height + st - 1) / st, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            gi.encodeResolve(ce, view: GV, lights: nil, lightCount: 0)
            ce.endEncoding()
        }
        // 3. the reflection rays' walk (into the same texture: the primary walk is used up)
        guard let er = cmd.makeRenderCommandEncoder(descriptor: wp) else { return }
        er.setRenderPipelineState(reflWalkPipe)
        er.setFragmentBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 0)
        for (i, t) in gTex.enumerated() { er.setFragmentTexture(t, index: i) }
        er.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        er.endEncoding()
        // 4. reflections' shading → reflTex
        let rp2 = MTLRenderPassDescriptor()
        rp2.colorAttachments[0].texture = reflTex
        rp2.colorAttachments[0].loadAction = .dontCare
        rp2.colorAttachments[0].storeAction = .store
        guard let e2 = cmd.makeRenderCommandEncoder(descriptor: rp2) else { return }
        e2.setRenderPipelineState(reflShadePipe)
        e2.setFragmentBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 0)
        e2.setFragmentBytes(&L, length: Self.lightCount * 16, index: 1)
        for (i, t) in gTex.enumerated() { e2.setFragmentTexture(t, index: i) }
        e2.setFragmentTexture(walkTex, index: 4)
        e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e2.endEncoding()
        // 5. reflections filtered, haze, glow, tone mapping → the target
        let rp3 = MTLRenderPassDescriptor()
        rp3.colorAttachments[0].texture = target
        rp3.colorAttachments[0].loadAction = .dontCare
        rp3.colorAttachments[0].storeAction = .store
        guard let e3 = cmd.makeRenderCommandEncoder(descriptor: rp3) else { return }
        e3.setRenderPipelineState(finalPipe)
        e3.setFragmentBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 0)
        e3.setFragmentBytes(&L, length: Self.lightCount * 16, index: 1)
        for (i, t) in gTex.enumerated() { e3.setFragmentTexture(t, index: i) }
        e3.setFragmentTexture(reflTex, index: 5)
        e3.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e3.endEncoding()
    }
}

/// Debug aid for exact A/B stills: AUDIOWATCH_CITY_DUMP=/path writes the uniforms + lights of frame
/// AUDIOWATCH_SNAPSHOT_FRAMES (its first number); AUDIOWATCH_CITY_LOAD=/path draws every frame from such a dump.
enum CityDebugIO {
    private static let env = ProcessInfo.processInfo.environment
    private static let dump = env["AUDIOWATCH_CITY_DUMP"], load = env["AUDIOWATCH_CITY_LOAD"]
    private static let dumpFrame = Int(env["AUDIOWATCH_SNAPSHOT_FRAMES"]?.split(separator: ",").first ?? "") ?? 0
    private static var frame = 0
    static func apply(_ u: inout CityUniforms, _ l: inout [SIMD4<Float>]) {
        frame += 1
        let n = MemoryLayout<CityUniforms>.stride
        if let load, let d = FileManager.default.contents(atPath: load), d.count >= n {
            let liveGI = u.cfg4.y        // (GI on / off stays live: A/B stills)
            d.withUnsafeBytes { b in
                u = b.loadUnaligned(as: CityUniforms.self)
                u.cfg4.y = liveGI
                l = (0..<(d.count - n) / 16).map { b.loadUnaligned(fromByteOffset: n + $0 * 16, as: SIMD4<Float>.self) }
            }
        } else if let dump, frame == dumpFrame {
            var d = withUnsafeBytes(of: u) { Data($0) }
            l.withUnsafeBytes { d.append(contentsOf: $0) }
            FileManager.default.createFile(atPath: dump, contents: d)
        }
    }
}
