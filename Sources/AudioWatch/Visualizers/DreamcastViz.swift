import Foundation
import simd

/// Dreamcast: a stack of retro-console layers (see DreamcastLayers.swift) drawn by DreamcastGPU. The CPU keeps the
/// music state (16 band levels relative to their own average and peak, bass / mid / treble, loudness, drum pulses,
/// the equalizer's falling peaks), every layer's clock (Speed × how hard the music drives it) and the HUD's text.
final class DreamcastViz: Visualizer {
    private static let bandCount = 16
    private var smoother = Smoother()
    private var levels = [SmoothValue](repeating: SmoothValue(), count: bandCount)
    private var avgs = [Float](repeating: 0.1, count: bandCount)
    private var peaks = [Float](repeating: 0.2, count: bandCount)
    /// Equalizer caps: they hold for a moment, then fall.
    private var caps = [Float](repeating: 0, count: bandCount)
    private var capHold = [Float](repeating: 0, count: bandCount)
    private var onsets = Onsets()
    private var kick: Float = 0, snare: Float = 0, hat: Float = 0, surge: Float = 0
    private var loudS = SmoothValue()
    private var clocks: [UUID: Double] = [:]
    // HUD state
    private var score: Double = 0
    private var hiScore: Double = 100_000
    private var lapTime: Double = 0
    private var countdown: Double = 60
    private var speedS = SmoothValue()
    private var shield: Float = 1
    private var enemies = 8
    private var missiles = 4
    // the little games' state, per layer
    private var aliens: [UUID: Aliens] = [:]
    private var breakers: [UUID: Breaker] = [:]
    private var runners: [UUID: Runner] = [:]

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
                let l = levels[i].step(to: (0.45 * steady + 0.55 * rise) * quiet, dt: dt, omega: 16)
                if l >= caps[i] { caps[i] = l; capHold[i] = 0.4 } else if capHold[i] > 0 { capHold[i] -= dt } else { caps[i] = max(l, caps[i] - dt * 0.6) }
            }
            for h in hits {
                switch h.band {
                case 0: kick = max(kick, 0.4 + 0.6 * h.strength); surge += h.strength
                case 1: snare = max(snare, 0.4 + 0.6 * h.strength)
                default: hat = max(hat, 0.3 + 0.7 * h.strength)
                }
            }
            kick *= exp(-dt / 0.15); snare *= exp(-dt / 0.15); hat *= exp(-dt / 0.08)
            surge = min(2, surge * exp(-dt / 0.3))
            // loudness: −50 … −8 dBFS (with Gain) → 0 … 1
            let db = 20 * log10f(rc.analyzer.rms(last: 2048) * Float(s.gain) + 1e-7)
            loud = loudS.step(to: min(1, max(0, (db + 50) / 42)), dt: dt, omega: 4)
        }
        func mean(_ r: Range<Int>) -> Float { r.reduce(0) { $0 + levels[$1].x } / Float(r.count) }
        let bass = mean(0..<4), mid = mean(4..<11), treble = mean(11..<16)
        // how hard the music pushes everything that moves (layers scale it by their Music amount)
        let drive = min(3, 0.8 * loud + 0.6 * bass + surge)

        var u = DCUniforms()
        u.music = SIMD4(bass, mid, treble, loud)
        u.hits = SIMD4(kick, snare, hat, rc.beat)
        u.crt = SIMD4(Float(s.dcCRT), Float(s.dcWarp), Float(rc.time.truncatingRemainder(dividingBy: 3600)), s.dcConsole.shaderIndex)
        let lv = levels.map(\.x)
        u.b0 = SIMD4(lv[0], lv[1], lv[2], lv[3]); u.b1 = SIMD4(lv[4], lv[5], lv[6], lv[7])
        u.b2 = SIMD4(lv[8], lv[9], lv[10], lv[11]); u.b3 = SIMD4(lv[12], lv[13], lv[14], lv[15])
        u.k0 = SIMD4(caps[0], caps[1], caps[2], caps[3]); u.k1 = SIMD4(caps[4], caps[5], caps[6], caps[7])
        u.k2 = SIMD4(caps[8], caps[9], caps[10], caps[11]); u.k3 = SIMD4(caps[12], caps[13], caps[14], caps[15])
        func pal(_ t: Float) -> SIMD4<Float> { SIMD4(rc.palette.rgb(t + rc.phase), 1) }
        u.pal0 = pal(0); u.pal1 = pal(1.0 / 3); u.pal2 = pal(2.0 / 3); u.pal3 = pal(1)
        // the screen in 3D: the orbit camera (drag to turn, scroll to zoom, pan); pan is in points, y down
        let R = rc.camera.rotation
        u.cam0 = SIMD4(R[0][0], R[1][0], R[2][0], 0)
        u.cam1 = SIMD4(R[0][1], R[1][1], R[2][1], 0)
        u.cam2 = SIMD4(R[0][2], R[1][2], R[2][2], 0)
        u.view = SIMD4(rc.camera.zoom, rc.camera.pan.x / max(1, rc.size.x / 2), -rc.camera.pan.y / max(1, rc.size.y / 2), 0)

        if !rc.frozen { stepHud(dt: Double(dt), loud: loud, drive: drive, hits: hits) }

        let aspect = rc.size.x / max(rc.size.y, 1)
        let lines = Int(s.dcRes.rounded())
        let pxA = s.dcConsole.pixelAspect
        let H = Float(max(48, min(1440, lines)))   // as DreamcastGPU clamps it
        var layers: [DCLayerUniforms] = []
        var text: [DCTextItem] = []
        var seen = Set<UUID>()
        for l in s.dcLayers.prefix(DCScene.maxLayers) {
            seen.insert(l.id)
            let react = Float(min(1, max(0, l.react)))
            var clock = clocks[l.id] ?? 0
            var dClock = 0.0
            if !rc.frozen {
                // react 0: steady at Speed; react 1: crawls in silence, races when it's loud
                let rate = l.speed * Double(1 - react + react * (0.2 + 1.6 * drive))
                dClock = rc.dt * rate
                clock += dClock
                if clock > 4096 { clock -= 4096 }
                clocks[l.id] = clock
            }
            guard l.on else { continue }
            var L = DCLayerUniforms()
            L.a = SIMD4(l.kind.shaderIndex, Float(min(max(0, l.style), l.kind.styles.count - 1)), Float(min(1, max(0, l.opacity))), react)
            L.b = SIMD4(Float(l.x) * aspect * 0.5, Float(l.y) * 0.5, Float(max(0.02, l.scale)), Float(l.rotation) * .pi / 180)
            var c = SIMD4<Float>(Float(clock), Float(l.hue), 0, 0)
            if l.kind == .hud {
                let start = text.count
                hudText(style: l.style, aspect: aspect, lines: H, pixelAspect: pxA, beatCount: rc.analyzer.beatCount, time: rc.time,
                        loud: loud, drive: drive, into: &text)
                if text.count > DreamcastGPU.maxText { text.removeLast(text.count - DreamcastGPU.maxText) }
                c.z = Float(start); c.w = Float(max(0, text.count - start))
            }
            let frozen = rc.frozen
            switch l.kind {
            case .invaders:
                var g = aliens[l.id] ?? Aliens()
                if !frozen { g.step(clock: clock, dt: dt, hits: hits, H: H) }
                aliens[l.id] = g
                g.fill(&c, &L, clock: clock, H: H)
            case .breaker:
                var g = breakers[l.id] ?? Breaker()
                if !frozen { g.step(dist: Float(dClock) * 0.9, dt: dt) }
                breakers[l.id] = g
                L.d = SIMD4(UInt32(truncatingIfNeeded: g.alive), UInt32(truncatingIfNeeded: g.alive >> 32), 0, 0)
                L.e = SIMD4(g.ball.x, g.ball.y, g.paddle, 0)
            case .platformer:
                var g = runners[l.id] ?? Runner()
                if !frozen { g.step(dt: dt, hits: hits) }
                runners[l.id] = g
                L.e = SIMD4(g.h, g.h > 0.01 ? 1 : 0, 0, 0)
            case .scroller:
                let start = text.count
                let f = max(1, (H / 80).rounded()) / H, cw = 6 * f
                let sc = Float(max(0.02, l.scale))
                let n = min(64, Int((aspect / sc) / cw) + 8)
                let pos = clock * 4
                let base = Int(floor(pos))
                let str = Array((l.text.isEmpty ? DCLayer.defaultText : l.text).uppercased().unicodeScalars) + Array("      ".unicodeScalars)
                let items = (n + 15) / 16
                for k in 0..<items {
                    var chunk = ""
                    for j in 0..<16 { chunk.unicodeScalars.append(str[(base + k * 16 + j) % str.count]) }
                    text.append(Self.item(chunk, 0, 0, 0, 0))
                }
                if text.count > DreamcastGPU.maxText { text.removeLast(text.count - DreamcastGPU.maxText) }
                c.z = Float(start); c.w = Float(max(0, text.count - start))
                L.e = SIMD4(Float(pos - Double(base)), -aspect / (2 * sc) - 4 * cw, cw, Float(base % 1000))
            default: break
            }
            L.c = c
            layers.append(L)
        }
        clocks = clocks.filter { seen.contains($0.key) }
        aliens = aliens.filter { seen.contains($0.key) }
        breakers = breakers.filter { seen.contains($0.key) }
        runners = runners.filter { seen.contains($0.key) }

        var su = baseUniforms(rc)
        su.count = Float(layers.count)
        f.shaderMode = ShaderModeDraw(kind: .dreamcast, u: su, data: [],
                                      dreamcast: DreamcastInput(u: u, layers: layers, text: text, lines: lines, pixelAspect: pxA))
    }

    // MARK: - HUD

    private func stepHud(dt: Double, loud: Float, drive: Float, hits: [(band: Int, strength: Float)]) {
        score += dt * Double(40 + 2600 * loud * loud + 900 * drive)
        if score > 9_999_990 { score = 0 }
        hiScore = max(hiScore, score)
        lapTime += dt
        if lapTime >= 600 { lapTime = 0 }
        countdown -= dt
        if countdown < 0 { countdown = Double(Int.random(in: 45...75)) }
        _ = speedS.step(to: 60 + 130 * min(2, drive), dt: Float(dt), omega: 3)
        shield = min(1, shield + Float(dt) * 0.08)
        for h in hits {
            if h.band == 0 {
                shield = max(0.1, shield - 0.06 * h.strength)
                missiles -= 1
                if missiles < 0 { missiles = 4 }
            } else if h.band == 1 {
                enemies -= 1
                if enemies < 0 { enemies = Int.random(in: 6...12) }
                score += 500
            }
        }
    }

    /// One text line: `x` / `y` = top-left in screen units (y up), `px` = font pixel, `style` = colour (see textColour).
    private static func item(_ str: String, _ x: Float, _ y: Float, _ px: Float, _ style: Int) -> DCTextItem {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, ch) in str.uppercased().unicodeScalars.prefix(16).enumerated() {
            let v = ch.value
            bytes[i] = v >= 32 && v < 96 ? UInt8(v) : 32
        }
        func word(_ k: Int) -> UInt32 {
            UInt32(bytes[k]) | UInt32(bytes[k + 1]) << 8 | UInt32(bytes[k + 2]) << 16 | UInt32(bytes[k + 3]) << 24
        }
        return DCTextItem(pos: SIMD4(x, y, px, Float(style)), chars: SIMD4(word(0), word(4), word(8), word(12)))
    }

    private static func bar(_ at: (Float, Float), _ px: Float, cells: Int, fill: Float, style: Int) -> DCTextItem {
        DCTextItem(pos: SIMD4(at.0, at.1, px, Float(16 + style)), chars: SIMD4(UInt32(cells), UInt32(min(1, max(0, fill)) * 1000), 0, 0))
    }

    /// Width of a text line in screen units.
    private static func width(_ str: String, _ px: Float) -> Float { Float(min(16, str.count) * 6 - 1) * px }

    private func hudText(style: Int, aspect: Float, lines H: Float, pixelAspect pxA: Float, beatCount: Int, time: Double,
                         loud: Float, drive: Float, into out: inout [DCTextItem]) {
        // one font pixel = one console pixel at 240 lines (never smaller than a console pixel, which is wide on the 2600)
        let px = max(1 / 240, pxA / H)
        let m: Float = 8 * px
        let left = -aspect / 2 + m, right = aspect / 2 - m, top: Float = 0.5 - m, bottom: Float = -0.5 + m
        // snap each line's corner to a console pixel's corner (as DreamcastGPU sizes the texture): otherwise pixel centres
        // can land right on the font's cell edges and columns double up or drop out
        let W = (H * aspect / pxA).rounded()
        func snap(_ x: Float, _ y: Float) -> (Float, Float) {
            (((x * H / pxA + W / 2).rounded() - W / 2) * pxA / H, ((y * H - H / 2).rounded() + H / 2) / H)
        }
        func put(_ s: String, _ x: Float, _ y: Float, _ size: Float = 1, _ st: Int) {
            let (sx, sy) = snap(x, y)
            out.append(Self.item(s, sx, sy, px * size, st))
        }
        func putR(_ s: String, _ x: Float, _ y: Float, _ size: Float = 1, _ st: Int) { put(s, x - Self.width(s, px * size), y, size, st) }
        func putC(_ s: String, _ y: Float, _ size: Float = 1, _ st: Int) { put(s, -Self.width(s, px * size) / 2, y, size, st) }
        let blink = beatCount > 0 ? beatCount % 2 == 0 : Int(time * 2) % 2 == 0
        switch style {
        case 0:   // racing
            put("TIME", left, top, 1, 3)
            put(String(format: "%02d", Int(countdown)), left + 28 * px, top + 3 * px, 2, 0)
            let sc = String(format: "%07d", Int(score))
            put("SCORE", -Self.width("SCORE " + sc, px) / 2, top, 1, 3)
            put(sc, -Self.width("SCORE " + sc, px) / 2 + 36 * px, top, 1, 1)
            let lap = String(format: "%d'%02d\"%02d", Int(lapTime) / 60, Int(lapTime) % 60, Int(lapTime * 100) % 100)
            putR(lap, right, top, 1, 1)
            putR("LAP", right - Self.width(lap, px) - 6 * px, top, 1, 2)
            let kmh = Int(speedS.x)
            put(String(format: "%3d", kmh), left, bottom + 22 * px, 2, 4)
            put("KM/H", left + 38 * px, bottom + 15 * px, 1, 4)
            out.append(Self.bar(snap(left, bottom + 6 * px), px, cells: 10, fill: Float(kmh) / 320, style: 0))
            let stage = 1 + (beatCount / 64) % 5
            putR("STAGE \(stage)", right, bottom + 7 * px, 1, 0)
        case 1:   // arcade
            put("1UP", left + 6 * px, top, 1, 4)
            put(String(format: "%06d", Int(score) % 1_000_000), left, top - 9 * px, 1, 1)
            putC("HI SCORE", top, 1, 4)
            putC(String(format: "%06d", Int(hiScore) % 1_000_000), top - 9 * px, 1, 1)
            putR("2UP", right - 6 * px, top, 1, 4)
            if blink { putC("PRESS START", bottom + 26 * px, 1, 0) }
            put("*\(1 + missiles % 4)", left, bottom + 7 * px, 1, 0)
            putR("CREDIT 0", right, bottom + 7 * px, 1, 1)
        default:  // shooter
            put("MISSILES: \(missiles)", left, top, 1, 1)
            putC("SCORE: \(Int(score))", top, 1, 1)
            putR("ENEMIES: \(enemies)", right, top, 1, 4)
            put("SPEED", left, bottom + 26 * px, 1, 1)
            out.append(Self.bar(snap(left, bottom + 18 * px), px, cells: 14, fill: 0.15 + 0.85 * min(1, drive / 2), style: 1))
            put("SHIELD", left, bottom + 9 * px, 1, 5)
            out.append(Self.bar(snap(left, bottom + 1 * px), px, cells: 14, fill: shield, style: 0))
            putR("LIVES: 3", right, bottom + 7 * px, 1, 1)
        }
    }
}

