import Foundation
import simd

/// Anime: a stack of anime-style layers (see DreamcastLayers.swift, the `an*` kinds) drawn by AnimeGPU. The CPU keeps
/// the music state (16 relative band levels, bass / mid / treble, loudness, drum pulses), the wind, every layer's clock,
/// the one-shot effects (slashes, bursts, shooting stars), and the camera: its move (pan, drift, push in, tilt up),
/// cuts on the beat, impact frames. The orbit camera (`rc.camera`) is not the shot's:
/// it looks at the layers as cards in 3D (one plane each, `anSpacing` apart), ray-cast in `anLayersFrag`. The layers' own animation can be held "on twos"
/// (a new drawing 12 times a second) while the camera moves smoothly, as in anime.
final class AnimeViz: Visualizer {
    private static let bandCount = 16
    private var smoother = Smoother()
    private var levels = [SmoothValue](repeating: SmoothValue(), count: bandCount)
    private var avgs = [Float](repeating: 0.1, count: bandCount)
    private var peaks = [Float](repeating: 0.2, count: bandCount)
    private var onsets = Onsets()
    private var kick: Float = 0, snare: Float = 0, hat: Float = 0, surge: Float = 0
    private var loudS = SmoothValue()
    private var clocks: [UUID: Double] = [:]
    private var shots: [UUID: Shots] = [:]
    // wind
    private var windS = SmoothValue()
    private var windPhase: Double = 0
    private var gust: Float = 0
    // camera
    private var travel: Double = 0
    private var driftClock: Double = 0
    private var shot: Double = 0          // progress of the current push-in / tilt-up shot
    private var framing = Framing()
    private var lastBeat = -1
    private var lastBeatTime: Double = -100
    private var cutTimer: Double = 0
    // impact frames
    private var impactT: Float = 0, impactStyle: Float = 0, impactCool: Float = 0, impactNext = 0
    // drawings on twos / threes: what the last drawing showed
    private var drawIdx = -1
    private var held: (music: SIMD4<Float>, hits: SIMD4<Float>, time: SIMD4<Float>, bands: [SIMD4<Float>],
                       layers: [UUID: (clock: Float, e: SIMD4<Float>, f: SIMD4<Float>)])?
    private var frame: Float = 0
    /// Debug: `AUDIOWATCH_ANIME_IMPACT=<0…5>` shows that impact look on every frame.
    private static let debugImpact: Int? = ProcessInfo.processInfo.environment["AUDIOWATCH_ANIME_IMPACT"].flatMap { Int($0) }
    /// Debug: `AUDIOWATCH_ANIME_SCENE=<name>` shows one of the ready-made stacks instead of the saved layers (never saved).
    private static let debugScene: [DCLayer]? = ProcessInfo.processInfo.environment["AUDIOWATCH_ANIME_SCENE"]
        .flatMap { name in DCScene.anime.first { $0.name.lowercased() == name.lowercased() }?.layers }

    /// Japanese titles: which line shows, for how long, and (Giant kanji) which of its characters.
    private struct TitleState {
        var line = 0
        var age: Float = 0
        var lastBeat = -1
        var char = 0
        var charT: Float = 0
        /// Ticker: the left edge of the current line (layer units); the next ones follow it.
        var x0: Float = 99
    }
    static let tickerChar: Float = 0.055, tickerGap: Float = 2
    private var titles: [UUID: TitleState] = [:]

    /// A cut's framing: extra camera offset, zoom and roll (Dutch angle).
    private struct Framing {
        var x: Double = 0, y: Double = 0, zoom: Double = 1, roll: Double = 0
    }

    /// One-shot effects of a layer: up to three slashes, a burst, a shooting star (ages in seconds × Speed, seeds 0…1).
    private struct Shots {
        var ages: [Float] = [99, 99, 99]
        var seeds: [Float] = [0, 0, 0]
        var strength: Float = 1
        var since: Float = 0
        var next = 0
    }

