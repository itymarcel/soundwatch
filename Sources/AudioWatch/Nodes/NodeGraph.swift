import Foundation

// MARK: - Model (saved with the settings, so presets carry their node patch)

struct NodeGraph: Codable, Equatable {
    var nodes: [GraphNode] = []
    var links: [NodeLink] = []
    /// Lets the user switch the whole patch off without deleting it.
    var enabled = true

    func node(_ id: UUID) -> GraphNode? { nodes.first { $0.id == id } }
    func link(into id: UUID, port: Int) -> NodeLink? { links.first { $0.to == id && $0.port == port } }
}

struct GraphNode: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: NodeKind
    var x: Double
    var y: Double
    /// Field values by key; missing keys fall back to the field's default.
    var values: [String: Double] = [:]
    /// Parameter id for output nodes.
    var target: String = ""

    func value(_ key: String) -> Double { values[key] ?? kind.fields.first { $0.key == key }?.def ?? 0 }
}

/// A wire: output of `from` → input `port` of `to`.
struct NodeLink: Codable, Equatable, Hashable {
    var from: UUID
    var to: UUID
    var port: Int
}

enum NodeCategory: String, CaseIterable {
    case input = "Music", generator = "Generators", modifier = "Modifiers", output = "Output"
}

struct NodeField {
    let key: String
    let label: String
    let range: ClosedRange<Double>
    let def: Double
    var format = "%.2f"
    var isLog = false
    /// Non-empty for a choice field: the value is the option index.
    var options: [String] = []
    /// A plain number box with no limits (constants, map ranges) instead of a slider.
    var free = false
}

enum NodeKind: String, Codable, CaseIterable {
    // music
    case band, loudness, beat, hit, pitch, brightness
    // generators
    case lfo, constant, random
    // modifiers
    case map, smooth, curve, invert, gate, steps, math, accumulate, hold
    // output
    case param

    init(from decoder: Decoder) throws {
        self = NodeKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .constant
    }

    var category: NodeCategory {
        switch self {
        case .band, .loudness, .beat, .hit, .pitch, .brightness: .input
        case .lfo, .constant, .random: .generator
        case .map, .smooth, .curve, .invert, .gate, .steps, .math, .accumulate, .hold: .modifier
        case .param: .output
        }
    }

    var title: String {
        switch self {
        case .band: "Frequency band"
        case .loudness: "Loudness"
        case .beat: "Beat"
        case .hit: "Drum hit"
        case .pitch: "Pitch"
        case .brightness: "Brightness"
        case .lfo: "LFO"
        case .constant: "Constant"
        case .random: "Random"
        case .map: "Map range"
        case .smooth: "Smooth"
        case .curve: "Curve"
        case .invert: "Invert"
        case .gate: "Threshold"
        case .steps: "Steps"
        case .math: "Math"
        case .accumulate: "Accumulate"
        case .hold: "Sample & hold"
        case .param: "Parameter"
        }
    }

    var help: String {
        switch self {
        case .band: "Level of a frequency range, 0 … ~1.5 (uses the Response settings: gain, floor, tilt)."
        case .loudness: "Overall level, 0 … ~1.5."
        case .beat: "1 on each detected beat (bass), decaying to 0."
        case .hit: "Jumps to the hit strength on each kick / snare / hat onset, then decays."
        case .pitch: "Dominant pitch, 0 at 50 Hz … 1 at 2 kHz (log)."
        case .brightness: "Spectral balance: 0 = all bass, 1 = all treble."
        case .lfo: "A steady wave, 0 … 1."
        case .constant: "A fixed value."
        case .random: "A new random value 0 … 1 at the given rate, glided."
        case .map: "Maps In min…max onto Out min…max."
        case .smooth: "Follows the input with separate rise and fall times."
        case .curve: "Shapes the response: <1 boosts quiet parts, >1 favours peaks."
        case .invert: "1 − input."
        case .gate: "1 while the input is above the threshold, else 0."
        case .steps: "Quantizes to a number of steps."
        case .math: "Combines two inputs."
        case .accumulate: "Adds up the input over time: a steady input gives a steady ramp (e.g. constant spinning)."
        case .hold: "Grabs a new value from In each time Trigger rises above 0.5."
        case .param: "Drives a setting. Add: the slider value + input × amount × range. Set: the input (0 … 1) spans the whole range."
        }
    }

