import AppKit
import Foundation
import Observation

enum VizMode: String, Codable, CaseIterable, Identifiable {
    case sphere, oscilloscope, snippet, vectorscope, halo, spectrogram, cymatics, flow
    case attractor, harmonograph, drumhead, primitives, field, mushrooms
    case membrane, fan, glass, diamond
    var id: String { rawValue }

    /// Newer, less polished modes: listed separately and marked "Experimental".
    var isExperimental: Bool { [.attractor, .harmonograph, .drumhead, .primitives, .field, .mushrooms, .membrane, .fan, .glass, .diamond].contains(self) }
    static var stable: [VizMode] { allCases.filter { !$0.isExperimental } }
    static var experimental: [VizMode] { allCases.filter(\.isExperimental) }

    /// Modes drawn as 3D surfaces that offer the Render choice (lines / shaded / fresnel).
    var usesLook: Bool { self == .primitives || self == .mushrooms }

    /// Saved modes that no longer exist fall back to Sphere instead of resetting every setting.
    init(from decoder: Decoder) throws {
        self = VizMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .sphere
    }

    var title: String {
        switch self {
        case .sphere: "Sphere"
        case .oscilloscope: "Oscilloscope"
        case .snippet: "Snippet"
        case .vectorscope: "Vectorscope"
        case .halo: "Halo"
        case .spectrogram: "Spectrogram"
        case .cymatics: "Cymatics"
        case .flow: "Flow"
        case .attractor: "Attractor"
        case .harmonograph: "Harmonograph"
        case .drumhead: "Drumhead"
        case .primitives: "Primitives"
        case .field: "Field"
        case .mushrooms: "Mushrooms"
        case .membrane: "Membrane"
        case .fan: "Spectral Fan"
        case .glass: "Glass Stack"
        case .diamond: "Diamond"
        }
    }

    var symbol: String {
        switch self {
        case .sphere: "globe"
        case .oscilloscope: "waveform.path"
        case .snippet: "waveform"
        case .vectorscope: "scope"
        case .halo: "sun.max"
        case .spectrogram: "square.stack.3d.down.forward"
        case .cymatics: "circle.grid.cross"
        case .flow: "wind"
        case .attractor: "atom"
        case .harmonograph: "scribble.variable"
        case .drumhead: "circle.circle"
        case .primitives: "cube.transparent"
        case .field: "circle.grid.3x3"
        case .mushrooms: "leaf"
        case .membrane: "water.waves"
        case .fan: "rainbow"
        case .glass: "square.stack.3d.up"
        case .diamond: "diamond"
        }
    }

    /// The "Detail" knob means something mode-specific.
    struct Detail {
        let label: String
        let range: ClosedRange<Double>
        let keyPath: WritableKeyPath<VizSettings, Double>
        let format: String
        var isLog = false
    }

    var detail: Detail {
        switch self {
        case .sphere: Detail(label: "Points (= frequency bands)", range: 100...2_000_000, keyPath: \.spherePoints, format: "%.0f", isLog: true)
        case .oscilloscope: Detail(label: "Time window (ms)", range: 5...300, keyPath: \.scopeMs, format: "%.0f ms")
        case .snippet: Detail(label: "Time window (s)", range: 0.5...15, keyPath: \.snippetSeconds, format: "%.1f s")
        case .vectorscope: Detail(label: "Time window (ms)", range: 5...500, keyPath: \.vectorMs, format: "%.0f ms")
        case .halo: Detail(label: "Bands", range: 16...4096, keyPath: \.haloBands, format: "%.0f", isLog: true)
        case .spectrogram: Detail(label: "Bands", range: 64...2048, keyPath: \.spectroBands, format: "%.0f")
        case .cymatics, .flow: Detail(label: "Particles", range: 10_000...4_000_000, keyPath: \.particleCount, format: "%.0f", isLog: true)
        case .attractor: Detail(label: "Time window (ms)", range: 5...200, keyPath: \.attractorMs, format: "%.0f ms")
        case .harmonograph: Detail(label: "Swings", range: 2...10, keyPath: \.harmonoSwings, format: "%.1f")
        case .primitives: Detail(label: "Density", range: 0.2...3, keyPath: \.primDensity, format: "%.1f×")
        case .field: Detail(label: "Particles", range: 5_000...200_000, keyPath: \.fieldParticles, format: "%.0f", isLog: true)
        case .mushrooms: Detail(label: "Mushrooms", range: 4...150, keyPath: \.shroomCount, format: "%.0f")
        case .drumhead: Detail(label: "Points", range: 2_000...80_000, keyPath: \.drumPoints, format: "%.0f", isLog: true)
        case .membrane: Detail(label: "Bumps (at most at once)", range: 4...24, keyPath: \.membraneBumps, format: "%.0f")
        case .fan: Detail(label: "Arcs", range: 16...120, keyPath: \.fanArcs, format: "%.0f")
        case .glass: Detail(label: "Rings", range: 3...12, keyPath: \.glassRings, format: "%.0f")
        case .diamond: Detail(label: "Lights", range: 1...8, keyPath: \.diamondLights, format: "%.0f")
        }
    }

