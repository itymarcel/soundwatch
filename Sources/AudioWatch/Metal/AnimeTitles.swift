import Foundation
import Metal
import CoreText
import CoreGraphics

/// Anime's Japanese titles layer: lines of text drawn with CoreText into a signed-distance atlas (crisp at any size,
/// cheap outlines and glows). One row per line, one 128 px cell per character (at most 16 per line, 24 lines);
/// r = Hiragino Mincho W6 (brush-like serif), g = Hiragino Sans W8 (heavy gothic).
/// Stored value = 0.5 − distance / (2 · spread): above 0.5 = inside the glyph.
enum AnimeTitles {
    static let cell = 128, cols = 16, maxRows = 24
    static let spread: Float = 12

    /// The layer's default lines (titles in Japanese, separated by "/").
    static let defaultText = "ドラゴンボール / ワンピース / シドニアの騎士 / 鋼の錬金術師 / デスノート / 呪術廻戦 / 魔界の影 / 進撃の巨人"

    /// A layer's text split into its lines ("/" or new lines), each at most `cols` characters.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "/" || $0 == "\n" || $0 == "／" })
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(cols)) }
            .filter { !$0.isEmpty }
    }

    /// Characters turned 90° in vertical writing, and small kana (they sit towards the top right of their cell there).
    private static let rotated: Set<Character> = ["ー", "－", "—", "―", "〜", "～", "…", "‥", "-", "=", "＝", "(", ")", "（", "）", "「", "」"]
    private static let small: Set<Character> = Set("ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ")

    /// Bit masks (as floats, exact up to 2^24) of the characters to turn / shift in vertical writing.
    static func masks(_ line: String) -> (rot: Float, small: Float) {
        var r = 0, s = 0
        for (i, ch) in line.enumerated() where i < cols {
            if rotated.contains(ch) { r |= 1 << i }
            if small.contains(ch) { s |= 1 << i }
        }
        return (Float(r), Float(s))
    }

    /// Builds the atlas for these lines (slow-ish: run it off the main thread).
    static func build(device: MTLDevice, lines: [String]) -> MTLTexture? {
        let rows = max(1, min(maxRows, lines.count))
        let W = cols * cell, H = rows * cell
        var out = [UInt8](repeating: 0, count: W * H * 2)
        let fonts = [CTFontCreateWithName("HiraMinProN-W6" as CFString, 100, nil),
                     CTFontCreateWithName("HiraginoSans-W8" as CFString, 100, nil)]
        for (ch, font) in fonts.enumerated() {
            guard let cov = coverage(lines: Array(lines.prefix(rows)), font: font, W: W, H: H) else { continue }
            let sd = signedDistance(cov, W: W, H: H)
            for i in 0..<(W * H) {
                let v = 0.5 - sd[i] / (2 * spread)
                out[i * 2 + ch] = UInt8(max(0, min(255, (v * 255).rounded())))
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: W, height: H, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        out.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: W * 2) }
        return tex
    }

    /// Glyph coverage (0…1), top row first, each character centred in its cell on the ideographic em box.
    private static func coverage(lines: [String], font: CTFont, W: Int, H: Int) -> [Float]? {
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(gray: 1, alpha: 1)
        let asc = CTFontGetAscent(font), desc = CTFontGetDescent(font)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        for (row, line) in lines.enumerated() {
            for (col, ch) in line.enumerated() where col < cols {
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: attrs))
                let adv = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                let x = CGFloat(col * cell) + (CGFloat(cell) - adv) / 2
                // CG's y is up: row 0 is the top row of the texture
                let cellBottom = CGFloat(H - (row + 1) * cell)
                let y = cellBottom + (CGFloat(cell) - (asc + desc)) / 2 + desc
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(ctLine, ctx)
            }
        }
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: W * H)
        // the context's memory starts with the top row
        return (0..<(W * H)).map { Float(p[$0]) / 255 }
    }

    /// Signed distance in pixels (negative inside) from coverage: exact Euclidean transforms (Felzenszwalb) of the
    /// inside and the outside, the edge pixels refined by their coverage.
    private static func signedDistance(_ cov: [Float], W: Int, H: Int) -> [Float] {
        let inf: Float = 1e10
        var toIn = cov.map { $0 >= 0.5 ? 0 : inf }
        var toOut = cov.map { $0 >= 0.5 ? inf : 0 }
        edt2D(&toIn, W: W, H: H)
        edt2D(&toOut, W: W, H: H)
        var sd = [Float](repeating: 0, count: W * H)
        let lim = spread + 2
        for i in 0..<(W * H) {
            let c = cov[i]
            if c > 0.02 && c < 0.98 { sd[i] = 0.5 - c; continue }
            sd[i] = c >= 0.5 ? -(min(toOut[i].squareRoot(), lim) - 0.5) : min(toIn[i].squareRoot(), lim) - 0.5
        }
        return sd
    }

    private static func edt2D(_ g: inout [Float], W: Int, H: Int) {
        let n = max(W, H)
        var f = [Float](repeating: 0, count: n), d = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        for x in 0..<W {
            for y in 0..<H { f[y] = g[y * W + x] }
            edt1D(f, H, &d, &v, &z)
            for y in 0..<H { g[y * W + x] = d[y] }
        }
        for y in 0..<H {
            for x in 0..<W { f[x] = g[y * W + x] }
            edt1D(f, W, &d, &v, &z)
            for x in 0..<W { g[y * W + x] = d[x] }
        }
    }

    /// Squared distance transform of a sampled function in one dimension (lower envelope of parabolas).
    private static func edt1D(_ f: [Float], _ n: Int, _ d: inout [Float], _ v: inout [Int], _ z: inout [Float]) {
        var k = 0
        v[0] = 0; z[0] = -.infinity; z[1] = .infinity
        if n > 1 {
            for q in 1..<n {
                var s: Float
                repeat {
                    let p = v[k]
                    s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * (q - p))
                    if s <= z[k] { k -= 1 } else { break }
                } while k >= 0
                k += 1
                v[k] = q; z[k] = s; z[k + 1] = .infinity
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let dq = Float(q - v[k])
            d[q] = dq * dq + f[v[k]]
        }
    }
}