// MARK: - The little games

/// Alien formation: 11 × 5 aliens marching (one step per ⅓ clock-second), who's alive, the explosion, the cannon's shot.
/// Geometry (layer units) must match dcInvaders: sprite pixel s, cells 12 s × 11 s, top row at 0.3 − rows down · 6 s.
private struct Aliens {
    static let full: UInt64 = (1 << 55) - 1
    static let sweep = 14
    var alive = full
    var boom = -1
    var boomT: Float = 0
    var stepBase = 0
    var quiet: Float = 0
    var shotX: Float = 0, shotY: Float = -2

    private func march(_ clock: Double) -> (x: Float, down: Int, step: Int) {
        let step = max(0, Int(clock * 3) - stepBase)
        let sweep = step / Self.sweep, within = step % Self.sweep
        let tri = sweep % 2 == 0 ? within : Self.sweep - within
        return (Float(tri - Self.sweep / 2) * 2, sweep, step)
    }

    private mutating func kill(_ i: Int) {
        alive &= ~(UInt64(1) << UInt64(i))
        boom = i; boomT = 0.3; quiet = 0
    }

    mutating func step(clock: Double, dt: Float, hits: [(band: Int, strength: Float)], H: Float) {
        if Int(clock * 3) < stepBase { stepBase = Int(clock * 3) }   // the clock wrapped
        var m = march(clock)
        if alive == 0 || m.down > 9 {
            alive = Self.full; stepBase = Int(clock * 3); m = march(clock)
        }
        boomT -= dt
        if boomT <= 0 { boom = -1 }
        quiet += dt
        let living = (0..<55).filter { alive & (UInt64(1) << UInt64($0)) != 0 }
        for h in hits where h.band == 0 { if let i = living.randomElement() { kill(i) } }
        if quiet > 4, let i = living.randomElement() { kill(i) }   // something happens even without kicks
        let s = max(1, (H / 120).rounded()) / H, cw = 12 * s, ch = 11 * s
        let cannon = 0.55 * Float(sin(clock * 0.8))
        if shotY < -1, hits.contains(where: { $0.band == 1 }) { shotX = cannon; shotY = -0.42 }
        if shotY > -1 {
            shotY += dt * 1.4
            let x0 = -5.5 * cw + m.x * s, y0 = 0.3 - Float(m.down) * 6 * s
            let col = Int(floor((shotX - x0) / cw))
            if col >= 0 && col < 11 {
                for r in stride(from: 4, through: 0, by: -1) where alive & (UInt64(1) << UInt64(r * 11 + col)) != 0 {
                    if shotY + 4 * s >= y0 - Float(r) * ch - 9 * s { kill(r * 11 + col); shotY = -2 }
                    break
                }
            }
            if shotY > 0.5 { shotY = -2 }
        }
    }

