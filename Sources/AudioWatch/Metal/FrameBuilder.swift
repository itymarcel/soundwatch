import simd

// Layouts must match the structs in Shaders.swift.

struct Seg {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var color: SIMD4<Float>
    var width: Float
    var dash: Float = 0
    var cap: Float = 0     // 0 = round, 1 = butt / square
    var pad: Float = 0
}

/// One vertex of a pre-projected, pre-lit triangle (matches TriV in Shaders.swift).
struct TriVert {
    var p: SIMD2<Float>
    var pad = SIMD2<Float>()
    var color: SIMD4<Float>
    /// Chrome only (n.w = 1): view-space normal, and the vector to the eye (xyz). The rest comes from ChromeUniforms.
    /// triFrag shades per pixel; otherwise `color` is used as is.
    var n = SIMD4<Float>()
    var e = SIMD4<Float>()
}

struct GPUUniforms {
    var viewPx: SIMD2<Float>; var pxScale: Float; var time: Float
    /// Camera: rotation rows for tilting the 2D scene plane, then pan (points) and zoom about the window centre.
    var cam0 = SIMD4<Float>(1, 0, 0, 0), cam1 = SIMD4<Float>(0, 1, 0, 0), cam2 = SIMD4<Float>(0, 0, 1, 0)
    var center = SIMD2<Float>(); var pan = SIMD2<Float>()
    var zoom: Float = 1; var persp: Float = 1000; var pad0: Float = 0; var pad1: Float = 0
}

struct SphereUniforms {
    var rot0 = SIMD4<Float>(), rot1 = SIMD4<Float>(), rot2 = SIMD4<Float>()
    var center = SIMD2<Float>(); var R: Float = 0; var cam: Float = 3.4
    var dotR: Float = 1; var dispK: Float = 0.55; var phase: Float = 0; var colorByFreq: Float = 1
    var lineW: Float = 1; var alphaK: Float = 1; var square: Float = 0; var dash: Float = 0
    var N: UInt32 = 0; var bandCount: UInt32 = 0; var mirror: UInt32 = 0; var mode: UInt32 = 0
    var layout: UInt32 = 0; var histBands: UInt32 = 0; var histCols: UInt32 = 0; var head: UInt32 = 0
    /// Harmonics layout: 8 smoothed spectrum weights (low → high modes) and per-mode spin angles.
    var w0 = SIMD4<Float>(), w1 = SIMD4<Float>()
    var spin0 = SIMD4<Float>(), spin1 = SIMD4<Float>()
}

struct BandUniforms {
    var fMin: Float, ratio: Float, binHz: Float, floorDB: Float
    var gain: Float, tilt: Float, release: Float, attack: Float
    var count: UInt32, halfBins: UInt32, levels: UInt32, frozen: UInt32
}

struct SpectroUniforms {
    var head: Float = 0, rows: Float = 0, phase: Float = 0, colorByFreq: Float = 1
    var mirror: Float = 0, nearest: Float = 0, bands: Float = 0, cellPx: Float = 0
}

struct CompositeUniforms {
    var ink: SIMD4<Float>
    var bg: SIMD4<Float>
    var glow: Float, scan: Float, vignette: Float, flicker: Float
    var bandY: Float, bgOpacity: Float, sceneGain: Float, cornerR: Float
    var time: Float, pxScale: Float, flickerRand: Float, grainSize: Float = 1
    /// brightness, contrast, saturation, hue rotation (turns)
    var grade = SIMD4<Float>(0, 1, 1, 0)
    /// aberration (px at the edge), pixel size (px, ≤1 = off), posterize levels (0 = off), invert
    var fx = SIMD4<Float>()
    /// blend mode index (−1 = no media), opacity, displacement (px), fit index
    var media = SIMD4<Float>(-1, 0, 0, 0)
    /// media aspect (w/h)
    var media2 = SIMD4<Float>(1, 0, 0, 0)
    /// media transform: offset x, y (screen heights), scale, angle (radians)
    var mediaXf = SIMD4<Float>(0, 0, 1, 0)
    /// kaleidoscope segments (<2 = off), tile mode
    var mediaKal = SIMD4<Float>()
    /// soft focus, streak, edge fringe (px), film grain
    var fx2 = SIMD4<Float>()
}

struct WarpUniforms { var decay: Float, zoom: Float, rot: Float, swirl: Float, ripple: Float, kaleido: Float, time: Float, aspect: Float }

struct SimUniforms {
    var w0 = SIMD4<Float>(), w1 = SIMD4<Float>()
    var shake: Float = 0, speed: Float = 1, dtScale: Float = 1, time: Float = 0
    var turb: Float = 0, noiseScale: Float = 3, beat: Float = 0, level: Float = 0
    var count: UInt32 = 0, frame: UInt32 = 0, bandCount: UInt32 = 0, kind: UInt32 = 0
    var aspect: Float = 1, p0: Float = 0, p1: Float = 0, p2: Float = 0
}

