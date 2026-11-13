import AppKit
import CoreText
import ImageIO
import simd

/// Image Particles: a picture made of particles, each on a spring to its pixel. Its frequency band (by horizontal
/// position) pushes it towards the viewer and makes it shimmer; kicks, snares and hats send shock waves rippling
/// through the picture; Springiness pulls everything back into place. Without an image it spells "soundwatch".
///
/// Loading and sampling run on a background queue (a big photo takes ~50-100 ms to decode, a million particles a few
/// tens of ms to sample); the old particles fly to the new homes when a new sample arrives.
final class ImageParticlesViz: Visualizer {
    /// Decoded image, RGBA8, not premultiplied.
    struct Pixels { let w: Int; let h: Int; let rgba: [UInt8] }
    /// One sampling of the image: home (x, y), luminance, colour per particle, and the grid spacing in world units.
    struct Sample {
        var home: [SIMD2<Float>] = []
        var lum: [Float] = []
        /// Rank 0…1 of each particle's brightness / colour (red → purple, greys by brightness) among all particles: the
        /// band maps use ranks, so every band gets its share whatever the picture (a bright photo isn't all treble).
        var lumRank: [Float] = []
        var toneRank: [Float] = []
        var color: [SIMD3<Float>] = []
        var cell: Float = 0.01
        /// Half width / height of the picture in world units (the longer side is 1).
        var half = SIMD2<Float>(1, 1)
    }
    private struct Wave { var center: SIMD2<Float>; var born: Double; var strength: Float; var speed: Float; var width: Float; var group: Int }
    private struct Key: Equatable { var path: String; var count: Int; var threshold: Double }

    private var sample = Sample()
    private var pos: [SIMD3<Float>] = [], vel: [SIMD3<Float>] = []
    private var band: [UInt8] = []
    private var bandKey: String?
    private var waves: [Wave] = []
    private var onsets = Onsets()
    private var clock = 0.0

    // Background work
    private let queue = DispatchQueue(label: "soundwatch.imageparticles", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Sample?
    private var requested: Key?
    private var pixelsPath: String?
    private var pixels: Pixels?                  // touched only on `queue`

    private static let bandCount = 32

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        request(Key(path: s.imgPath, count: Int(s.imgParticles), threshold: s.imgThreshold))
        adoptPending()
        guard !pos.isEmpty else { return }
        let key = "\(s.imgBandMap.rawValue)-\(s.mirror)"
        if bandKey != key { assignBands(s.imgBandMap, mirror: s.mirror); bandKey = key }

        let dt = Float(min(rc.dt, 1.0 / 30))
        if !rc.frozen {
            clock += rc.dt
            for hit in onsets.step(rc) where waves.count < 10 { spawnWave(hit.band, hit.strength) }
            waves.removeAll { clock - $0.born > 2.5 }
            simulate(dt, rc)
            if Self.trace { traceGroups() }
        }
        draw(f, rc)
    }

    // MARK: - Simulation

    private func spawnWave(_ b: Int, _ strength: Float) {
        // kick: from near the middle, strong and wide; snare: anywhere, medium; hats: small quick ripples
        let spread: Float = [0.25, 0.8, 0.9][b]
        let c = SIMD2(Float.random(in: -spread...spread), Float.random(in: -spread...spread) * 0.7)
        waves.append(Wave(center: c, born: clock, strength: [1.0, 0.6, 0.3][b] * (0.5 + strength),
                          speed: [1.1, 1.4, 1.8][b], width: [0.22, 0.14, 0.08][b], group: b))
    }