    func fill(_ c: inout SIMD4<Float>, _ L: inout DCLayerUniforms, clock: Double, H: Float) {
        let m = march(clock)
        c.z = m.x; c.w = Float(m.down)
        L.d = SIMD4(UInt32(truncatingIfNeeded: alive), UInt32(truncatingIfNeeded: alive >> 32), boom >= 0 ? UInt32(boom) : 0xFFFF, UInt32(m.step & 1))
        L.e = SIMD4(0.55 * Float(sin(clock * 0.8)), shotX, shotY, 0)
    }
}

/// Brick breaker: 10 × 6 bricks, a ball and a paddle that follows it. Geometry must match dcBreaker.
private struct Breaker {
    static let full: UInt64 = (1 << 60) - 1
    var alive = full
    var ball = SIMD2<Float>(0, -0.2)
    var vel = simd_normalize(SIMD2<Float>(0.6, 0.8))
    var paddle: Float = 0
    var clearT: Float = 0

    mutating func step(dist: Float, dt: Float) {
        let n = max(1, Int(dist / 0.008) + 1)
        let d = dist / Float(n)
        for _ in 0..<n {
            ball += vel * d
            if ball.x < -0.619 { ball.x = -0.619; vel.x = abs(vel.x) }
            if ball.x > 0.619 { ball.x = 0.619; vel.x = -abs(vel.x) }
            if ball.y > 0.434 { ball.y = 0.434; vel.y = -abs(vel.y) }
            if vel.y < 0, ball.y <= -0.379, ball.y > -0.42, abs(ball.x - paddle) < 0.09 {
                vel = simd_normalize(SIMD2((ball.x - paddle) / 0.09 * 0.9, 1))
            }
            if ball.y < -0.55 { ball = SIMD2(paddle, -0.37); vel = simd_normalize(SIMD2(Float.random(in: -0.6...0.6), 1)) }
            let col = Int(floor((ball.x + 0.62) / 0.124)), row = Int(floor((0.27 - ball.y) / 0.03))
            if col >= 0, col < 10, row >= 0, row < 6 {
                let bit = UInt64(1) << UInt64(row * 10 + col)
                if alive & bit != 0 { alive &= ~bit; vel.y = -vel.y }
            }
        }
        paddle += (ball.x - paddle) * min(1, dt * 10)
        paddle = min(0.55, max(-0.55, paddle))
        if alive == 0 { clearT += dt; if clearT > 0.8 { alive = Self.full; clearT = 0 } }
    }
}

/// Platformer: the runner's jump (in tiles above the ground under it). Kicks make it jump; it hops by itself when idle.
private struct Runner {
    var h: Float = 0, v: Float = 0, idle: Float = 0

    mutating func step(dt: Float, hits: [(band: Int, strength: Float)]) {
        if h <= 0 {
            idle += dt
            if let k = hits.first(where: { $0.band == 0 }) { v = 20 * (0.8 + 0.4 * k.strength); idle = 0 }
            else if idle > 2.5 { v = 16; idle = 0 }
        }
        h += v * dt
        v -= 60 * dt
        if h <= 0 { h = 0; v = 0 }
    }
}