    func build(_ f: FrameBuilder, _ rc: RenderContext) {
        let s = rc.s
        let dt = Float(rc.dt)
        let n = Self.bandCount
        let vals = smoother.step(rc.analyzer.bands(count: n, s: s), smoothing: min(s.smoothing, 0.6), dt: rc.dt, frozen: rc.frozen)
        let hits = rc.frozen ? [] : onsets.step(rc)
        var loud: Float = loudS.x
        if !rc.frozen {
            for i in 0..<n {
                let v = vals[i]
                avgs[i] += (v - avgs[i]) * (1 - exp(-dt / 1.5))
                peaks[i] = max(v, peaks[i] * exp(-dt / 3))
                let steady = min(1, v / max(peaks[i], 0.05))
                let rise = min(1, max(0, v - avgs[i]) / max(peaks[i] - avgs[i], 0.03))
                let quiet = min(1, v / 0.03)
                _ = levels[i].step(to: (0.45 * steady + 0.55 * rise) * quiet, dt: dt, omega: 16)
            }
            for h in hits {
                switch h.band {
                case 0: kick = max(kick, 0.4 + 0.6 * h.strength); surge += h.strength
                    gust = max(gust, h.strength)
                case 1: snare = max(snare, 0.4 + 0.6 * h.strength)
                default: hat = max(hat, 0.3 + 0.7 * h.strength)
                }
            }
            kick *= exp(-dt / 0.15); snare *= exp(-dt / 0.15); hat *= exp(-dt / 0.08)
            surge = min(2, surge * exp(-dt / 0.3))
            gust *= exp(-dt / 0.6)
            let db = 20 * log10f(rc.analyzer.rms(last: 2048) * Float(s.gain) + 1e-7)
            loud = loudS.step(to: min(1, max(0, (db + 50) / 42)), dt: dt, omega: 4)
        }
        func mean(_ r: Range<Int>) -> Float { r.reduce(0) { $0 + levels[$1].x } / Float(r.count) }
        let bass = mean(0..<4), mid = mean(4..<11), treble = mean(11..<16)
        let drive = min(3, 0.8 * loud + 0.6 * bass + surge)

        if !rc.frozen {
            // wind: a breeze, the bass and the kicks' gusts
            let w = windS.step(to: 0.3 + 0.9 * bass + 0.5 * gust, dt: dt, omega: 1.6)
            windPhase += rc.dt * Double(0.3 + w)
            if windPhase > 100_000 { windPhase -= 100_000 }
            stepCamera(s, dt: rc.dt, drive: drive, beatCount: rc.analyzer.beatCount, time: rc.time)
            stepImpact(s, dt: dt, hits: hits)
        }

        // the drawing this frame shows: on twos / threes the layers' own motion holds between drawings
        let fps = s.anFrames.fps
        let idx = fps > 0 ? Int(floor(rc.time * fps)) : Int(frame)
        let seedRate = fps > 0 ? fps : 12
        let seed = Float(Int(floor(rc.time * seedRate)) % 100_000)
        let newDrawing = held == nil || idx != drawIdx || rc.frozen

        var u = ANUniforms()
        u.music = SIMD4(bass, mid, treble, loud)
        u.hits = SIMD4(kick, snare, hat, rc.beat)
        let tStep = fps > 0 ? floor(rc.time * fps) / fps : rc.time
        u.time = SIMD4(Float(tStep.truncatingRemainder(dividingBy: 3600)), windS.x, Float(windPhase), gust)
        let lv = levels.map(\.x)
        var bands = [SIMD4(lv[0], lv[1], lv[2], lv[3]), SIMD4(lv[4], lv[5], lv[6], lv[7]),
                     SIMD4(lv[8], lv[9], lv[10], lv[11]), SIMD4(lv[12], lv[13], lv[14], lv[15])]
        if !newDrawing, let h = held {
            u.music = h.music; u.hits = h.hits; u.time = h.time; bands = h.bands
        }
        u.b0 = bands[0]; u.b1 = bands[1]; u.b2 = bands[2]; u.b3 = bands[3]
        func pal(_ t: Float) -> SIMD4<Float> { SIMD4(rc.palette.rgb(t + rc.phase), 1) }
        u.pal0 = pal(0); u.pal1 = pal(1.0 / 3); u.pal2 = pal(2.0 / 3); u.pal3 = pal(1)
        fillCamera(&u, s, rc)
        u.post = SIMD4(Float(s.anFilm), impactT > 0 ? 1 : 0, Float(s.anLetterbox), impactStyle)
        frame += 1
        if frame > 1_000_000 { frame = 0 }
        u.outp.z = frame
        u.outp.w = Float(s.anRetro)
        if let look = Self.debugImpact { u.post.y = 1; u.post.w = Float(look) }

        var layers: [ANLayerUniforms] = []
        var seen = Set<UUID>()
        var nextHeld: [UUID: (clock: Float, e: SIMD4<Float>, f: SIMD4<Float>)] = [:]
        // every titles layer's lines, each layer's in a block of rows (the atlas)
        var titleLines: [String] = []
        var titleBase: [UUID: (row: Int, count: Int)] = [:]
        for l in (Self.debugScene ?? s.anLayers).prefix(DCScene.maxLayers) where l.kind == .anTitle && l.on {
            let ls = AnimeTitles.lines(l.text).prefix(max(0, AnimeTitles.maxRows - titleLines.count))
            titleBase[l.id] = (titleLines.count, ls.count)
            titleLines += ls
        }
        for l in (Self.debugScene ?? s.anLayers).prefix(DCScene.maxLayers) {
            seen.insert(l.id)
            let react = Float(min(1, max(0, l.react)))
            var clock = clocks[l.id] ?? 0
            if !rc.frozen {
                let rate = l.speed * Double(1 - react + react * (0.2 + 1.6 * drive))
                clock += rc.dt * rate
                if clock > 4096 { clock -= 4096 }
                clocks[l.id] = clock
                stepShots(l, dt: dt, react: react, hits: hits)
                if l.kind == .anTitle {
                    stepTitle(l, dt: dt, react: react, beatCount: rc.analyzer.beatCount,
                              edge: Float(rc.size.x / max(rc.size.y, 1)) * 0.5 / Float(max(0.02, l.scale)) + 0.05,
                              clockStep: Float(rc.dt * rate))
                }
            }
            guard l.on, l.kind.era.mode == .anime else { continue }
            var L = ANLayerUniforms()
            L.a = SIMD4(l.kind.shaderIndex, Float(min(max(0, l.style), l.kind.styles.count - 1)), Float(min(1, max(0, l.opacity))), react)
            let aspect = rc.size.x / max(rc.size.y, 1)
            L.b = SIMD4(Float(l.x) * aspect * 0.5, Float(l.y) * 0.5, Float(max(0.02, l.scale)), Float(l.rotation) * .pi / 180)
            L.c = SIMD4(Float(clock), Float(l.hue), Float(max(0, l.depth)), seed)
            if l.kind == .anSlash { L.e = SIMD4(99, 0, 99, 0); L.f = SIMD4(99, 0, 0, 0) }
            if l.kind == .anBurst || l.kind == .anStars { L.e = SIMD4(99, 0, 1, 0) }
            if l.kind.repeatsSideways { L.f.w = 1 }
            if l.kind == .anTitle {
                let st = titles[l.id] ?? TitleState()
                L.e = SIMD4(-1, 0, 0, 0)
                if let base = titleBase[l.id], base.count > 0 {
                    let k = st.line % base.count
                    let line = titleLines[base.row + k]
                    let m = AnimeTitles.masks(line)
                    let n = min(line.count, AnimeTitles.cols)
                    L.e = SIMD4(Float(base.row + k), Float(n), st.age, m.rot)
                    L.f = SIMD4(m.small, Float(st.char % max(1, n)), 0, 0)
                    if l.style == 2 {
                        // the ticker: all the layer's lines end to end from x0, starting at the current one;
                        // their lengths − 1 packed 4 bits each (6 a float)
                        var packs: [Int] = [0, 0]
                        for j in 0..<min(base.count, 12) {
                            let c = max(1, min(titleLines[base.row + j].count, AnimeTitles.cols)) - 1
                            packs[j / 6] |= c << (4 * (j % 6))
                        }
                        L.e = SIMD4(Float(base.row), Float(min(base.count, 12)), st.x0, Float(k))
                        L.f = SIMD4(Float(packs[0]), Float(packs[1]), 0, 0)
                    }
                }
            }
            if let sh = shots[l.id] {
                switch l.kind {
                case .anSlash:
                    L.e = SIMD4(sh.ages[0], sh.seeds[0], sh.ages[1], sh.seeds[1])
                    L.f = SIMD4(sh.ages[2], sh.seeds[2], 0, 0)
                case .anBurst, .anStars:
                    let k = (sh.next + 2) % 3   // the newest
                    L.e = SIMD4(sh.ages[k], sh.seeds[k], sh.strength, 0)
                default: break
                }
            }
            if !newDrawing, let h = held?.layers[l.id] {
                L.c.x = h.clock; L.e = h.e; L.f = h.f
            }
            nextHeld[l.id] = (L.c.x, L.e, L.f)
            layers.append(L)
        }
        if newDrawing {
            held = (u.music, u.hits, u.time, bands, nextHeld)
            drawIdx = idx
        }
        clocks = clocks.filter { seen.contains($0.key) }
        shots = shots.filter { seen.contains($0.key) }
        titles = titles.filter { seen.contains($0.key) }

        var su = baseUniforms(rc)
        su.count = Float(layers.count)
        f.shaderMode = ShaderModeDraw(kind: .anime, u: su, data: [],
                                      anime: AnimeInput(u: u, layers: layers, lines: Int(s.anRes.rounded()), titleLines: titleLines))
    }

