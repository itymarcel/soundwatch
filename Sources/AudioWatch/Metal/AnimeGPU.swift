import Foundation
import Metal
import simd

/// Matches ANU in AnimeShaders.swift.
struct ANUniforms {
    var res = SIMD4<Float>()     // width, height, aspect, layer count (filled in by AnimeGPU)
    var music = SIMD4<Float>()   // bass, mid, treble, loudness
    var hits = SIMD4<Float>()    // kick, snare, hat, beat
    var time = SIMD4<Float>()    // seconds (stepped), wind strength, wind phase, gust
    var cam = SIMD4<Float>(0, 0, 1, 0)   // x, y, zoom, roll
    var cam2 = SIMD4<Float>()    // push-in travel, unused, unused, sideways travel (repeating layers only)
    var post = SIMD4<Float>()    // film, impact (1 while shown), letterbox, impact style
    var outp = SIMD4<Float>()    // output size (filled in by AnimeGPU), frame counter, old-anime amount
    var b0 = SIMD4<Float>(), b1 = SIMD4<Float>(), b2 = SIMD4<Float>(), b3 = SIMD4<Float>()
    var pal0 = SIMD4<Float>(), pal1 = SIMD4<Float>(), pal2 = SIMD4<Float>(), pal3 = SIMD4<Float>()
    /// The orbit camera in 3D: rotation rows (as Dreamcast's `cam0…2`), then zoom, pan x / y (NDC), layer gap.
    var rot0 = SIMD4<Float>(1, 0, 0, 0), rot1 = SIMD4<Float>(0, 1, 0, 0), rot2 = SIMD4<Float>(0, 0, 1, 0)
    var view = SIMD4<Float>(1, 0, 0, 0)
}

/// Matches ANL: (kind, style, opacity, music), (offset x, y, scale, rotation), (clock, hue, depth, drawing seed), e / f per kind.
struct ANLayerUniforms {
    var a = SIMD4<Float>(), b = SIMD4<Float>(), c = SIMD4<Float>()
    var e = SIMD4<Float>(), f = SIMD4<Float>()
}

/// What AnimeViz hands the renderer each frame.
struct AnimeInput {
    var u: ANUniforms
    var layers: [ANLayerUniforms]
    /// Resolution of the layer pass in lines (the width follows the window's aspect).
    var lines: Int
    /// Every Japanese-titles layer's lines (atlas rows, in order; see AnimeTitles).
    var titleLines: [String] = []
}

/// Anime mode on the GPU: the layer stack into a mipmapped half-float texture, then the post pass (scale-up, film look,
/// impact frames, letterbox) full size into the off-screen target (the renderer adds that into the scene).
final class AnimeGPU {
    private let device: MTLDevice
    private let lib: MTLLibrary
    private var layerPipe: MTLRenderPipelineState?
    private var postPipe: MTLRenderPipelineState?
    private var postFormat: MTLPixelFormat = .invalid
    private var lowTex: MTLTexture?
    // the titles' glyph atlas, rebuilt off the main thread when the lines change
    private var titleTex: MTLTexture?
    private var titleKey: [String] = []
    private var titleBuilding = false
    private let emptyTex: MTLTexture?

    init?(device: MTLDevice) {
        self.device = device
        do {
            lib = try device.makeLibrary(source: animeShaderSource, options: nil)
        } catch {
            NSLog("soundwatch: anime shader error \(error)")
            return nil
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false)
        emptyTex = device.makeTexture(descriptor: d)
        layerPipe = pipe("anLayersFrag", .rgba16Float)
    }

    private func updateTitles(_ lines: [String]) {
        guard lines != titleKey, !titleBuilding, !lines.isEmpty else { return }
        titleBuilding = true
        let dev = device
        DispatchQueue.global(qos: .userInitiated).async {
            let tex = AnimeTitles.build(device: dev, lines: lines)
            DispatchQueue.main.async {
                self.titleTex = tex
                self.titleKey = lines
                self.titleBuilding = false
            }
        }
    }

    private func pipe(_ frag: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "anVert")
        d.fragmentFunction = lib.makeFunction(name: frag)
        d.colorAttachments[0].pixelFormat = format
        do { return try device.makeRenderPipelineState(descriptor: d) } catch {
            NSLog("soundwatch: anime pipeline error \(error)"); return nil
        }
    }

    func encode(cmd: MTLCommandBuffer, target: MTLTexture, input: AnimeInput) {
        if postFormat != target.pixelFormat { postPipe = pipe("anPostFrag", target.pixelFormat); postFormat = target.pixelFormat }
        guard let layerPipe, let postPipe else { return }
        let aspect = Float(target.width) / Float(max(1, target.height))
        // never more lines than the target has (the UI throttle renders the frame at a third of its size)
        let h = max(120, min(input.lines, max(120, target.height)))
        let w = max(32, Int((Float(h) * aspect).rounded()))
        if lowTex?.width != w || lowTex?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            lowTex = device.makeTexture(descriptor: d)
        }
        guard let lowTex else { return }
        updateTitles(input.titleLines)
        var u = input.u
        u.res = SIMD4(Float(w), Float(h), Float(w) / Float(h), Float(input.layers.count))
        u.outp.x = Float(target.width); u.outp.y = Float(target.height)
        var layers = input.layers.isEmpty ? [ANLayerUniforms()] : input.layers

        let lp = MTLRenderPassDescriptor()
        lp.colorAttachments[0].texture = lowTex
        lp.colorAttachments[0].loadAction = .dontCare
        lp.colorAttachments[0].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: lp) {
            e.setRenderPipelineState(layerPipe)
            e.setFragmentBytes(&u, length: MemoryLayout<ANUniforms>.stride, index: 0)
            // the atlas only counts once it holds these lines (until then the layer draws nothing: e.x = −1 below)
            let ready = titleKey == input.titleLines && titleTex != nil
            if !ready { for i in layers.indices where layers[i].a.x == DCKind.anTitle.shaderIndex { layers[i].e.x = -1 } }
            e.setFragmentBytes(&layers, length: MemoryLayout<ANLayerUniforms>.stride * layers.count, index: 1)
            e.setFragmentTexture(ready ? titleTex : emptyTex, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        if let b = cmd.makeBlitCommandEncoder() {
            b.generateMipmaps(for: lowTex)
            b.endEncoding()
        }
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = target
        cp.colorAttachments[0].loadAction = .dontCare
        cp.colorAttachments[0].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: cp) {
            e.setRenderPipelineState(postPipe)
            e.setFragmentBytes(&u, length: MemoryLayout<ANUniforms>.stride, index: 0)
            e.setFragmentTexture(lowTex, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
    }
}
