import simd
import AppKit
import Foundation
import Observation

enum VizMode: String, Codable, CaseIterable, Identifiable {
    case sphere, oscilloscope, snippet, vectorscope, halo, spectrogram, cymatics, flow
    case attractor, harmonograph, drumhead, primitives, field, mushrooms
    case membrane, fan, glass, diamond, orbs, imageParticles, ferro, metaballs
    var id: String { rawValue }

    /// Newer, less polished modes: listed separately and marked "Experimental".
    var isExperimental: Bool { [.attractor, .harmonograph, .drumhead, .primitives, .field, .mushrooms, .membrane, .fan, .glass, .diamond, .orbs, .imageParticles, .ferro, .metaballs].contains(self) }
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
        case .orbs: "Orbs"
        case .imageParticles: "Image Particles"
        case .ferro: "Splashs"
        case .metaballs: "Real Metaballs"
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
        case .orbs: "smallcircle.filled.circle"
        case .imageParticles: "photo.artframe"
        case .ferro: "water.waves"
        case .metaballs: "drop.fill"
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
        case .sphere: Detail(label: "Points (= frequency bands)", range: 100...4_000_000, keyPath: \.spherePoints, format: "%.0f", isLog: true)
        case .oscilloscope: Detail(label: "Time window (ms)", range: 5...300, keyPath: \.scopeMs, format: "%.0f ms")
        case .snippet: Detail(label: "Time window (s)", range: 0.5...15, keyPath: \.snippetSeconds, format: "%.1f s")
        case .vectorscope: Detail(label: "Time window (ms)", range: 5...500, keyPath: \.vectorMs, format: "%.0f ms")
        case .halo: Detail(label: "Bands", range: 16...4096, keyPath: \.haloBands, format: "%.0f", isLog: true)
        case .spectrogram: Detail(label: "Bands", range: 64...2048, keyPath: \.spectroBands, format: "%.0f")
        case .cymatics, .flow: Detail(label: "Particles", range: 10_000...8_000_000, keyPath: \.particleCount, format: "%.0f", isLog: true)
        case .attractor: Detail(label: "Time window (ms)", range: 5...200, keyPath: \.attractorMs, format: "%.0f ms")
        case .harmonograph: Detail(label: "Swings", range: 2...10, keyPath: \.harmonoSwings, format: "%.1f")
        case .primitives: Detail(label: "Density", range: 0.2...3, keyPath: \.primDensity, format: "%.1f×")
        case .field: Detail(label: "Particles", range: 5_000...1_000_000, keyPath: \.fieldParticles, format: "%.0f", isLog: true)
        case .mushrooms: Detail(label: "Mushrooms", range: 4...150, keyPath: \.shroomCount, format: "%.0f")
        case .drumhead: Detail(label: "Points", range: 2_000...80_000, keyPath: \.drumPoints, format: "%.0f", isLog: true)
        case .membrane: Detail(label: "Bumps (at most at once)", range: 4...24, keyPath: \.membraneBumps, format: "%.0f")
        case .fan: Detail(label: "Arcs", range: 16...120, keyPath: \.fanArcs, format: "%.0f")
        case .glass: Detail(label: "Rings", range: 3...12, keyPath: \.glassRings, format: "%.0f")
        case .diamond: Detail(label: "Lights", range: 1...8, keyPath: \.diamondLights, format: "%.0f")
        case .orbs: Detail(label: "Orbs (= frequency bands)", range: 3...16, keyPath: \.orbCount, format: "%.0f")
        case .imageParticles: Detail(label: "Particles", range: 5_000...1_000_000, keyPath: \.imgParticles, format: "%.0f", isLog: true)
        case .ferro: Detail(label: "Fluid", range: 0.3...2, keyPath: \.ferroFluid, format: "%.2f")
        case .metaballs: Detail(label: "Fluid", range: 0.25...3, keyPath: \.mbFluid, format: "%.2f")
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
        case .orbs: return ![.stereo, .mirror, .style, .segmented, .persistence].contains(k)
        case .imageParticles: return ![.stereo].contains(k)
        case .ferro: return ![.stereo, .mirror, .style, .segmented, .persistence, .colorBy, .glow, .size].contains(k)
        case .metaballs: return ![.stereo, .mirror, .style, .segmented, .persistence, .colorBy, .glow, .size, .motion].contains(k)
        }
    }

    var hint: String {
        switch self {
        case .sphere: "A globe of points, one per frequency band, arranged by the chosen Layout."
        case .oscilloscope: "The waveform, held still by triggering on zero crossings."
        case .snippet: "A rolling waveform of the last few seconds, each slice tinted by its bass/treble balance."
        case .vectorscope: "The stereo field as a Lissajous figure: vertical is mono, horizontal is stereo width."
        case .halo: "The spectrum bent into a ring, bass at the bottom when mirrored."
        case .spectrogram: "A scrolling frequency waterfall."
        case .cymatics: "Sand on a vibrating plate that forms simple figures for low notes and intricate ones for high notes."
        case .flow: "Particles drifting through curl noise, each listening to its own frequency band."
        case .attractor: "The waveform plotted against its own past, so a pure tone draws a ring, a chord a knot and noise a cloud."
        case .harmonograph: "A pendulum drawing machine tuned by the strongest notes, calm for consonant intervals and knotted for dissonant ones."
        case .primitives: "3D shapes conjured by kicks, snares and hats that breathe with their band and fade away."
        case .field: "A ball of particles that invisible spheres pull in and pile up as the music plays, then let drift home."
        case .mushrooms: "Glowing mushrooms that sprout and grow on the hits in their own frequency range, linked by mycelium threads."
        case .membrane: "A rubber sheet lit from the side that kicks, snares and hats push up into swells, bumps and ripples."
        case .fan: "A split screen with a fan of spectral arcs on one side and rings sent out by the hits on the other."
        case .glass: "A stack of see-through glass rings, one per frequency band, that float, tilt and swell with their band."
        case .diamond: "A raytraced brilliant-cut diamond that the music reshapes, lit by coloured lights that follow the bands."
        case .orbs: "A chrome sphere circled by smaller chrome orbs, one per frequency band, that sink in and dent it when their band is loud."
        case .drumhead: "A 3D drum skin where each frequency band drives one of its real vibration modes."
        case .ferro: "A pool of ferrofluid over an electromagnet driven by the bass: the fluid gathers into a mound and, past the critical field, bristles into the hexagonal spikes of the Rosensweig instability. Drum hits splash it."
        case .metaballs: "Ferrofluid in water with an electromagnet behind it, like the ferrofluid speaker: one frequency band drives the coil, which pulls the fluid in; it stretches, bristles, tears into drops that push each other apart and merges again."
        case .imageParticles: "Your picture as particles, each on a spring to its spot: its frequency band (by position, brightness, colour or at random) pushes it out and makes it shimmer, and drum hits send shock waves through the picture."
        }
    }
}