    /// Which shared settings affect this mode (others are greyed out in the panel).
    /// Low latency swaps the long FFT for short ones above ~200 Hz. Modes whose look comes from fine spectral
    /// detail (each Flow particle follows one narrow band; the spectrogram shows every bin) keep the full FFT.
    var supportsLowLatency: Bool { self != .spectrogram && self != .flow }

    func uses(_ k: Knob) -> Bool {
        switch self {
        case .sphere: return ![.stereo].contains(k)
        // Waveform modes work on raw samples, so the FFT settings don't apply to them.
        case .oscilloscope: return ![.floor, .tilt, .smoothing, .freqRange, .fft].contains(k)
        case .snippet: return ![.floor, .tilt, .smoothing, .freqRange, .motion, .fft].contains(k)
        case .vectorscope: return ![.floor, .tilt, .smoothing, .freqRange, .stereo, .fft].contains(k)
        case .halo: return ![.stereo].contains(k)
        case .spectrogram: return ![.style, .size, .persistence, .zoom, .stereo, .reach].contains(k)
        case .cymatics: return ![.style, .stereo, .mirror, .tilt].contains(k)
        case .flow: return ![.stereo, .mirror].contains(k)
        case .attractor: return ![.floor, .tilt, .smoothing, .freqRange, .fft, .mirror, .stereo].contains(k)
        case .harmonograph: return ![.stereo, .mirror, .floor, .tilt].contains(k)
        case .drumhead, .field: return ![.stereo, .mirror].contains(k)
        case .primitives, .mushrooms: return ![.stereo, .mirror, .style].contains(k)
        case .membrane: return ![.stereo, .mirror, .style, .persistence, .segmented, .colorBy].contains(k)
        case .fan: return ![.stereo, .style, .segmented].contains(k)
        case .glass: return ![.stereo, .mirror, .style, .segmented].contains(k)
        case .diamond: return ![.stereo, .mirror, .style, .segmented, .colorBy].contains(k)
        }
    }

