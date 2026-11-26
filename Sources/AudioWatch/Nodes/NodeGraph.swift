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
    /// Parameter id for output nodes (Layer nodes: the layer value's id, see `LayerParam`).
    var target: String = ""
    /// Layer nodes: the layer they drive (`DCLayer.id`).
    var layer: UUID?

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
    case band, loudness, beat, hit, pitch, brightness, tempo
    // generators
    case lfo, constant, random, counter
    // modifiers
    case map, smooth, curve, invert, gate, steps, math, accumulate, hold
    // output
    case param, layer

    init(from decoder: Decoder) throws {
        self = NodeKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .constant
    }

    var category: NodeCategory {
        switch self {
        case .band, .loudness, .beat, .hit, .pitch, .brightness, .tempo: .input
        case .lfo, .constant, .random, .counter: .generator
        case .map, .smooth, .curve, .invert, .gate, .steps, .math, .accumulate, .hold: .modifier
        case .param, .layer: .output
        }
    }

    var title: String {
        switch self {
        case .band: "Frequency band"
        case .loudness: "Loudness"
        case .beat: "Beat"
        case .tempo: "Tempo"
        case .hit: "Drum hit"
        case .pitch: "Pitch"
        case .brightness: "Brightness"
        case .lfo: "LFO"
        case .constant: "Constant"
        case .random: "Random"
        case .counter: "Counter"
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
        case .layer: "Layer"
        }
    }

    var help: String {
        switch self {
        case .band: "Level of a frequency range, 0 … ~1.5 (uses the Response settings: gain, floor, tilt)."
        case .loudness: "Overall level, 0 … ~1.5."
        case .beat: "1 on each beat, decaying to 0 (on the tracked tempo with Lock to tempo, else bass hits)."
        case .tempo: "From the tracked tempo. Beat ramp: rises 0 → 1 over each beat (feed a Curve or Steps for beat-synced motion). BPM: 0 at 60 … 1 at 200. Confidence: 0 … 1, how steady the beat is."
        case .hit: "Jumps to the hit's strength on each kick / snare / hi-hat, then decays. Sensitivity: higher catches quieter hits (and more wrong ones)."
        case .pitch: "Dominant pitch, 0 at 50 Hz … 1 at 2 kHz (log)."
        case .brightness: "Spectral balance: 0 = all bass, 1 = all treble."
        case .lfo: "A steady wave, 0 … 1. Sync → Music tempo: one cycle per the chosen number of beats, locked to the tracked beat (free-running at the last tempo until one is found)."
        case .constant: "A fixed value."
        case .random: "A new random value 0 … 1 at the given rate, glided."
        case .counter: "Grows steadily by Speed every second, without end (0, 1, 2, …). Into a cyclic parameter (hue, angle) it keeps turning."
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
        case .layer: "Drives one value of one layer (modes with layers: Dreamcast). Add: the layer's slider value + input × amount × range. Set: the input (0 … 1) spans the whole range. Inactive (dimmed) in modes without layers; removed with its layer."
        }
    }

    var inputs: [String] {
        switch self {
        case .band, .loudness, .beat, .hit, .pitch, .brightness, .tempo, .lfo, .constant, .random, .counter: []
        case .math: ["A", "B"]
        case .hold: ["In", "Trigger"]
        default: ["In"]
        }
    }
    var hasOutput: Bool { category != .output }

    var fields: [NodeField] {
        switch self {
        case .band: [NodeField(key: "lo", label: "Low", range: 20...16000, def: 40, format: "%.0f Hz", isLog: true),
                     NodeField(key: "hi", label: "High", range: 20...16000, def: 150, format: "%.0f Hz", isLog: true)]
        case .hit: [NodeField(key: "drum", label: "Drum", range: 0...2, def: 0, options: ["Kick", "Snare", "Hats"]),
                    NodeField(key: "decay", label: "Decay", range: 20...2000, def: 250, format: "%.0f ms", isLog: true),
                    NodeField(key: "sens", label: "Sensitivity", range: 0...Double(DrumDetector.levels - 1), def: Double(DrumDetector.normalLevel),
                              options: DrumDetector.levelNames)]
        case .beat, .loudness, .pitch, .brightness: []
        case .tempo: [NodeField(key: "out", label: "Output", range: 0...2, def: 0, options: ["Beat ramp", "BPM", "Confidence"])]
        case .lfo: [NodeField(key: "rate", label: "Rate", range: 0.01...10, def: 0.25, format: "%.2f Hz", isLog: true),
                    NodeField(key: "shape", label: "Shape", range: 0...3, def: 0, options: ["Sine", "Triangle", "Saw", "Square"]),
                    NodeField(key: "sync", label: "Sync", range: 0...1, def: 0, options: ["Free (Rate)", "Music tempo"]),
                    NodeField(key: "beats", label: "Cycle", range: 0...Double(NodeKind.lfoBeats.count - 1), def: 4,
                              options: NodeKind.lfoBeats.map(\.title))]
        case .constant: [NodeField(key: "v", label: "Value", range: -1e6...1e6, def: 1, free: true)]
        case .random: [NodeField(key: "rate", label: "Rate", range: 0.05...10, def: 1, format: "%.2f Hz", isLog: true),
                       NodeField(key: "glide", label: "Glide", range: 0...2000, def: 200, format: "%.0f ms")]
        case .counter: [NodeField(key: "speed", label: "Speed", range: 0.01...100, def: 1, format: "%.2f /s", isLog: true)]
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
        case .param, .layer: [NodeField(key: "amount", label: "Amount", range: -1...1, def: 0.5),
                      NodeField(key: "mode", label: "Mode", range: 0...1, def: 0, options: ["Add", "Set"])]
        }
    }

    /// The LFO's cycle lengths when synced to the music (beats per cycle). A "bar" is 4 beats counted from wherever the
    /// tracker started (downbeats aren't detected).
    static let lfoBeats: [(title: String, beats: Double)] = [
        ("¼ beat", 0.25), ("½ beat", 0.5), ("1 beat", 1), ("2 beats", 2), ("1 bar", 4), ("2 bars", 8), ("4 bars", 16), ("8 bars", 32)]

    /// Entries of the right-click menu: several are one kind with different starting values.
    static let menu: [(category: NodeCategory, items: [(title: String, kind: NodeKind, values: [String: Double])])] = [
        (.input, [("Bass", .band, ["lo": 30, "hi": 150]),
                  ("Mids", .band, ["lo": 300, "hi": 2000]),
                  ("Highs", .band, ["lo": 4000, "hi": 16000]),
                  ("Frequency band…", .band, ["lo": 150, "hi": 600]),
                  ("Loudness", .loudness, [:]),
                  ("Beat", .beat, [:]),
                  ("Beat ramp", .tempo, ["out": 0]),
                  ("Tempo (BPM)", .tempo, ["out": 1]),
                  ("Kick hit", .hit, ["drum": 0]),
                  ("Snare hit", .hit, ["drum": 1]),
                  ("Hats hit", .hit, ["drum": 2]),
                  ("Pitch", .pitch, [:]),
                  ("Brightness", .brightness, [:])]),
        (.generator, [("LFO", .lfo, [:]), ("Random", .random, [:]), ("Constant", .constant, [:]), ("Counter", .counter, [:])]),
        (.modifier, [("Map range", .map, [:]), ("Smooth", .smooth, [:]), ("Curve", .curve, [:]),
                     ("Invert", .invert, [:]), ("Threshold", .gate, [:]), ("Steps", .steps, [:]),
                     ("Math", .math, [:]), ("Accumulate", .accumulate, [:]), ("Sample & hold", .hold, [:])]),
        (.output, [("Parameter", .param, [:])]),
    ]
}

