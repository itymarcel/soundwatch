import Foundation
import Metal
import simd

/// Matches DCU in DreamcastShaders.swift.
struct DCUniforms {
    var res = SIMD4<Float>()     // console width, height, aspect, layer count (filled in by DreamcastGPU)
    var music = SIMD4<Float>()   // bass, mid, treble, loudness
    var hits = SIMD4<Float>()    // kick, snare, hat, beat
    var crt = SIMD4<Float>()     // CRT style, warp, time, 0
    var outp = SIMD4<Float>()    // output size, pixel aspect (filled in by DreamcastGPU), screen width (share of the window)
    var b0 = SIMD4<Float>(), b1 = SIMD4<Float>(), b2 = SIMD4<Float>(), b3 = SIMD4<Float>()
    var k0 = SIMD4<Float>(), k1 = SIMD4<Float>(), k2 = SIMD4<Float>(), k3 = SIMD4<Float>()
    var pal0 = SIMD4<Float>(), pal1 = SIMD4<Float>(), pal2 = SIMD4<Float>(), pal3 = SIMD4<Float>()
    var cam0 = SIMD4<Float>(1, 0, 0, 0), cam1 = SIMD4<Float>(0, 1, 0, 0), cam2 = SIMD4<Float>(0, 0, 1, 0)
    var view = SIMD4<Float>(1, 0, 0, 1)   // zoom, pan x, pan y (half-screens, y up), screen height (share of the window)
}

/// Matches DCL: (kind, style, opacity, music), (offset x, y, scale, rotation), (clock, hue, per kind …), d / e per kind
/// (see DCL in DreamcastShaders.swift).
struct DCLayerUniforms {
    var a = SIMD4<Float>(), b = SIMD4<Float>(), c = SIMD4<Float>()
    var d = SIMD4<UInt32>()
    var e = SIMD4<Float>()
}

/// Matches DCT: one HUD text line (or bar). pos = top-left x, y, font pixel size, style; chars = 16 bytes.
struct DCTextItem {
    var pos = SIMD4<Float>()
    var chars = SIMD4<UInt32>()
}

/// What DreamcastViz hands the renderer each frame.
struct DreamcastInput {
    var u: DCUniforms
    var layers: [DCLayerUniforms]
    var text: [DCTextItem]
    /// Console resolution in lines (the width follows the window's aspect and the pixel shape).
    var lines: Int
    /// Width / height of a console pixel (2 for the Atari 2600).
    var pixelAspect: Float = 1
}

/// Dreamcast mode on the GPU: the layer stack at console resolution into a small texture, then the CRT pass
/// full size into the off-screen target (the renderer adds that into the scene).
final class DreamcastGPU {
    static let maxText = 120
    private let device: MTLDevice
    private let lib: MTLLibrary
    private var layerPipe: MTLRenderPipelineState?
    private var crtPipe: MTLRenderPipelineState?
    private var crtFormat: MTLPixelFormat = .invalid
    private var lowTex: MTLTexture?

    init?(device: MTLDevice) {
        self.device = device
        do {
            lib = try device.makeLibrary(source: dreamcastShaderSource.replacingOccurrences(of: "//@FONT@", with: DreamcastFont.msl + DreamcastSprites.msl + DreamcastNESPalette.msl),
                                         options: nil)
        } catch {
            NSLog("soundwatch: dreamcast shader error \(error)")
            return nil
        }
        layerPipe = pipe("dcLayersFrag", .rgba8Unorm)
    }

    private func pipe(_ frag: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "dcVert")
        d.fragmentFunction = lib.makeFunction(name: frag)
        d.colorAttachments[0].pixelFormat = format
        do { return try device.makeRenderPipelineState(descriptor: d) } catch {
            NSLog("soundwatch: dreamcast pipeline error \(error)"); return nil
        }
    }

    func encode(cmd: MTLCommandBuffer, target: MTLTexture, input: DreamcastInput) {
        if crtFormat != target.pixelFormat { crtPipe = pipe("dcCrtFrag", target.pixelFormat); crtFormat = target.pixelFormat }
        guard let layerPipe, let crtPipe else { return }
        // the screen's shape: the window's, scaled by Width (outp.w) and Height (view.w)
        let sw = input.u.outp.w > 0 ? input.u.outp.w : 1, sh = input.u.view.w > 0 ? input.u.view.w : 1
        let aspect = Float(target.width) * sw / (Float(max(1, target.height)) * sh)
        let h = max(48, min(1440, input.lines))
        let pxA = max(1, input.pixelAspect)
        let w = max(32, Int((Float(h) * aspect / pxA).rounded()))
        if lowTex?.width != w || lowTex?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            lowTex = device.makeTexture(descriptor: d)
        }
        guard let lowTex else { return }
        var u = input.u
        u.res = SIMD4(Float(w), Float(h), Float(w) * pxA / Float(h), Float(input.layers.count))
        u.outp = SIMD4(Float(target.width), Float(target.height), pxA, sw)
        u.view.w = sh
        var layers = input.layers.isEmpty ? [DCLayerUniforms()] : input.layers
        var text = input.text.isEmpty ? [DCTextItem()] : Array(input.text.prefix(Self.maxText))

        let lp = MTLRenderPassDescriptor()
        lp.colorAttachments[0].texture = lowTex
        lp.colorAttachments[0].loadAction = .dontCare
        lp.colorAttachments[0].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: lp) {
            e.setRenderPipelineState(layerPipe)
            e.setFragmentBytes(&u, length: MemoryLayout<DCUniforms>.stride, index: 0)
            e.setFragmentBytes(&layers, length: MemoryLayout<DCLayerUniforms>.stride * layers.count, index: 1)
            e.setFragmentBytes(&text, length: MemoryLayout<DCTextItem>.stride * text.count, index: 2)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = target
        cp.colorAttachments[0].loadAction = .dontCare
        cp.colorAttachments[0].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: cp) {
            e.setRenderPipelineState(crtPipe)
            e.setFragmentBytes(&u, length: MemoryLayout<DCUniforms>.stride, index: 0)
            e.setFragmentTexture(lowTex, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
    }
}