    var hint: String {
        switch self {
        case .sphere: "Each point is a log-spaced frequency band; Layout decides where each frequency sits (and how the globe moves). Mirror puts bass at both ends of the spectrum."
        case .oscilloscope: "Zero-crossing triggered waveform. Stereo splits L/R, Mirror reflects the trace."
        case .snippet: "Rolling waveform of the last few seconds. Colour-by-frequency tints each slice by its bass/treble balance."
        case .vectorscope: "Stereo field (Lissajous): vertical = mono content, horizontal = stereo width."
        case .halo: "Radial spectrum. Mirror makes it symmetric with bass at the bottom."
        case .spectrogram: "Scrolling frequency waterfall. Motion = scroll speed, Mirror puts bass in the centre."
        case .cymatics: "Sand on a vibrating Chladni plate. The dominant pitch picks the plate mode (low → simple figure, high → intricate); loudness and beats shake the sand."
        case .flow: "Particles drifting through curl noise. Each particle listens to one frequency band. Lines style = motion streaks."
        case .attractor: "Delay embedding: each point is (x(t), x(t−τ), x(t−2τ)), with τ a quarter period of the dominant pitch. A pure tone draws a ring, a chord a knot, noise a cloud. Drag to orbit."
        case .harmonograph: "A pendulum drawing machine tuned by the music: the strongest notes set the pendulums' frequency ratios. Consonant intervals draw calm closed figures, dissonant ones dense knots. Swings = how long each pendulum runs before it dies down."
        case .primitives: "3D primitives conjured by the music: kicks bring spheres, tori and octahedra, snares cubes, pyramids and planes, hats lines, crosses and barcodes. Each appears, breathes with its band, then fades. Render: wireframe, shaded or fresnel. Density = how many."
        case .field: "A ball of particles at rest, each on a spring to its home spot. Invisible spheres of different sizes and masses appear with the music, pull particles in and let them pile up on their surface, then vanish; the particles drift back. Springiness = how hard they want to go home."
        case .mushrooms: "Glowing mushrooms sprout where the music hits, grow slowly in small steps on the hits in their own frequency range, glow with their own frequency band, release spores on beats, then wilt and fade. Mycelium threads connect them. Render switches between wireframe, shaded and glassy fresnel."
        case .membrane: "A grey rubber sheet lit from the side. Kicks push up broad swells, snares rounder bumps, hats small sharp dents; each hit sends a ripple across the sheet, and the bass lifts the middle. Reach = height, Size = bump size, Motion = ripple speed. Relief pushes the media layer's picture up through the sheet (soften it with Media blur)."
        case .fan: "Split screen around a glowing seam. Left: a fan of spectral arcs, each radius a frequency band, broken into streaks by its loudness. Right: thin grainy rings sent out by the hits. Dust drifts over both. Mirror swaps the sides, Motion = how fast the arcs travel."
        case .glass: "A stack of see-through glass rings and discs, one per frequency band (bass at the bottom). Each floats, tilts and swells with its band; overlaps mix their colours. Softness blurs what's far from the middle like a shallow depth of field. Drag to orbit."
        case .diamond: "A brilliant-cut diamond, raytraced: light refracts in, bounces around inside (total internal reflection) and splits into colour. Coloured lights orbit the stone, each brightening with its own frequency band. Facets = how finely it's cut. Movement slowly shifts and tilts the facets with the music. Rainbow = how much the light splits into colour on its way through the stone (0 = white sparkle only). Detail = number of lights. Drag to orbit."
        case .drumhead: "A circular drum skin in 3D. Each frequency band drives one of the membrane's real vibration modes (Bessel modes): bass the broad dome, treble the fine rings and petals. Drag to orbit."
        }
    }
}

extension VizSettings {
    /// Modes that build real 3D geometry and apply the camera orbit themselves; the others are tilted as a flat plane.
    var isVolumetric: Bool {
        mode == .sphere || (mode.isExperimental && mode != .membrane && mode != .fan) || (mode == .oscilloscope && scopeShape == .ridgeline)
    }
}

enum Knob { case segmented, style, colorBy, gain, floor, tilt, smoothing, freqRange, size, glow, persistence, motion, zoom, stereo, mirror, fft, reach }

enum SphereLayout: String, Codable, CaseIterable, Identifiable {
    case poles, harmonics, ripples, terrain, cells, timeGlobe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .poles: "Poles"
        case .harmonics: "Harmonics"
        case .ripples: "Ripples"
        case .terrain: "Terrain"
        case .cells: "Cells"
        case .timeGlobe: "Time globe"
        }
    }
    var hint: String {
        switch self {
        case .poles: "Bass at the bottom pole, treble at the top."
        case .harmonics: "The globe morphs into spherical-harmonic shapes: bass drives broad lobes, treble fine ridges."
        case .ripples: "The newest spectrum is born at the top pole and rolls down the globe as a ring; frequency runs around each ring."
        case .terrain: "A smooth noise map: bass fills the valleys, treble the peaks, so the spectrum flows across the surface like contour lines."
        case .cells: "Patches each repeat the full spectrum, bass at their centres."
        case .timeGlobe: "Latitude = frequency, longitude = time. The recent past wraps around the globe."
        }
    }
    /// Layouts that read from the spectrum-history ring.
    var usesHistory: Bool { self == .timeGlobe || self == .ripples }
    /// Shader mode: 0 = static band per point, 1 = time globe, 2 = ripples, 3 = harmonics.
    var shaderMode: UInt32 {
        switch self {
        case .timeGlobe: 1
        case .ripples: 2
        case .harmonics: 3
        default: 0
        }
    }

    /// Saved layouts that no longer exist fall back to Poles instead of resetting every setting.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SphereLayout(rawValue: raw) ?? .poles
    }
}