// MARK: - Example patches (the editor's "Add example patch" dialog)

struct ExamplePatch: Identifiable {
    struct Item {
        let kind: NodeKind
        /// Grid position: columns left to right, rows top to bottom.
        let col: Double, row: Double
        var values: [String: Double] = [:]
        var target = ""
    }
    let title: String
    let summary: String
    let items: [Item]
    /// Wires between items, by index.
    let links: [(from: Int, to: Int, port: Int)]
    var id: String { title }

    /// Fresh nodes and links (new ids every time), with the top-left node at `origin`.
    func build(x: Double, y: Double) -> (nodes: [GraphNode], links: [NodeLink]) {
        let nodes = items.map {
            GraphNode(kind: $0.kind, x: x + $0.col * 240, y: y + $0.row * 110, values: $0.values, target: $0.target)
        }
        return (nodes, links.map { NodeLink(from: nodes[$0.from].id, to: nodes[$0.to].id, port: $0.port) })
    }

    static let all: [ExamplePatch] = [
        ExamplePatch(title: "Bass pulse", summary: "The bass makes everything swell: Bass → Smooth → Size.",
                     items: [Item(kind: .band, col: 0, row: 0, values: ["lo": 30, "hi": 150]),
                             Item(kind: .smooth, col: 1, row: 0, values: ["rise": 20, "fall": 250]),
                             Item(kind: .param, col: 2, row: 0, values: ["amount": 0.15, "mode": 0], target: "size")],
                     links: [(0, 1, 0), (1, 2, 0)]),
        ExamplePatch(title: "Kick zoom", summary: "Every kick drum punches the picture in, then it eases back: Kick hit → Zoom.",
                     items: [Item(kind: .hit, col: 0, row: 0, values: ["drum": 0, "decay": 220]),
                             Item(kind: .param, col: 1, row: 0, values: ["amount": 0.08, "mode": 0], target: "zoom")],
                     links: [(0, 1, 0)]),
        ExamplePatch(title: "Hi-hat sparkle", summary: "Hats and cymbals light up the glow and split the colours: Highs → Curve → Glow + Chromatic aberration.",
                     items: [Item(kind: .band, col: 0, row: 0, values: ["lo": 4000, "hi": 16000]),
                             Item(kind: .curve, col: 1, row: 0, values: ["exp": 2]),
                             Item(kind: .param, col: 2, row: 0, values: ["amount": 0.5, "mode": 0], target: "glow"),
                             Item(kind: .param, col: 2, row: 1, values: ["amount": 0.3, "mode": 0], target: "aberration")],
                     links: [(0, 1, 0), (1, 2, 0), (1, 3, 0)]),
        ExamplePatch(title: "New colour on every beat", summary: "Each beat picks a random hue and holds it until the next one: Random + Beat → Sample & hold → Hue rotate.",
                     items: [Item(kind: .random, col: 0, row: 0, values: ["rate": 10, "glide": 0]),
                             Item(kind: .beat, col: 0, row: 1),
                             Item(kind: .hold, col: 1, row: 0),
                             Item(kind: .param, col: 2, row: 0, values: ["mode": 1], target: "hueRotate")],
                     links: [(0, 2, 0), (1, 2, 1), (2, 3, 0)]),
        ExamplePatch(title: "Loudness turntable", summary: "The view orbits by itself, faster when the music is loud (3D modes): Loudness → Accumulate → Orbit spin.",
                     items: [Item(kind: .loudness, col: 0, row: 0),
                             Item(kind: .accumulate, col: 1, row: 0, values: ["rate": 0.15, "wrap": 1]),
                             Item(kind: .param, col: 2, row: 0, values: ["mode": 1], target: "camYaw")],
                     links: [(0, 1, 0), (1, 2, 0)]),
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
        ModParam(id: "imgSpring", title: "Image particles springiness", group: "Mode", range: 0...1, target: .setting(\.imgSpring)),
        ModParam(id: "imgDepth", title: "Image particles depth", group: "Mode", range: 0...1, target: .setting(\.imgDepth)),
        ModParam(id: "primDensity", title: "Primitives density", group: "Mode", range: 0.2...3, target: .setting(\.primDensity)),
        ModParam(id: "harmonoSwings", title: "Harmonograph swings", group: "Mode", range: 2...10, target: .setting(\.harmonoSwings)),
        ModParam(id: "scopeMs", title: "Oscilloscope window", group: "Mode", range: 1...300, target: .setting(\.scopeMs)),
        ModParam(id: "vectorMs", title: "Vectorscope window", group: "Mode", range: 5...500, target: .setting(\.vectorMs)),
        ModParam(id: "attractorMs", title: "Attractor window", group: "Mode", range: 5...200, target: .setting(\.attractorMs)),
        ModParam(id: "membraneTint", title: "Membrane tint", group: "Mode", range: 0...1, target: .setting(\.membraneTint)),
        ModParam(id: "membraneRelief", title: "Membrane relief", group: "Mode", range: 0...1, target: .setting(\.membraneRelief)),
        ModParam(id: "diamondMove", title: "Diamond movement", group: "Mode", range: 0...1, target: .setting(\.diamondMove)),
        ModParam(id: "diamondFacets", title: "Diamond facets", group: "Mode", range: 5...50, target: .setting(\.diamondFacets)),
        ModParam(id: "diamondFire", title: "Diamond rainbow", group: "Mode", range: 0...1, target: .setting(\.diamondFire)),
        ModParam(id: "ferroSpikes", title: "Splashs magnet", group: "Mode", range: 0...1, target: .setting(\.ferroSpikes)),
        ModParam(id: "ferroSplash", title: "Splashs splash", group: "Mode", range: 0...1, target: .setting(\.ferroSplash)),
        ModParam(id: "ferroFluid", title: "Splashs fluid", group: "Mode", range: 0.3...2, target: .setting(\.ferroFluid)),
        ModParam(id: "mbMagnet", title: "Ferrofluid magnet", group: "Mode", range: 1...2, target: .setting(\.mbMagnet)),
        ModParam(id: "mbMagnets", title: "Ferrofluid magnets", group: "Mode", range: 3...Double(MetaballsViz.maxCoils), target: .setting(\.mbMagnets)),
        ModParam(id: "mbHold", title: "Ferrofluid hold", group: "Mode", range: 0...1, target: .setting(\.mbHold)),
        ModParam(id: "mbLag", title: "Ferrofluid coil lag", group: "Mode", range: 5...200, target: .setting(\.mbLag)),
        ModParam(id: "mbHome", title: "Ferrofluid centre pull", group: "Mode", range: 0.25...0.75, target: .setting(\.mbHome)),
        ModParam(id: "mbBurstAmt", title: "Ferrofluid burst strength", group: "Mode", range: 0...2, target: .setting(\.mbBurstAmt)),
        ModParam(id: "mbBurstThr", title: "Ferrofluid burst threshold", group: "Mode", range: 0...1, target: .setting(\.mbBurstThr)),
        ModParam(id: "mbFluid", title: "Ferrofluid fluid", group: "Mode", range: 0.25...5, target: .setting(\.mbFluid)),
        ModParam(id: "orbGoo", title: "Orbs goo", group: "Mode", range: 0...1, target: .setting(\.orbGoo)),
        ModParam(id: "orbPress", title: "Orbs spread", group: "Mode", range: 0...1, target: .setting(\.orbPress)),
        ModParam(id: "chromeTint", title: "Chrome tint", group: "Mode", range: 0...1, target: .setting(\.chromeTint)),
        ModParam(id: "chromeBlur", title: "Chrome blur", group: "Mode", range: 0...1, target: .setting(\.chromeBlur)),
        ModParam(id: "chromeTurn", title: "Chrome environment turn", group: "Mode", range: 0...1, target: .setting(\.chromeTurn), cyclic: true),
        ModParam(id: "infBands", title: "Infinity bands", group: "Mode", range: 2...16, target: .setting(\.infBands)),
        ModParam(id: "infFold", title: "Infinity fold", group: "Mode", range: 0...1, target: .setting(\.infFold)),
        ModParam(id: "infMorph", title: "Infinity morph", group: "Mode", range: 0...1, target: .setting(\.infMorph)),
        ModParam(id: "forSun", title: "Forest sun", group: "Mode", range: 0...1, target: .setting(\.forSun)),
        ModParam(id: "forMist", title: "Landscape mist / haze", group: "Mode", range: 0...1, target: .setting(\.forMist)),
        ModParam(id: "forWind", title: "Forest wind", group: "Mode", range: 0...2, target: .setting(\.forWind)),
        ModParam(id: "forBirds", title: "Forest birds", group: "Mode", range: 0...1, target: .setting(\.forBirds)),
        ModParam(id: "forNight", title: "Forest day / night", group: "Mode", range: 0...1, target: .setting(\.forNight)),
        ModParam(id: "forFireflies", title: "Forest fireflies", group: "Mode", range: 0...1, target: .setting(\.forFireflies)),
        ModParam(id: "forSeason", title: "Forest season", group: "Mode", range: 0...1, target: .setting(\.forSeason), cyclic: true),
        ModParam(id: "forWeather", title: "Forest rain / snow", group: "Mode", range: 0...1, target: .setting(\.forWeather)),
        ModParam(id: "forGlow", title: "Landscape band light", group: "Mode", range: 0...1, target: .setting(\.forGlow)),
        ModParam(id: "dcCRT", title: "Dreamcast CRT style", group: "Mode", range: 0...1, target: .setting(\.dcCRT)),
        ModParam(id: "dcWarp", title: "Dreamcast warp", group: "Mode", range: 0...1, target: .setting(\.dcWarp)),
        ModParam(id: "dcWidth", title: "Dreamcast screen width", group: "Mode", range: 0.1...1, target: .setting(\.dcWidth)),
        ModParam(id: "dcHeight", title: "Dreamcast screen height", group: "Mode", range: 0.1...1, target: .setting(\.dcHeight)),
        ModParam(id: "dcRes", title: "Dreamcast resolution", group: "Mode", range: 96...720, target: .setting(\.dcRes), isLog: true),
        ModParam(id: "anRes", title: "Anime resolution", group: "Mode", range: 360...2160, target: .setting(\.anRes), isLog: true),
        ModParam(id: "anCamSpeed", title: "Anime camera speed", group: "Mode", range: 0...2, target: .setting(\.anCamSpeed)),
        ModParam(id: "anImpact", title: "Anime impact frames", group: "Mode", range: 0...1, target: .setting(\.anImpact)),
        ModParam(id: "anCuts", title: "Anime cuts", group: "Mode", range: 0...1, target: .setting(\.anCuts)),
        ModParam(id: "anFilm", title: "Anime film look", group: "Mode", range: 0...1, target: .setting(\.anFilm)),
        ModParam(id: "anRetro", title: "Anime old look", group: "Mode", range: 0...1, target: .setting(\.anRetro)),
        ModParam(id: "anLetterbox", title: "Anime letterbox", group: "Mode", range: 0...1, target: .setting(\.anLetterbox)),
        ModParam(id: "anZoom", title: "Anime zoom", group: "Mode", range: 0.1...3, target: .setting(\.anZoom), isLog: true),
        ModParam(id: "anPanX", title: "Anime pan X", group: "Mode", range: -1...1, target: .setting(\.anPanX)),
        ModParam(id: "anPanY", title: "Anime pan Y", group: "Mode", range: -1...1, target: .setting(\.anPanY)),
        ModParam(id: "anSpacing", title: "Anime 3D layer spacing", group: "Mode", range: 0...1, target: .setting(\.anSpacing)),
        ModParam(id: "cityTowers", title: "City towers", group: "Mode", range: 0.1...1, target: .setting(\.cityTowers)),
        ModParam(id: "cityAlt", title: "City camera height", group: "Mode", range: 0...1, target: .setting(\.cityAlt)),
        ModParam(id: "cityLights", title: "City light drones", group: "Mode", range: 0...1, target: .setting(\.cityLights)),
        ModParam(id: "cityBeams", title: "City searchlights", group: "Mode", range: 0...1, target: .setting(\.cityBeams)),
        ModParam(id: "cityTraffic", title: "City traffic", group: "Mode", range: 0...1, target: .setting(\.cityTraffic)),
        ModParam(id: "cityWet", title: "City wet streets", group: "Mode", range: 0...1, target: .setting(\.cityWet)),
        ModParam(id: "cityGloom", title: "City gloom", group: "Mode", range: 0...1, target: .setting(\.cityGloom)),
        ModParam(id: "cityReflect", title: "City window reflections", group: "Mode", range: 0...1, target: .setting(\.cityReflect)),
        ModParam(id: "cityReflBlur", title: "City reflection blur", group: "Mode", range: 0...1, target: .setting(\.cityReflBlur)),
        ModParam(id: "cityFlyby", title: "City fly-bys", group: "Mode", range: 0...1, target: .setting(\.cityFlyby)),
        ModParam(id: "cityArch", title: "City architecture", group: "Mode", range: 0...1, target: .setting(\.cityArch)),
        ModParam(id: "cityDrive", title: "City music drive", group: "Mode", range: 0...1, target: .setting(\.cityDrive)),
        ModParam(id: "cityPulse", title: "City kick pulses", group: "Mode", range: 0...1, target: .setting(\.cityPulse)),
        ModParam(id: "cityStorm",title: "City storm", group: "Mode", range: 0...1, target: .setting(\.cityStorm)),
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
        ModParam(id: "distortAmt", title: "Distortion amount", group: "Distortion", range: 0...1, target: .setting(\.distortAmt)),
        ModParam(id: "distortScale", title: "Distortion scale", group: "Distortion", range: 0.25...4, target: .setting(\.distortScale), isLog: true),
        ModParam(id: "distortSpeed", title: "Distortion speed", group: "Distortion", range: 0...3, target: .setting(\.distortSpeed)),
        ModParam(id: "dofAmount", title: "Depth of field", group: "Camera", range: 0...1, target: .setting(\.dofAmount)),
        ModParam(id: "dofNoise", title: "Blur noise", group: "Camera", range: 0...1, target: .setting(\.dofNoise)),
        ModParam(id: "dofFocus", title: "Focus distance", group: "Camera", range: 0...1, target: .setting(\.dofFocus)),
        ModParam(id: "dofRange", title: "Focus range", group: "Camera", range: 0...1, target: .setting(\.dofRange)),
        ModParam(id: "landGIAmount", title: "GI intensity", group: "Camera", range: 0...3, target: .setting(\.landGIAmount)),
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
    /// The parameter that drives this setting, if any (sliders built from a key path, e.g. the per-mode Detail).
    static func id(for keyPath: WritableKeyPath<VizSettings, Double>) -> String? {
        all.first { if case .setting(let kp) = $0.target { kp == keyPath } else { false } }?.id
    }
    static var groups: [String] { all.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } } }
}

