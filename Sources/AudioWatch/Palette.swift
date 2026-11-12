import SwiftUI
import simd

enum PaletteKind: String, Codable, CaseIterable, Identifiable {
    // retro / sci-fi / solarpunk
    case phosphor, silo, amber, brass, solarpunk, verdigris, hologram
    // vivid
    case aurora, neon, fire, ocean, sunset, acid, rainbow, mono
    // soft / glassy
    case glass, cobalt, spectral
    var id: String { rawValue }

    var title: String {
        switch self {
        case .phosphor: "Phosphor P1"
        case .silo: "Silo Terminal"
        case .amber: "Amber P3"
        case .brass: "Brass Tablet"
        case .solarpunk: "Solarpunk"
        case .verdigris: "Verdigris"
        case .hologram: "Hologram"
        default: rawValue.capitalized
        }
    }

    var palette: Palette {
        switch self {
        case .phosphor: Palette([0x03200F, 0x0B5A2E, 0x1FBF6A, 0x7DFFB0, 0xE6FFF0])
        case .silo: Palette([0x021A1A, 0x0A4F4F, 0x1EA89A, 0x6FF2D8, 0xE0FFF8])
        case .amber: Palette([0x220E00, 0x6B3200, 0xD97A00, 0xFFB000, 0xFFE9B0])
        case .brass: Palette([0x1A1004, 0x5A3F12, 0xB08A3E, 0xE8C46A, 0xFFF3CC])
        case .solarpunk: Palette([0x10301A, 0x2F6B2A, 0x7FB33C, 0xE8C547, 0xFFF1B8])
        case .verdigris: Palette([0x2A1408, 0x8C4A1E, 0xC07A3A, 0x4FA38A, 0xA8E6CF])
        case .hologram: Palette([0x0A1A2A, 0x3A6E9E, 0x9CCBF0, 0xF2FAFF])
        case .aurora: Palette([0x0B3D91, 0x00C2A8, 0x7CFFB2, 0xB47CFF, 0xFF5FA2])
        case .neon: Palette([0xFF00C8, 0x8A2BFF, 0x00E5FF, 0x39FF14])
        case .fire: Palette([0x4A0000, 0xC01800, 0xFF6A00, 0xFFC400, 0xFFF6D0])
        case .ocean: Palette([0x021B4D, 0x0050A0, 0x00A6D6, 0x7FE7F2, 0xE8FFFF])
        case .sunset: Palette([0x2D0B59, 0x8E1E7A, 0xE8475C, 0xFF9A3C, 0xFFE07A])
        case .acid: Palette([0x0A3D00, 0x58D600, 0xE6FF00, 0xFFFFFF])
        case .rainbow: Palette([0xFF2D2D, 0xFFA21F, 0xF5F52A, 0x2BE36B, 0x26C6FF, 0x5A4BFF, 0xD13BFF])
        case .mono: Palette([0x5A6270, 0xC8D0DC, 0xFFFFFF])
        case .glass: Palette([0x1A2BFF, 0x7A3CFF, 0xFF3FC8, 0x5FE0F0, 0xA8F5C8, 0xF4FBFF])
        case .cobalt: Palette([0x050A40, 0x0F1FB8, 0x1A3CFF, 0x5C8CFF, 0xBCD2F2, 0xE8ECF2])
        case .spectral: Palette([0x3A2A7A, 0xE8323C, 0xF2C53A, 0x4FD67A, 0x3ACBE8, 0x7A5CFF])
        }
    }

    /// Accent colour matching the palette (used for subtle guide lines and the CRT refresh band).
    var ink: UInt32 {
        switch self {
        case .phosphor: 0x4DFF9A
        case .silo: 0x5CF2D2
        case .amber: 0xFFB000
        case .brass: 0xE8C46A
        case .solarpunk: 0xC9E36A
        case .verdigris: 0x7FD6B5
        case .hologram: 0xA8D8FF
        case .aurora: 0x7CFFB2
        case .neon: 0x00E5FF
        case .fire: 0xFFA040
        case .ocean: 0x7FE7F2
        case .sunset: 0xFF9A3C
        case .acid: 0xE6FF00
        case .rainbow, .mono: 0xE0E6EE
        case .glass: 0xC8B8FF
        case .cobalt: 0x5C8CFF
        case .spectral: 0xE8E0FF
        }
    }

}

struct Palette {
    let stops: [SIMD3<Float>]

