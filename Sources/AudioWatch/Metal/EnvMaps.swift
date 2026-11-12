import Foundation
import Metal

/// The HDR environments that chrome reflects (Resources/env/*.envmap, made by Resources/make_envmaps.swift from the
/// HDRIs in Resources/hdr). Each is loaded the first time it's needed into a mipmapped half-float texture; the shader
/// picks a blurrier mip level for higher Blur. A missing file falls back to a plain grey environment.
final class EnvMaps {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var cache: [ChromeEnvironment: MTLTexture] = [:]
    private lazy var grey: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var px: [UInt16] = [0x34CD, 0x34CD, 0x34CD, 0x3C00]   // half floats 0.3, 0.3, 0.3, 1 (Float16 isn't available on Intel)
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 8)
        return t
    }()

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    func texture(for env: ChromeEnvironment) -> MTLTexture? {
        if let t = cache[env] { return t }
        guard let t = load(env.fileName) else { return grey }
        cache[env] = t
        return t
    }

    private func load(_ name: String) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "envmap"),
              let file = try? Data(contentsOf: url), file.count > 12,
              file.prefix(4) == Data("ENV1".utf8) else { return nil }
        let w = Int(file.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        let h = Int(file.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard let raw = try? (file.subdata(in: 12..<file.count) as NSData).decompressed(using: .lzfse) as Data,
              raw.count == w * h * 8 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        raw.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cmd.commit()
        }
        return t
    }
}