// MARK: - Layer values a Layer node can drive (modes with layers: Dreamcast)

struct LayerParam: Identifiable {
    let id: String
    let title: String
    let range: ClosedRange<Double>
    let keyPath: WritableKeyPath<DCLayer, Double>
    var isLog = false
    var cyclic = false
    var animeOnly = false

    static let all: [LayerParam] = [
        LayerParam(id: "opacity", title: "Opacity", range: 0...1, keyPath: \.opacity),
        LayerParam(id: "x", title: "X", range: -1...1, keyPath: \.x),
        LayerParam(id: "y", title: "Y", range: -1...1, keyPath: \.y),
        LayerParam(id: "scale", title: "Scale", range: 0.1...4, keyPath: \.scale, isLog: true),
        LayerParam(id: "rotation", title: "Rotation", range: -180...180, keyPath: \.rotation, cyclic: true),
        LayerParam(id: "hue", title: "Hue", range: 0...1, keyPath: \.hue, cyclic: true),
        LayerParam(id: "speed", title: "Speed", range: 0...4, keyPath: \.speed),
        LayerParam(id: "react", title: "Music", range: 0...1, keyPath: \.react),
        LayerParam(id: "depth", title: "Depth", range: 0...2, keyPath: \.depth, animeOnly: true),
    ]
    /// The values a Layer node can drive in a mode (Depth only in Anime: Dreamcast's layers have no parallax).
    static func of(_ mode: VizMode) -> [LayerParam] { all.filter { !$0.animeOnly || mode == .anime } }
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

enum LayerNodes {
    /// Name of a layer for the node editor: its type and place in the stack, counted from the front (as the Layers list).
    static func title(_ id: UUID?, in layers: [DCLayer]) -> String? {
        guard let id, let i = layers.firstIndex(where: { $0.id == id }) else { return nil }
        return "\(layers.count - i). \(layers[i].kind.title)"
    }