    var inputs: [String] {
        switch self {
        case .band, .loudness, .beat, .hit, .pitch, .brightness, .lfo, .constant, .random: []
        case .math: ["A", "B"]
        case .hold: ["In", "Trigger"]
        default: ["In"]
        }
    }
    var hasOutput: Bool { self != .param }

    var fields: [NodeField] {
        switch self {
        case .band: [NodeField(key: "lo", label: "Low", range: 20...16000, def: 40, format: "%.0f Hz", isLog: true),
                     NodeField(key: "hi", label: "High", range: 20...16000, def: 150, format: "%.0f Hz", isLog: true)]
        case .hit: [NodeField(key: "drum", label: "Drum", range: 0...2, def: 0, options: ["Kick", "Snare", "Hats"]),
                    NodeField(key: "decay", label: "Decay", range: 20...2000, def: 250, format: "%.0f ms", isLog: true)]
        case .beat, .loudness, .pitch, .brightness: []
        case .lfo: [NodeField(key: "rate", label: "Rate", range: 0.01...10, def: 0.25, format: "%.2f Hz", isLog: true),
                    NodeField(key: "shape", label: "Shape", range: 0...3, def: 0, options: ["Sine", "Triangle", "Saw", "Square"])]
        case .constant: [NodeField(key: "v", label: "Value", range: -1e6...1e6, def: 1, free: true)]
        case .random: [NodeField(key: "rate", label: "Rate", range: 0.05...10, def: 1, format: "%.2f Hz", isLog: true),
                       NodeField(key: "glide", label: "Glide", range: 0...2000, def: 200, format: "%.0f ms")]
        case .map: [NodeField(key: "inLo", label: "In min", range: -1e6...1e6, def: 0, free: true),
                    NodeField(key: "inHi", label: "In max", range: -1e6...1e6, def: 1, free: true),
                    NodeField(key: "outLo", label: "Out min", range: -1e6...1e6, def: 0, free: true),
                    NodeField(key: "outHi", label: "Out max", range: -1e6...1e6, def: 1, free: true),
                    NodeField(key: "clamp", label: "Clamp", range: 0...1, def: 1, options: ["Off", "On"])]
        case .smooth: [NodeField(key: "rise", label: "Rise", range: 0...2000, def: 30, format: "%.0f ms"),
                       NodeField(key: "fall", label: "Fall", range: 0...5000, def: 400, format: "%.0f ms")]
        case .curve: [NodeField(key: "exp", label: "Exponent", range: 0.1...6, def: 2, isLog: true)]
        case .invert: []
        case .gate: [NodeField(key: "th", label: "Threshold", range: 0...1.5, def: 0.5)]
        case .steps: [NodeField(key: "n", label: "Steps", range: 2...32, def: 4, format: "%.0f")]
        case .math: [NodeField(key: "op", label: "Op", range: 0...5, def: 0, options: ["A + B", "A − B", "A × B", "Min", "Max", "Mix ½"])]
        case .accumulate: [NodeField(key: "rate", label: "Rate", range: 0...4, def: 0.5),
                           NodeField(key: "wrap", label: "Wrap 0…1", range: 0...1, def: 1, options: ["Off", "On"])]
        case .hold: []
        case .param: [NodeField(key: "amount", label: "Amount", range: -1...1, def: 0.5),
                      NodeField(key: "mode", label: "Mode", range: 0...1, def: 0, options: ["Add", "Set"])]
        }
    }