    init(stops: [SIMD3<Float>]) { self.stops = stops }

    /// Mixes two palettes by sampling both at the same points.
    static func blend(_ a: Palette, _ b: Palette, _ t: Float, samples: Int = 16) -> Palette {
        Palette(stops: (0..<samples).map { i in
            let u = Float(i) / Float(samples - 1)
            return simd_mix(a.rgb(u), b.rgb(u), SIMD3(repeating: t))
        })
    }

    init(_ hex: [UInt32]) {
        stops = hex.map {
            SIMD3(Float(($0 >> 16) & 0xFF) / 255, Float(($0 >> 8) & 0xFF) / 255, Float($0 & 0xFF) / 255)
        }
    }

    /// Maps any t onto 0…1 by bouncing back and forth, so cycling stays smooth.
    @inline(__always) static func pingPong(_ t: Float) -> Float {
        let m = t - 2 * floor(t / 2)
        return m <= 1 ? m : 2 - m
    }

    func rgb(_ t: Float) -> SIMD3<Float> {
        let u = Palette.pingPong(t) * Float(stops.count - 1)
        let i = min(Int(u), stops.count - 2)
        let f = u - Float(i)
        return stops[i] + (stops[i + 1] - stops[i]) * f
    }

    func color(_ t: Float, _ alpha: Double = 1) -> Color {
        let c = rgb(t)
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: alpha)
    }

    func gradient(_ t0: Float, _ t1: Float, steps: Int = 12) -> Gradient {
        Gradient(stops: (0...steps).map { i in
            let f = Float(i) / Float(steps)
            return .init(color: color(t0 + (t1 - t0) * f), location: CGFloat(f))
        })
    }
}

/// The one smoothing rule used everywhere: rises land within ~one frame regardless of the Smoothing setting,
/// falls glide back with a time constant set by the slider. Frame-rate independent.
enum Envelope {
    /// Rise time constant (s). Short enough to look instant, long enough to drop single-sample spikes.
    static let riseTau = 0.004

    /// Fall time constant (s) for a Smoothing slider value: the value kept per 60 fps frame.
    static func fallTau(_ smoothing: Double) -> Double {
        let s = min(max(smoothing, 0.001), 0.98)
        return -1 / (60 * log(s))
    }

    /// Per-frame keep-factors (rise, fall): next = old × k + new × (1 − k).
    static func coeffs(smoothing: Double, dt: Double) -> (rise: Float, fall: Float) {
        (Float(exp(-dt / riseTau)), Float(exp(-dt / fallTau(smoothing))))
    }

    @inline(__always) static func step(_ old: Float, _ new: Float, _ k: (rise: Float, fall: Float)) -> Float {
        let c = new > old ? k.rise : k.fall
        return old * c + new * (1 - c)
    }
}

struct Smoother {
    private(set) var v: [Float] = []

    mutating func step(_ x: [Float], smoothing: Double, dt: Double, frozen: Bool) -> [Float] {
        if v.count != x.count { v = x; return v }
        if frozen { return v }
        let k = Envelope.coeffs(smoothing: smoothing, dt: dt)
        for i in x.indices { v[i] = Envelope.step(v[i], x[i], k) }
        return v
    }
}

struct RenderContext {
    let size: SIMD2<Float>
    let s: VizSettings
    let time: Double
    let dt: Double
    let frozen: Bool
    let analyzer: Analyzer
    let palette: Palette
    /// Palette offset (hue shift + colour cycling)
    let phase: Float
    /// Accent colour for guide lines
    let ink: SIMD3<Float>
    /// Beat pulse (0…1, decays after each detected beat) × the Beat setting.
    let beat: Float
    /// User camera for this mode (3D visualizers apply the rotation themselves).
    var camera = CameraState()

    var center: SIMD2<Float> { size * 0.5 }
    var minDim: Float { min(size.x, size.y) }
    /// Base line width / dot size scaled to the window.
    var unit: Float { max(0.5, Float(s.size) * minDim / 600) }

    /// Palette colour; `t` should already include `phase`.
    @inline(__always) func col(_ t: Float, _ a: Float) -> SIMD4<Float> { SIMD4(palette.rgb(t), a) }
    @inline(__always) func inkC(_ a: Float) -> SIMD4<Float> { SIMD4(ink, a) }
}

protocol Visualizer: AnyObject {
    /// Emit GPU primitives for this frame.
    func build(_ f: FrameBuilder, _ rc: RenderContext)
}
