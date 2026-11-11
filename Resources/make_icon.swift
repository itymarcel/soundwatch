// Makes Resources/AppIcon.icns from a square artwork PNG, following the macOS (Big Sur+) icon grid:
// 1024 canvas, 824×824 rounded-square body centred (100 px margin), continuous corners (R 185.4),
// drop shadow (28 px blur, 12 px down, 50 % black) and a faint inner edge so the dark icon reads on dark Docks.
//
//   swift Resources/make_icon.swift _input/icon.png
import AppKit

let args = CommandLine.arguments
guard args.count > 1, let art = NSImage(contentsOfFile: args[1]),
      let artCG = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: swift Resources/make_icon.swift artwork.png"); exit(1)
}

// Rounded square with continuous ("squircle") corners: corner radius R plus 60 % corner smoothing,
// which is the usual match for Apple's icon shape (R = 185.4 on the 824 body).
func continuousRect(_ r: CGRect, radius R: CGFloat = 185.4, smoothing xi: CGFloat = 0.6) -> CGPath {
    let rad = { (d: CGFloat) in d * .pi / 180 }
    let p = (1 + xi) * R
    let arcMeasure = 90 * (1 - xi)
    let arcLen = sin(rad(arcMeasure / 2)) * R * sqrt(2)
    let alpha = (90 - arcMeasure) / 2
    let p34 = R * tan(rad(alpha / 2))
    let beta = 45 * xi
    let c = p34 * cos(rad(beta)), d = c * tan(rad(beta))
    let b = (p - arcLen - c - d) / 3, a = 2 * b
    // Top-right corner in local coords (corner at 0,0): from (-p, 0) on the top edge to (0, -p) on the right edge.
    func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 1...24 {
            let t = CGFloat(i) / 24, u = 1 - t
            let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
            let x = w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x
            let y = w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }
    let s0 = CGPoint(x: -p, y: 0), s1 = CGPoint(x: -p + a + b + c, y: -d)
    let e1 = CGPoint(x: -d, y: -p + a + b + c), e0 = CGPoint(x: 0, y: -p)
    var corner = [s0]
    corner += cubic(s0, CGPoint(x: -p + a, y: 0), CGPoint(x: -p + a + b, y: 0), s1)
    let ctr = CGPoint(x: -R, y: -R)
    let a0 = atan2(s1.y - ctr.y, s1.x - ctr.x), a1 = atan2(e1.y - ctr.y, e1.x - ctr.x)
    for i in 1...32 {
        let t = a0 + (a1 - a0) * CGFloat(i) / 32
        corner.append(CGPoint(x: ctr.x + R * cos(t), y: ctr.y + R * sin(t)))
    }
    corner += cubic(e1, CGPoint(x: 0, y: -p + a + b), CGPoint(x: 0, y: -p + a), e0)
    // Mirror it to the four corners, clockwise in y-up coords.
    let quads: [(CGPoint, CGFloat, CGFloat, Bool)] = [   // corner, x sign, y sign, reverse order
        (CGPoint(x: r.maxX, y: r.maxY),  1,  1, false),
        (CGPoint(x: r.maxX, y: r.minY),  1, -1, true),
        (CGPoint(x: r.minX, y: r.minY), -1, -1, false),
        (CGPoint(x: r.minX, y: r.maxY), -1,  1, true),
    ]
    let path = CGMutablePath()
    for (k, (o, sx, sy, rev)) in quads.enumerated() {
        let pts = rev ? Array(corner.reversed()) : corner
        for (i, q) in pts.enumerated() {
            let pt = CGPoint(x: o.x + sx * q.x, y: o.y + sy * q.y)
            (k == 0 && i == 0) ? path.move(to: pt) : path.addLine(to: pt)
        }
    }
    path.closeSubpath()
    return path
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: s, y: s)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)   // y-up: shadow goes to -y
    let shape = continuousRect(body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s,
                  color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.draw(artCG, in: body)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.addPath(shape); ctx.setLineWidth(4); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.strokePath()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! render(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! render(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
try! render(1024).write(to: root.appendingPathComponent("AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns + AppIcon.png" : "iconutil failed")