    /// Entries of the right-click menu: several are one kind with different starting values.
    static let menu: [(category: NodeCategory, items: [(title: String, kind: NodeKind, values: [String: Double])])] = [
        (.input, [("Bass", .band, ["lo": 30, "hi": 150]),
                  ("Mids", .band, ["lo": 300, "hi": 2000]),
                  ("Highs", .band, ["lo": 4000, "hi": 16000]),
                  ("Frequency band…", .band, ["lo": 150, "hi": 600]),
                  ("Loudness", .loudness, [:]),
                  ("Beat", .beat, [:]),
                  ("Kick hit", .hit, ["drum": 0]),
                  ("Snare hit", .hit, ["drum": 1]),
                  ("Hats hit", .hit, ["drum": 2]),
                  ("Pitch", .pitch, [:]),
                  ("Brightness", .brightness, [:])]),
        (.generator, [("LFO", .lfo, [:]), ("Random", .random, [:]), ("Constant", .constant, [:])]),
        (.modifier, [("Map range", .map, [:]), ("Smooth", .smooth, [:]), ("Curve", .curve, [:]),
                     ("Invert", .invert, [:]), ("Threshold", .gate, [:]), ("Steps", .steps, [:]),
                     ("Math", .math, [:]), ("Accumulate", .accumulate, [:]), ("Sample & hold", .hold, [:])]),
        (.output, [("Parameter", .param, [:])]),
    ]
}

// MARK: - Parameters a node can drive

struct ModParam: Identifiable {
    enum Target {
        case setting(WritableKeyPath<VizSettings, Double>)
        case camYaw, camPitch, camZoom
    }
    let id: String
    let title: String
    let group: String
    let range: ClosedRange<Double>
    let target: Target
    var isLog = false
    /// Wraps around instead of stopping at the ends (hue, spin).
    var cyclic = false

