import Foundation

// Dreamcast mode: a stack of up to 10 animated retro-console graphics layers (sky, road, grid, platformer, demo
// effects, HUD …), all drawn procedurally in DreamcastShaders.swift (our own pixel art: genres and eras, no game's art)
// at a low "console" resolution, quantised to the chosen console's colours, then shown through a CRT pass.
// The layers are saved in VizSettings.dcLayers (bottom first).

/// The console whose screen is imitated: resolution, pixel shape and colours.
enum DCConsole: String, Codable, CaseIterable, Identifiable {
    case atari, nes, gameboy, megadrive, snes, dreamcast
    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        self = DCConsole(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .dreamcast
    }

    var title: String {
        switch self {
        case .atari: "Atari 2600"
        case .nes: "NES"
        case .gameboy: "Game Boy"
        case .megadrive: "Mega Drive"
        case .snes: "SNES"
        case .dreamcast: "Dreamcast"
        }
    }

    var help: String {
        switch self {
        case .atari: "192 lines of wide, chunky pixels and the 2600's 128-colour palette (16 hues × 8 brightnesses), no dithering."
        case .nes: "240 lines and the NES's fixed palette of about 50 colours."
        case .gameboy: "144 lines in the four shades of green of the original handheld."
        case .megadrive: "224 lines and 512 colours (3 bits per channel), with the dithering its games used for in-between shades."
        case .snes: "224 lines and 32 768 colours (5 bits per channel)."
        case .dreamcast: "480 lines and 16-bit colour: smooth gradients."
        }
    }

    /// Native lines (Resolution is set to this when the console is picked).
    var lines: Double {
        switch self {
        case .atari: 192
        case .nes: 240
        case .gameboy: 144
        case .megadrive, .snes: 224
        case .dreamcast: 480
        }
    }

    /// Width of a pixel relative to its height (the 2600's pixels are twice as wide as tall).
    var pixelAspect: Float { self == .atari ? 2 : 1 }

    var shaderIndex: Float { Float(Self.allCases.firstIndex(of: self) ?? 5) }
}

/// Where a layer kind comes from (groups the Add menu).
enum DCEra: CaseIterable {
    case atari, eightBit, sixteenBit, threeD, overlay
    var title: String {
        switch self {
        case .atari: "Atari & arcade"
        case .eightBit: "8-bit · NES, Master System"
        case .sixteenBit: "16-bit · Mega Drive, SNES, Amiga"
        case .threeD: "3D · PlayStation, Dreamcast"
        case .overlay: "Overlays"
        }
    }
}