enum ScopeShape: String, Codable, CaseIterable, Identifiable {
    case line, circle, filled, ridgeline, bloom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .line: "Line"
        case .circle: "Circle"
        case .filled: "Filled"
        case .ridgeline: "Ridges"
        case .bloom: "Bloom"
        }
    }
    var hint: String {
        switch self {
        case .line: "Classic scope trace, triggered on zero crossings so it holds still."
        case .circle: "The trace wrapped around a ring. Stereo puts L outside and R inside."
        case .filled: "Solid area between the trace and the centre line, like a DAW clip zoomed right in."
        case .ridgeline: "Recent traces stacked into a 3D ridge landscape that scrolls back in time. Tilt it with the mouse."
        case .bloom: "The trace mirrored into a rotating kaleidoscope flower (6 petals). Motion spins it."
        }
    }
    init(from decoder: Decoder) throws {
        self = ScopeShape(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .line
    }
}

enum SurfaceLook: String, Codable, CaseIterable, Identifiable {
    case lines, shaded, fresnel
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    init(from decoder: Decoder) throws {
        self = SurfaceLook(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .lines
    }
}

/// How the media layer (image / video) is combined with the visuals.
enum MediaBlend: String, Codable, CaseIterable, Identifiable {
    case background, add, screen, overlay, multiply, mask, difference, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .background: "Behind"
        case .add: "Add"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .multiply: "Multiply"
        case .mask: "Mask"
        case .difference: "Difference"
        case .hidden: "Hidden (warp only)"
        }
    }
    var hint: String {
        switch self {
        case .background: "The media sits behind the visuals."
        case .add: "Media light is added on top of the visuals."
        case .screen: "Like Add, but softer: never blows out to white."
        case .overlay: "The visuals light up and tint the media (contrasty, like the Photoshop mode)."
        case .multiply: "The visuals are tinted by the media; dark parts of the media hide them."
        case .mask: "The visuals only show where the media is bright."
        case .difference: "Colours invert where visuals and media overlap."
        case .hidden: "The media isn't shown; use it only to warp the visuals with Displace."
        }
    }
    var shaderIndex: Float { Float(Self.allCases.firstIndex(of: self) ?? 0) }
    init(from decoder: Decoder) throws {
        self = MediaBlend(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .background
    }
}

enum MediaTile: String, Codable, CaseIterable, Identifiable {
    case off, repeating, mirror
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .repeating: "Repeat"
        case .mirror: "Mirror"
        }
    }
    var shaderIndex: Float { Float(Self.allCases.firstIndex(of: self) ?? 0) }
    init(from decoder: Decoder) throws {
        self = MediaTile(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .off
    }
}