    static let all: [ModParam] = [
        ModParam(id: "gain", title: "Gain", group: "Response", range: 0.2...5, target: .setting(\.gain)),
        ModParam(id: "floorDB", title: "Floor", group: "Response", range: -120...(-30), target: .setting(\.floorDB)),
        ModParam(id: "tilt", title: "Tilt", group: "Response", range: 0...6, target: .setting(\.tilt)),
        ModParam(id: "smoothing", title: "Smoothing", group: "Response", range: 0...0.97, target: .setting(\.smoothing)),
        ModParam(id: "minFreq", title: "Low freq", group: "Response", range: 20...1000, target: .setting(\.minFreq), isLog: true),
        ModParam(id: "maxFreq", title: "High freq", group: "Response", range: 1500...22000, target: .setting(\.maxFreq), isLog: true),

        ModParam(id: "size", title: "Size", group: "Shape & motion", range: 0.2...4, target: .setting(\.size)),
        ModParam(id: "glow", title: "Glow", group: "Shape & motion", range: 0...1, target: .setting(\.glow)),
        ModParam(id: "persistence", title: "Trails", group: "Shape & motion", range: 0...1, target: .setting(\.persistence)),
        ModParam(id: "motion", title: "Motion", group: "Shape & motion", range: 0...2, target: .setting(\.motion)),
        ModParam(id: "zoom", title: "Zoom", group: "Shape & motion", range: 0.3...2.5, target: .setting(\.zoom)),
        ModParam(id: "reach", title: "Reach (current mode)", group: "Shape & motion", range: 0...4, target: .setting(\.reach)),

        ModParam(id: "hueShift", title: "Colour offset", group: "Colour", range: 0...2, target: .setting(\.hueShift), cyclic: true),
        ModParam(id: "colorCycle", title: "Colour cycling", group: "Colour", range: 0...2, target: .setting(\.colorCycle)),

        ModParam(id: "warp", title: "Warp amount", group: "Feedback", range: 0...1, target: .setting(\.warp)),
        ModParam(id: "beat", title: "Beat", group: "Feedback", range: 0...1.5, target: .setting(\.beat)),

        ModParam(id: "camYaw", title: "Orbit spin", group: "Camera", range: -Double.pi...Double.pi, target: .camYaw, cyclic: true),
        ModParam(id: "camPitch", title: "Orbit tilt", group: "Camera", range: -1.4...1.4, target: .camPitch),
        ModParam(id: "camZoom", title: "Camera zoom", group: "Camera", range: 0.25...4, target: .camZoom, isLog: true),

        ModParam(id: "fieldSpring", title: "Field springiness", group: "Mode", range: 0...1, target: .setting(\.fieldSpring)),
        ModParam(id: "primDensity", title: "Primitives density", group: "Mode", range: 0.2...3, target: .setting(\.primDensity)),
        ModParam(id: "harmonoSwings", title: "Harmonograph swings", group: "Mode", range: 2...10, target: .setting(\.harmonoSwings)),
        ModParam(id: "scopeMs", title: "Oscilloscope window", group: "Mode", range: 5...300, target: .setting(\.scopeMs)),
        ModParam(id: "vectorMs", title: "Vectorscope window", group: "Mode", range: 5...500, target: .setting(\.vectorMs)),
        ModParam(id: "attractorMs", title: "Attractor window", group: "Mode", range: 5...200, target: .setting(\.attractorMs)),
        ModParam(id: "membraneTint", title: "Membrane tint", group: "Mode", range: 0...1, target: .setting(\.membraneTint)),
        ModParam(id: "membraneRelief", title: "Membrane relief", group: "Mode", range: 0...1, target: .setting(\.membraneRelief)),
        ModParam(id: "diamondMove", title: "Diamond movement", group: "Mode", range: 0...1, target: .setting(\.diamondMove)),
        ModParam(id: "diamondFacets", title: "Diamond facets", group: "Mode", range: 5...50, target: .setting(\.diamondFacets)),
        ModParam(id: "diamondFire", title: "Diamond rainbow", group: "Mode", range: 0...1, target: .setting(\.diamondFire)),
        ModParam(id: "orbGoo", title: "Orbs goo", group: "Mode", range: 0...1, target: .setting(\.orbGoo)),
        ModParam(id: "orbPress", title: "Orbs spread", group: "Mode", range: 0...1, target: .setting(\.orbPress)),
        ModParam(id: "chromeTint", title: "Chrome tint", group: "Mode", range: 0...1, target: .setting(\.chromeTint)),
        ModParam(id: "chromeBlur", title: "Chrome blur", group: "Mode", range: 0...1, target: .setting(\.chromeBlur)),
        ModParam(id: "chromeTurn", title: "Chrome environment turn", group: "Mode", range: 0...1, target: .setting(\.chromeTurn), cyclic: true),
        ModParam(id: "glassSoft", title: "Glass softness", group: "Mode", range: 0...1, target: .setting(\.glassSoft)),
        ModParam(id: "snippetSeconds", title: "Snippet window", group: "Mode", range: 0.5...15, target: .setting(\.snippetSeconds)),

        ModParam(id: "brightness", title: "Brightness", group: "Post-processing", range: -1...1, target: .setting(\.brightness)),
        ModParam(id: "contrast", title: "Contrast", group: "Post-processing", range: 0.2...2, target: .setting(\.contrast)),
        ModParam(id: "saturation", title: "Saturation", group: "Post-processing", range: 0...2, target: .setting(\.saturation)),
        ModParam(id: "hueRotate", title: "Hue rotate", group: "Post-processing", range: 0...1, target: .setting(\.hueRotate), cyclic: true),
        ModParam(id: "aberration", title: "Chromatic aberration", group: "Post-processing", range: 0...1, target: .setting(\.aberration)),
        ModParam(id: "pixelate", title: "Pixelate", group: "Post-processing", range: 0...1, target: .setting(\.pixelate)),
        ModParam(id: "posterize", title: "Posterize", group: "Post-processing", range: 0...1, target: .setting(\.posterize)),
        ModParam(id: "invert", title: "Invert", group: "Post-processing", range: 0...1, target: .setting(\.invert)),
        ModParam(id: "softFocus", title: "Soft focus", group: "Post-processing", range: 0...1, target: .setting(\.softFocus)),
        ModParam(id: "streak", title: "Streak", group: "Post-processing", range: 0...1, target: .setting(\.streak)),
        ModParam(id: "fringe", title: "Edge fringe", group: "Post-processing", range: 0...1, target: .setting(\.fringe)),
        ModParam(id: "filmGrain", title: "Film grain", group: "Post-processing", range: 0...1, target: .setting(\.filmGrain)),
        ModParam(id: "colourMorph", title: "Colours (morph)", group: "Creative", range: 0...Double(PaletteKind.allCases.count), target: .setting(\.colourMorph), cyclic: true),
        ModParam(id: "intensity", title: "Intensity", group: "Creative", range: -1...1, target: .setting(\.intensity)),
        ModParam(id: "grainSize", title: "Grain size", group: "Post-processing", range: 0.5...6, target: .setting(\.grainSize), isLog: true),

        ModParam(id: "mediaOpacity", title: "Media opacity", group: "Media layer", range: 0...1, target: .setting(\.mediaOpacity)),
        ModParam(id: "mediaDisplace", title: "Media displace", group: "Media layer", range: 0...1, target: .setting(\.mediaDisplace)),
        ModParam(id: "mediaBlur", title: "Media blur", group: "Media layer", range: 0...1, target: .setting(\.mediaBlur)),
        ModParam(id: "mediaScale", title: "Media scale", group: "Media layer", range: 0.1...8, target: .setting(\.mediaScale), isLog: true),
        ModParam(id: "mediaX", title: "Media X", group: "Media layer", range: -1...1, target: .setting(\.mediaX)),
        ModParam(id: "mediaY", title: "Media Y", group: "Media layer", range: -1...1, target: .setting(\.mediaY)),
        ModParam(id: "mediaRotate", title: "Media rotate", group: "Media layer", range: 0...1, target: .setting(\.mediaRotate), cyclic: true),
        ModParam(id: "mediaKaleido", title: "Media kaleido segments", group: "Media layer", range: 0...16, target: .setting(\.mediaKaleido)),
        ModParam(id: "mediaDrift", title: "Media drift", group: "Media layer", range: 0...1, target: .setting(\.mediaDrift)),
        ModParam(id: "mediaDriftDir", title: "Media drift direction", group: "Media layer", range: 0...1, target: .setting(\.mediaDriftDir), cyclic: true),
        ModParam(id: "mediaSpin", title: "Media spin", group: "Media layer", range: -1...1, target: .setting(\.mediaSpin)),
        ModParam(id: "mediaWander", title: "Media wander", group: "Media layer", range: 0...1, target: .setting(\.mediaWander)),
        ModParam(id: "mediaSpeed", title: "Video speed", group: "Media layer", range: 0...4, target: .setting(\.mediaSpeed)),

        ModParam(id: "scanlines", title: "Scanlines", group: "Post-processing", range: 0...1, target: .setting(\.scanlines)),
        ModParam(id: "vignette", title: "Vignette", group: "Post-processing", range: 0...1, target: .setting(\.vignette)),
        ModParam(id: "flicker", title: "Flicker", group: "Post-processing", range: 0...1, target: .setting(\.flicker)),
    ]
    /// Old patches may target "grain" (the CRT grain, since removed): it now drives Film grain.
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        .merging(["grain": all.first { $0.id == "filmGrain" }!]) { cur, _ in cur }
    static var groups: [String] { all.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } } }
}