/// What a layer draws. Raw values are saved; the shader numbers (`shaderIndex`) are fixed: don't renumber.
/// The case order is the order in the menus (by era).
enum DCKind: String, Codable, CaseIterable, Identifiable {
    case invaders, breaker, stars
    case platformer, clouds, palm
    case sky, sun, skyline, ocean, road, checker, rasterBars, scroller, demo, car
    case polygon, grid, planet, jet
    case hud, equalizer
    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        self = DCKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .sky
    }

    var era: DCEra {
        switch self {
        case .invaders, .breaker, .stars: .atari
        case .platformer, .clouds, .palm: .eightBit
        case .sky, .sun, .skyline, .ocean, .road, .checker, .rasterBars, .scroller, .demo, .car: .sixteenBit
        case .polygon, .grid, .planet, .jet: .threeD
        case .hud, .equalizer: .overlay
        }
    }

    var title: String {
        switch self {
        case .sky: "Sky"
        case .clouds: "Clouds"
        case .sun: "Sun"
        case .skyline: "Skyline"
        case .ocean: "Ocean"
        case .road: "Road"
        case .palm: "Palm trees"
        case .grid: "Grid"
        case .checker: "Checkerboard"
        case .stars: "Stars"
        case .planet: "Planet"
        case .polygon: "3D object"
        case .car: "Car"
        case .jet: "Jet"
        case .equalizer: "Equalizer"
        case .hud: "HUD"
        case .invaders: "Alien formation"
        case .breaker: "Brick breaker"
        case .platformer: "Platformer"
        case .rasterBars: "Raster bars"
        case .scroller: "Sine scroller"
        case .demo: "Demo effect"
        }
    }

    var symbol: String {
        switch self {
        case .sky: "sun.horizon"
        case .clouds: "cloud"
        case .sun: "sun.max"
        case .skyline: "building.2"
        case .ocean: "water.waves"
        case .road: "road.lanes"
        case .palm: "tree"
        case .grid: "squareshape.split.3x3"
        case .checker: "checkerboard.rectangle"
        case .stars: "sparkles"
        case .planet: "globe.europe.africa"
        case .polygon: "cube"
        case .car: "car.rear"
        case .jet: "airplane"
        case .equalizer: "chart.bar"
        case .hud: "gauge.with.dots.needle.33percent"
        case .invaders: "ladybug"
        case .breaker: "rectangle.split.3x3"
        case .platformer: "figure.run"
        case .rasterBars: "line.3.horizontal"
        case .scroller: "textformat"
        case .demo: "circle.hexagongrid"
        }
    }

    /// The Style choices of this kind (index = the shader's style number).
    var styles: [String] {
        switch self {
        case .sky: ["Day", "Sunset", "Dusk", "Night", "Space", "Striped (Atari)"]
        case .clouds: ["Cumulus", "Sunset streaks", "Haze bands"]
        case .sun: ["Striped sun", "Moon", "Bright sun"]
        case .skyline: ["Neon city", "Dark city", "Hills", "Mountains"]
        case .ocean: ["Day", "Sunset", "Night"]
        case .road: ["Coast", "Coast + palms", "Beach (open left side)", "Neon", "Neon + lamps"]
        case .palm: ["Single", "Pair", "Street lamp"]
        case .grid: ["Floor", "Floor lines only", "Room", "Tunnel"]
        case .checker: ["Floor (Mode 7)", "Scrolling", "Wavy"]
        case .stars: ["Twinkle", "Parallax", "Warp"]
        case .planet: ["Lava", "Gas giant", "Ice", "Earth-like"]
        case .polygon: ["Cube", "Pyramid", "Gem", "Ship", "Wire cube", "Wire ship"]
        case .car: ["Sports car", "Hover car"]
        case .jet: ["Jet", "Jet + trails"]
        case .equalizer: ["Bars", "LED", "Mirror"]
        case .hud: ["Racing", "Arcade", "Shooter"]
        case .invaders: ["Classic"]
        case .breaker: ["Classic"]
        case .platformer: ["Grassland", "Underground", "Castle"]
        case .rasterBars: ["Horizontal", "Vertical", "Copper sky"]
        case .scroller: ["Sine wave", "Bounce", "Mirrored"]
        case .demo: ["Plasma", "Tunnel", "Rotozoom"]
        }
    }

    /// What the music does to it (the layer's Music slider scales it), shown as the layer's help.
    var help: String {
        switch self {
        case .sky: "A banded, dithered sky gradient (or hard Atari colour bands). The beat brightens the horizon; Night and Space twinkle with the treble."
        case .clouds: "Pixel clouds drifting by (Speed). Louder music makes them swell; the bass makes the streaks wave."
        case .sun: "A big retro sun with scrolling stripes, a cratered moon or a bright sun. It swells with the bass."
        case .skyline: "City towers or hills along the horizon, scrolling sideways. Every tower rises with its own frequency band; windows flicker with the treble."
        case .ocean: "Water down to the horizon with rolling glints. The treble makes it glitter."
        case .road: "A pseudo-3D racing road with curves, rumble strips and roadside palms or lamps. The music drives the speed."
        case .palm: "A swaying palm tree (or a street lamp) to place anywhere. The bass makes it sway."
        case .grid: "A neon perspective grid: a floor, a grid room or a tunnel, rushing towards you. The beat flashes the lines."
        case .checker: "A checkerboard floor in the Mode 7 style, scrolling or wavy. Kicks flash it."
        case .stars: "A starfield: twinkling, scrolling in layers, or warp speed. The music speeds it up and the treble twinkles."
        case .planet: "A turning pixel planet with dithered shading. Its atmosphere glows with the bass."
        case .polygon: "A low-poly 3D object, flat-shaded or wireframe, spinning. Kicks spin it, the bass pumps it."
        case .car: "A rear-view car bouncing on the bass; its tail lights flash on the kicks."
        case .jet: "A jet seen from behind, banking; its afterburners flare with the loudness."
        case .equalizer: "Chunky spectrum bars with falling peaks."
        case .hud: "A game HUD: score, timer, speed and stage readouts that run with the music."
        case .invaders: "A formation of pixel aliens marching back and forth and stepping down. Kicks blow one up, snares fire the cannon; the music drives the march."
        case .breaker: "A ball breaking a wall of bricks; the music sets its pace. A new wall comes when it's cleared."
        case .platformer: "A side-scrolling tile world with platforms and spinning coins; the runner jumps on the kicks."
        case .rasterBars: "Shaded colour bars bouncing up and down (or sideways), one per frequency band: louder bands are fatter. Or a whole sky of line-by-line colour."
        case .scroller: "Big text gliding across the screen on a wave, every letter bouncing with the bass. Type your own text."
        case .demo: "Classic demo effects: a colour plasma, a tunnel flight or a spinning, zooming pattern, in the palette's colours. The bass pushes them."
        }
    }

    /// The shader's kind number (fixed).
    var shaderIndex: Float {
        switch self {
        case .sky: 0
        case .clouds: 1
        case .sun: 2
        case .skyline: 3
        case .ocean: 4
        case .road: 5
        case .palm: 6
        case .grid: 7
        case .checker: 8
        case .stars: 9
        case .planet: 10
        case .polygon: 11
        case .car: 12
        case .jet: 13
        case .equalizer: 14
        case .hud: 15
        case .invaders: 16
        case .breaker: 17
        case .platformer: 18
        case .rasterBars: 19
        case .scroller: 20
        case .demo: 21
        }
    }
}