struct PartDrawUniforms {
    var origin = SIMD2<Float>(), extent = SIMD2<Float>()
    var dotR: Float = 1, alphaK: Float = 1, phase: Float = 0, colorByFreq: Float = 1
    var square: Float = 0, streak: Float = 0, domT: Float = 0, speedK: Float = 1
    var kind: UInt32 = 0, count: UInt32 = 0, bandCount: UInt32 = 0, pad: UInt32 = 0
}

enum ParticleKind: UInt32 { case cymatics = 0, flow = 1 }

struct ParticleDraw {
    var kind: ParticleKind
    var count: Int
    /// GPU spectrum bands needed by the simulation (0 = none)
    var bandCount: Int
    var sim: SimUniforms
    var draw: PartDrawUniforms
}

struct SphereDraw {
    var u: SphereUniforms
    var n: Int
    var layout: SphereLayout
    var bandCount: Int
    var dots: Bool
    var spikes: Bool
    var baseDots: Bool
}

/// Uniforms of the full-screen shader modes (Membrane, Spectral Fan, Glass Stack). Matches ShaderModeU.
struct ShaderModeUniforms {
    /// View matrix rows (world → view), for the raymarched modes.
    var view0 = SIMD4<Float>(1, 0, 0, 0), view1 = SIMD4<Float>(0, 1, 0, 0), view2 = SIMD4<Float>(0, 0, 1, 0)
    var viewPt = SIMD2<Float>(); var center = SIMD2<Float>()
    var pan = SIMD2<Float>(); var zoom: Float = 1; var world: Float = 1
    var time: Float = 0; var phase: Float = 0; var colorByFreq: Float = 1; var level: Float = 0
    var bass: Float = 0; var beat: Float = 0; var reach: Float = 1; var count: Float = 0
    var p0 = SIMD4<Float>(), p1 = SIMD4<Float>()
}

/// Chrome settings for triFrag (matches ChromeU): environment turn, blur, tint, exposure.
struct ChromeUniforms {
    var turn: Float = 0, blur: Float = 0, tint: Float = 0, exposure: Float = 1
}

enum ShaderModeKind { case membrane, fan, glass, diamond, orbs }

struct ShaderModeDraw {
    var kind: ShaderModeKind
    var u: ShaderModeUniforms
    /// Per-mode list (bumps, bands + rings, ring frames).
    var data: [Float]
}

struct SpectroDraw {
    var bands: Int
    var newRows: [[Float]]
    var u: SpectroUniforms
}

/// Collects one frame's GPU primitives. Points are in window points (top-left origin).
final class FrameBuilder {
    /// Additive blend: dots, bars, spokes (overlaps glow brighter).
    var add: [Seg] = []
    /// Max blend: polylines and outlines (joints don't double up).
    var lines: [Seg] = []
    /// Shaded surfaces, alpha-blended ("over"), already sorted back to front.
    var trisOver: [TriVert] = []
    /// Glowing surfaces (fresnel), additive.
    var trisAdd: [TriVert] = []
    var sphere: SphereDraw?
    var spectro: SpectroDraw?
    var particles: ParticleDraw?
    var shaderMode: ShaderModeDraw?

    func reset() {
        add.removeAll(keepingCapacity: true)
        lines.removeAll(keepingCapacity: true)
        trisOver.removeAll(keepingCapacity: true)
        trisAdd.removeAll(keepingCapacity: true)
        sphere = nil
        spectro = nil
        particles = nil
        shaderMode = nil
    }

    @inline(__always) func dot(_ p: SIMD2<Float>, _ r: Float, _ c: SIMD4<Float>, square: Bool = false) {
        add.append(Seg(a: p, b: p, color: c, width: 2 * r, cap: square ? 1 : 0))
    }

    @inline(__always) func spoke(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD4<Float>, _ w: Float, dash: Float = 0) {
        add.append(Seg(a: a, b: b, color: c, width: w, dash: dash, cap: dash > 0 ? 1 : 0))
    }

    /// Axis-aligned rect drawn as a butt-capped vertical bar; dash gives screen-aligned LED blocks.
    @inline(__always) func rect(x: Float, y: Float, w: Float, h: Float, _ c: SIMD4<Float>, dash: Float = 0) {
        add.append(Seg(a: SIMD2(x + w / 2, y), b: SIMD2(x + w / 2, y + h), color: c, width: w, dash: dash, cap: 1))
    }

    @inline(__always) func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD4<Float>, _ w: Float, dash: Float = 0) {
        lines.append(Seg(a: a, b: b, color: c, width: w, dash: dash, cap: 0))
    }

    func polyline(_ pts: [SIMD2<Float>], _ w: Float, dash: Float = 0, color: (Int) -> SIMD4<Float>) {
        guard pts.count > 1 else { return }
        for k in 1..<pts.count { line(pts[k - 1], pts[k], color(k), w, dash: dash) }
    }

    func circle(_ c: SIMD2<Float>, _ r: Float, _ col: SIMD4<Float>, _ w: Float = 1, dash: Float = 0, segments: Int = 160) {
        var prev = c + SIMD2(r, 0)
        for i in 1...segments {
            let th = Float(i) / Float(segments) * 2 * .pi
            let p = c + SIMD2(cos(th), sin(th)) * r
            line(prev, p, col, w, dash: dash)
            prev = p
        }
    }
}