enum MediaFit: String, Codable, CaseIterable, Identifiable {
    case fill, fit, stretch
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var shaderIndex: Float { Float(Self.allCases.firstIndex(of: self) ?? 0) }
    init(from decoder: Decoder) throws {
        self = MediaFit(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .fill
    }
}

enum WarpStyle: String, Codable, CaseIterable, Identifiable {
    case tunnel, vortex, ripple, spin, kaleido, implode
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum DrawStyle: String, Codable, CaseIterable, Identifiable {
    case points, lines, both
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ColorBy: String, Codable, CaseIterable, Identifiable {
    case frequency, amplitude
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct VizSettings: Codable, Equatable {
    var mode: VizMode = .sphere
    var style: DrawStyle = .points

    // Color
    var palette: PaletteKind = .phosphor
    var colorBy: ColorBy = .frequency
    var hueShift: Double = 0
    var colorCycle: Double = 0.2

    // Response
    var gain: Double = 1.2
    var floorDB: Double = -80
    var tilt: Double = 3
    var smoothing: Double = 0.7
    var fftSize: Double = 8192
    /// Multi-resolution spectrum: long FFT for bass detail, short FFTs above ~200 Hz for fast reaction.
    var lowLatency: Bool = true
    var minFreq: Double = 30
    var maxFreq: Double = 16_000

    // Shape & motion
    var size: Double = 1
    var glow: Double = 0.5
    var persistence: Double = 0.25
    var motion: Double = 0.3
    var zoom: Double = 1
    /// Reach per mode (mode name → multiplier on how far things move/displace); missing = 1×.
    var reachByMode: [String: Double] = [:]
    var stereo: Bool = false
    var mirror: Bool = false

    // Per-mode detail
    var spherePoints: Double = 20000
    var sphereLayout: SphereLayout = .poles
    var particleCount: Double = 400_000

    // Feedback warp + beat
    var warp: Double = 0
    var warpStyle: WarpStyle = .tunnel
    var beat: Double = 0.5
    var scopeMs: Double = 40
    var scopeShape: ScopeShape = .line
    var snippetSeconds: Double = 4
    var vectorMs: Double = 50
    var haloBands: Double = 160
    var spectroBands: Double = 512
    var attractorMs: Double = 30
    var harmonoSwings: Double = 6
    var drumPoints: Double = 20_000
    var primDensity: Double = 1
    var fieldParticles: Double = 60_000
    var shroomCount: Double = 40
    /// Render for surface modes (Primitives, Mushrooms).
    var look: SurfaceLook = .lines
    /// Field: how strongly particles are pulled back home (0 … 1).
    var fieldSpring: Double = 0.4
    /// Membrane: most bumps alive at once, palette tint of the grey sheet, media picture pushed up as relief.
    var membraneBumps: Double = 14
    var membraneTint: Double = 0
    var membraneRelief: Double = 0
    /// Spectral Fan: number of arcs.
    var fanArcs: Double = 56
    /// Glass Stack: number of rings, depth-of-field softness.
    var glassRings: Double = 7
    var glassSoft: Double = 0.4
    /// Diamond: number of orbiting lights, cut symmetry (facet detail), how much the facets move with the music,
    /// colour dispersion (shown as "Rainbow").
    var diamondLights: Double = 4
    var diamondCut: Double = 8
    var diamondMove: Double = 0.3
    var diamondFire: Double = 0.5
    /// The node patch (Nodes window): music features → modifiers → parameters.
    var nodes = NodeGraph()

    // Post-processing (colour grade + effects on the final image)
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var hueRotate: Double = 0
    var aberration: Double = 0
    var pixelate: Double = 0
    var posterize: Double = 0
    var invert: Double = 0
    /// Soft focus (wide blur mixed in), vertical light streaks, colour fringes on edges, film grain.
    var softFocus: Double = 0
    var streak: Double = 0
    var fringe: Double = 0
    var filmGrain: Double = 0

    // Media layer (an image or video file combined with the visuals)
    var mediaPath: String = ""
    var mediaBlend: MediaBlend = .background
    var mediaFit: MediaFit = .fill
    var mediaOpacity: Double = 0.6
    var mediaDisplace: Double = 0
    var mediaBlur: Double = 0
    // media transform
    var mediaScale: Double = 1
    var mediaX: Double = 0
    var mediaY: Double = 0
    var mediaRotate: Double = 0
    var mediaTile: MediaTile = .off
    var mediaKaleido: Double = 0
    // media motion
    var mediaDrift: Double = 0
    var mediaDriftDir: Double = 0
    var mediaSpin: Double = 0
    var mediaWander: Double = 0
    var mediaBeatZoom: Double = 0
    var mediaBreathe: Double = 0
    var mediaShake: Double = 0
    var mediaJump: Double = 0
    var mediaSpeed: Double = 1
    var mediaPulse: Double = 0

    // Window
    // CRT treatment (shown under Post-processing)
    var scanlines: Double = 0.5
    var vignette: Double = 0.6
    var flicker: Double = 0.3
    var segmented: Bool = false

    var bgOpacity: Double = 1
    var bgRed: Double = 0
    var bgGreen: Double = 0
    var bgBlue: Double = 0
    var alwaysOnTop: Bool = false
    var showFPS: Bool = false
}

@Observable
final class SettingsStore {
    // Keys keep the app's old name (AudioViz) so existing settings and presets carry over.
    private static let key = "AudioViz.settings.v2"
    private static let presetsKey = "AudioViz.presets.v1"
    private static let presetCamerasKey = "AudioViz.presetCameras.v1"
    /// Debug runs (AUDIOWATCH_SETTINGS) never write anything back.
    private static let persist = ProcessInfo.processInfo.environment["AUDIOWATCH_SETTINGS"] == nil

    var s: VizSettings {
        didSet { if s != oldValue { save() } }
    }

    /// Named looks. A preset stores every setting except the window ones (see `windowOnly`).
    private(set) var presets: [String: VizSettings] = [:]
    /// The camera view (for the preset's mode) saved with each preset.
    private(set) var presetCameras: [String: CameraState] = [:]
    var presetNames: [String] { presets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    init() {
        s = Self.load()
        presets = Self.loadPresets()
        if let data = UserDefaults.standard.data(forKey: Self.presetCamerasKey),
           let cams = try? JSONDecoder().decode([String: CameraState].self, from: data) { presetCameras = cams }
    }

    func resetLook() {
        var d = VizSettings()
        d.mode = s.mode
        d.alwaysOnTop = s.alwaysOnTop
        d.bgOpacity = s.bgOpacity
        d.nodes = s.nodes
        s = d
    }

    // MARK: - Presets

    /// Creates or overwrites the preset `name` with the current settings and camera view.
    func savePreset(_ name: String, camera: CameraState) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        presets[n] = s
        presetCameras[n] = camera
        savePresets()
    }

    func deletePreset(_ name: String) {
        presets[name] = nil
        presetCameras[name] = nil
        savePresets()
    }

    /// Applies the preset's settings and returns its camera view (nil for presets saved before views were stored).
    func applyPreset(_ name: String) -> CameraState? {
        guard var p = presets[name] else { return nil }
        Self.keepWindow(from: s, into: &p)
        s = p
        return presetCameras[name]
    }

    /// True when the current look matches the preset (window settings ignored).
    func matches(_ name: String) -> Bool {
        guard var p = presets[name] else { return false }
        Self.keepWindow(from: s, into: &p)
        return p == s
    }

    /// Window behaviour belongs to the machine, not the look.
    private static func keepWindow(from cur: VizSettings, into p: inout VizSettings) {
        p.alwaysOnTop = cur.alwaysOnTop
        p.showFPS = cur.showFPS
    }

    private func savePresets() {
        guard Self.persist else { return }
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: Self.presetsKey) }
        if let data = try? JSONEncoder().encode(presetCameras) { UserDefaults.standard.set(data, forKey: Self.presetCamerasKey) }
    }

    private static func loadPresets() -> [String: VizSettings] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return [:] }
        return saved.compactMapValues { decodeMerged($0) }
    }

