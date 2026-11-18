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
    /// G-buffer formats (colour + distance, reflection origin, direction, weight): match CityG in CityShaders.swift.
    private static let gFormats: [MTLPixelFormat] = [.rgba16Float, .rgba32Float, .rgba32Float, .rgba16Float]
    private let device: MTLDevice
    private let lib: MTLLibrary
    private var walkPipe: MTLRenderPipelineState?, reflWalkPipe: MTLRenderPipelineState?, mainPipe: MTLRenderPipelineState?, resolvePipe: MTLRenderPipelineState?
    private var walkTex: MTLTexture?
    private var pipeFormat: MTLPixelFormat = .invalid
    private var gTex: [MTLTexture] = []

    init?(device: MTLDevice) {
        self.device = device
        do {
            let o = MTLCompileOptions()
            // debug: AUDIOWATCH_SHADER_DEFS=A,B defines macros (for A/B timing of compiled-out code)
            var m: [String: NSObject] = [:]
            for d in (ProcessInfo.processInfo.environment["AUDIOWATCH_SHADER_DEFS"] ?? "").split(separator: ",") { m[String(d)] = NSNumber(value: 1) }
            o.preprocessorMacros = m
            lib = try device.makeLibrary(source: cityShaderSource, options: o)
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
        resolvePipe = pipe("cityResolve", [format])
        pipeFormat = format
    }

    func encode(cmd: MTLCommandBuffer, target: MTLTexture, input: CityInput) {
        if walkPipe == nil || reflWalkPipe == nil || mainPipe == nil || resolvePipe == nil || pipeFormat != target.pixelFormat {
            makePipes(target.pixelFormat)
        }
        guard let walkPipe, let reflWalkPipe, let mainPipe, let resolvePipe else { return }
        if gTex.first?.width != target.width || gTex.first?.height != target.height {
            func tex(_ f: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: target.width, height: target.height, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            gTex = Self.gFormats.compactMap(tex)
            walkTex = tex(.rgba32Float)
        }
        guard gTex.count == Self.gFormats.count, let walkTex else { return }
        var U = input.u
        U.right.w = U.up.w * Float(target.width) / Float(target.height)
        U.fwd.w = 2 * U.up.w / Float(target.height)       // radians per pixel (for antialiasing fine detail)
        var L = input.lights
        if L.count < Self.lightCount { L += Array(repeating: SIMD4<Float>(), count: Self.lightCount - L.count) }
        CityDebugIO.apply(&U, &L)

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
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        // 3. the reflection rays' walk (into the same texture: the primary walk is used up)
        guard let er = cmd.makeRenderCommandEncoder(descriptor: wp) else { return }
        er.setRenderPipelineState(reflWalkPipe)
        er.setFragmentBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 0)
        for (i, t) in gTex.enumerated() { er.setFragmentTexture(t, index: i) }
        er.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        er.endEncoding()
        // 4. reflections' shading, haze, glow, tone mapping → the target
        let rp2 = MTLRenderPassDescriptor()
        rp2.colorAttachments[0].texture = target
        rp2.colorAttachments[0].loadAction = .dontCare
        rp2.colorAttachments[0].storeAction = .store
        guard let e2 = cmd.makeRenderCommandEncoder(descriptor: rp2) else { return }
        e2.setRenderPipelineState(resolvePipe)
        e2.setFragmentBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 0)
        e2.setFragmentBytes(&L, length: Self.lightCount * 16, index: 1)
        for (i, t) in gTex.enumerated() { e2.setFragmentTexture(t, index: i) }
        e2.setFragmentTexture(walkTex, index: 4)
        e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e2.endEncoding()
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
            d.withUnsafeBytes { b in
                u = b.loadUnaligned(as: CityUniforms.self)
                l = (0..<(d.count - n) / 16).map { b.loadUnaligned(fromByteOffset: n + $0 * 16, as: SIMD4<Float>.self) }
            }
        } else if let dump, frame == dumpFrame {
            var d = withUnsafeBytes(of: u) { Data($0) }
            l.withUnsafeBytes { d.append(contentsOf: $0) }
            FileManager.default.createFile(atPath: dump, contents: d)
        }
    }
}