    // MARK: - Camera

    private func stepCamera(_ s: VizSettings, dt: Double, drive: Float, beatCount: Int, time: Double) {
        let speed = s.anCamSpeed * (1 + 0.8 * Double(drive))
        travel += dt * speed * 0.06
        driftClock += dt * max(0.05, speed)
        shot += dt * speed * 0.12
        // cuts: every 32 beats at low values … every 4 at 1 (by time when no beat is found)
        if s.anCuts > 0.001 {
            let every = max(4, Int((32 * pow(1.0 / 8, s.anCuts)).rounded()))
            if beatCount != lastBeat {
                if lastBeat >= 0, beatCount % every == 0 { cut(s) }
                lastBeat = beatCount
                lastBeatTime = time
            } else if time - lastBeatTime > 3 {
                cutTimer += dt
                if cutTimer > Double(every) * 0.5 { cut(s) }
            }
        } else if framing.zoom != 1 || framing.x != 0 || framing.y != 0 || framing.roll != 0 {
            framing = Framing()
        }
        // push in / tilt up start over by themselves when nothing cuts them
        if (s.anCamStyle == .pushIn || s.anCamStyle == .tiltUp) && shot > 3.2 && s.anCuts <= 0.001 { shot = 0 }
    }

    private func cut(_ s: VizSettings) {
        cutTimer = 0
        shot = 0
        travel += Double.random(in: 0.6...3)
        switch Int.random(in: 0..<5) {
        case 0: framing = Framing()
        case 1: framing = Framing(x: .random(in: -0.25...0.25), y: .random(in: -0.08...0.12), zoom: .random(in: 1.2...1.45))
        case 2: framing = Framing(x: .random(in: -0.15...0.15), y: .random(in: -0.05...0.1), zoom: .random(in: 1.55...1.9))
        case 3: framing = Framing(x: .random(in: -0.2...0.2), y: .random(in: -0.05...0.15), zoom: .random(in: 1.1...1.4),
                                  roll: (Bool.random() ? 1 : -1) * .random(in: 0.05...0.1))
        default: framing = Framing(x: .random(in: -0.3...0.3), y: .random(in: 0...0.2), zoom: 1)
        }
    }

