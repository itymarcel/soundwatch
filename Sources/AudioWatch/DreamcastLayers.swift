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

/// Where a layer kind comes from (groups the Add menu). The anime groups belong to the Anime mode.
enum DCEra: CaseIterable {
    case atari, eightBit, sixteenBit, threeD, overlay
    case animeSky, animeLand, animeWeather, animeAction, animeSpace
    var title: String {
        switch self {
        case .atari: "Atari & arcade"
        case .eightBit: "8-bit · NES, Master System"
        case .sixteenBit: "16-bit · Mega Drive, SNES, Amiga"
        case .threeD: "3D · PlayStation, Dreamcast"
        case .overlay: "Overlays"
        case .animeSky: "Sky & light"
        case .animeLand: "Land & water"
        case .animeWeather: "Weather & sparkle"
        case .animeAction: "Action"
        case .animeSpace: "Space & figures"
        }
    }

    /// The mode whose stack these kinds belong to.
    var mode: VizMode {
        switch self {
        case .atari, .eightBit, .sixteenBit, .threeD, .overlay: .dreamcast
        default: .anime
        }
    }

    static func of(_ mode: VizMode) -> [DCEra] { allCases.filter { $0.mode == mode } }
}

/// What a layer draws. Raw values are saved; the shader numbers (`shaderIndex`) are fixed: don't renumber.
/// The case order is the order in the menus (by era).
enum DCKind: String, Codable, CaseIterable, Identifiable {
    case invaders, breaker, stars
    case platformer, clouds, palm
    case sky, sun, skyline, ocean, road, checker, rasterBars, scroller, demo, car
    case polygon, grid, planet, jet
    case hud, equalizer
    // Anime mode (AnimeShaders.swift; own shader numbers)
    case anSky, anClouds, anSun, anRays, anStars
    case anMountains, anMeadow, anTrees, anWater, anTown
    case anParticles, anSparkles
    case anSpeedLines, anBurst, anAura, anSlash, anWings, anTitle
    case anPlanet, anShip, anFigure
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
        case .anSky, .anClouds, .anSun, .anRays, .anStars: .animeSky
        case .anMountains, .anMeadow, .anTrees, .anWater, .anTown: .animeLand
        case .anParticles, .anSparkles: .animeWeather
        case .anSpeedLines, .anBurst, .anAura, .anSlash, .anWings, .anTitle: .animeAction
        case .anPlanet, .anShip, .anFigure: .animeSpace
        }
    }

    /// Anime: scenery that goes on sideways forever (follows the camera's endless pan); one-off objects (sun, figure,
    /// aura …) only follow its bounded moves, so a pan never carries them out of the picture for good.
    var repeatsSideways: Bool {
        switch self {
        case .anSky, .anClouds, .anStars, .anMountains, .anMeadow, .anTrees, .anWater, .anTown, .anParticles, .anSparkles: true
        default: false
        }
    }

    /// Kinds of one mode, in menu order.
    static func of(_ mode: VizMode) -> [DCKind] { allCases.filter { $0.era.mode == mode } }

    /// Anime: how far away it is for the camera's parallax (0 = moves with the screen, 1 = the subject's distance,
    /// > 1 = in front). New layers start here.
    var defaultDepth: Double {
        switch self {
        case .anSky, .anStars: 0.02
        case .anSun, .anPlanet: 0.05
        case .anClouds: 0.15
        case .anMountains: 0.3
        case .anRays: 0.4
        case .anTown, .anTrees: 0.7
        case .anMeadow, .anWater, .anFigure, .anShip, .anAura, .anWings: 1
        case .anParticles: 1.3
        case .anSparkles: 1.5
        case .anSpeedLines, .anBurst, .anSlash, .anTitle: 0
        default: 1
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
        case .anSky: "Sky"
        case .anClouds: "Clouds"
        case .anSun: "Sun & moon"
        case .anRays: "Light rays"
        case .anStars: "Stars"
        case .anMountains: "Mountains"
        case .anMeadow: "Meadow"
        case .anTrees: "Tree line"
        case .anWater: "Water"
        case .anTown: "Town"
        case .anParticles: "Petals, snow & rain"
        case .anSparkles: "Sparkles"
        case .anSpeedLines: "Speed lines"
        case .anBurst: "Impact burst"
        case .anAura: "Aura"
        case .anSlash: "Slashes"
        case .anWings: "Light wings"
        case .anTitle: "Japanese titles"
        case .anPlanet: "Planet & nebula"
        case .anShip: "Spaceship"
        case .anFigure: "Silhouette"
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
        case .anSky: "sun.horizon"
        case .anClouds: "cloud"
        case .anSun: "sun.max"
        case .anRays: "light.beacon.max"
        case .anStars: "sparkles"
        case .anMountains: "mountain.2"
        case .anMeadow: "leaf"
        case .anTrees: "tree"
        case .anWater: "water.waves"
        case .anTown: "house"
        case .anParticles: "snowflake"
        case .anSparkles: "sparkle"
        case .anSpeedLines: "rays"
        case .anBurst: "burst"
        case .anAura: "flame"
        case .anSlash: "scribble"
        case .anWings: "bird"
        case .anTitle: "character.book.closed.ja"
        case .anPlanet: "globe.asia.australia"
        case .anShip: "airplane"
        case .anFigure: "figure.stand"
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
        case .anSky: ["Summer day", "Golden hour", "Sunset", "Twilight", "Night", "Crimson", "Overcast"]
        case .anClouds: ["Summer towers", "Sunset clouds", "Wisps", "Storm"]
        case .anSun: ["Sun + flare", "Red sun", "Full moon", "Crescent moon"]
        case .anRays: ["From above", "Fan", "Underwater"]
        case .anStars: ["Twinkle", "Shooting stars", "Milky way"]
        case .anMountains: ["Blue ranges", "Snowy peaks", "Green hills", "Dusk ridges"]
        case .anMeadow: ["Flower meadow", "Tall grass", "Golden field", "Night meadow"]
        case .anTrees: ["Conifers", "Round trees", "Bamboo"]
        case .anWater: ["Sea", "Shallows", "Night lake"]
        case .anTown: ["Rooftops + wires", "Power lines", "Distant city"]
        case .anParticles: ["Cherry petals", "Autumn leaves", "Snow", "Rain", "Fireflies", "Dust in the light"]
        case .anSparkles: ["Glints", "Bokeh", "Light leak"]
        case .anSpeedLines: ["Focus (ink)", "Focus (white)", "Horizontal", "Vertical"]
        case .anBurst: ["Starburst", "Shockwave", "Cracks"]
        case .anAura: ["Cursed flame", "Golden aura", "Spirit flame", "Lightning"]
        case .anSlash: ["Clean cut", "Water arc", "Flame arc", "Thunder"]
        case .anWings: ["Light wings", "Cross blast", "Halo"]
        case .anTitle: ["Vertical title", "Title card", "Ticker", "Giant kanji"]
        case .anPlanet: ["Earth from orbit", "Nebula", "Ringed planet"]
        case .anShip: ["Fighter", "Cruiser", "Comet"]
        case .anFigure: ["Lone figure", "Giant robot", "Figure on a cliff", "Swordsman", "Girl with umbrella", "Two figures",
                          "Cat on a wall", "Hooded wanderer", "Lone tree", "Shrine gate"]
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
        case .anSky: "A hand-painted sky gradient. The beat lifts the glow at the horizon; Night and Twilight have a few stars."
        case .anClouds: "Cel-shaded clouds with a hard shadow edge, drifting with the wind (Speed). Louder music makes them swell."
        case .anSun: "A sun with a lens flare, a huge red sun, or the moon. It swells and glows with the bass."
        case .anRays: "Soft beams of light falling through the picture. The beat brightens them."
        case .anStars: "Stars with cross-shaped glints, shooting stars, or the Milky Way. The treble makes them twinkle; hits send shooting stars."
        case .anMountains: "Painted mountain ranges fading into the haze, each ridge at its own distance (parallax)."
        case .anMeadow: "A field of grass and flowers down to the horizon. Wind waves roll through it, pushed by the bass; blades in front sway."
        case .anTrees: "A line of trees along the horizon or in front, swaying with the wind and the bass."
        case .anWater: "The sea with glinting highlights, bright ripples over shallow water, or a lake at night. The treble makes it glitter."
        case .anTown: "Rooftops with lit windows and power lines against the sky, or a distant skyline whose windows follow their frequency bands."
        case .anParticles: "Falling cherry petals, leaves, snow, rain, fireflies or dust, in three depths. The wind and the bass blow them along."
        case .anSparkles: "Twinkling star glints, soft bokeh circles or a drifting light leak. The treble and hats make them sparkle."
        case .anSpeedLines: "Manga speed lines: focus lines closing in on the middle, or streaks rushing by. Redrawn every few frames; kicks and loudness push them in."
        case .anBurst: "A burst on the kicks and snares: a white starburst, a shockwave ring or cracks running across the screen."
        case .anAura: "A flaming aura around the middle (where a figure stands): banded cel flames or lightning that flare with the loudness and kicks."
        case .anSlash: "Sword slashes on the hits: a clean white cut, a curling water arc, a flame arc or a thunder streak."
        case .anWings: "Glowing wings of light branching out to both sides, a cross-shaped blast or a halo. They swell with the bass and flare on kicks."
        case .anPlanet: "A planet's curved horizon from orbit, a painted nebula or a ringed planet."
        case .anShip: "A spaceship of our own design flying across the sky, its engines flaring with the loudness."
        case .anTitle: "Japanese titles, one line at a time (Text: lines separated by /): a vertical column stamped in character by character, a title card wiping in, a news ticker, or one giant character behind everything that changes on every beat. A new line comes in on the beat; with more Music sooner, and the kicks punch it."
        case .anFigure: "A silhouette with a rim light: figures whose coats, hair, sleeves and scarves blow in the wind (it gusts with the bass), a giant robot whose eyes light up on the kicks, a swordsman whose blade glints on the beat, a cat whose tail swishes, a wind-bent tree or a shrine gate."
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
        // anime library
        case .anSky: 0
        case .anClouds: 1
        case .anSun: 2
        case .anRays: 3
        case .anStars: 4
        case .anMountains: 5
        case .anMeadow: 6
        case .anTrees: 7
        case .anWater: 8
        case .anTown: 9
        case .anParticles: 10
        case .anSparkles: 11
        case .anSpeedLines: 12
        case .anBurst: 13
        case .anAura: 14
        case .anSlash: 15
        case .anWings: 16
        case .anPlanet: 17
        case .anShip: 18
        case .anFigure: 19
        case .anTitle: 20
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
    /// Anime: distance for the camera's parallax (see DCKind.defaultDepth).
    var depth = 1.0

    init(_ kind: DCKind, style: Int = 0, speed: Double = 1, x: Double = 0, y: Double = 0, scale: Double = 1,
         rotation: Double = 0, opacity: Double = 1, react: Double = 0.5, hue: Double = 0, depth: Double? = nil) {
        self.kind = kind; self.style = style; self.speed = speed; self.x = x; self.y = y; self.scale = scale
        self.rotation = rotation; self.opacity = opacity; self.react = react; self.hue = hue
        self.depth = depth ?? kind.defaultDepth
        if kind == .anTitle { text = AnimeTitles.defaultText }
    }

    /// Tolerant decoding: fields added later never break saved stacks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DCLayer(.sky)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decodeIfPresent(DCKind.self, forKey: .kind)) ?? .sky
        style = (try? c.decodeIfPresent(Int.self, forKey: .style)) ?? 0
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? true
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? (kind == .anTitle ? AnimeTitles.defaultText : Self.defaultText)
        func num(_ k: CodingKeys, _ def: Double) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? def }
        speed = num(.speed, d.speed); x = num(.x, d.x); y = num(.y, d.y); scale = num(.scale, d.scale)
        rotation = num(.rotation, d.rotation); opacity = num(.opacity, d.opacity); react = num(.react, d.react)
        hue = num(.hue, d.hue)
        depth = num(.depth, kind.defaultDepth)
        style = min(max(0, style), kind.styles.count - 1)
    }

    /// Same settings, new identity (duplicating, loading a scene).
    func copy() -> DCLayer { var l = self; l.id = UUID(); return l }
}

