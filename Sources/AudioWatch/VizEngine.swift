import Foundation
import simd

/// Owns audio capture, analysis and the visualizers. The Metal renderer drives it once per frame.
final class VizEngine {
    let ring = AudioRing()
    lazy var analyzer = Analyzer(ring: ring)
    private var tap: SystemAudioTap?
    private var fileFeed: DebugFileFeed?
    private var tapError: String?
    private var statusTimer: Timer?
    private var startTime = Date().timeIntervalSinceReferenceDate
    private var cyclePhase: Float = 0
    /// Evaluates the node patch each frame.
    let nodes = NodeRuntime()
    /// Smoothed frame rate, written by the renderer.
    var fps: Double = 0

    private let visualizers: [VizMode: Visualizer] = [
        .sphere: SphereViz(),
        .oscilloscope: ScopeViz(),
        .snippet: SnippetViz(),
        .vectorscope: VectorViz(),
        .halo: HaloViz(),
        .spectrogram: SpectroViz(),
        .cymatics: CymaticsViz(),
        .flow: FlowViz(),
        .attractor: AttractorViz(),
        .harmonograph: HarmonographViz(),
        .drumhead: DrumheadViz(),
        .primitives: PrimitivesViz(),
        .field: FieldViz(),
        .mushrooms: MushroomsViz(),
        .membrane: MembraneViz(),
        .fan: FanViz(),
        .glass: GlassViz(),
        .diamond: DiamondViz(),
    ]

    var outputName: String { tap?.outputName ?? "" }
    var tapOK: Bool { tapError == nil }

    func visualizer(for mode: VizMode) -> Visualizer { visualizers[mode]! }

    func start(app: AppState) {
        guard tap == nil, fileFeed == nil else { return }
        startTime = Date().timeIntervalSinceReferenceDate
        if let path = ProcessInfo.processInfo.environment["AUDIOWATCH_WAV"] {
            fileFeed = DebugFileFeed(path: path, ring: ring)
            return
        }
        let tap = SystemAudioTap(ring: ring)
        tap.onStatus = { [weak self] msg in self?.tapError = msg }
        self.tap = tap
        tap.start()

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak app] _ in
            guard let self, let app else { return }
            let now = Date().timeIntervalSinceReferenceDate
            var msg: String?
            if let err = self.tapError {
                msg = "Audio capture failed: \(err). Requires macOS 14.2 or later."
            } else if !app.frozen && now - self.startTime > 3 && CACurrentMediaTimeSafe() - self.analyzer.lastSoundTime > 3 {
                msg = "No audio signal. If something is playing, allow soundwatch in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch."
            }
            if app.status != msg { app.status = msg }
        }
    }

    func prepare(size: SIMD2<Float>, settings base: VizSettings, dt: Double, time: Double, frozen: Bool) -> RenderContext {
        // The waterfall shows time smearing directly, so it keeps one consistent window.
        analyzer.lowLatency = base.lowLatency && base.mode.supportsLowLatency
        if !frozen { analyzer.update(now: CACurrentMediaTimeSafe(), fftSize: Int(base.fftSize)) }
        let s = nodes.apply(base, analyzer: analyzer, dt: dt, frozen: frozen).applyingIntensity()
        cyclePhase += Float(dt * s.colorCycle * 0.15)
        if cyclePhase > 2 { cyclePhase -= 2 }
        return RenderContext(
            size: size, s: s, time: time, dt: dt, frozen: frozen, analyzer: analyzer,
            palette: s.effectivePalette, phase: Float(s.hueShift) + cyclePhase,
            ink: s.effectiveInk,
            beat: analyzer.beatPulse * Float(s.beat))
    }
}

import QuartzCore
@inline(__always) func CACurrentMediaTimeSafe() -> Double { CACurrentMediaTime() }

import AVFoundation

/// Debug aid: AUDIOWATCH_WAV=/path/file plays a file into the ring in real time (looped) instead of the system tap.
final class DebugFileFeed {
    private let timer: DispatchSourceTimer
    init?(path: String, ring: AudioRing) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), sr = file.processingFormat.sampleRate
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = buf.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        ring.sampleRate = sr
        let chunk = Int(ProcessInfo.processInfo.environment["AUDIOWATCH_WAV_CHUNK"] ?? "512") ?? 512
        var pos = 0
        let start = CACurrentMediaTime()
        var sent = 0
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "soundwatch.filefeed", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler {
            let due = Int((CACurrentMediaTime() - start) * sr)
            while sent + chunk <= due {
                var lc = [Float](repeating: 0, count: chunk), rc = lc
                for i in 0..<chunk { lc[i] = l[(pos + i) % n]; rc[i] = r[(pos + i) % n] }
                lc.withUnsafeBufferPointer { lp in rc.withUnsafeBufferPointer { rp in
                    ring.writeFrames(l: lp.baseAddress!, r: rp.baseAddress!, frames: chunk)
                } }
                pos = (pos + chunk) % n
                sent += chunk
            }
        }
        timer.resume()
    }
}