    /// A Layer node can't do anything outside a mode with layers, or once its layer is gone.
    static func active(_ n: GraphNode, mode: VizMode, layers: [DCLayer]) -> Bool {
        n.kind != .layer || (mode.hasLayers && n.layer.map { id in layers.contains { $0.id == id } } == true)
    }
}

extension VizMode {
    /// Modes whose picture is a stack of layers that Layer nodes can drive.
    var hasLayers: Bool { self == .dreamcast || self == .anime }
}

extension VizSettings {
    /// The layers of the current mode (empty in modes without layers).
    var modeLayers: [DCLayer] { mode.hasLayers ? self[keyPath: layersKeyPath] : [] }

    /// Where the current mode keeps its layers (Dreamcast's when the mode has none).
    var layersKeyPath: WritableKeyPath<VizSettings, [DCLayer]> { mode == .anime ? \.anLayers : \.dcLayers }

    /// The layers Layer nodes are shown with: the current mode's, or (in modes without layers) both stacks, so a
    /// node's layer still has a name.
    var nodeLayers: [DCLayer] { mode.hasLayers ? self[keyPath: layersKeyPath] : dcLayers + anLayers }

    func layerNodeActive(_ n: GraphNode) -> Bool { LayerNodes.active(n, mode: mode, layers: modeLayers) }