// MARK: - Runtime (evaluated once per frame by the renderer, on the main thread)

final class NodeRuntime {
    /// Latest output of every node (for the editor's meters). Output nodes hold the parameter value they produced.
    private(set) var values: [UUID: Float] = [:]
    /// Camera offsets produced this frame.
    private(set) var camYaw: Float = 0, camPitch: Float = 0, camZoom: Float = 1
    /// Ids of the parameters currently driven (the settings panel marks them).
    private(set) var driven: Set<String> = []
    /// Output nodes whose parameter is pinned at the end of its range this frame (the editor flags them).
    private(set) var limited: Set<UUID> = []

    private var state: [UUID: SIMD4<Float>] = [:]
    private var onsets = Onsets()
    private var hitEnv = [Float](repeating: 0, count: 3)
    private var hitStrength = [Float](repeating: 0, count: 3)
    private var memo: [UUID: Float] = [:]
    private var visiting: Set<UUID> = []

    func apply(_ base: VizSettings, analyzer: Analyzer, dt: Double, frozen: Bool) -> VizSettings {
        let g = base.nodes
        camYaw = 0; camPitch = 0; camZoom = 1
        guard g.enabled, g.nodes.contains(where: { $0.kind == .param }) else {
            if !driven.isEmpty { driven = [] }
            limited = []
            if !g.enabled { values = [:] }
            return base
        }
        let dt = frozen ? 0 : Float(dt)

        // shared per-frame features
        var hits: [(band: Int, strength: Float)] = []
        if !frozen { hits = onsets.step(analyzer: analyzer, s: base, dt: Double(dt)) }
        for d in 0..<3 {
            if let h = hits.first(where: { $0.band == d }) { hitEnv[d] = 1; hitStrength[d] = 0.4 + 0.6 * h.strength }
        }
        let f = Features(analyzer: analyzer, s: base, hits: hitStrength, dt: dt)

        memo = [:]; visiting = []
        var s = base
        var drivenNow = Set<String>()
        var atLimit = Set<String>()
        var sets: [String: Double] = [:], adds: [String: Double] = [:]
        for n in g.nodes where n.kind == .param {
            guard let p = ModParam.byID[n.target] else { continue }
            let v = Double(input(n, 0, g, f))
            drivenNow.insert(p.id)
            if n.value("mode") >= 0.5 { sets[p.id] = min(1, max(0, v)) }
            else { adds[p.id, default: 0] += v * n.value("amount") }
        }
        for p in ModParam.all where drivenNow.contains(p.id) {
            // work in log space for log parameters so a modulation sweeps octaves evenly
            let lo = p.isLog ? log(p.range.lowerBound) : p.range.lowerBound
            let hi = p.isLog ? log(p.range.upperBound) : p.range.upperBound
            let cur: Double
            switch p.target {
            case .setting(let kp): cur = s[keyPath: kp]
            case .camYaw, .camPitch: cur = 0
            case .camZoom: cur = 1
            }
            var x = sets[p.id].map { lo + $0 * (hi - lo) } ?? (p.isLog ? log(max(1e-6, cur)) : cur)
            x += (adds[p.id] ?? 0) * (hi - lo)
            if p.cyclic {
                x = lo + (x - lo).truncatingRemainder(dividingBy: hi - lo)
                if x < lo { x += hi - lo }
            } else if x > hi || x < lo {
                x = min(hi, max(lo, x))
                atLimit.insert(p.id)
            }
            let out = p.isLog ? exp(x) : x
            switch p.target {
            case .setting(let kp): s[keyPath: kp] = out
            case .camYaw: camYaw = Float(out)
            case .camPitch: camPitch = Float(out)
            case .camZoom: camZoom = Float(out)
            }
        }
        for n in g.nodes where n.kind == .param {
            if let p = ModParam.byID[n.target] {
                switch p.target {
                case .setting(let kp): memo[n.id] = Float(s[keyPath: kp])
                case .camYaw: memo[n.id] = camYaw
                case .camPitch: memo[n.id] = camPitch
                case .camZoom: memo[n.id] = camZoom
                }
            }
        }
        // evaluate unconnected chains too, so their meters move while patching
        for n in g.nodes where memo[n.id] == nil { _ = eval(n, g, f) }
        for d in 0..<3 { hitEnv[d] = 0 }   // consumed: a hit is a one-frame event
        values = memo
        limited = Set(g.nodes.filter { $0.kind == .param && atLimit.contains($0.target) }.map(\.id))
        if driven != drivenNow { driven = drivenNow }
        return s
    }