extension VizSettings {
    /// Modes that build real 3D geometry and apply the camera orbit themselves; the others are tilted as a flat plane.
    var isVolumetric: Bool {
        mode == .sphere || (mode.isExperimental && mode != .membrane && mode != .fan) || (mode == .oscilloscope && scopeShape == .ridgeline)
    }
}

/// Image Particles: how particles are assigned to frequency bands.
enum ImageBandMap: String, Codable, CaseIterable, Identifiable {
    case position, random, brightness, colour
    var id: String { rawValue }
    init(from decoder: Decoder) throws {
        self = ImageBandMap(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .position
    }
    var title: String {
        switch self {
        case .position: "Position"
        case .random: "Random"
        case .brightness: "Brightness"
        case .colour: "Colour"
        }
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
        case .timeGlobe: "Latitude is frequency and longitude is time, so the recent past wraps around the globe."
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
        case .circle: "The trace wrapped around a ring, with L outside and R inside in stereo."
        case .filled: "Solid area between the trace and the centre line, like a DAW clip zoomed right in."
        case .ridgeline: "Recent traces stacked into a 3D ridge landscape that scrolls back in time."
        case .bloom: "The trace mirrored into a six-petal kaleidoscope flower that Motion spins."
        }
    }
    init(from decoder: Decoder) throws {
        self = ScopeShape(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .line
    }
}

enum SurfaceLook: String, Codable, CaseIterable, Identifiable {
    case lines, chrome = "shaded", fresnel   // "shaded" kept as the saved value, so old settings and presets map to Chrome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lines: "Lines"
        case .chrome: "Chrome"
        case .fresnel: "Fresnel"
        }
    }
    init(from decoder: Decoder) throws {
        self = SurfaceLook(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .lines
    }
}