    /// Removes the Layer nodes (and their wires) whose layer is in neither stack any more.
    mutating func dropOrphanLayerNodes() {
        let ids = Set(dcLayers.map(\.id) + anLayers.map(\.id))
        let gone = Set(nodes.nodes.filter { $0.kind == .layer && !($0.layer.map(ids.contains) ?? false) }.map(\.id))
        guard !gone.isEmpty else { return }
        nodes.links.removeAll { gone.contains($0.from) || gone.contains($0.to) }
        nodes.nodes.removeAll { gone.contains($0.id) }
    }
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
    /// Drum hits this frame per drum and sensitivity level (a hit is a one-frame event), and the latest strength per drum.
    private var drumSeen = -1
    private var hitNow = [[Bool]](repeating: [Bool](repeating: false, count: DrumDetector.levels), count: 3)
    private var hitStrength = [[Float]](repeating: [Float](repeating: 0, count: DrumDetector.levels), count: 3)
    private var memo: [UUID: Float] = [:]
    private var visiting: Set<UUID> = []

    func apply(_ base: VizSettings, analyzer: Analyzer, dt: Double, frozen: Bool) -> VizSettings {
        let g = base.nodes
        camYaw = 0; camPitch = 0; camZoom = 1
        guard g.enabled, g.nodes.contains(where: { $0.kind.category == .output }) else {
            if !driven.isEmpty { driven = [] }
            limited = []
            if !g.enabled { values = [:] }
            return base
        }
        let dt = frozen ? 0 : Float(dt)

        // shared per-frame features
        if !frozen && drumSeen >= 0 {
            for l in 0..<DrumDetector.levels {
                for h in analyzer.drumHits(after: drumSeen, level: l) {
                    hitNow[h.drum][l] = true
                    hitStrength[h.drum][l] = max(hitStrength[h.drum][l], 0.4 + 0.6 * h.strength)
                }
            }
        }
        drumSeen = analyzer.drumSeq
        let f = Features(analyzer: analyzer, s: base, dt: dt)

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
        // Layer nodes: only in a mode with layers, on layers that still exist (else they are inactive)
        if s.mode.hasLayers {
            let lkp = s.layersKeyPath
            var lsets: [String: Double] = [:], ladds: [String: Double] = [:]
            var touched: [(layer: Int, p: LayerParam, key: String)] = []
            for n in g.nodes where n.kind == .layer {
                guard let lid = n.layer, let li = s[keyPath: lkp].firstIndex(where: { $0.id == lid }),
                      let p = LayerParam.byID[n.target] else { continue }
                let key = "\(lid)/\(p.id)"
                let v = Double(input(n, 0, g, f))
                if !touched.contains(where: { $0.key == key }) { touched.append((li, p, key)) }
                if n.value("mode") >= 0.5 { lsets[key] = min(1, max(0, v)) }
                else { ladds[key, default: 0] += v * n.value("amount") }
            }
            for t in touched {
                let p = t.p
                let lo = p.isLog ? log(p.range.lowerBound) : p.range.lowerBound
                let hi = p.isLog ? log(p.range.upperBound) : p.range.upperBound
                let cur = s[keyPath: lkp][t.layer][keyPath: p.keyPath]
                var x = lsets[t.key].map { lo + $0 * (hi - lo) } ?? (p.isLog ? log(max(1e-6, cur)) : cur)
                x += (ladds[t.key] ?? 0) * (hi - lo)
                if p.cyclic {
                    x = lo + (x - lo).truncatingRemainder(dividingBy: hi - lo)
                    if x < lo { x += hi - lo }
                } else if x > hi || x < lo {
                    x = min(hi, max(lo, x))
                    atLimit.insert(t.key)
                }
                s[keyPath: lkp][t.layer][keyPath: p.keyPath] = p.isLog ? exp(x) : x
            }
            for n in g.nodes where n.kind == .layer {
                guard let lid = n.layer, let l = s[keyPath: lkp].first(where: { $0.id == lid }),
                      let p = LayerParam.byID[n.target] else { continue }
                memo[n.id] = Float(l[keyPath: p.keyPath])
            }
        }
        // evaluate unconnected chains too, so their meters move while patching
        for n in g.nodes where memo[n.id] == nil { _ = eval(n, g, f) }
        for d in 0..<3 { for l in 0..<DrumDetector.levels { hitNow[d][l] = false; hitStrength[d][l] = 0 } }   // consumed
        values = memo
        limited = Set(g.nodes.filter {
            ($0.kind == .param && atLimit.contains($0.target))
                || ($0.kind == .layer && atLimit.contains("\($0.layer?.uuidString ?? "")/\($0.target)"))
        }.map(\.id))
        if driven != drivenNow { driven = drivenNow }
        return s
    }