/// Ready-made stacks (the Layers group's Presets menu), each on its console. Bottom layer first.
struct DCScene: Identifiable {
    let name: String
    /// Dreamcast scenes switch to their console; Anime scenes have none.
    var console: DCConsole? = nil
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

    /// Anime mode's ready-made stacks (our own scenes in the genre's styles; no show's characters or designs).
    static let anime: [DCScene] = [
        DCScene(name: "Summer meadow", layers: [
            DCLayer(.anSky, style: 0),
            DCLayer(.anClouds, style: 0, speed: 0.6, y: 0.2),
            DCLayer(.anMountains, style: 0, y: 0.04),
            DCLayer(.anTrees, style: 0, y: 0.02, scale: 0.8),
            DCLayer(.anMeadow, style: 0, y: 0.04),
            DCLayer(.anParticles, style: 5, speed: 0.6, opacity: 0.8, react: 0.4),
            DCLayer(.anSparkles, style: 0, opacity: 0.6, react: 0.7),
        ]),
        DCScene(name: "Cherry evening", layers: [
            DCLayer(.anSky, style: 1),
            DCLayer(.anSun, style: 0, x: 0.45, y: 0.18, scale: 0.9),
            DCLayer(.anClouds, style: 1, speed: 0.4, y: 0.42, opacity: 0.9),
            DCLayer(.anRays, style: 1, x: 0.45, y: 0.18, opacity: 0.4),
            DCLayer(.anTown, style: 0, speed: 0.6),
            DCLayer(.anParticles, style: 0, react: 0.6),
        ]),
        DCScene(name: "Cursed energy", layers: [
            DCLayer(.anSky, style: 5),
            DCLayer(.anRays, style: 0, opacity: 0.4),
            DCLayer(.anAura, style: 0, y: -0.25, react: 0.8),
            DCLayer(.anFigure, style: 0, y: -0.25),
            DCLayer(.anSpeedLines, style: 0, opacity: 0.9, react: 0.8),
            DCLayer(.anSlash, style: 0, react: 0.8),
            DCLayer(.anBurst, style: 2, react: 0.8),
        ]),
        DCScene(name: "Water breath", layers: [
            DCLayer(.anSky, style: 4),
            DCLayer(.anSun, style: 2, x: -0.5, y: 0.45, scale: 0.8),
            DCLayer(.anStars, style: 0, opacity: 0.8),
            DCLayer(.anTrees, style: 2, y: -0.2, scale: 1.2),
            DCLayer(.anParticles, style: 4, react: 0.6),
            DCLayer(.anSlash, style: 1, react: 0.8),
            DCLayer(.anSpeedLines, style: 1, opacity: 0.6, react: 0.9),
        ]),
        DCScene(name: "Red sun", layers: [
            DCLayer(.anSky, style: 5),
            DCLayer(.anSun, style: 1, y: 0.15, scale: 1.2),
            DCLayer(.anClouds, style: 2, speed: 0.5, y: 0.05, opacity: 0.5),
            DCLayer(.anFigure, style: 1, y: -0.75, scale: 1.4),
            DCLayer(.anParticles, style: 5, opacity: 0.7),
            DCLayer(.anBurst, style: 1, react: 0.7, hue: 0.0),
        ]),
        DCScene(name: "Shrine dusk", layers: [
            DCLayer(.anSky, style: 2),
            DCLayer(.anSun, style: 1, x: -0.35, y: 0.12, scale: 0.6),
            DCLayer(.anMountains, style: 3, y: 0.02),
            DCLayer(.anFigure, style: 9, y: -0.42, scale: 1.1),
            DCLayer(.anParticles, style: 0, speed: 0.7, react: 0.6),
            DCLayer(.anTitle, style: 0, x: 0.78, y: 0.12, react: 0.6),
        ]),
        DCScene(name: "City pop", layers: [
            DCLayer(.anSky, style: 4),
            DCLayer(.anStars, style: 0, opacity: 0.7),
            DCLayer(.anTown, style: 2, speed: 0.4, y: 0.02),
            DCLayer(.anSparkles, style: 1, opacity: 0.8, react: 0.7),
            DCLayer(.anFigure, style: 6, x: 0.3, y: -0.3),
            DCLayer(.anTitle, style: 2, y: -0.82, react: 0.6),
        ]),
        DCScene(name: "Rainy wires", layers: [
            DCLayer(.anSky, style: 6),
            DCLayer(.anTown, style: 2, speed: 0.3, y: 0.02),
            DCLayer(.anTown, style: 1, speed: 0.8),
            DCLayer(.anParticles, style: 3, react: 0.6),
        ]),
        DCScene(name: "Shallows", layers: [
            DCLayer(.anWater, style: 1),
            DCLayer(.anRays, style: 2, opacity: 0.3),
            DCLayer(.anSparkles, style: 0, opacity: 0.8, react: 0.8),
            DCLayer(.anParticles, style: 0, speed: 0.4, opacity: 0.8),
        ]),
        DCScene(name: "Sea breeze", layers: [
            DCLayer(.anSky, style: 0),
            DCLayer(.anClouds, style: 0, speed: 0.5, y: 0.15),
            DCLayer(.anWater, style: 0),
            DCLayer(.anFigure, style: 2, x: 0.55, y: -0.1),
            DCLayer(.anSparkles, style: 2, opacity: 0.7),
        ]),
    ]

    static var defaultAnimeLayers: [DCLayer] { anime[0].layers.map { $0.copy() } }

    /// The ready-made stacks of a mode.
    static func of(_ mode: VizMode) -> [DCScene] { mode == .anime ? anime : all }
}