/// What chrome reflects.
/// HDRIs from Poly Haven (CC0), converted by Resources/make_envmaps.swift.
enum ChromeEnvironment: String, Codable, CaseIterable, Identifiable {
    case studio, woodStudio, moonrise, night
    var id: String { rawValue }
    var title: String {
        switch self {
        case .studio: "Studio"
        case .woodStudio: "Wood"
        case .moonrise: "Moonrise"
        case .night: "Night"
        }
    }
    var fileName: String {
        switch self {
        case .studio: "ferndale_studio_12"
        case .woodStudio: "wooden_studio_09"
        case .moonrise: "qwantani_moonrise_puresky"
        case .night: "qwantani_night"
        }
    }
    /// The maps are normalised to the same median brightness; this evens out what's left by eye.
    var exposure: Float {
        switch self {
        case .studio, .woodStudio, .moonrise, .night: 1
        }
    }
    init(from decoder: Decoder) throws {
        self = ChromeEnvironment(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .studio
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
    /// A/V sync offset in ms on top of the automatic speaker-latency match: + = picture later, − = earlier.
    /// Belongs to the machine/speakers, not the look: kept across presets and Reset look.
    var avSync: Double = 0
    /// Beat follows the tracked tempo (predicted, on time, steady through fills) while it's locked; else detected bass hits.
    var beatLock: Bool = true
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
    /// Creative controls. paletteMix (0…1) blends the palette toward the next one in the list (see `colourMorph`).
    var paletteMix: Double = 0
    /// −1 (calm) … +1 (wild): nudges many settings at once, only at render time (the sliders keep their values).
    var intensity: Double = 0
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
    /// Image Particles: the picture (empty = "soundwatch" lettering), particle count, brightness threshold, image colours
    /// vs. palette, pull back home, brightness → depth.
    var imgPath: String = ""
    var imgParticles: Double = 150_000
    var imgThreshold: Double = 0.08
    var imgColours: Bool = true
    var imgSpring: Double = 0.5
    var imgDepth: Double = 0.3
    /// Image Particles: which frequency band each particle listens to (and which drum waves move it).
    var imgBandMap: ImageBandMap = .position
    /// Splashs (ferrofluid pool): amount of fluid, magnet strength (how far past the critical field), how hard
    /// drum hits splash the surface. Reflections use the chrome settings (environment, turn, blur, tint).
    var ferroFluid: Double = 1
    var ferroSpikes: Double = 0.6
    var ferroSplash: Double = 0.5
    /// Real Metaballs (ferrofluid in water, simulated as particles): amount of fluid; Magnet = the device's dial
    /// (gain from the band envelope to the coil's PWM duty); which MSGEQ7-style band drives the coil (0 = 63 Hz …
    /// 6 = 16 kHz); the coil's L/R time constant in ms (how smoothed the motion is).
    var mbFluid: Double = 1
    var mbMagnet: Double = 1.4
    var mbMagnets: Double = 6
    var mbHold: Double = 0.6
    var mbBand: Double = 0
    var mbLag: Double = 40
    var mbHome: Double = 0.45
    var mbBurst: Double = 0.35
    /// Membrane: most bumps alive at once, palette tint of the grey sheet, media picture pushed up as relief.
    var membraneBumps: Double = 14
    var membraneTint: Double = 0
    var membraneRelief: Double = 0
    /// Spectral Fan: number of arcs.
    var fanArcs: Double = 56
    /// Glass Stack: number of rings, depth-of-field softness.
    var glassRings: Double = 7
    var glassSoft: Double = 0.4
    /// Diamond: number of orbiting lights, total facet count (5…50), how much the stone moves with the music,
    /// colour dispersion (shown as "Rainbow").
    var diamondLights: Double = 4
    var diamondFacets: Double = 33
    var diamondMove: Double = 0.3
    var diamondFire: Double = 0.5
    /// Orbs: how many orbs (one per band), how far loud orbs swell out (Spread), how much they melt together (Goo).
    var orbGoo: Double = 0.5
    /// Tint: how much the palette
    /// colours chrome (Orbs and the Chrome surface look).
    var orbCount: Double = 8
    var orbPress: Double = 0.6
    var chromeTint: Double = 0.15
    /// Chrome finish: blur (soft, satin reflections), what it reflects and how that environment is turned (0…1 = a full turn).
    var chromeBlur: Double = 0.3
    var chromeTurn: Double = 0
    var chromeEnv: ChromeEnvironment = .studio
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
    /// Grain size: 1 = about one pixel; larger = coarser, clumpier grain.
    var grainSize: Double = 1

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
    var showFPS: Bool = false
    /// Smooth edges: 4× multisampling for lines and surfaces, supersampling for the raytraced modes when the GPU has
    /// time to spare. Belongs to the machine, not the look: kept across presets and Reset look.
    var antialias: Bool = true

    // Auto-loop through presets on the beat (kept when a preset is applied, like the window settings)
    var presetLoop: Bool = false
    var presetLoopBeats: Double = 16
    var presetLoopRandom: Double = 0
}

@Observable
final class SettingsStore {
    // Keys keep the app's old name (AudioViz) so existing settings and presets carry over.
    private static let key = "AudioViz.settings.v2"
    private static let presetsKey = "AudioViz.presets.v1"
    private static let presetCamerasKey = "AudioViz.presetCameras.v1"
    /// Names of the built-in presets already offered once, so deleting one keeps it gone.
    private static let seededKey = "AudioViz.defaultPresetsSeeded.v1"
    /// Debug runs (AUDIOWATCH_SETTINGS) never write anything back.
    private static let persist = ProcessInfo.processInfo.environment["AUDIOWATCH_SETTINGS"] == nil

    var s: VizSettings {
        didSet { if s != oldValue { scheduleSave() } }
    }
    /// Slider drags change `s` many times a second; encoding + writing every tick made dragging (and the sidebar) stutter.
    /// Saves are coalesced to one per 0.4 s and flushed when the app quits.
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    private func scheduleSave() {
        guard Self.persist else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Named looks. A preset stores every setting except the window ones (see `windowOnly`).
    private(set) var presets: [String: VizSettings] = [:]
    /// The camera view (for the preset's mode) saved with each preset.
    private(set) var presetCameras: [String: CameraState] = [:]
    var presetNames: [String] { presets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    /// The built-in preset a fresh install starts with.
    static let firstLaunchPresetName = "Acid Garden"
    /// The preset shown in the picker (not saved). Picking one applies it; launch and auto-loop set it after applying.
    var selectedPreset = ""
    /// Set on a fresh install: that preset's camera view, for the main view to apply once (it clears this).
    var launchCamera: CameraState?

    init() {
        let fresh = UserDefaults.standard.data(forKey: Self.key) == nil
        s = Self.load()
        presets = Self.loadPresets()
        if let data = UserDefaults.standard.data(forKey: Self.presetCamerasKey),
           let cams = try? JSONDecoder().decode([String: CameraState].self, from: data) { presetCameras = cams }
        seedDefaultPresets()
        if fresh && Self.persist, presets[Self.firstLaunchPresetName] != nil {
            launchCamera = applyPreset(Self.firstLaunchPresetName)
            selectedPreset = Self.firstLaunchPresetName
            save()   // observers don't run inside init
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
    }

    /// Writes a pending (debounced) save now.
    func flushSave() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        save()
    }

    /// Adds the built-in presets (DefaultPresets.swift) that haven't been offered before.
    private func seedDefaultPresets() {
        guard let data = DefaultPresets.json.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        var seeded = Set(UserDefaults.standard.stringArray(forKey: Self.seededKey) ?? [])
        var changed = false
        for item in list {
            guard let name = item["name"] as? String, !seeded.contains(name) else { continue }
            seeded.insert(name)
            guard presets[name] == nil, let dict = item["settings"] as? [String: Any],
                  let settings = Self.decodeMerged(dict) else { continue }
            presets[name] = settings
            if let cam = item["camera"] as? [String: Any],
               let camData = try? JSONSerialization.data(withJSONObject: cam),
               let state = try? JSONDecoder().decode(CameraState.self, from: camData) { presetCameras[name] = state }
            changed = true
        }
        guard Self.persist else { return }
        UserDefaults.standard.set(seeded.sorted(), forKey: Self.seededKey)
        if changed { savePresets() }
    }

    func resetLook() {
        var d = VizSettings()
        d.mode = s.mode
        d.bgOpacity = s.bgOpacity
        d.avSync = s.avSync
        d.beatLock = s.beatLock
        d.antialias = s.antialias
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
        p.showFPS = cur.showFPS
        p.antialias = cur.antialias
        p.avSync = cur.avSync
        p.beatLock = cur.beatLock
        p.presetLoop = cur.presetLoop
        p.presetLoopBeats = cur.presetLoopBeats
        p.presetLoopRandom = cur.presetLoopRandom
    }

    // MARK: - Auto-loop

    // Written every frame by the renderer: not observed, so they never notify SwiftUI.
    @ObservationIgnored private var loopLastBeat = -1
    @ObservationIgnored private var loopBeats = 0
    @ObservationIgnored private var loopTarget = 0

    /// Called every frame with the analyzer's beat counter. With auto-loop on, counts beats and, once the wait
    /// (Beats + random 0…Random) is over, applies the next preset in list order. Returns its camera view when it switched.
    func presetLoopStep(beatCount: Int) -> (switched: Bool, camera: CameraState?) {
        defer { loopLastBeat = beatCount }
        guard s.presetLoop, presets.count > 1, loopLastBeat >= 0, beatCount >= loopLastBeat else {
            loopBeats = 0; loopTarget = 0
            return (false, nil)
        }
        if loopTarget == 0 {
            loopTarget = max(1, Int(s.presetLoopBeats.rounded())) + Int.random(in: 0...max(0, Int(s.presetLoopRandom.rounded())))
        }
        loopBeats += beatCount - loopLastBeat
        guard loopBeats >= loopTarget else { return (false, nil) }
        loopBeats = 0; loopTarget = 0
        let names = presetNames
        let next = names[(names.firstIndex(of: selectedPreset).map { $0 + 1 } ?? 0) % names.count]
        let cam = applyPreset(next)
        selectedPreset = next
        return (true, cam)
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
        saveWork = nil
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
    /// The "how to use" overlay (first launch, or the ? button).
    var showIntro = false

    /// Shows the intro with the settings sidebar open, so its tips can point at it.
    func startIntro() {
        overlay = false
        showSettings = true
        showIntro = true
    }
    var frozen = false
    /// Overlay mode: only the canvas, floating above other windows: no HUD, sidebar, window buttons or shadow.
    /// Not saved (the app always starts as a normal window); entered with T or the Window toggle, left only with Esc.
    var overlay = false
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

    /// Position on the palette list as one number: the integer part picks the palette, the fraction blends
    /// toward the next one (wrapping from the last back to the first).
    var colourMorph: Double {
        get { Double(PaletteKind.allCases.firstIndex(of: palette) ?? 0) + paletteMix }
        set {
            let n = Double(PaletteKind.allCases.count)
            var v = newValue.truncatingRemainder(dividingBy: n)
            if v < 0 { v += n }
            let i = min(Int(v), PaletteKind.allCases.count - 1)
            palette = PaletteKind.allCases[i]
            paletteMix = v - Double(i) < 0.001 ? 0 : v - Double(i)
        }
    }

    /// The palette actually drawn: the chosen one, blended toward the next by `paletteMix`.
    var effectivePalette: Palette {
        guard paletteMix > 0.001 else { return palette.palette }
        let all = PaletteKind.allCases
        let next = all[((all.firstIndex(of: palette) ?? 0) + 1) % all.count]
        return Palette.blend(palette.palette, next.palette, Float(paletteMix))
    }

    var effectiveInk: SIMD3<Float> {
        func rgb(_ h: UInt32) -> SIMD3<Float> { SIMD3(Float((h >> 16) & 0xFF), Float((h >> 8) & 0xFF), Float(h & 0xFF)) / 255 }
        guard paletteMix > 0.001 else { return rgb(palette.ink) }
        let all = PaletteKind.allCases
        let next = all[((all.firstIndex(of: palette) ?? 0) + 1) % all.count]
        return simd_mix(rgb(palette.ink), rgb(next.ink), SIMD3(repeating: Float(paletteMix)))
    }

    /// Applies the Intensity macro: calm (−1) slows, softens and settles everything; wild (+1) pushes motion,
    /// reach, glow, trails, warp, beat punch, colour and edge effects.
    func applyingIntensity() -> VizSettings {
        let e = intensity
        guard abs(e) > 0.001 else { return self }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        var o = self
        o.reach = max(0.05, reach * (1 + 0.8 * e))
        o.motion = clamp(motion * (1 + 0.8 * e), 0, 3)
        o.size = clamp(size * (1 + 0.3 * e), 0.1, 5)
        o.glow = clamp(glow + 0.35 * e, 0, 1)
        o.persistence = clamp(persistence + 0.25 * e, 0, 0.99)
        o.warp = clamp(warp + 0.3 * e, 0, 1)
        o.beat = clamp(beat + 0.5 * e, 0, 1.5)
        o.smoothing = clamp(smoothing - 0.2 * e, 0, 0.97)
        o.saturation = clamp(saturation * (1 + 0.35 * e), 0, 2)
        o.contrast = clamp(contrast * (1 + 0.2 * e), 0.2, 2)
        if e > 0 {
            o.aberration = clamp(aberration + 0.25 * e, 0, 1)
            o.fringe = clamp(fringe + 0.2 * e, 0, 1)
        } else {
            o.softFocus = clamp(softFocus - 0.3 * e, 0, 1)
        }
        return o
    }
}