/// One layer of the stack. Position is in half-screens (−1 … 1), rotation in degrees, hue = a turn of the colour wheel.
struct DCLayer: Codable, Equatable, Identifiable {
    static let defaultText = "SOUNDWATCH IS PLAYING YOUR MUSIC ... GREETINGS TO EVERYONE ON THE DANCEFLOOR ..."
    var id = UUID()
    var kind: DCKind = .sky
    var style = 0
    var on = true
    var speed = 1.0
    var x = 0.0
    var y = 0.0
    var scale = 1.0
    var rotation = 0.0
    var opacity = 1.0
    /// How much the music drives it (speed, pulses, sizes): 0 = runs on its own.
    var react = 0.5
    var hue = 0.0
    /// Sine scroller: its text.
    var text = DCLayer.defaultText

    init(_ kind: DCKind, style: Int = 0, speed: Double = 1, x: Double = 0, y: Double = 0, scale: Double = 1,
         rotation: Double = 0, opacity: Double = 1, react: Double = 0.5, hue: Double = 0) {
        self.kind = kind; self.style = style; self.speed = speed; self.x = x; self.y = y; self.scale = scale
        self.rotation = rotation; self.opacity = opacity; self.react = react; self.hue = hue
    }

    /// Tolerant decoding: fields added later never break saved stacks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DCLayer(.sky)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decodeIfPresent(DCKind.self, forKey: .kind)) ?? .sky
        style = (try? c.decodeIfPresent(Int.self, forKey: .style)) ?? 0
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? true
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? Self.defaultText
        func num(_ k: CodingKeys, _ def: Double) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? def }
        speed = num(.speed, d.speed); x = num(.x, d.x); y = num(.y, d.y); scale = num(.scale, d.scale)
        rotation = num(.rotation, d.rotation); opacity = num(.opacity, d.opacity); react = num(.react, d.react)
        hue = num(.hue, d.hue)
        style = min(max(0, style), kind.styles.count - 1)
    }

    /// Same settings, new identity (duplicating, loading a scene).
    func copy() -> DCLayer { var l = self; l.id = UUID(); return l }
}

/// Ready-made stacks (the Layers group's Presets menu), each on its console. Bottom layer first.
struct DCScene: Identifiable {
    let name: String
    let console: DCConsole
    let layers: [DCLayer]
    var id: String { name }

    static let maxLayers = 10