    private struct Features {
        let analyzer: Analyzer
        let s: VizSettings
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
        case .tempo:
            switch Int(p("out").rounded()) {
            case 1: v = a.tracker.bpm > 0 ? Float(min(1, max(0, (a.tracker.bpm - 60) / 140))) : 0
            case 2: v = a.tracker.confidence
            default: v = a.beatRamp
            }
        case .hit:
            let d = Int(p("drum").rounded()).clamped(0, 2), l = Int(p("sens").rounded()).clamped(0, DrumDetector.levels - 1)
            if hitNow[d][l] { st.x = hitStrength[d][l] }
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
            if p("sync") >= 0.5 {
                // locked to the music: one cycle per N beats of the tracked tempo. The phase runs at the tempo and is
                // pulled onto the beat clock (a big jump, e.g. a new tempo, is taken at once); before any tempo is
                // known it runs at its last speed (120 BPM at first).
                let beats = NodeKind.lfoBeats[Int(p("beats").rounded()).clamped(0, NodeKind.lfoBeats.count - 1)].beats
                let bps = a.tracker.bpm > 0 ? a.tracker.bpm / 60 : 2
                st.x += dt * Float(bps / beats)
                if dt > 0, a.tracker.bpm > 0 {
                    let target = Float((a.beatClock / beats).truncatingRemainder(dividingBy: 1))
                    var d = target - st.x
                    d -= d.rounded()
                    st.x += abs(d) > 0.2 ? d : d * (1 - exp(-dt / 0.15))
                }
                st.x -= floor(st.x)
            } else {
                st.x = (st.x + dt * p("rate")).truncatingRemainder(dividingBy: 1)
            }
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
        case .counter:
            // whole part and fraction kept apart, so the step stays exact after hours of counting
            st.y += dt * p("speed")
            let w = floor(st.y)
            st.x += w; st.y -= w
            v = st.x + st.y
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
        case .param, .layer:
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