    private struct Features {
        let analyzer: Analyzer
        let s: VizSettings
        let hits: [Float]
        let dt: Float
    }

    private func input(_ n: GraphNode, _ port: Int, _ g: NodeGraph, _ f: Features) -> Float {
        guard let l = g.link(into: n.id, port: port), let src = g.node(l.from) else { return 0 }
        return eval(src, g, f)
    }

    private func eval(_ n: GraphNode, _ g: NodeGraph, _ f: Features) -> Float {
        if let v = memo[n.id] { return v }
        if visiting.contains(n.id) { return values[n.id] ?? 0 }   // a loop: use last frame's value
        visiting.insert(n.id)
        defer { visiting.remove(n.id) }
        var st = state[n.id] ?? .zero
        let dt = f.dt
        let p = { (k: String) in Float(n.value(k)) }
        let a = f.analyzer
        let v: Float
        switch n.kind {
        case .band:
            let lo = Double(min(p("lo"), p("hi"))), hi = Double(max(p("lo"), p("hi")))
            v = a.level(lo, max(lo * 1.05, hi), s: f.s)
        case .loudness:
            v = a.level(30, 16_000, s: f.s)
        case .beat:
            v = a.beatPulse
        case .hit:
            let d = Int(p("drum").rounded()).clamped(0, 2)
            if hitEnv[d] > 0 { st.x = f.hits[d] }
            st.x *= exp(-dt / max(0.01, p("decay") / 1000))
            v = st.x
        case .pitch:
            let hz = max(50, min(2000, a.dominantHz))
            v = a.peakLevel > 1e-4 ? Float(log(hz / 50) / log(40)) : 0
        case .brightness:
            let b = a.bands(count: 16, s: f.s)
            var sum: Float = 0, w: Float = 0
            for (i, x) in b.enumerated() { sum += x * Float(i); w += x }
            st.x += ((w > 1e-3 ? sum / (w * 15) : 0) - st.x) * (1 - exp(-dt / 0.08))
            v = st.x
        case .lfo:
            st.x = (st.x + dt * p("rate")).truncatingRemainder(dividingBy: 1)
            let t = st.x
            switch Int(p("shape").rounded()) {
            case 1: v = 1 - abs(2 * t - 1)
            case 2: v = t
            case 3: v = t < 0.5 ? 1 : 0
            default: v = 0.5 - 0.5 * cos(2 * .pi * t)
            }
        case .constant:
            v = p("v")
        case .random:
            st.y += dt * p("rate")
            if st.y >= 1 || st.w == 0 { st.y = st.y.truncatingRemainder(dividingBy: 1); st.z = Float.random(in: 0...1); st.w = 1 }
            let g = p("glide") / 1000
            st.x = g < 0.005 ? st.z : st.x + (st.z - st.x) * (1 - exp(-dt / g))
            v = st.x
        case .map:
            let x = input(n, 0, g, f)
            let span = p("inHi") - p("inLo")
            var t = abs(span) < 1e-6 ? 0 : (x - p("inLo")) / span
            if p("clamp") >= 0.5 { t = min(1, max(0, t)) }
            v = p("outLo") + t * (p("outHi") - p("outLo"))
        case .smooth:
            let x = input(n, 0, g, f)
            let tau = (x > st.x ? p("rise") : p("fall")) / 1000
            st.x = tau < 0.001 ? x : st.x + (x - st.x) * (1 - exp(-dt / tau))
            v = st.x
        case .curve:
            let x = input(n, 0, g, f)
            v = x < 0 ? -pow(-x, p("exp")) : pow(x, p("exp"))
        case .invert:
            v = 1 - input(n, 0, g, f)
        case .gate:
            let x = input(n, 0, g, f), th = p("th")
            // a little hysteresis so noise around the threshold doesn't chatter
            if st.x > 0.5 { st.x = x < th * 0.9 ? 0 : 1 } else { st.x = x > th ? 1 : 0 }
            v = st.x
        case .steps:
            let k = max(1, p("n").rounded() - 1)
            v = (input(n, 0, g, f) * k).rounded() / k
        case .math:
            let x = input(n, 0, g, f), y = input(n, 1, g, f)
            switch Int(p("op").rounded()) {
            case 1: v = x - y
            case 2: v = x * y
            case 3: v = min(x, y)
            case 4: v = max(x, y)
            case 5: v = 0.5 * (x + y)
            default: v = x + y
            }
        case .accumulate:
            st.x += input(n, 0, g, f) * p("rate") * dt
            if p("wrap") >= 0.5 { st.x -= floor(st.x) } else { st.x = min(1000, max(-1000, st.x)) }
            v = st.x
        case .hold:
            let x = input(n, 0, g, f), trig = input(n, 1, g, f)
            if trig > 0.5 && st.y <= 0.5 { st.x = x }
            st.y = trig
            v = st.x
        case .param:
            v = input(n, 0, g, f)
        }
        state[n.id] = st
        let out = v.isFinite ? v : 0
        memo[n.id] = out
        return out
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(hi, Swift.max(lo, self)) }
}