    private func simulate(_ dt: Float, _ rc: RenderContext) {
        let s = rc.s
        let lv = rc.analyzer.bands(count: Self.bandCount, s: s)
        let reach = Float(s.reach), motion = Float(s.motion)
        let depth = Float(s.imgDepth)
        let spring = 4 + 90 * Float(s.imgSpring * s.imgSpring)
        let damp = exp(-dt * (3 + 9 * Float(s.imgSpring)))
        let beatLift = rc.beat * 0.08
        let t = Float(clock)
        let live: [(c: SIMD2<Float>, front: Float, w: Float, k: Float, g: Int)] = waves.map { w in
            let age = Float(clock - w.born)
            let fade = max(0, 1 - age / 2.5)
            return (w.center, age * w.speed, w.width, w.strength * fade * fade * reach, w.group)
        }
        // Except for Position, drum waves follow the band map too: kicks move mostly the bass particles, hats the treble.
        let prm = StepParams(dt: dt, spring: spring, damp: damp, reach: reach, depth: depth, beatLift: beatLift,
                             wobble: 0.004 + 0.02 * motion, t: t, waves: live, selective: s.imgBandMap != .position)
        let n = pos.count, chunks = Self.chunks(n)
        sample.home.withUnsafeBufferPointer { (H: UnsafeBufferPointer<SIMD2<Float>>) in
        sample.lum.withUnsafeBufferPointer { (L: UnsafeBufferPointer<Float>) in
        band.withUnsafeBufferPointer { (B: UnsafeBufferPointer<UInt8>) in
        lv.withUnsafeBufferPointer { (LV: UnsafeBufferPointer<Float>) in
        pos.withUnsafeMutableBufferPointer { (P: inout UnsafeMutableBufferPointer<SIMD3<Float>>) in
        vel.withUnsafeMutableBufferPointer { (V: inout UnsafeMutableBufferPointer<SIMD3<Float>>) in
            let Pp = P, Vp = V
            DispatchQueue.concurrentPerform(iterations: chunks) { (c: Int) in
                Self.step((c * n / chunks)..<((c + 1) * n / chunks), H, L, B, LV, Pp, Vp, prm)
            }
        } } } } } }
    }

    private struct StepParams {
        var dt, spring, damp, reach, depth, beatLift, wobble, t: Float
        var waves: [(c: SIMD2<Float>, front: Float, w: Float, k: Float, g: Int)]
        var selective: Bool
    }

    private static func step(_ range: Range<Int>, _ H: UnsafeBufferPointer<SIMD2<Float>>, _ L: UnsafeBufferPointer<Float>,
                             _ B: UnsafeBufferPointer<UInt8>, _ LV: UnsafeBufferPointer<Float>,
                             _ P: UnsafeMutableBufferPointer<SIMD3<Float>>, _ V: UnsafeMutableBufferPointer<SIMD3<Float>>,
                             _ q: StepParams) {
        let bandCount = Self.bandCount
        for i in range {
            let h = H[i]
            let level = min(1.5, LV[Int(B[i])])
            let group = Int(B[i]) * 3 / bandCount                  // 0 bass, 1 mids, 2 treble
            // rest pose: bright parts forward (Depth), pushed further out by the particle's band and the beat
            let z = q.depth * (L[i] - 0.5) * 0.6 + level * q.reach * 0.28 + q.beatLift
            // shimmer: a little drift that grows with the band level (and Motion)
            let ph = h.x * 9.1 + h.y * 7.3
            let amp = level * q.wobble
            let wx = sin(ph + q.t * 2.3) * amp
            let wy = cos(ph * 1.3 - q.t * 1.9) * amp
            let target = SIMD3<Float>(h.x + wx, h.y + wy, z)
            let p = P[i]
            var force = (target - p) * q.spring
            for w in q.waves where w.k > 0.001 {
                let d = SIMD2<Float>(p.x, p.y) - w.c
                let dist = max(simd_length(d), 1e-4)
                let off = abs(dist - w.front)
                guard off < w.w else { continue }
                let x = 1 - off / w.w
                let push = w.k * x * x * 6 * (!q.selective || w.g == group ? 1 : 0.2)
                force += SIMD3<Float>(d.x / dist * push, d.y / dist * push, push * 0.8)
            }
            let v = (V[i] + force * q.dt) * q.damp
            V[i] = v
            P[i] = p + v * q.dt
        }
    }

    // MARK: - Drawing

