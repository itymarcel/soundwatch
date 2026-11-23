import AppKit
import AVFoundation
import CoreVideo
import Metal
import MetalKit

/// The user's image or video, as a Metal texture for the composite pass.
/// Videos loop, muted (their sound would otherwise end up in the system-audio tap), at a variable speed.
/// Lives on the main thread (driven by the renderer's draw).
final class MediaLayer {
    private let device: MTLDevice
    private var path = ""
    private(set) var texture: MTLTexture?
    /// Width / height of the current picture.
    private(set) var aspect: Float = 1
    private(set) var isVideo = false

    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var endObserver: NSObjectProtocol?
    private var cache: CVMetalTextureCache?
    private var cvTexture: CVMetalTexture?   // keeps the current frame's texture alive

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// Call once per frame. Loads a new file when the path changes and pulls the latest video frame.
    func update(path newPath: String, speed: Double) {
        if newPath != path { load(newPath) }
        guard let player, let output else { return }
        let rate = Float(max(0, speed))
        if abs(player.rate - rate) > 0.01 { player.rate = rate }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil), let cache else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cv: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cv)
        if let cv, let tex = CVMetalTextureGetTexture(cv) {
            cvTexture = cv
            texture = tex
            aspect = Float(w) / Float(max(h, 1))
        }
    }

    // MARK: - Motion (transform + music-driven animation), evaluated once per frame

    private var drift = SIMD2<Float>()
    private var spin: Float = 0
    private var wanderT: Float = 0
    private var bass = SmoothValue()
    private var shake = SIMD2<Float>(), shakeV = SIMD2<Float>()
    private var jumpOffset = SIMD2<Float>(), jumpAngle: Float = 0
    private var lastBeat = 0
    private var onsets = Onsets()
    private var resetToken = 0

    /// Clears everything the motion has accumulated (spin angle, drift distance, wander time, shake, jumps).
    func resetMotion() {
        drift = .zero; spin = 0; wanderT = 0
        shake = .zero; shakeV = .zero
        jumpOffset = .zero; jumpAngle = 0
    }

    /// Offset x, y (screen heights, y down), scale, angle (radians) for this frame.
    func motion(_ s: VizSettings, analyzer: Analyzer, dt rawDt: Double, frozen: Bool, reset: Int) -> SIMD4<Float> {
        if reset != resetToken { resetToken = reset; resetMotion() }
        let dt = frozen ? 0 : Float(rawDt)
        // drift: steady scroll in a direction (pairs well with Tile)
        let dir = Float(s.mediaDriftDir) * 2 * .pi
        drift += SIMD2(cos(dir), -sin(dir)) * Float(s.mediaDrift * s.mediaDrift) * 0.8 * dt
        drift = SIMD2(drift.x.truncatingRemainder(dividingBy: 1000), drift.y.truncatingRemainder(dividingBy: 1000))
        spin = (spin + Float(s.mediaSpin) * .pi * dt).truncatingRemainder(dividingBy: 2 * .pi)

        // wander: slow, aimless camera move over the picture (Ken Burns)
        wanderT += dt
        let w = Float(s.mediaWander), t = wanderT
        let wanderOff = SIMD2(sin(t * 0.13) + 0.5 * sin(t * 0.31 + 1), cos(t * 0.11 + 2) + 0.5 * sin(t * 0.23)) * 0.15 * w
        let wanderScale = 1 + w * 0.35 * (0.5 + 0.5 * sin(t * 0.09))
        let wanderAngle = w * 0.18 * sin(t * 0.07)

        // music
        let b = bass.step(to: min(1.2, analyzer.level(30, 150, s: s)), dt: max(dt, 1e-4), omega: 9)
        let punch = 1 + Float(s.mediaBeatZoom) * 0.35 * analyzer.beatPulse
        if !frozen {
            for hit in onsets.step(analyzer: analyzer) where hit.band >= 1 && s.mediaShake > 0 {
                let a = Float.random(in: 0..<(2 * .pi))
                shakeV += SIMD2(cos(a), sin(a)) * Float(s.mediaShake) * hit.strength * (hit.band == 1 ? 2.2 : 0.8)
            }
            // under-damped spring: a jolt, a couple of wobbles, back to rest
            let om: Float = 20, zeta: Float = 0.3
            shakeV += (-om * om * shake - 2 * zeta * om * shakeV) * dt
            shake += shakeV * dt

            if s.mediaJump < 0.001 { jumpOffset = .zero; jumpAngle = 0 }
            if analyzer.beatCount != lastBeat {
                lastBeat = analyzer.beatCount
                if Double.random(in: 0..<1) < s.mediaJump { jump(tiled: s.mediaTile != .off) }
            }
        }

        let offset = SIMD2(Float(s.mediaX), -Float(s.mediaY)) + drift + wanderOff + shake + jumpOffset
        let scale = Float(s.mediaScale) * wanderScale * punch * (1 + Float(s.mediaBreathe) * 0.5 * b)
        let angle = Float(s.mediaRotate) * 2 * .pi + spin + wanderAngle + jumpAngle
        return SIMD4(offset.x, offset.y, max(0.02, scale), angle)
    }

    /// Beat jump: a video cuts to a random moment; a picture jumps to a new spot and orientation.
    private func jump(tiled: Bool) {
        if let player, let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0.5 {
                player.seek(to: CMTime(seconds: Double.random(in: 0..<(d - 0.2)), preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
            }
        } else {
            jumpOffset = SIMD2(Float.random(in: -0.35...0.35), Float.random(in: -0.35...0.35)) * (tiled ? 2 : 1)
            jumpAngle = Float(Int.random(in: 0..<4)) * .pi / 2
        }
    }

    private func load(_ newPath: String) {
        path = newPath
        resetMotion()
        stopVideo()
        texture = nil
        isVideo = false
        guard !newPath.isEmpty, FileManager.default.fileExists(atPath: newPath) else { return }
        let url = URL(fileURLWithPath: newPath)
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            startVideo(url)
        } else {
            loadImage(url)
        }
    }

    private func loadImage(_ url: URL) {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let loader = MTKTextureLoader(device: device)
        texture = try? loader.newTexture(cgImage: cg, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
        aspect = Float(cg.width) / Float(max(cg.height, 1))
    }

    private func startVideo(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
        }
        player = p
        output = out
        isVideo = true
        p.play()
    }

    private func stopVideo() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        output = nil
        cvTexture = nil
    }
}
