// Makes the chrome environment maps (Resources/env/*.envmap) from full-size equirectangular HDRIs in Resources/hdr/*.exr.
// Each map is halved to 1024×512 (blurred chrome doesn't need more), scaled so its median brightness is the same
// (switching environments doesn't jump in exposure), stored as half floats and LZFSE-compressed: ~1–3 MB instead of ~20.
//
// File layout: "ENV1", UInt32 width, UInt32 height (little endian), then LZFSE(RGBA half floats, row 0 = top).
//
//   swift Resources/make_envmaps.swift [preview folder]     (previews = tone-mapped PNGs, to eyeball the maps)
import Foundation
import CoreGraphics
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let inDir = root.appendingPathComponent("hdr"), outDir = root.appendingPathComponent("env")
let previewDir = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let floatInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
let targetMedian: Float = 0.3

func readFloats(_ url: URL) -> (w: Int, h: Int, px: [Float])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [Float](repeating: 0, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                  space: cs, bitmapInfo: floatInfo) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (w, h, px) : nil
}

let files = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension.lowercased() == "exr" }.sorted { $0.path < $1.path } ?? []
for f in files {
    guard let (w, h, px) = readFloats(f) else { print("can't read \(f.lastPathComponent)"); continue }
    let ow = w / 2, oh = h / 2
    var out = [Float](repeating: 1, count: ow * oh * 4)
    var lum = [Float](repeating: 0, count: ow * oh)
    for y in 0..<oh {
        for x in 0..<ow {
            let o = (y * ow + x) * 4
            for c in 0..<3 {
                var s: Float = 0
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] { s += px[((y * 2 + dy) * w + x * 2 + dx) * 4 + c] }
                out[o + c] = max(0, s / 4)
            }
            lum[y * ow + x] = 0.2126 * out[o] + 0.7152 * out[o + 1] + 0.0722 * out[o + 2]
        }
    }
    let median = max(1e-6, lum.sorted()[lum.count / 2])
    let scale = targetMedian / median
    for i in 0..<(ow * oh) { for c in 0..<3 { out[i * 4 + c] = min(out[i * 4 + c] * scale, 60_000) } }   // half range
    var half = out.map { Float16($0) }
    let raw = half.withUnsafeMutableBytes { Data($0) }
    guard let packed = try? (raw as NSData).compressed(using: .lzfse) as Data else { print("compress failed"); continue }
    var file = Data("ENV1".utf8)
    for v in [UInt32(ow), UInt32(oh)] { withUnsafeBytes(of: v.littleEndian) { file.append(contentsOf: $0) } }
    file.append(packed)
    let name = f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_2k", with: "")
    try! file.write(to: outDir.appendingPathComponent(name + ".envmap"))
    print(String(format: "%@  %dx%d  median %.4f → ×%.3f  %.1f MB", name, ow, oh, median, scale, Double(file.count) / 1e6))
    if let previewDir {   // Reinhard-tone-mapped sRGB preview
        var p8 = [UInt8](repeating: 255, count: ow * oh * 4)
        for i in 0..<(ow * oh) { for c in 0..<3 { let v = out[i * 4 + c]; p8[i * 4 + c] = UInt8(min(255, pow(v / (1 + v), 1 / 2.2) * 255)) } }
        let ctx = CGContext(data: &p8, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: ow * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pd = CGImageDestinationCreateWithURL(previewDir.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(pd, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(pd)
    }
}
