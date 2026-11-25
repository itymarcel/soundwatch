import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Compact native settings panel.
struct SettingsPanel: View {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState

    private var mode: VizMode { store.v.mode }

    var body: some View {
        // A plain scroll view (not a grouped Form): lighter to scroll, and groups can really shrink when they fold
        // (Form rows keep a minimum height, so content could only fade, not collapse).
        ScrollView {
            PixelStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Settings").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { app.settingsDetached.toggle() } label: {
                    Image(systemName: app.settingsDetached ? "sidebar.right" : "macwindow.on.rectangle")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(app.settingsDetached ? "Put the settings back into the main window's sidebar"
                                           : "Detach: show the settings in a window of their own")
            }
            .padding(.leading, 6).padding(.trailing, 4)

            FoldSection("Always overwrite", icon: "pin") {
                Toggle("Overwrite the background", isOn: $store.v.owOn)
                    .help("While this is on, the background colour and opacity below are used whatever preset or look is loaded. Presets keep their own background; turn this off to see it again.")
                Group {
                    ColorPicker("Background", selection: rgbBinding(\.owRed, \.owGreen, \.owBlue), supportsOpacity: false)
                    SliderRow("Opacity", $store.v.owOpacity, 0...1, "%.2f")
                }
                .disabled(!store.v.owOn).opacity(store.v.owOn ? 1 : 0.4)
            }

            PresetSection(store: store, app: app)

            FoldSection("Mode", icon: "square.grid.2x2") {
                ModePicker(mode: $store.v.mode, app: app)
                if mode == .sphere {
                    Picker("Layout", selection: $store.v.sphereLayout) {
                        ForEach(SphereLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                } else if mode == .oscilloscope {
                    Picker("Shape", selection: $store.v.scopeShape) {
                        ForEach(ScopeShape.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                }
                if mode.uses(.style) {
                    Picker("Style", selection: $store.v.style) {
                        ForEach(DrawStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if mode.usesLook {
                    Picker("Render", selection: $store.v.look) {
                        ForEach(SurfaceLook.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Lines: wireframe outlines. Chrome: mirror-polished metal reflecting a studio. Fresnel: glassy, glowing rims.")
                }
                if mode == .orbs || mode == .ferro || mode == .metaballs || mode == .infinity || (mode.usesLook && store.v.look == .chrome) {
                    SliderRow("Tint", $store.v.chromeTint, 0...1, "%.2f").node("chromeTint")
                        .help("0 = pure silver chrome; higher tints the chrome with the palette colours.")
                    Picker("Reflects", selection: $store.v.chromeEnv) {
                        ForEach(ChromeEnvironment.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)
                    .help("What the chrome reflects (HDR photos): a white studio with neon tubes, a warm wooden studio with coloured lights, a sky at moonrise, or a starry night over the hills.")
                    SliderRow("Turn", $store.v.chromeTurn, 0...1, "%.2f").node("chromeTurn")
                        .help("Turns the environment around, so different lights and colours land on the chrome. Wire it to an LFO in Nodes for slowly moving reflections.")
                    SliderRow("Blur", $store.v.chromeBlur, 0...1, "%.2f").node("chromeBlur")
                        .help("0 = sharp mirror; higher = softer, blurrier satin-metal reflections (slightly grainy).")
                }
                if mode == .forest {
                    Picker("Scene", selection: $store.v.landScene) {
                        ForEach(LandscapeScene.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)
                    .help("Which landscape you fly through: a forest river valley by day, or a city at night.")
                }
                if mode != .dreamcast { detailRow }   // Dreamcast: below its Console picker
                if mode == .field {
                    SliderRow("Springiness", $store.v.fieldSpring, 0...1, "%.2f").node("fieldSpring")
                        .help("How strongly particles are pulled back to their home spot. Low = slow, lazy return; high = snappy.")
                }
                if mode == .membrane {
                    SliderRow("Tint", $store.v.membraneTint, 0...1, "%.2f").node("membraneTint")
                        .help("0 = plain grey rubber; higher tints the sheet with the palette (by height).")
                    SliderRow("Relief", $store.v.membraneRelief, 0...1, "%.2f").node("membraneRelief")
                        .help("Pushes the media layer's picture up through the sheet (bright = high). Needs a media file; set its Blend to Hidden to see only the relief, and add Media blur for smooth shapes.")
                }
                if mode == .diamond {
                    SliderRow("Facets", Binding(get: { store.v.diamondFacets }, set: { store.v.diamondFacets = $0.rounded() }), 5...50, "%.0f").node("diamondFacets")
                        .help("How many facets the stone has: from a chunky crystal (5) to a near-brilliant cut (50).")
                    SliderRow("Movement", $store.v.diamondMove, 0...1, "%.2f").node("diamondMove")
                        .help("How much the music reshapes the stone. Each side follows its own frequency band: it tilts and pushes out or sinks in; bass stretches the stone taller and nudges it off-centre, treble makes it wider; it also slowly turns and tumbles. 0 = a perfect, still stone.")
                    SliderRow("Rainbow", $store.v.diamondFire, 0...1, "%.2f").node("diamondFire")
                        .help("How much the light splits into rainbow colours as it passes through the stone, like a prism. 0 = only white sparkle (and about 3× cheaper to draw); higher = coloured flashes and rainbow edges on the facets.")
                }
                if mode == .orbs {
                    SliderRow("Spread", $store.v.orbPress, 0...1, "%.2f").node("orbPress")
                        .help("How far a loud band swells its orb out of the big sphere (and how much it grows). 0 = the orbs stay melted into the surface. Reach scales it too.")
                    SliderRow("Goo", $store.v.orbGoo, 0...1, "%.2f").node("orbGoo")
                        .help("How much the orbs melt into the sphere and into each other, like metaballs. 0 = separate balls; higher = thick, gooey necks.")
                }
                if mode == .ferro {
                    SliderRow("Magnet", $store.v.ferroSpikes, 0...1, "%.2f").node("ferroSpikes")
                        .help("How strong the electromagnet gets on the bass. Spikes only appear past the critical field, first over the middle of the magnet and spreading outward as it gets stronger; 0 = the fluid only gathers into a smooth mound.")
                    SliderRow("Splash", $store.v.ferroSplash, 0...1, "%.2f").node("ferroSplash")
                        .help("How hard drum hits jolt the surface (ripples and splashes). 0 = only the magnet moves it.")
                }
                if mode == .metaballs {
                    SliderRow("Magnet", $store.v.mbMagnet, 1...2, "%.2f").node("mbMagnet")
                        .help("The dial on the device: how hard the music drives the electromagnets. Low = the fluid only leans towards them; high = it is torn into arms that pinch off.")
                    SliderRow("Magnets", Binding(get: { max(3, store.v.mbMagnets) }, set: { store.v.mbMagnets = $0.rounded() }), 3...Double(MetaballsViz.maxCoils), "%.0f").node("mbMagnets")
                        .help("How many electromagnets sit around the glass sphere, spread evenly over a sphere of their own. They split 30 Hz – 17 kHz between them, in a shuffled order around the sphere, so they pull at different moments and from different sides and tear the fluid between them.")
                    SliderRow("Hold", $store.v.mbHold, 0...1, "%.2f").node("mbHold")
                        .help("How long the magnets hold their strength before following the music again. Hits always switch them at once, so the fluid snaps into a new arrangement and stays there. 0 = the coils follow every change of the music.")
                    SliderRow("Centre pull", $store.v.mbHome, 0.25...0.75, "%.2f").node("mbHome")
                        .help("How strongly the fluid wants to float back to the middle of the glass. Without it the magnets drag it out onto the glass and it stays there; high = it only reaches out with arms and snaps back.")
                    SliderRow("Burst strength", $store.v.mbBurstAmt, 0...2, "%.2f").node("mbBurstAmt")
                        .help("How hard a burst blows the liquid apart and yanks it towards its magnet. It scales with how big the hit is in the music, so harder hits still burst harder. 0 = no bursts.")
                    SliderRow("Burst threshold", $store.v.mbBurstThr, 0...1, "%.2f").node("mbBurstThr")
                        .help("How sudden a hit in a magnet's part of the spectrum must be to set off a burst. Low = most hits burst (and they can come quicker after each other); high = only the hardest hits.")
                    SliderRow("Coil lag", $store.v.mbLag, 5...200, "%.0f ms").node("mbLag")
                        .help("The coil's time constant L/R: how long its current takes to follow the music. Short = twitchy, every hit snaps the fluid; long = smooth, swelling motion.")
                }
                if mode == .infinity {
                    Picker("Structure", selection: $store.v.infStructure) {
                        ForEach(InfinityStructure.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)
                    .help("What the endless building is made of. Castle: ornate fortress walls (a Mandelbox). Vault: a solid block with chambers and coffers carved into it. Bubbles: round shells nested inside each other, smooth and curvy. City: endless streets of towers below you and an upside-down city above; every tower rises with its own frequency band (Morph). Fold reshapes each of them.")
                    SliderRow("Fold", $store.v.infFold, 0...1, "%.2f").node("infFold")
                        .help("Reshapes the structure. Castle: big open monuments … dense shattered machinery. Vault: how deep it is carved. Bubbles: how far the bubbles swell into each other. City: low town … skyscrapers.")
                    SliderRow("Depth", Binding(get: { store.v.infCastleDetail }, set: { store.v.infCastleDetail = $0.rounded() }), 5...14, "%.0f")
                        .help("How many times the fractal folds into itself: more = finer detail (and more work for the GPU).")
                    SliderRow("Morph", $store.v.infMorph, 0...1, "%.2f").node("infMorph")
                        .help("How far a kick pushes the fold of the structure before it eases back. City: also how far every tower rises with its band. 0 = a fixed building.")
                    Picker("Pattern", selection: $store.v.infPattern) {
                        ForEach(InfinityPattern.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)
                    .help("What is drawn on the walls, each part lighting up with its own frequency band. Seams: coloured bands with bright seams. Contours: fine contour lines on dark stone. Circuit: thin traces like a circuit board. Blocks: flat colour per fold depth, glowing as a whole. Plain: nothing, just the material.")
                    Picker("Surface", selection: $store.v.infSurface) {
                        ForEach(InfinitySurface.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)
                    .help("What the castle is made of. Solid: matte stone. Reflective: polished, mirroring the rest of the castle and the environment (Reflects / Turn / Blur / Tint above). Glass: see-through, up to three walls deep. Milky glass: frosted and cloudy, thick parts turn opaque.")
                    Toggle("Speakers", isOn: $store.v.infSpeakers)
                        .help("Scatters loudspeaker cones over the walls. Each one listens to its own frequency band and pumps in and out with it.")
                }
                if mode == .forest && store.v.landScene == .city {
                    SliderRow("Camera height", $store.v.cityAlt, 0...1, "%.2f").node("cityAlt")
                        .help("How high the camera flies: 0 = at street level between the cars, ~0.3 = in the canyons between the towers, 1 = high over the rooftops.")
                    SliderRow("Music drive", $store.v.cityDrive, 0...1, "%.2f").node("cityDrive")
                        .help("How much the music moves the camera: louder music flies faster, the bass pushes (with Reach), kicks shove it forward. Only the speed changes, not the height or the view. 0 = a steady flight at the Motion speed.")
                    SliderRow("Architecture", $store.v.cityArch, 0...1, "%.2f").node("cityArch")
                        .help("How much architectural detail the buildings get: cornices, pilasters, balconies, fire escapes, AC units, corner stones, rusticated bases, floodlit facades, glass fins, rooftop penthouses and water tanks. Higher = more buildings have more of them. 0 = plain facades.")
                    SliderRow("Gloom", $store.v.cityGloom, 0...1, "%.2f").node("cityGloom")
                        .help("How gloomy the night is: thick haze glowing with the city's light, low clouds, muted colours, fewer lit windows and soft light bouncing between the buildings. 0 = a clear night.")
                    SliderRow("Haze", $store.v.forMist, 0...1, "%.2f").node("forMist")
                        .help("How thick the night haze is: the city fades into it and every light gets a halo.")
                    SliderRow("Band light", $store.v.forGlow, 0...1, "%.2f").node("forGlow")
                        .help("Every tower listens to its own frequency band: its lit windows climb up the facade like a level meter.")
                    SliderRow("Light drones", $store.v.cityLights, 0...1, "%.2f").node("cityLights")
                        .help("Coloured lights flying through the streets, each with its own band. They light the facades and throw moving shadows of the buildings. 0 = none.")
                    SliderRow("Fly-bys", $store.v.cityFlyby, 0...1, "%.2f").node("cityFlyby")
                        .help("How often a light shoots past close to the camera: across the street ahead, overtaking you or coming head-on. Hard hits bring the next one sooner. 0 = never.")
                    SliderRow("Kick pulses", $store.v.cityPulse, 0...1, "%.2f").node("cityPulse")
                        .help("Rings of light that kicks send running out along the streets from a crossing ahead. 0 = off.")
                    SliderRow("Searchlights", $store.v.cityBeams, 0...1, "%.2f").node("cityBeams")
                        .help("Beams from the rooftops sweeping the haze; every beat swings them somewhere new. 0 = none.")
                    SliderRow("Traffic", $store.v.cityTraffic, 0...1, "%.2f").node("cityTraffic")
                        .help("Head and tail lights in the streets. The mids make the traffic faster.")
                    SliderRow("Wet streets", $store.v.cityWet, 0...1, "%.2f").node("cityWet")
                        .help("How wet the streets are: they mirror the towers, lights and drones. The treble makes the puddles glitter.")
                    SliderRow("Window reflections", $store.v.cityReflect, 0...1, "%.2f").node("cityReflect")
                        .help("How much the window glass mirrors the city: the towers across the street, lights, drones and traffic. Every pane is set slightly differently, so the mirror image breaks up like real glass. 0 = only a faint sky sheen.")
                    SliderRow("Reflection blur", $store.v.cityReflBlur, 0...1, "%.2f").node("cityReflBlur")
                        .help("How blurry the mirror image in the windows is: 0 = sharp polished glass, 1 = soft, frosted reflections where only the lights stay recognisable.")
                    SliderRow("Storm", $store.v.cityStorm, 0...1, "%.2f").node("cityStorm")
                        .help("Lightning on hard snare hits: a flash throws hard shadows of every tower across the city. Higher = more often. 0 = no storm.")
                    SliderRow("Palette tint", $store.v.forTint, 0...1, "%.2f")
                        .help("How much the colour palette tints the windows, street lamps and haze. The drones and neon always use the palette.")
                }
                if mode == .forest && store.v.landScene == .forest {
                    SliderRow("Sun", $store.v.forSun, 0...1, "%.2f").node("forSun")
                        .help("Time of day: 0 = sunrise (low light from the side), 0.5 = noon, 1 = sunset (flying into the low sun).")
                    SliderRow("Day / night", $store.v.forNight, 0...1, "%.2f").node("forNight")
                        .help("0 = day, 1 = night: moonlight, a dark blue sky with stars and fireflies over the meadows and the river. In between: dusk.")
                    SliderRow("Fireflies", $store.v.forFireflies, 0...1, "%.2f").node("forFireflies")
                        .help("How many fireflies fly at night (they only come out as it gets dark). The music moves them: louder = livelier, hits make some of them flash, the bass lifts them. 0 = none.")
                    SliderRow("Season", $store.v.forSeason, 0...1, label: { forestSeasonLabel(store.v.forSeason) }).node("forSeason")
                        .help("The day of the year, 1 Jan … 31 Dec. Winter: snow on the ground and the trees, bare broadleaf trees, an icy river and a low sun. Spring: blossom, falling petals, fresh green and flowers in the meadows. Summer: full green. Autumn: the leaves turn yellow, orange and red and the gusts blow them off.")
                    SliderRow("Weather", $store.v.forWeather, 0...1, "%.2f").node("forWeather")
                        .help("Rain, or snowfall when the season is cold enough: overcast sky, rings on the river, wet ground. Louder music makes it pour. 0 = dry.")
                    SliderRow("Mist", $store.v.forMist, 0...1, "%.2f").node("forMist")
                        .help("How thick the haze in the valleys is: distant hills fade into it.")
                    SliderRow("Clouds", $store.v.forClouds, 0...1, "%.2f")
                    SliderRow("Wind", $store.v.forWind, 0...2, "%.2f").node("forWind")
                        .help("How hard the music shakes the forest: bass gusts roll across the treetops, the treble makes the leaves flutter and the river ripple. 0 = still.")
                    SliderRow("Band light", $store.v.forGlow, 0...1, "%.2f").node("forGlow")
                        .help("Every tree listens to its own frequency band and lights up with it.")
                    SliderRow("Birds", $store.v.forBirds, 0...1, "%.2f").node("forBirds")
                        .help("Flocks of birds fly up from the trees: a hard hit in the music sets one off, and a hit while they fly makes the flock swerve. Higher = more often and bigger flocks. 0 = no birds.")
                    SliderRow("Palette tint", $store.v.forTint, 0...1, "%.2f")
                        .help("How much the colour palette tints the sunlight, sky and mist. 0 = natural colours.")
                }
                if mode == .imageParticles {
                    ImageParticleControls(store: store)
                }
                if mode == .glass {
                    SliderRow("Softness", $store.v.glassSoft, 0...1, "%.2f").node("glassSoft")
                        .help("Depth of field: rings far in front of or behind the middle go soft.")
                }
                if mode == .dreamcast {
                    Picker("Console", selection: Binding(get: { store.v.dcConsole },
                                                         set: { store.v.dcConsole = $0; store.v.dcRes = $0.lines })) {
                        ForEach(DCConsole.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)
                    .help("Whose screen it imitates: its colours, pixel shape and (set when picked) its resolution. " + store.v.dcConsole.help)
                    detailRow
                    SliderRow("CRT style", $store.v.dcCRT, 0...1, "%.2f").node("dcCRT")
                        .help("How much it looks like an old tube TV: scanlines (when a console line is a few screen pixels tall), soft glowing pixels, the RGB stripes of the screen, a darker edge and a little noise. 0 = crisp square pixels.")
                    SliderRow("Warp", $store.v.dcWarp, 0...1, "%.2f").node("dcWarp")
                        .help("How much the screen bulges like curved glass, with rounded corners. 0 = flat.")
                }
            }

            if mode == .dreamcast {
                DreamcastLayersSection(store: store, app: app)
            }

            FoldSection("Camera", icon: "camera.aperture") {
                SliderRow("DOF", $store.v.dofAmount, 0...1, "%.2f").node("dofAmount")
                    .help("Depth of field. Shallow focus: the middle of the picture stays sharp, the rest blurs more and more towards the edges, and bright points open into bokeh shapes.")
                Group {
                    Picker("Focus", selection: $store.v.dofFocusMode) {
                        ForEach(DofFocusMode.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)
                    .help(store.v.dofFocusMode.help)
                    if store.v.dofFocusMode == .depth {
                        SliderRow("Distance", $store.v.dofFocus, 0...1) { focusLabel(store.v.dofFocus) }.node("dofFocus")
                            .help("Focus distance: left = right at the camera, middle = the subject, right = infinity. Things nearer or farther blur more the further they are from it.")
                    }
                    SliderRow("Range", $store.v.dofRange, 0...1, "%.2f").node("dofRange")
                        .help(store.v.dofFocusMode == .depth
                              ? "How deep the sharp zone is: everything this close to the focus distance stays sharp, the blur starts beyond it. 0 = only the focus distance itself is sharp."
                              : "How big the sharp area in the middle is. 0 = only a small spot in the centre stays sharp; higher keeps more of the picture sharp, the blur starts closer to the edges.")
                    Picker("Bokeh", selection: $store.v.dofBokeh) {
                        ForEach(BokehShape.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)
                    .help(store.v.dofBokeh.help)
                    SliderRow("Blur noise", $store.v.dofNoise, 0...1, "%.2f").node("dofNoise")
                        .help("Grain in the blur: invisible where the picture is sharp, stronger the blurrier it gets.")
                }
                .disabled(store.v.dofAmount <= 0)
                if mode == .forest {
                    Toggle("Global illumination", isOn: $store.v.landGI)
                        .help("Landscape only: light bounces between surfaces, computed every frame. Sky light is blocked under the canopy and between the towers, sunlit meadows and lit windows throw coloured light onto their surroundings, glowing trees (Band light) and fireflies light up what's around them. Costs GPU time.")
                    SliderRow("GI intensity", $store.v.landGIAmount, 0...3, "%.2f").node("landGIAmount")
                        .help("How strong the bounced light and sky light are: 1 = natural, below = darker shadows, above = more glow from everything lit.")
                        .disabled(!store.v.landGI)
                }
            }

            FoldSection("Shape & motion", icon: "move.3d") {
                SliderRow("Size", $store.v.size, 0.2...4, "%.2f").node("size").knob(.size, mode)
                SliderRow("Glow", $store.v.glow, 0...1, "%.2f").node("glow").knob(.glow, mode)
                SliderRow("Trails", $store.v.persistence, 0...1, "%.2f").node("persistence").knob(.persistence, mode)
                SliderRow("Motion", $store.v.motion, 0...2, "%.2f").node("motion").knob(.motion, mode)
                SliderRow("Zoom", $store.v.zoom, 0.3...2.5, "%.2f×").node("zoom").knob(.zoom, mode)
                SliderRow("Reach", $store.v.reach, 0...4, "%.2f×").node("reach").knob(.reach, mode)
                    .help("How far things travel: sphere bulge, spoke length, particle steps, trace height.")
                HStack {
                    Toggle("Stereo", isOn: $store.v.stereo).knob(.stereo, mode)
                    Toggle("Mirror", isOn: $store.v.mirror).knob(.mirror, mode)
                    Toggle("Segmented", isOn: $store.v.segmented).knob(.segmented, mode)
                }
            }

            FoldSection("Response", icon: "waveform") {
                InputPicker(store: store)
                Picker("FFT size", selection: $store.v.fftSize) {
                    ForEach([2048.0, 4096, 8192, 16384, 32768], id: \.self) { Text("\(Int($0))").tag($0) }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                .help("Bigger = finer frequency detail (good for huge point counts), slower response. Waveform modes don't use the FFT.")
                .knob(.fft, mode)
                Toggle("Low latency", isOn: $store.v.lowLatency)
                    .knob(.fft, mode)
                    .disabled(!mode.supportsLowLatency)
                    .help(mode.supportsLowLatency
                          ? "Above ~200 Hz use short FFTs, so drums and vocals react within ~20 ms. The FFT size then only sets the bass detail."
                          : "Not used here: this mode's look depends on the full FFT's fine frequency detail.")
                SliderRow("A/V sync", Binding(get: { store.v.avSync }, set: { store.v.avSync = $0.rounded() }), -30...200) { store.v.avSync == 0 ? "auto" : String(format: "%+.0f ms", store.v.avSync) }
                    .help("Lines the picture up with what you hear. soundwatch already matches the speakers' reported delay; if hits still look early, move right (picture later), if late, move left. Bluetooth, AirPlay and TV/monitor speakers often report too little delay and need +50…+200 ms. Left of about −10 ms does nothing more: the picture can't show sound that hasn't arrived yet.")
                SliderRow("Gain", $store.v.gain, 0.2...5, "%.2f×").node("gain").knob(.gain, mode)
                SliderRow("Floor", $store.v.floorDB, -120...(-30), "%.0f dB").node("floorDB").knob(.floor, mode)
                SliderRow("Tilt", $store.v.tilt, 0...6, "%.1f dB").node("tilt").knob(.tilt, mode)
                SliderRow("Smoothing", $store.v.smoothing, 0...0.97) { Self.fallLabel(store.v.smoothing) }.node("smoothing")
                    .knob(.smoothing, mode)
                    .help("How slowly levels fall back after a hit. Rises are always instant.")
                SliderRow("Low freq", logBinding(\.minFreq), log10(20)...log10(1000)) { hz(store.v.minFreq) }.node("minFreq")
                    .knob(.freqRange, mode)
                SliderRow("High freq", logBinding(\.maxFreq), log10(1500)...log10(22000)) { hz(store.v.maxFreq) }.node("maxFreq")
                    .knob(.freqRange, mode)
            }

            FoldSection("Colour", icon: "paintpalette") {
                Picker("Palette", selection: Binding(get: { store.v.palette },
                                                     set: { store.v.palette = $0 })) {
                    ForEach(PaletteKind.allCases) { p in
                        HStack { PaletteSwatch(palette: p.palette); Text(p.title) }.tag(p)
                    }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                Picker("Colour by", selection: $store.v.colorBy) {
                    ForEach(ColorBy.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .knob(.colorBy, mode)
                SliderRow("Offset", $store.v.hueShift, 0...2, "%.2f").node("hueShift")
                SliderRow("Cycling", $store.v.colorCycle, 0...2, "%.2f").node("colorCycle")
            }

            FoldSection("Feedback & beat", icon: "metronome") {
                Picker("Warp", selection: $store.v.warpStyle) {
                    ForEach(WarpStyle.allCases) { Text($0.title).tag($0) }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                .knob(.persistence, mode)
                SliderRow("Warp amt", $store.v.warp, 0...1, "%.2f").node("warp").knob(.persistence, mode)
                SliderRow("Beat", $store.v.beat, 0...1.5, "%.2f").node("beat")
                Toggle("Lock to tempo", isOn: $store.v.beatLock)
                    .help("Finds the song's tempo and fires Beat exactly on the beat, even predicting it, and keeps the pulse steady through fills and syncopation. Falls back to plain bass hits when there's no steady beat (ambient, intros) or while it's still listening (~5 s). Off = always bass hits.")
            }

            MediaSection(store: store, app: app)

            FoldSection("Distortion", icon: "water.waves") {
                Picker("Style", selection: $store.v.distort) {
                    ForEach(DistortStyle.allCases) { Text($0.title).tag($0) }
                }
                .controlSize(.small)
                .help(store.v.distort.help)
                Group {
                    SliderRow("Amount", $store.v.distortAmt, 0...1, "%.2f").node("distortAmt")
                        .help("How strongly the picture is bent. The beat gives it a push.")
                    SliderRow("Scale", $store.v.distortScale, 0.25...4, "%.2f").node("distortScale")
                        .help("Size of the waves, drops, cells or swirls: higher = bigger.")
                    SliderRow("Speed", $store.v.distortSpeed, 0...3, "%.2f").node("distortSpeed")
                        .help("How fast it moves (0 = frozen). The bass speeds it up on top.")
                }
                .disabled(store.v.distort == .none)
            }

            FoldSection("Post-processing", icon: "camera.filters") {
                SliderRow("Brightness", $store.v.brightness, -1...1, "%+.2f").node("brightness")
                SliderRow("Contrast", $store.v.contrast, 0.2...2, "%.2f").node("contrast")
                SliderRow("Saturation", $store.v.saturation, 0...2, "%.2f").node("saturation")
                SliderRow("Hue", $store.v.hueRotate, 0...1, "%.2f").node("hueRotate")
                    .help("Rotates every colour around the colour wheel (applied after everything else).")
                SliderRow("Aberration", $store.v.aberration, 0...1, "%.2f").node("aberration")
                    .help("Chromatic aberration: red and blue drift apart towards the edges, like a cheap lens.")
                SliderRow("Pixelate", $store.v.pixelate, 0...1, "%.2f").node("pixelate")
                SliderRow("Posterize", $store.v.posterize, 0...1, "%.2f").node("posterize")
                    .help("Fewer colour levels: banded, print-like colours.")
                SliderRow("Invert", $store.v.invert, 0...1, "%.2f").node("invert")
                SliderRow("Soft focus", $store.v.softFocus, 0...1, "%.2f").node("softFocus")
                    .help("Mixes in a wide blur of the image: dreamy, out-of-focus glow. Unlike Glow it softens shapes, not just brightens them.")
                SliderRow("Streak", $store.v.streak, 0...1, "%.2f").node("streak")
                    .help("Bright parts smear into long vertical light streaks, like an anamorphic lens.")
                SliderRow("Fringe", $store.v.fringe, 0...1, "%.2f").node("fringe")
                    .help("Rainbow colour fringes along edges (green/yellow on one side, red/blue on the other), like light through glass.")
                SliderRow("Film grain", $store.v.filmGrain, 0...1, "%.2f").node("filmGrain")
                    .help("Fine photographic grain; shows on dark, bright and grey areas alike.")
                SliderRow("Grain size", $store.v.grainSize, 0.5...6, "%.1f").node("grainSize")
                    .disabled(store.v.filmGrain <= 0)
                    .help("1 = about a pixel. Higher = coarser, clumpier grain, like faster film.")
                SliderRow("Scanlines", $store.v.scanlines, 0...1, "%.2f").node("scanlines")
                    .disabled(mode == .dreamcast).opacity(mode == .dreamcast ? 0.4 : 1)
                    .help(mode == .dreamcast ? "Not used in Dreamcast: its CRT style (in Mode) draws scanlines at the console resolution." : "")
                SliderRow("Vignette", $store.v.vignette, 0...1, "%.2f").node("vignette")
                SliderRow("Flicker", $store.v.flicker, 0...1, "%.2f").node("flicker")
                    .help("CRT flicker and a slow rolling refresh band.")
                Button("Reset post-processing") {
                    let d = VizSettings()
                    store.v.brightness = d.brightness; store.v.contrast = d.contrast; store.v.saturation = d.saturation
                    store.v.hueRotate = d.hueRotate; store.v.aberration = d.aberration; store.v.pixelate = d.pixelate
                    store.v.posterize = d.posterize; store.v.invert = d.invert
                    store.v.softFocus = d.softFocus; store.v.streak = d.streak; store.v.fringe = d.fringe
                    store.v.filmGrain = d.filmGrain; store.v.grainSize = d.grainSize
                    store.v.scanlines = d.scanlines; store.v.vignette = d.vignette; store.v.flicker = d.flicker
                }
            }

            FoldSection("Window", icon: "macwindow") {
                Group {
                    ColorPicker("Background", selection: rgbBinding(\.bgRed, \.bgGreen, \.bgBlue), supportsOpacity: false)
                    SliderRow("Opacity", $store.v.bgOpacity, 0...1, "%.2f")
                }
                .disabled(store.v.owOn).opacity(store.v.owOn ? 0.4 : 1)
                .help(store.v.owOn ? "Replaced by Always overwrite (top of the settings) while that is switched on." : "")
                Toggle("Overlay mode (exit with Esc)", isOn: $app.overlay)
                    .help("Shows only the picture, floating above all other windows: no buttons, sidebar, window controls or shadow. Lower Opacity to see through the background. Press Esc to leave (click the picture first if another app is in front). ⌘-drag moves it.")
                Toggle("Anti-aliasing", isOn: $store.v.antialias)
                    .help("Smooth edges: lines and surfaces are drawn with 4× multisampling, the raytraced modes (Glass Stack, Diamond, Orbs, Splashs, Ferrofluid) at up to 1.5× resolution when the GPU has time to spare. Turn it off for more speed on a slow Mac.")
                Toggle("Show FPS", isOn: $store.v.showFPS)
            }

            PixelStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button("Reset look") { store.resetLook() }
                    Button("Buy me a Coffee") { NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/mcut3000")!) }
                        .help("Support soundwatch: opens buymeacoffee.com/mcut3000 in your browser.")
                }
                Hint("1–8 modes · ← → presets · S settings · Space freeze · F full screen · T overlay (Esc exits) · R reset view")
            }
            .padding(.horizontal, 2).padding(.top, 8)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .scrollIndicators(.automatic)
        .background(Color(nsColor: .windowBackgroundColor))   // opaque, like the grouped Form was (the window itself is clear)
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .font(.system(size: 11))
    }

    @ViewBuilder private var detailRow: some View {
        let d = mode == .forest && store.v.landScene == .city ? VizMode.cityDetail : mode.detail
        let short = d.label.components(separatedBy: " (").first ?? d.label
        if d.isLog {
            SliderRow(short, Binding(
                get: { log10(store.v[d.keyPath]) },
                set: { store.v[d.keyPath] = Self.niceRound(pow(10, $0)) }
            ), log10(d.range.lowerBound)...log10(d.range.upperBound)) { Self.compact(store.v[d.keyPath]) }
                .node(ModParam.id(for: d.keyPath))
        } else {
            SliderRow(short, Binding(
                get: { store.v[d.keyPath] },
                set: { store.v[d.keyPath] = $0.rounded(toPlaces: d.range.upperBound > 50 ? 0 : 1) }
            ), d.range, d.format)
                .node(ModParam.id(for: d.keyPath))
        }
    }

    /// Rounds to 2 significant digits so log sliders land on clean numbers.
    static func niceRound(_ v: Double) -> Double {
        let mag = pow(10, floor(log10(max(v, 1))) - 1)
        return (v / mag).rounded() * mag
    }

    static func grouped(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: Int(v))) ?? "\(Int(v))"
    }

    static func compact(_ v: Double) -> String {
        v >= 1_000_000 ? String(format: "%.1fM", v / 1_000_000) : v >= 10_000 ? String(format: "%.0fk", v / 1000) : String(format: "%.0f", v)
    }

    private func rgbBinding(_ r: WritableKeyPath<VizSettings, Double>, _ g: WritableKeyPath<VizSettings, Double>,
                            _ b: WritableKeyPath<VizSettings, Double>) -> Binding<Color> {
        Binding(
            get: { Color(.sRGB, red: store.v[r], green: store.v[g], blue: store.v[b]) },
            set: { c in
                guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
                var v = store.s
                v[keyPath: r] = Double(ns.redComponent)
                v[keyPath: g] = Double(ns.greenComponent)
                v[keyPath: b] = Double(ns.blueComponent)
                store.s = v
            })
    }

    private func logBinding(_ kp: WritableKeyPath<VizSettings, Double>) -> Binding<Double> {
        Binding(get: { log10(store.v[kp]) }, set: { store.v[kp] = pow(10, $0).rounded() })
    }

    /// Fall time to ~10 % (2.3 time constants), e.g. "60 ms" / "1.2 s".
    static func fallLabel(_ smoothing: Double) -> String {
        let t = Envelope.fallTau(smoothing) * 2.3
        return t < 1 ? String(format: "%.0f ms", t * 1000) : String(format: "%.1f s", t)
    }

    private func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.1fk", f / 1000) : String(format: "%.0f", f)
    }
}

/// Where the sound comes from: the Mac's own output (default) or an input device such as a microphone.
private struct InputPicker: View {
    @Bindable var store: SettingsStore
    @State private var devices: [(uid: String, name: String)] = []

    var body: some View {
        Picker("Input", selection: Binding(get: { store.v.audioInput }, set: { uid in
            var v = store.s
            v.audioInput = uid
            v.audioInputName = devices.first { $0.uid == uid }?.name ?? ""
            store.s = v
        })) {
            Text("System audio").tag("")
            if !store.v.audioInput.isEmpty && !devices.contains(where: { $0.uid == store.v.audioInput }) {
                Text("\(store.v.audioInputName.isEmpty ? "Unknown input" : store.v.audioInputName) (not connected)").tag(store.v.audioInput)
            }
            Section("Inputs") {
                ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
            }
        }
        .controlSize(.small)
        .help("What soundwatch listens to. System audio = everything the Mac plays. Or pick a microphone or audio interface input to react to the room, an instrument or a turntable (macOS asks for microphone access the first time).")
        .onAppear { devices = AudioInputs.list() }
        .onReceive(NotificationCenter.default.publisher(for: AudioInputs.changed)) { _ in devices = AudioInputs.list() }
    }
}

/// One-line slider: label · slider · value.
/// The Season slider's label: 0…1 → "1.1." … "31.12.".
func forestSeasonLabel(_ v: Double) -> String {
    let day = Int((min(1, max(0, v)) * 364).rounded())
    let lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var d = day, m = 0
    while d >= lengths[m] { d -= lengths[m]; m += 1 }
    return "\(d + 1).\(m + 1)."
}

/// Focus distance as a multiple of the subject's distance (the slider is 0 … 1 = camera … infinity, ½ = the subject).
func focusLabel(_ f: Double) -> String {
    if f >= 0.995 { return "∞" }
    let d = f / (1 - f)
    return d < 10 ? String(format: "%.2f×", d) : String(format: "%.0f×", d)
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var label: (() -> String)?
    /// The node parameter this slider is (`ModParam` id): shows the workflow button that adds a node for it.
    var param: String?

    init(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String = "", label: (() -> String)? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).frame(width: 64, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture(count: 2) { resetToDefault($value) }
            Slider(value: $value, in: range).labelsHidden()
                .resetOnDoubleClick($value)
            Text(label?() ?? String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            if let param {
                NodeAddButton(param: param, title: ModParam.byID[param]?.title ?? title)
            } else {
                Color.clear.frame(width: NodeAddButton.size, height: 1)   // keeps the sliders' columns lined up
            }
        }
    }

    /// Marks the slider as a node parameter: a workflow button after the value adds a Parameter node for it.
    func node(_ id: String?) -> SliderRow {
        var c = self
        c.param = id.flatMap { ModParam.byID[$0] != nil ? $0 : nil }
        return c
    }
}

/// The small workflow icon beside a slider that can be driven by nodes: adds a Parameter node for it to the node
/// editor (opening the editor if needed). Orange while a node already drives that setting.
struct NodeAddButton: View {
    static let size: CGFloat = 13
    let param: String
    let title: String
    @State private var hover = false

    var body: some View {
        let used = SettingsStore.shared?.v.nodes.nodes.contains { $0.kind == .param && $0.target == param } ?? false
        Button { AppState.shared?.addParamNode(param) } label: {
            WorkflowIcon()
                .stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 10)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(used ? NodeCategory.output.color : Color.secondary.opacity(hover ? 1 : 0.55))
        .onHover { hover = $0 }
        .help(used ? "\(title) is driven by a node. Click to add another Parameter node for it."
                   : "Add a node for \(title) to the node editor (connect the music to it there).")
    }
}

/// Lucide's "workflow" icon (two rounded squares joined by an elbow), drawn in its 24 × 24 grid.
struct WorkflowIcon: Shape {
    func path(in r: CGRect) -> Path {
        let k = min(r.width, r.height) / 18, o = CGPoint(x: r.midX - 9 * k, y: r.midY - 9 * k)   // icon spans 3…21
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + (x - 3) * k, y: o.y + (y - 3) * k) }
        var path = Path()
        path.addRoundedRect(in: CGRect(origin: p(3, 3), size: CGSize(width: 8 * k, height: 8 * k)), cornerSize: CGSize(width: 2 * k, height: 2 * k))
        path.addRoundedRect(in: CGRect(origin: p(13, 13), size: CGSize(width: 8 * k, height: 8 * k)), cornerSize: CGSize(width: 2 * k, height: 2 * k))
        path.move(to: p(7, 11))
        path.addLine(to: p(7, 15))
        path.addQuadCurve(to: p(9, 17), control: p(7, 17))
        path.addLine(to: p(13, 17))
        return path
    }
}

/// Double-clicking a slider puts it back to its default (the value a fresh `VizSettings` has).
/// SwiftUI tap gestures don't reach an NSSlider (it tracks the mouse itself), so a small view behind the slider
/// watches for double clicks inside its frame and swallows the second click.
struct DoubleClickReset: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ v: Catcher, context: Context) { v.action = action }

    final class Catcher: NSView {
        var action: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
                guard let self, e.clickCount == 2, let w = self.window, e.window === w, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(e.locationInWindow, from: nil)) else { return e }
                self.action?()
                return nil
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

extension View {
    /// The default is looked up through the binding itself: read it once while the store holds fresh settings.
    func resetOnDoubleClick(_ value: Binding<Double>) -> some View {
        background(DoubleClickReset { resetToDefault(value) })
    }
}

/// Puts a settings-backed value back to its default (double-click on a slider or its label).
func resetToDefault(_ value: Binding<Double>) {
    guard let store = SettingsStore.shared else { return }
    let mine = store.s
    store.s = VizSettings()
    let def = value.wrappedValue
    store.s = mine
    if def != value.wrappedValue { value.wrappedValue = def }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct PaletteSwatch: View {
    let palette: Palette
    var width: CGFloat = 28
    var body: some View {
        LinearGradient(gradient: palette.gradient(0, 1, steps: 8), startPoint: .leading, endPoint: .trailing)
            .frame(width: width, height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

extension View {
    /// Greys out settings that don't affect the current mode.
    func knob(_ k: Knob, _ mode: VizMode) -> some View {
        let on = mode.uses(k)
        return disabled(!on).opacity(on ? 1 : 0.4)
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}

/// Named looks: pick to apply, Save under a new name, overwrite the selected one, delete it.
struct PresetSection: View {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState
    /// The picked preset lives in the store, so auto-loop switches show here too.
    private var selected: String {
        get { store.selectedPreset }
        nonmutating set { store.selectedPreset = newValue }
    }
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        FoldSection("Presets", icon: "bookmark") {
            if store.presetNames.isEmpty {
                Hint("No presets yet. Save stores the current look under a name.")
            } else {
                // Picking applies the preset; setting `selectedPreset` elsewhere (launch, auto-loop) only shows it.
                HStack(spacing: 4) {
                Picker("Preset", selection: Binding(get: { selected }, set: { name in
                    selected = name
                    guard !name.isEmpty else { return }
                    if let cam = store.applyPreset(name) { app.camera.set(cam, for: store.v.mode) }
                })) {
                    Text("None").tag("")
                    ForEach(store.presetNames, id: \.self) { name in
                        Text(name == selected && !store.matches(name) ? "\(name) (edited)" : name).tag(name)
                    }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                Button { app.stepPreset(-1, store) } label: { Image(systemName: "chevron.left") }
                    .help("Previous preset (←)")
                Button { app.stepPreset(1, store) } label: { Image(systemName: "chevron.right") }
                    .help("Next preset (→)")
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                Button("Save") {
                    newName = selected
                    naming = true
                }
                Button("Overwrite") { store.savePreset(selected, camera: app.camera.state(for: store.v.mode)) }
                    .disabled(selected.isEmpty)
                    .help("Save the current look and camera view into the selected preset")
                    .fixedSize()   // keep the full label instead of "Overwr…"
                Button("Delete") { confirmDelete = true }
                    .disabled(selected.isEmpty)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            // Presentation modifiers live on this single row (not the Section) so they attach exactly once.
            .alert("Save Preset", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Save") { saveNew() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves the current look and camera view. Using an existing name replaces that preset.")
            }
            .confirmationDialog("Delete preset \u{201C}\(selected)\u{201D}?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    store.deletePreset(selected)
                    selected = ""
                }
            }
            // Single-key shortcuts (S, F, Space…) would swallow typing while the name dialog is open.
            .onChange(of: naming) { _, open in app.textEditing = open }

            Toggle("Auto-loop through presets", isOn: $store.v.presetLoop)
                .disabled(store.presetNames.count < 2)
                .help("Switches to the next preset in the list on a beat.")
            if store.v.presetLoop {
                SliderRow("Beats", $store.v.presetLoopBeats, 1...64) { "\(Int(store.v.presetLoopBeats.rounded()))" }
                    .help("How many detected beats between switches.")
                SliderRow("Random +", $store.v.presetLoopRandom, 0...32) {
                    store.v.presetLoopRandom < 0.5 ? "off" : "0–\(Int(store.v.presetLoopRandom.rounded()))"
                }
                .help("Adds a random number of extra beats (up to this many) to each wait, so switches don't land on a fixed grid.")
            }
        }
        .onAppear {
            if selected.isEmpty, let match = store.presetNames.first(where: { store.matches($0) }) { selected = match }
        }
    }

    private func saveNew() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        store.savePreset(n, camera: app.camera.state(for: store.v.mode))
        selected = n
    }
}

/// Image Particles: the picture and how it's turned into particles.
private struct ImageParticleControls: View {
    @Bindable var store: SettingsStore
    private var path: String { store.v.imgPath }

    var body: some View {
        HStack {
            Button(path.isEmpty ? "Choose image…" : "Change…") { choose() }
            if !path.isEmpty {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? .primary : Color.red)
                    .help(path)
                Spacer()
                Button { store.v.imgPath = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Remove the image (back to the soundwatch lettering)")
            }
        }
        SliderRow("Threshold", $store.v.imgThreshold, 0...0.95, "%.2f")
            .help("Leaves out the darker parts of the picture. Transparent parts of a PNG are always left out. 0 = every pixel.")
        Picker("Reacts by", selection: $store.v.imgBandMap) {
            ForEach(ImageBandMap.allCases) { Text($0.title).tag($0) }
        }
        .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
        .help("Which frequency band each particle listens to: its position (left = bass), at random, its brightness (dark = bass) or its colour (reds = bass, blues = treble). Except for Position, kicks shake the bass particles and hats the treble ones.")
        Picker("Colours", selection: $store.v.imgColours) {
            Text("Image").tag(true)
            Text("Palette").tag(false)
        }
        .pickerStyle(.segmented)
        SliderRow("Springiness", $store.v.imgSpring, 0...1, "%.2f").node("imgSpring")
            .help("How hard the particles pull back into the picture. Low = loose, slow, they scatter far; high = tight and snappy.")
        SliderRow("Depth", $store.v.imgDepth, 0...1, "%.2f").node("imgDepth")
            .help("Pulls the bright parts of the picture forward, a relief you can see when you orbit the view.")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture to turn into particles"
        if panel.runModal() == .OK, let url = panel.url { store.v.imgPath = url.path }
    }
}

/// An image or video combined with the visuals.
private struct MediaSection: View {
    @Bindable var store: SettingsStore
    let app: AppState

    private var path: String { store.v.mediaPath }
    private var isVideo: Bool {
        UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension).map {
            $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent)
        } ?? false
    }

    @ViewBuilder var body: some View {
        FoldSection("Media layer", icon: "photo") {
            HStack {
                Button(path.isEmpty ? "Choose image or video…" : "Change…") { choose() }
                if !path.isEmpty {
                    Image(systemName: isVideo ? "film" : "photo").foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(FileManager.default.fileExists(atPath: path) ? .primary : Color.red)
                        .help(path)
                    Spacer()
                    Button { store.v.mediaPath = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Remove the media")
                }
            }
            if !path.isEmpty {
                Picker("Blend", selection: $store.v.mediaBlend) {
                    ForEach(MediaBlend.allCases) { Text($0.title).tag($0) }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                Picker("Fit", selection: $store.v.mediaFit) {
                    ForEach(MediaFit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.v.mediaBlend != .hidden {
                    SliderRow("Opacity", $store.v.mediaOpacity, 0...1, "%.2f").node("mediaOpacity")
                    SliderRow("Beat pulse", $store.v.mediaPulse, 0...1, "%.2f")
                        .help("Each detected beat flashes the media's opacity up by this much.")
                }
                SliderRow("Blur", $store.v.mediaBlur, 0...1, "%.2f").node("mediaBlur")
                    .help("Softens the media. Also smooths the Displace warp.")
                SliderRow("Displace", $store.v.mediaDisplace, 0...1, "%.2f").node("mediaDisplace")
                    .help("Warps the visuals using the media as a map: edges push sideways, bright parts push outward.")
                if isVideo {
                    SliderRow("Speed", $store.v.mediaSpeed, 0...4, "%.2f×").node("mediaSpeed")
                        .help("Playback speed (0 = paused). Can be driven by the music in the Nodes panel.")
                }
            }
        }
        if !path.isEmpty {
            FoldSection("Media transform", icon: "crop.rotate") {
                SliderRow("Scale", logScale, log10(0.1)...log10(8)) { String(format: "%.2f×", store.v.mediaScale) }.node("mediaScale")
                SliderRow("X", $store.v.mediaX, -1...1, "%+.2f").node("mediaX")
                SliderRow("Y", $store.v.mediaY, -1...1, "%+.2f").node("mediaY")
                SliderRow("Rotate", $store.v.mediaRotate, 0...1) { String(format: "%.0f°", store.v.mediaRotate * 360) }.node("mediaRotate")
                Picker("Tile", selection: $store.v.mediaTile) {
                    ForEach(MediaTile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Repeat the media to fill the screen when it's scaled down or moved. Mirror flips every other copy, so the seams disappear.")
                SliderRow("Kaleido", $store.v.mediaKaleido, 0...16) {
                    store.v.mediaKaleido < 1.5 ? "off" : String(format: "%.0f", store.v.mediaKaleido.rounded())
                }.node("mediaKaleido")
                .help("Folds the media into a kaleidoscope with this many mirrored segments.")
                Button("Reset transform") {
                    let d = VizSettings()
                    store.v.mediaScale = d.mediaScale; store.v.mediaX = d.mediaX; store.v.mediaY = d.mediaY
                    store.v.mediaRotate = d.mediaRotate; store.v.mediaTile = d.mediaTile; store.v.mediaKaleido = d.mediaKaleido
                    app.mediaMotionReset += 1
                }
            }
            FoldSection("Media motion", icon: "wind") {
                SliderRow("Drift", $store.v.mediaDrift, 0...1, "%.2f").node("mediaDrift")
                    .help("Scrolls the media steadily. Turn on Tile for an endless scroll.")
                SliderRow("Direction", $store.v.mediaDriftDir, 0...1) { String(format: "%.0f°", store.v.mediaDriftDir * 360) }.node("mediaDriftDir")
                SliderRow("Spin", $store.v.mediaSpin, -1...1, "%+.2f").node("mediaSpin")
                SliderRow("Wander", $store.v.mediaWander, 0...1, "%.2f").node("mediaWander")
                    .help("A slow, aimless pan, zoom and tilt over the picture (Ken Burns).")
                SliderRow("Beat zoom", $store.v.mediaBeatZoom, 0...1, "%.2f")
                    .help("Each beat punches the media in, then it eases back.")
                SliderRow("Breathe", $store.v.mediaBreathe, 0...1, "%.2f")
                    .help("Scale follows the bass level.")
                SliderRow("Shake", $store.v.mediaShake, 0...1, "%.2f")
                    .help("Snares and hats jolt the media off-centre; it wobbles back.")
                SliderRow("Beat jump", $store.v.mediaJump, 0...1, "%.2f")
                    .help("Chance per beat of a cut: a video jumps to a random moment, a picture to a new spot and orientation.")
                Button("Stop all motion") {
                    let d = VizSettings()
                    store.v.mediaDrift = d.mediaDrift; store.v.mediaSpin = d.mediaSpin; store.v.mediaWander = d.mediaWander
                    store.v.mediaBeatZoom = d.mediaBeatZoom; store.v.mediaBreathe = d.mediaBreathe
                    store.v.mediaShake = d.mediaShake; store.v.mediaJump = d.mediaJump
                    app.mediaMotionReset += 1   // and put back what spin / drift / wander had moved
                }
            }
        }
    }

    private var logScale: Binding<Double> {
        Binding(get: { log10(max(0.1, store.v.mediaScale)) },
                set: { store.v.mediaScale = (pow(10, $0) * 100).rounded() / 100 })
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image or a video to combine with the visuals"
        if panel.runModal() == .OK, let url = panel.url { store.v.mediaPath = url.path }
    }
}

enum SettingsGroupInfo {
    /// What each group is for, shown from the ? beside its title.
    static let text: [String: String] = [
        "Always overwrite": "Settings that win over every preset and look. Use it to keep one background colour and opacity whatever you load.",
        "Presets": "Saved looks. Pick one to load it, save the current look under a name, step through them with ← / →, or let them change on the beat with Auto-loop.",
        "Mode": "Which visualizer is drawn, plus the options that only this mode has (shape, layout, detail and its own controls).",
        "Layers": "Dreamcast's stack of animated layers (up to 10): add, hide, reorder, duplicate and remove them, or load one of the ready-made layer presets (each on its console). The screen sits in 3D: drag to turn it, scroll to zoom; empty parts show the background. The top of the list is in front. Each layer has its own style, speed, position, size, rotation, opacity, colour turn and how much the music drives it.",
        "Camera": "Lens effects on the finished picture: depth of field (what's sharp and what blurs), the shape of the out-of-focus highlights and grain in the blur. In Landscape also global illumination: light bouncing between surfaces.",
        "Shape & motion": "The basic look shared by most modes: how big things are, how much they glow and leave trails, how fast they move and how far the music pushes them.",
        "Response": "How the sound is read: the audio source, how loud and how detailed it's taken, which frequencies count, how fast levels fall back, and A/V sync.",
        "Colour": "The colour palette and how it's spread over the picture: by frequency, position, level or time, with an offset and slow cycling.",
        "Feedback & beat": "Trails that warp and feed back into the next frame, and how hard each beat punches the picture. Lock to tempo follows the song's beat.",
        "Media layer": "Combine your own image or video with the visuals: how it's blended in, fitted, blurred, and used to warp the picture.",
        "Media transform": "Where the media sits: scale, position, rotation, tiling and a kaleidoscope fold.",
        "Media motion": "Makes the media move on its own or with the music: drift, spin, slow wander, beat zooms, shakes and jumps.",
        "Distortion": "Bends the whole picture like looking through something: liquid, ripples, heat haze, rain on glass and more, moving with the music.",
        "Post-processing": "Final touches on the whole frame: brightness, contrast and colour, plus lens, print, film and CRT effects.",
        "Window": "The app window itself: background colour and see-through opacity, overlay mode (picture only, above other windows), anti-aliasing and the FPS counter.",
    ]
}

/// A settings group that folds away. Groups start collapsed unless `open` is set; changes are remembered.
struct FoldSection<Content: View>: View {
    let title: String
    let icon: String
    let defaultOpen: Bool
    /// Shown in a small popover from the ? next to the title (none when empty).
    let info: String
    @ViewBuilder var content: () -> Content
    /// "Title=1|Title=0": each group's last open/closed state; groups never touched use their default.
    @AppStorage("AudioViz.settingsGroupState.v3") private var stateList = ""
    @State private var hovered = false
    @State private var showInfo = false
    /// Local open state (seeded from `stateList`), so the toggle animates: an @AppStorage write doesn't carry the animation.
    @State private var openState: Bool?
    /// True while the box is shrinking (or about to grow): its height is driven to 0, the content removed afterwards.
    @State private var folded = false

    /// Debug aid (sidebar snapshots): AUDIOWATCH_SIDEBAR_OPEN=1 shows every group open.
    static var forceOpen: Bool { foldForceOpen }
    /// Slow start, long soft landing, the same both ways.
    static var foldAnimation: Animation { .timingCurve(0.6, 0, 0.25, 1, duration: 0.28) }

    init(_ title: String, icon: String, open: Bool = false, info: String = "", @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.defaultOpen = open
        self.info = info.isEmpty ? (SettingsGroupInfo.text[title] ?? "") : info
        self.content = content
    }

    private var saved: [String: Bool] {
        Dictionary(stateList.components(separatedBy: "|").compactMap { item -> (String, Bool)? in
            guard let eq = item.lastIndex(of: "=") else { return nil }
            return (String(item[..<eq]), item[item.index(after: eq)...] == "1")
        }, uniquingKeysWith: { _, b in b })
    }
    private var isOpen: Bool { Self.forceOpen || (openState ?? saved[title] ?? defaultOpen) }

    private func toggle() {
        let open = !(isOpen && !folded)
        if open {
            // Insert the content at zero height, then grow it on the next update.
            folded = true
            openState = true
            DispatchQueue.main.async { withAnimation(Self.foldAnimation) { folded = false } }
        } else {
            withAnimation(Self.foldAnimation, completionCriteria: .logicallyComplete) {
                folded = true
            } completion: {
                if folded { openState = false; folded = false }   // unless it was reopened meanwhile
            }
        }
        var state = saved
        state[title] = open
        stateList = state.keys.sorted().map { "\($0)=\(state[$0]! ? 1 : 0)" }.joined(separator: "|")
    }

    var body: some View {
        PixelStack(spacing: 2) {
            // Mail-style header: icon + title (+ ?) on the left, disclosure chevron on the right; a click anywhere
            // else on the row toggles. A tap gesture, not a Button: the ? button can't sit inside another button.
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14)
                Text(title).fontWeight(.bold)
                if !info.isEmpty {
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        Text(info)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 240, alignment: .leading)
                            .padding(12)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen && !folded ? 90 : 0))
            }
            .foregroundStyle(.primary)   // icon, title and chevron in the normal text colour
            .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hovered = $0 }

            if isOpen {
                PixelStack(spacing: 7) { content() }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(FoldReveal(progress: folded ? 0 : 1))
            }
        }
    }
}

/// Folding: the box (darker background included) grows from / shrinks to zero height, top edge fixed,
/// content clipped and fading with it.
private struct FoldReveal: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        RevealLayout(progress: progress) { content }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.07)))   // group contents slightly darker than the panel
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(Double(min(1, progress * 1.6)))
    }
}

/// Reports `progress` × the child's natural height; the child keeps its full size, pinned to the top.
private struct RevealLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? s.width, height: s.height * max(0, progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}


/// A leading-aligned vertical stack that puts every row on a whole point. SwiftUI's 11 pt text lines are ~13.1 pt tall,
/// so in a plain VStack the rows below drift onto fractional pixels, and AppKit-backed controls (pop-ups, segmented
/// controls, checkboxes) render their labels blurry there. Rows keep their natural heights; only their origins are rounded.
struct PixelStack: Layout {
    var spacing: CGFloat

    /// Row heights for one width: placeSubviews reuses what sizeThatFits measured (it measured every row twice).
    /// SwiftUI rebuilds the cache whenever the rows change.
    struct Cache { var width: CGFloat?; var valid = false; var heights: [CGFloat] = []; var maxWidth: CGFloat = 0 }
    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func measure(_ width: CGFloat?, _ subviews: Subviews, _ cache: inout Cache) {
        if cache.valid && cache.width == width && cache.heights.count == subviews.count { return }
        let inner = ProposedViewSize(width: width, height: nil)
        cache.heights.removeAll(keepingCapacity: true); cache.maxWidth = 0
        for v in subviews {
            let size = v.sizeThatFits(inner)
            cache.heights.append(size.height)
            cache.maxWidth = max(cache.maxWidth, size.width)
        }
        cache.width = width; cache.valid = true
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measure(proposal.width, subviews, &cache)
        var height: CGFloat = 0
        for (k, h) in cache.heights.enumerated() { height += h.rounded(.up) + (k > 0 ? spacing : 0) }
        return CGSize(width: proposal.width ?? cache.maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(bounds.width, subviews, &cache)
        var y = bounds.minY.rounded()
        let x = bounds.minX.rounded()
        for (v, h) in zip(subviews, cache.heights) {
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h.rounded(.up) + spacing
        }
    }
}

/// Read once: `ProcessInfo.environment` builds a new dictionary on every call (it showed up while dragging sliders).
private let foldForceOpen = ProcessInfo.processInfo.environment["AUDIOWATCH_SIDEBAR_OPEN"] != nil