    private func fillCamera(_ u: inout ANUniforms, _ s: VizSettings, _ rc: RenderContext) {
        var cx = 0.0, cy = 0.0, push = 0.0, roll = 0.0, side = 0.0
        switch s.anCamStyle {
        case .still: break
        case .pan: side = travel.truncatingRemainder(dividingBy: 2048)
        case .drift:
            let t = driftClock
            cx = 0.10 * sin(0.21 * t) + 0.04 * sin(0.53 * t + 1)
            cy = 0.04 * sin(0.17 * t + 2)
            roll = 0.012 * sin(0.13 * t)
            push = 0.08 + 0.06 * sin(0.11 * t)
        case .pushIn:
            push = 0.55 * (1 - exp(-shot))
        case .tiltUp:
            let k = min(1, shot / 2.5)
            cy = -0.35 + 0.85 * k * k * (3 - 2 * k)
        }
        cx += framing.x; cy += framing.y; roll += framing.roll
        // the shot's own framing (sliders); the orbit camera moves around the layers in 3D instead (below)
        cx += s.anPanX * 0.6
        cy += s.anPanY * 0.4
        u.cam = SIMD4(Float(cx), Float(cy), Float(max(0.05, s.anZoom) * framing.zoom), Float(roll))
        u.cam2 = SIMD4(Float(push), 0, 0, Float(side))
        // the layer cards in 3D, seen through the orbit camera (drag to turn, scroll to zoom, pan; pan is in points, y down)
        let R = rc.camera.rotation
        u.rot0 = SIMD4(R[0][0], R[1][0], R[2][0], 0)
        u.rot1 = SIMD4(R[0][1], R[1][1], R[2][1], 0)
        u.rot2 = SIMD4(R[0][2], R[1][2], R[2][2], 0)
        u.view = SIMD4(rc.camera.zoom, rc.camera.pan.x / max(1, rc.size.x / 2), -rc.camera.pan.y / max(1, rc.size.y / 2),
                       Float(max(0, s.anSpacing)) * 0.4)
    }

