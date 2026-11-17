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

/// The Landscape's City scene: one full-screen ray-traced pass (see CityShaders.swift) into the off-screen target.
final class CityGPU {
    static let lightCount = 32
    private let device: MTLDevice
    private let lib: MTLLibrary
    private var pipe: MTLRenderPipelineState?
    private var pipeFormat: MTLPixelFormat = .invalid

    init?(device: MTLDevice) {
        self.device = device
        do {
            lib = try device.makeLibrary(source: cityShaderSource, options: nil)
        } catch {
            NSLog("soundwatch: city shader error \(error)")
            return nil
        }
    }

    func encode(cmd: MTLCommandBuffer, target: MTLTexture, input: CityInput) {
        if pipe == nil || pipeFormat != target.pixelFormat {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "cityVert")
            d.fragmentFunction = lib.makeFunction(name: "cityFrag")
            d.colorAttachments[0].pixelFormat = target.pixelFormat
            do { pipe = try device.makeRenderPipelineState(descriptor: d); pipeFormat = target.pixelFormat } catch {
                NSLog("soundwatch: city pipeline error \(error)"); return
            }
        }
        guard let pipe else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        var U = input.u
        U.right.w = U.up.w * Float(target.width) / Float(target.height)
        U.fwd.w = 2 * U.up.w / Float(target.height)       // radians per pixel (for antialiasing fine detail)
        var L = input.lights
        if L.count < Self.lightCount { L += Array(repeating: SIMD4<Float>(), count: Self.lightCount - L.count) }
        e.setRenderPipelineState(pipe)
        e.setFragmentBytes(&U, length: MemoryLayout<CityUniforms>.stride, index: 0)
        e.setFragmentBytes(&L, length: Self.lightCount * 16, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }
}