    private func draw(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let view = rc.camera.rotation
        // fit the picture into the canvas (with a margin) at Zoom 1
        let world = min(rc.size.x / sample.half.x, rc.size.y / sample.half.y) * 0.45 * Float(s.zoom)
        let lw = max(0.6, rc.unit * 0.7)
        // a dot about one grid cell wide fills the picture; Size scales it
        let cellR = max(lw, sample.cell * world * 0.62) * Float(s.size)
        let useImage = s.imgColours, byFreq = s.colorBy == .frequency, phase = rc.phase
        let square: Float = s.segmented ? 1 : 0
        let n = pos.count
        if s.style == .points {
            let base = f.add.count
            f.add.append(contentsOf: repeatElement(Seg(a: .zero, b: .zero, color: .zero, width: 0), count: n))
            sample.home.withUnsafeBufferPointer { H in
            sample.lum.withUnsafeBufferPointer { L in
            sample.color.withUnsafeBufferPointer { C in
            pos.withUnsafeBufferPointer { P in
            f.add.withUnsafeMutableBufferPointer { A in
                let chunks = Self.chunks(n)
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    for i in (c * n / chunks)..<((c + 1) * n / chunks) {
                        let (p, k) = project(P[i], view, rc, world: world)
                        let col = Self.color(i, P[i], H, L, C, useImage: useImage, byFreq: byFreq, phase: phase, rc: rc)
                        A[base + i] = Seg(a: p, b: p, color: col, width: 2 * cellR * k, cap: square)
                    }
                }
            } } } } }
            return
        }
        // Lines / Both: moving particles draw a short streak along their velocity
        sample.home.withUnsafeBufferPointer { H in
        sample.lum.withUnsafeBufferPointer { L in
        sample.color.withUnsafeBufferPointer { C in
            for i in 0..<n {
                let col = Self.color(i, pos[i], H, L, C, useImage: useImage, byFreq: byFreq, phase: phase, rc: rc)
                let (p, k) = project(pos[i], view, rc, world: world)
                // moving particles streak along their velocity (Lines: instead of the dot, Both: as well); still ones are
                // dots either way, or the picture would vanish wherever it's at rest
                let moving = simd_length(vel[i]) > 0.03
                if moving {
                    let (pt, _) = project(pos[i] - vel[i] * 0.05, view, rc, world: world)
                    f.line(pt, p, col, max(lw, cellR * 0.8) * k)
                }
                if !moving || s.style != .lines { f.dot(p, cellR * k, col, square: s.segmented) }
            }
        } } }
    }

    @inline(__always)
    private static func color(_ i: Int, _ p: SIMD3<Float>, _ H: UnsafeBufferPointer<SIMD2<Float>>, _ L: UnsafeBufferPointer<Float>,
                              _ C: UnsafeBufferPointer<SIMD3<Float>>, useImage: Bool, byFreq: Bool, phase: Float,
                              rc: RenderContext) -> SIMD4<Float> {
        let h = H[i]
        // displaced particles light up a little
        let e = min(1, simd_length(SIMD2(p.x, p.y) - h) * 6 + max(0, p.z) * 1.5)
        if useImage { return SIMD4(C[i] * (0.85 + 0.6 * e), 0.9) }
        let tc: Float = byFreq ? (h.x + 1) * 0.5 : 0.15 + 0.75 * L[i]
        return rc.col(tc + phase, 0.45 + 0.55 * max(e, L[i]))
    }

    /// Band per particle (0 = bass … treble) by the chosen map.
    private func assignBands(_ map: ImageBandMap, mirror: Bool) {
        let n = sample.home.count
        let maxX = max(1e-3, sample.home.map { abs($0.x) }.max() ?? 1)
        func u(_ i: Int) -> Float {
            switch map {
            case .position:
                let x = sample.home[i].x
                return mirror ? abs(x) / maxX : (x / maxX + 1) * 0.5
            case .random:
                var z = UInt64(i) &* 0x9E37_79B9_7F4A_7C15                 // stable per particle (splitmix64)
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
            case .brightness: return sample.lumRank[i]
            case .colour: return sample.toneRank[i]
            }
        }
        band = (0..<n).map { UInt8(min(Self.bandCount - 1, max(0, Int(u($0) * Float(Self.bandCount))))) }
    }

    private static let trace = ProcessInfo.processInfo.environment["AUDIOWATCH_TRACE"] != nil
    private var traceFrame = 0
    /// AUDIOWATCH_TRACE: every 30 frames, the mean distance from home of the bass / mid / treble particles.
    private func traceGroups() {
        traceFrame += 1
        guard traceFrame % 30 == 0, band.count == pos.count else { return }
        var sum = [Float](repeating: 0, count: 3), cnt = [Float](repeating: 0, count: 3)
        for i in stride(from: 0, to: pos.count, by: 7) {
            let g = Int(band[i]) * 3 / Self.bandCount, h = sample.home[i]
            sum[g] += simd_length(pos[i] - SIMD3(h.x, h.y, 0)); cnt[g] += 1
        }
        print(String(format: "IMGP bass=%.4f mid=%.4f treble=%.4f", sum[0] / max(1, cnt[0]), sum[1] / max(1, cnt[1]), sum[2] / max(1, cnt[2])))
    }

    private static func chunks(_ n: Int) -> Int { max(1, min(32, n / 8192)) }

    // MARK: - Loading and sampling (background)

    private func request(_ key: Key) {
        lock.lock()
        let same = key == requested
        requested = key
        lock.unlock()
        guard !same else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.pixelsPath != key.path || self.pixels == nil {
                self.pixelsPath = key.path
                // no image, or one that can't be read: the "soundwatch" lettering
                self.pixels = (key.path.isEmpty ? nil : Self.load(path: key.path)) ?? Self.textImage()
            }
            // a newer request replaces this one: skip the work
            self.lock.lock(); let stale = self.requested != key; self.lock.unlock()
            if stale { return }
            let s = Self.sample(self.pixels!, count: key.count, threshold: Float(key.threshold))
            self.lock.lock(); self.pending = s; self.lock.unlock()
        }
    }

    private func adoptPending() {
        lock.lock(); let next = pending; pending = nil; lock.unlock()
        guard let next else { return }
        let old = pos
        sample = next
        let n = next.home.count
        // the old particles fly to their new homes; the first picture assembles from a cloud
        pos = (0..<n).map { i in
            if !old.isEmpty { return old[i % old.count] }
            let h = next.home[i]
            return SIMD3(h.x * 1.6 + Float.random(in: -0.6...0.6), h.y * 1.6 + Float.random(in: -0.6...0.6), Float.random(in: -1...1))
        }
        vel = .init(repeating: .zero, count: n)
        bandKey = nil
    }

    /// Decodes an image file, scaled down to at most 1600 px on its longer side, EXIF orientation applied.
    static func load(path: String) -> Pixels? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1600]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return render(width: img.width, height: img.height) { ctx in
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }

    /// "soundwatch" in bold white letters on transparent: the picture before an image is chosen.
    static func textImage() -> Pixels {
        render(width: 1600, height: 420) { ctx in
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 300, nil)
            let attr = NSAttributedString(string: "soundwatch", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textPosition = CGPoint(x: (1600 - b.width) / 2 - b.minX, y: (420 - b.height) / 2 - b.minY)
            CTLineDraw(line, ctx)
        }!
    }

    private static func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> Pixels? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx)
        guard let data = ctx.data else { return nil }
        let src = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let a = src[i * 4 + 3]
            rgba[i * 4 + 3] = a
            guard a > 0 else { continue }
            for c in 0..<3 { rgba[i * 4 + c] = UInt8(min(255, Int(src[i * 4 + c]) * 255 / Int(a))) }   // un-premultiply
        }
        return Pixels(w: width, h: height, rgba: rgba)
    }

    /// Picks about `count` particles on a jittered grid over the pixels that pass the threshold (and aren't transparent).
    /// The grid is sized from the share of pixels that pass, so the count comes out right whatever the image.
    static func sample(_ px: Pixels, count: Int, threshold: Float) -> Sample {
        func lum(_ i: Int) -> Float {
            (0.2126 * Float(px.rgba[i * 4]) + 0.7152 * Float(px.rgba[i * 4 + 1]) + 0.0722 * Float(px.rgba[i * 4 + 2])) / 255
        }
        // The threshold uses the strongest channel (HSV value), not luminance: pure blue is a bright colour but only 7 % luminance.
        func value(_ i: Int) -> Float { Float(max(px.rgba[i * 4], px.rgba[i * 4 + 1], px.rgba[i * 4 + 2])) / 255 }
        func keep(_ i: Int) -> Bool {
            guard px.rgba[i * 4 + 3] >= 128 else { return false }
            let v = value(i)
            return v >= threshold
        }
        // share of pixels kept, from a coarse pass
        var kept = 0, seen = 0
        for y in stride(from: 0, to: px.h, by: 4) { for x in stride(from: 0, to: px.w, by: 4) { seen += 1; if keep(y * px.w + x) { kept += 1 } } }
        let share = max(0.002, Double(kept) / Double(max(1, seen)))
        let cells = Double(count) / share
        let aspect = Double(px.w) / Double(px.h)
        let gw = max(2, Int((cells * aspect).squareRoot())), gh = max(2, Int(Double(gw) / aspect))
        // fit the longer side to −1…1
        let half = aspect >= 1 ? SIMD2(Float(1), Float(1 / aspect)) : SIMD2(Float(aspect), Float(1))
        var out = Sample()
        out.half = half
        out.cell = 2 * max(half.x / Float(gw), half.y / Float(gh))
        var tones: [Float] = []
        tones.reserveCapacity(count + count / 8)
        out.home.reserveCapacity(count + count / 8)
        out.lum.reserveCapacity(count + count / 8)
        out.color.reserveCapacity(count + count / 8)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let u = (Float(gx) + Float.random(in: 0.15...0.85)) / Float(gw)
                let v = (Float(gy) + Float.random(in: 0.15...0.85)) / Float(gh)
                let x = min(px.w - 1, Int(u * Float(px.w))), y = min(px.h - 1, Int(v * Float(px.h)))
                let i = y * px.w + x
                guard keep(i) else { continue }
                out.home.append(SIMD2((u * 2 - 1) * half.x, (1 - v * 2) * half.y))
                out.lum.append(lum(i))
                let c = SIMD3(Float(px.rgba[i * 4]), Float(px.rgba[i * 4 + 1]), Float(px.rgba[i * 4 + 2])) / 255
                tones.append(tone(c, lum: lum(i)))
                out.color.append(c)
            }
        }
        out.lumRank = ranks(out.lum)
        out.toneRank = ranks(tones)
        return out
    }

    /// Colour-wheel position for the Colour map: red 0 → orange, yellow, green, cyan, blue → purple ~1 (magenta-reds wrap
    /// back to red). Greys and near-blacks have no real hue: they're placed by brightness, after the colours.
    private static func tone(_ c: SIMD3<Float>, lum: Float) -> Float {
        let mx = c.max(), mn = c.min(), d = mx - mn
        guard mx > 0.06, d / mx > 0.18 else { return 1 + lum }        // grey: sorts after every colour
        var h: Float
        if mx == c.x { h = (c.y - c.z) / d } else if mx == c.y { h = 2 + (c.z - c.x) / d } else { h = 4 + (c.x - c.y) / d }
        h /= 6
        if h < 0 { h += 1 }
        return h > 0.92 ? 0 : h                                        // pinks / magenta-reds count as red
    }

    /// Rank of each value among all, 0…1 (ties broken by position).
    private static func ranks(_ v: [Float]) -> [Float] {
        let n = v.count
        guard n > 1 else { return .init(repeating: 0, count: n) }
        let order = (0..<n).sorted { v[$0] < v[$1] }
        var r = [Float](repeating: 0, count: n)
        for (k, i) in order.enumerated() { r[i] = Float(k) / Float(n - 1) }
        return r
    }
}