    static let all: [DCScene] = [
        DCScene(name: "Sunset drive", console: .dreamcast, layers: [
            DCLayer(.sky, style: 1),
            DCLayer(.clouds, style: 1, speed: 0.5, y: 0.1, opacity: 0.85),
            DCLayer(.sun, style: 0, y: 0.1),
            DCLayer(.skyline, style: 0, speed: 0.6),
            DCLayer(.road, style: 4),
            DCLayer(.car),
            DCLayer(.hud, style: 0),
        ]),
        DCScene(name: "Alien attack", console: .atari, layers: [
            DCLayer(.stars, style: 0, opacity: 0.7),
            DCLayer(.invaders, react: 0.6),
            DCLayer(.hud, style: 1),
        ]),
        DCScene(name: "Brick breaker", console: .atari, layers: [
            DCLayer(.sky, style: 5, opacity: 0.35),
            DCLayer(.breaker, speed: 1.2, react: 0.6),
            DCLayer(.hud, style: 1),
        ]),
        DCScene(name: "8-bit adventure", console: .nes, layers: [
            DCLayer(.sky, style: 0),
            DCLayer(.clouds, style: 0, speed: 0.3, y: 0.15),
            DCLayer(.platformer, style: 0, react: 0.7),
            DCLayer(.hud, style: 1),
        ]),
        DCScene(name: "Pocket dungeon", console: .gameboy, layers: [
            DCLayer(.sky, style: 0),
            DCLayer(.platformer, style: 2, react: 0.7),
            DCLayer(.hud, style: 1),
        ]),
        DCScene(name: "16-bit demo", console: .megadrive, layers: [
            DCLayer(.demo, style: 0, speed: 0.8),
            DCLayer(.rasterBars, style: 0, opacity: 0.95),
            DCLayer(.scroller, style: 0, y: -0.45, react: 0.7),
        ]),
        DCScene(name: "Coast run", console: .megadrive, layers: [
            DCLayer(.sky, style: 0),
            DCLayer(.clouds, style: 0, speed: 0.4),
            DCLayer(.ocean, style: 0),
            DCLayer(.road, style: 2),
            DCLayer(.car),
            DCLayer(.hud, style: 0),
        ]),
        DCScene(name: "Special stage", console: .snes, layers: [
            DCLayer(.sky, style: 4),
            DCLayer(.checker, style: 0, speed: 1.2),
            DCLayer(.polygon, style: 1, y: 0.1, scale: 0.9, react: 0.8),
            DCLayer(.hud, style: 1),
        ]),
        DCScene(name: "Synth grid", console: .snes, layers: [
            DCLayer(.sky, style: 2),
            DCLayer(.stars, style: 0, opacity: 0.8),
            DCLayer(.sun, style: 0, y: 0.08, scale: 1.2),
            DCLayer(.skyline, style: 3, speed: 0.3),
            DCLayer(.grid, style: 0),
            DCLayer(.equalizer, style: 2, y: 0.55, scale: 0.6, opacity: 0.7),
        ]),
        DCScene(name: "Demo tunnel", console: .snes, layers: [
            DCLayer(.demo, style: 1),
            DCLayer(.scroller, style: 1, y: 0.55, react: 0.8),
        ]),
        DCScene(name: "Deep space", console: .dreamcast, layers: [
            DCLayer(.stars, style: 1, speed: 0.5),
            DCLayer(.planet, style: 0, speed: 0.6, x: 0.45, y: 0.35, scale: 1.6),
            DCLayer(.stars, style: 2, speed: 0.6, opacity: 0.6),
            DCLayer(.polygon, style: 3, x: -0.25, y: -0.25, scale: 1.3),
            DCLayer(.hud, style: 2),
        ]),
        DCScene(name: "Grid room", console: .dreamcast, layers: [
            DCLayer(.grid, style: 2, speed: 0.7),
            DCLayer(.polygon, style: 2, scale: 1.2, react: 0.7),
            DCLayer(.equalizer, style: 1, y: -0.55, scale: 0.7, opacity: 0.9),
            DCLayer(.hud, style: 1),
        ]),
        DCScene(name: "Sky pilot", console: .dreamcast, layers: [
            DCLayer(.sky, style: 0),
            DCLayer(.clouds, style: 0, speed: 1.2),
            DCLayer(.ocean, style: 0, speed: 1.6),
            DCLayer(.jet, style: 1),
            DCLayer(.hud, style: 2),
        ]),
    ]

    static var defaultLayers: [DCLayer] { all[0].layers.map { $0.copy() } }
}