    // MARK: - Current settings

    private func save() {
        guard Self.persist else { return }
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private static func load() -> VizSettings {
        var saved: [String: Any] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { saved = d }
        // Debug aid: AUDIOWATCH_SETTINGS='{"mode":"cymatics"}' overrides saved values for this run.
        if let json = ProcessInfo.processInfo.environment["AUDIOWATCH_SETTINGS"]?.data(using: .utf8),
           let over = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] {
            saved.merge(over) { _, new in new }
        }
        return decodeMerged(saved) ?? VizSettings()
    }

    /// Merges saved values over defaults so new settings fields never break old saves or presets.
    private static func decodeMerged(_ saved: [String: Any]) -> VizSettings? {
        guard let defData = try? JSONEncoder().encode(VizSettings()),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return nil }
        merged.merge(saved) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(VizSettings.self, from: data)
    }
}

@Observable
final class AppState {
    var showSettings = false
    var frozen = false
    var status: String?
    /// While a text field is being edited, single-key shortcuts are switched off so typing works.
    var textEditing = false
    /// Bumped by the media "Stop all motion" / "Reset transform" buttons: clears accumulated spin, drift, wander…
    @ObservationIgnored var mediaMotionReset = 0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored let camera = Camera()
}

extension VizSettings {
    /// How far things move/displace in the current mode (sphere bulge, spoke length, particle steps, trace height).
    /// Stored per mode, so turning it down for one mode doesn't shrink the others.
    var reach: Double {
        get { reachByMode[mode.rawValue] ?? 1 }
        set { reachByMode[mode.rawValue] = newValue }
    }
}