    // MARK: - Impact frames, one-shots

    private func stepImpact(_ s: VizSettings, dt: Float, hits: [(band: Int, strength: Float)]) {
        impactT -= dt
        impactCool -= dt
        guard s.anImpact > 0.001 else { impactT = 0; return }
        let thr = Float(0.9 - 0.55 * s.anImpact)
        for h in hits where (h.band == 0 || h.band == 1) && h.strength > thr && impactCool <= 0 {
            impactT = 0.09 + 0.06 * h.strength
            impactCool = Float(3.0 - 2.6 * s.anImpact)
            if s.anImpactLook == .rotate {
                impactStyle = Float(impactNext)
                impactNext = (impactNext + 1 + Int.random(in: 0..<2)) % AnimeImpactLook.looks
            } else {
                impactStyle = Float(s.anImpactLook.shaderIndex)
            }
        }
    }

    /// The next line comes in on a beat once the current one has had its time (sooner with more Music, longer at a
    /// lower Speed); Giant kanji steps through the line's characters on every beat.
    private func stepTitle(_ l: DCLayer, dt: Float, react: Float, beatCount: Int, edge: Float, clockStep: Float) {
        let ls = Array(AnimeTitles.lines(l.text).prefix(12))
        let n = ls.count
        var st = titles[l.id] ?? TitleState()
        if l.style == 2 {
            // the ticker scrolls on the layer's clock (Speed × music); a line that has left the screen hands over
            if st.x0 > edge + 1 { st.x0 = edge }
            st.x0 -= 0.25 * clockStep
            if n > 0 {
                let w = Float(min(ls[st.line % n].count, AnimeTitles.cols)) + Self.tickerGap
                if st.x0 + w * Self.tickerChar < -edge { st.x0 += w * Self.tickerChar; st.line = (st.line + 1) % n }
            }
            st.age += dt
            titles[l.id] = st
            return
        }
        let sp = Float(max(0.1, l.speed))
        st.age += dt
        st.charT += dt * sp
        let hold = (2.5 + 9 * (1 - react)) / sp
        func next() { st.line = n > 0 ? (st.line + 1) % n : 0; st.age = 0; st.char = 0; st.charT = 0 }
        if beatCount != st.lastBeat {
            if st.lastBeat >= 0 {
                if st.age >= hold { next() } else if st.charT > 0.25 { st.char += 1; st.charT = 0 }
            }
            st.lastBeat = beatCount
        }
        if st.age >= hold + 2.5 { next() }          // no beat found: by time
        if st.charT > 1.6 { st.char += 1; st.charT = 0 }
        titles[l.id] = st
    }

    private func stepShots(_ l: DCLayer, dt: Float, react: Float, hits: [(band: Int, strength: Float)]) {
        guard l.kind == .anSlash || l.kind == .anBurst || l.kind == .anStars else { return }
        var sh = shots[l.id] ?? Shots()
        let sp = Float(max(0.05, l.speed))
        for i in 0..<3 { sh.ages[i] += dt * sp }
        sh.since += dt * sp
        func spawn(_ strength: Float) {
            sh.ages[sh.next] = 0
            sh.seeds[sh.next] = Float.random(in: 0..<1)
            sh.strength = strength
            sh.next = (sh.next + 1) % 3
            sh.since = 0
        }
        switch l.kind {
        case .anSlash:
            for h in hits where h.band <= 1 && sh.since > 0.12 && Float.random(in: 0..<1) < react { spawn(h.strength) }
            if sh.since > 1.0 + 2.5 * react { spawn(0.7) }
        case .anBurst:
            for h in hits where h.band <= 1 && sh.since > 0.25 && Float.random(in: 0..<1) < react { spawn(h.strength) }
            if sh.since > 1.5 + 3 * react { spawn(0.7) }
        default:   // shooting stars on the hats and snares
            for h in hits where h.band >= 1 && sh.since > 0.8 && Float.random(in: 0..<1) < 0.3 * react { spawn(h.strength) }
        }
        shots[l.id] = sh
    }
}
