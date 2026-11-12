import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Compact native settings panel.
struct SettingsPanel: View {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState

    private var mode: VizMode { store.s.mode }

    var body: some View {
        Form {
            PresetSection(store: store, app: app)

            FoldSection("Mode", icon: "square.grid.2x2") {
                Picker("Mode", selection: $store.s.mode) {
                    ForEach(VizMode.stable) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    Section("Experimental") {
                        ForEach(VizMode.experimental) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                if mode == .sphere {
                    Picker("Layout", selection: $store.s.sphereLayout) {
                        ForEach(SphereLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                    Hint(store.s.sphereLayout.hint)
                } else if mode == .oscilloscope {
                    Picker("Shape", selection: $store.s.scopeShape) {
                        ForEach(ScopeShape.allCases) { Text($0.title).tag($0) }
                    }
                    .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                    Hint(store.s.scopeShape.hint)
                } else {
                    Hint(mode.hint)
                }
                if mode.uses(.style) {
                    Picker("Style", selection: $store.s.style) {
                        ForEach(DrawStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if mode.usesLook {
                    Picker("Render", selection: $store.s.look) {
                        ForEach(SurfaceLook.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Lines: wireframe outlines. Shaded: solid, lit surfaces. Fresnel: glassy, glowing rims.")
                }
                detailRow
                if mode == .field {
                    SliderRow("Springiness", $store.s.fieldSpring, 0...1, "%.2f")
                        .help("How strongly particles are pulled back to their home spot. Low = slow, lazy return; high = snappy.")
                }
                if mode == .membrane {
                    SliderRow("Tint", $store.s.membraneTint, 0...1, "%.2f")
                        .help("0 = plain grey rubber; higher tints the sheet with the palette (by height).")
                    SliderRow("Relief", $store.s.membraneRelief, 0...1, "%.2f")
                        .help("Pushes the media layer's picture up through the sheet (bright = high). Needs a media file; set its Blend to Hidden to see only the relief, and add Media blur for smooth shapes.")
                }
                if mode == .diamond {
                    SliderRow("Facets", Binding(get: { store.s.diamondFacets }, set: { store.s.diamondFacets = $0.rounded() }), 5...50, "%.0f")
                        .help("How many facets the stone has: from a chunky crystal (5) to a near-brilliant cut (50).")
                    SliderRow("Movement", $store.s.diamondMove, 0...1, "%.2f")
                        .help("How much the music reshapes the stone. Each side follows its own frequency band: it tilts and pushes out or sinks in; bass stretches the stone taller and nudges it off-centre, treble makes it wider; it also slowly turns and tumbles. 0 = a perfect, still stone.")
                    SliderRow("Rainbow", $store.s.diamondFire, 0...1, "%.2f")
                        .help("How much the light splits into rainbow colours as it passes through the stone, like a prism. 0 = only white sparkle (and about 3× cheaper to draw); higher = coloured flashes and rainbow edges on the facets.")
                }
                if mode == .glass {
                    SliderRow("Softness", $store.s.glassSoft, 0...1, "%.2f")
                        .help("Depth of field: rings far in front of or behind the middle go soft.")
                }
            }

            FoldSection("Creative controls", icon: "wand.and.stars") {
                HStack(spacing: 6) {
                    Text("Colours").lineLimit(1).frame(width: 64, alignment: .leading)
                    Slider(value: $store.s.colourMorph, in: 0...Double(PaletteKind.allCases.count - 1)).labelsHidden()
                    PaletteSwatch(palette: store.s.effectivePalette, width: 44)
                }
                .help("Morphs smoothly through all the colour palettes. The Palette menu below follows along.")
                SliderRow("Intensity", $store.s.intensity, -1...1) { Self.intensityLabel(store.s.intensity) }
                    .help("One knob for the whole look: left calms everything down (slower, smaller, softer, steadier); right makes it wilder (more motion, reach, glow, trails, warp, beat punch, colour and edge effects). Your other sliders keep their values.")
                Hint("A quick way to try things out: Intensity nudges many other settings at once without changing them.")
            }

            FoldSection("Colour", icon: "paintpalette") {
                Picker("Palette", selection: Binding(get: { store.s.palette },
                                                     set: { store.s.palette = $0; store.s.paletteMix = 0 })) {
                    ForEach(PaletteKind.allCases) { p in
                        HStack { PaletteSwatch(palette: p.palette); Text(p.title) }.tag(p)
                    }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                Picker("Colour by", selection: $store.s.colorBy) {
                    ForEach(ColorBy.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .knob(.colorBy, mode)
                SliderRow("Offset", $store.s.hueShift, 0...2, "%.2f")
                SliderRow("Cycling", $store.s.colorCycle, 0...2, "%.2f")
            }

            FoldSection("Response", icon: "waveform") {
                Picker("FFT size", selection: $store.s.fftSize) {
                    ForEach([2048.0, 4096, 8192, 16384, 32768], id: \.self) { Text("\(Int($0))").tag($0) }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                .help("Bigger = finer frequency detail (good for huge point counts), slower response. Waveform modes don't use the FFT.")
                .knob(.fft, mode)
                Toggle("Low latency", isOn: $store.s.lowLatency)
                    .knob(.fft, mode)
                    .disabled(!mode.supportsLowLatency)
                    .help(mode.supportsLowLatency
                          ? "Above ~200 Hz use short FFTs, so drums and vocals react within ~20 ms. The FFT size then only sets the bass detail."
                          : "Not used here: this mode's look depends on the full FFT's fine frequency detail.")
                SliderRow("Gain", $store.s.gain, 0.2...5, "%.2f×").knob(.gain, mode)
                SliderRow("Floor", $store.s.floorDB, -120...(-30), "%.0f dB").knob(.floor, mode)
                SliderRow("Tilt", $store.s.tilt, 0...6, "%.1f dB").knob(.tilt, mode)
                SliderRow("Smoothing", $store.s.smoothing, 0...0.97) { Self.fallLabel(store.s.smoothing) }
                    .knob(.smoothing, mode)
                    .help("How slowly levels fall back after a hit. Rises are always instant.")
                SliderRow("Low freq", logBinding(\.minFreq), log10(20)...log10(1000)) { hz(store.s.minFreq) }
                    .knob(.freqRange, mode)
                SliderRow("High freq", logBinding(\.maxFreq), log10(1500)...log10(22000)) { hz(store.s.maxFreq) }
                    .knob(.freqRange, mode)
            }

            FoldSection("Shape & motion", icon: "move.3d") {
                SliderRow("Size", $store.s.size, 0.2...4, "%.2f").knob(.size, mode)
                SliderRow("Glow", $store.s.glow, 0...1, "%.2f").knob(.glow, mode)
                SliderRow("Trails", $store.s.persistence, 0...1, "%.2f").knob(.persistence, mode)
                SliderRow("Motion", $store.s.motion, 0...2, "%.2f").knob(.motion, mode)
                SliderRow("Zoom", $store.s.zoom, 0.3...2.5, "%.2f×").knob(.zoom, mode)
                SliderRow("Reach", $store.s.reach, 0...4, "%.2f×").knob(.reach, mode)
                    .help("How far things travel: sphere bulge, spoke length, particle steps, trace height.")
                HStack {
                    Toggle("Stereo", isOn: $store.s.stereo).knob(.stereo, mode)
                    Toggle("Mirror", isOn: $store.s.mirror).knob(.mirror, mode)
                    Toggle("Segmented", isOn: $store.s.segmented).knob(.segmented, mode)
                }
            }

            FoldSection("Feedback & beat", icon: "metronome") {
                Picker("Warp", selection: $store.s.warpStyle) {
                    ForEach(WarpStyle.allCases) { Text($0.title).tag($0) }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                .knob(.persistence, mode)
                SliderRow("Warp amt", $store.s.warp, 0...1, "%.2f").knob(.persistence, mode)
                SliderRow("Beat", $store.s.beat, 0...1.5, "%.2f")
                Hint("Warp feeds the previous frame back through a zoom/spin/swirl driven by bass. Beat = how hard detected kicks punch the image.")
            }

            FoldSection("Post-processing", icon: "camera.filters") {
                SliderRow("Brightness", $store.s.brightness, -1...1, "%+.2f")
                SliderRow("Contrast", $store.s.contrast, 0.2...2, "%.2f")
                SliderRow("Saturation", $store.s.saturation, 0...2, "%.2f")
                SliderRow("Hue", $store.s.hueRotate, 0...1, "%.2f")
                    .help("Rotates every colour around the colour wheel (applied after everything else).")
                SliderRow("Aberration", $store.s.aberration, 0...1, "%.2f")
                    .help("Chromatic aberration: red and blue drift apart towards the edges, like a cheap lens.")
                SliderRow("Pixelate", $store.s.pixelate, 0...1, "%.2f")
                SliderRow("Posterize", $store.s.posterize, 0...1, "%.2f")
                    .help("Fewer colour levels: banded, print-like colours.")
                SliderRow("Invert", $store.s.invert, 0...1, "%.2f")
                SliderRow("Soft focus", $store.s.softFocus, 0...1, "%.2f")
                    .help("Mixes in a wide blur of the image: dreamy, out-of-focus glow. Unlike Glow it softens shapes, not just brightens them.")
                SliderRow("Streak", $store.s.streak, 0...1, "%.2f")
                    .help("Bright parts smear into long vertical light streaks, like an anamorphic lens.")
                SliderRow("Fringe", $store.s.fringe, 0...1, "%.2f")
                    .help("Rainbow colour fringes along edges (green/yellow on one side, red/blue on the other), like light through glass.")
                SliderRow("Film grain", $store.s.filmGrain, 0...1, "%.2f")
                    .help("Fine photographic grain; shows on dark, bright and grey areas alike.")
                SliderRow("Grain size", $store.s.grainSize, 0.5...6, "%.1f")
                    .disabled(store.s.filmGrain <= 0)
                    .help("1 = about a pixel. Higher = coarser, clumpier grain, like faster film.")
                SliderRow("Scanlines", $store.s.scanlines, 0...1, "%.2f")
                SliderRow("Vignette", $store.s.vignette, 0...1, "%.2f")
                SliderRow("Flicker", $store.s.flicker, 0...1, "%.2f")
                    .help("CRT flicker and a slow rolling refresh band.")
                Button("Reset post-processing") {
                    let d = VizSettings()
                    store.s.brightness = d.brightness; store.s.contrast = d.contrast; store.s.saturation = d.saturation
                    store.s.hueRotate = d.hueRotate; store.s.aberration = d.aberration; store.s.pixelate = d.pixelate
                    store.s.posterize = d.posterize; store.s.invert = d.invert
                    store.s.softFocus = d.softFocus; store.s.streak = d.streak; store.s.fringe = d.fringe
                    store.s.filmGrain = d.filmGrain; store.s.grainSize = d.grainSize
                    store.s.scanlines = d.scanlines; store.s.vignette = d.vignette; store.s.flicker = d.flicker
                }
            }

            MediaSection(store: store, app: app)

            FoldSection("Window", icon: "macwindow") {
                ColorPicker("Background", selection: bgColor, supportsOpacity: false)
                SliderRow("Opacity", $store.s.bgOpacity, 0...1, "%.2f")
                HStack {
                    Toggle("Always on top", isOn: $store.s.alwaysOnTop)
                    Toggle("Show FPS", isOn: $store.s.showFPS)
                }
            }

            Section {
                Button("Reset look") { store.resetLook() }
                Hint("1–8 modes · S settings · Space freeze · F full screen · T on top · R reset view")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .font(.system(size: 11))
    }

    @ViewBuilder private var detailRow: some View {
        let d = mode.detail
        let short = d.label.components(separatedBy: " (").first ?? d.label
        if d.isLog {
            SliderRow(short, Binding(
                get: { log10(store.s[keyPath: d.keyPath]) },
                set: { store.s[keyPath: d.keyPath] = Self.niceRound(pow(10, $0)) }
            ), log10(d.range.lowerBound)...log10(d.range.upperBound)) { Self.compact(store.s[keyPath: d.keyPath]) }
        } else {
            SliderRow(short, Binding(
                get: { store.s[keyPath: d.keyPath] },
                set: { store.s[keyPath: d.keyPath] = $0.rounded(toPlaces: d.range.upperBound > 50 ? 0 : 1) }
            ), d.range, d.format)
        }
    }

    static func intensityLabel(_ v: Double) -> String {
        abs(v) < 0.01 ? "0" : String(format: "%+.0f%%", v * 100)
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

    private var bgColor: Binding<Color> {
        Binding(
            get: { Color(.sRGB, red: store.s.bgRed, green: store.s.bgGreen, blue: store.s.bgBlue) },
            set: { c in
                guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
                store.s.bgRed = Double(ns.redComponent)
                store.s.bgGreen = Double(ns.greenComponent)
                store.s.bgBlue = Double(ns.blueComponent)
            })
    }

    private func logBinding(_ kp: WritableKeyPath<VizSettings, Double>) -> Binding<Double> {
        Binding(get: { log10(store.s[keyPath: kp]) }, set: { store.s[keyPath: kp] = pow(10, $0).rounded() })
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

/// One-line slider: label · slider · value.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var label: (() -> String)?

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
            Slider(value: $value, in: range).labelsHidden()
            Text(label?() ?? String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
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
                Picker("Preset", selection: Binding(get: { selected }, set: { name in
                    selected = name
                    guard !name.isEmpty else { return }
                    if let cam = store.applyPreset(name) { app.camera.set(cam, for: store.s.mode) }
                })) {
                    Text("None").tag("")
                    ForEach(store.presetNames, id: \.self) { name in
                        Text(name == selected && !store.matches(name) ? "\(name) (edited)" : name).tag(name)
                    }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
            }
            HStack(spacing: 8) {
                Button("Save") {
                    newName = selected
                    naming = true
                }
                Button("Overwrite") { store.savePreset(selected, camera: app.camera.state(for: store.s.mode)) }
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

            Toggle("Auto-loop through presets", isOn: $store.s.presetLoop)
                .disabled(store.presetNames.count < 2)
                .help("Switches to the next preset in the list on a beat.")
            if store.s.presetLoop {
                SliderRow("Beats", $store.s.presetLoopBeats, 1...64) { "\(Int(store.s.presetLoopBeats.rounded()))" }
                    .help("How many detected beats between switches.")
                SliderRow("Random +", $store.s.presetLoopRandom, 0...32) {
                    store.s.presetLoopRandom < 0.5 ? "off" : "0–\(Int(store.s.presetLoopRandom.rounded()))"
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
        store.savePreset(n, camera: app.camera.state(for: store.s.mode))
        selected = n
    }
}

/// An image or video combined with the visuals.
private struct MediaSection: View {
    @Bindable var store: SettingsStore
    let app: AppState

    private var path: String { store.s.mediaPath }
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
                    Button { store.s.mediaPath = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Remove the media")
                }
            }
            if path.isEmpty {
                Hint("Combine a picture or a looping video with the visuals: behind them, blended in, as a mask, or as a warp map. Videos play muted.")
            } else {
                Picker("Blend", selection: $store.s.mediaBlend) {
                    ForEach(MediaBlend.allCases) { Text($0.title).tag($0) }
                }
                .controlSize(.small)   // dropdown text at the panel's 11 pt (mini is ~9 pt)
                Hint(store.s.mediaBlend.hint)
                Picker("Fit", selection: $store.s.mediaFit) {
                    ForEach(MediaFit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.s.mediaBlend != .hidden {
                    SliderRow("Opacity", $store.s.mediaOpacity, 0...1, "%.2f")
                    SliderRow("Beat pulse", $store.s.mediaPulse, 0...1, "%.2f")
                        .help("Each detected beat flashes the media's opacity up by this much.")
                }
                SliderRow("Blur", $store.s.mediaBlur, 0...1, "%.2f")
                    .help("Softens the media. Also smooths the Displace warp.")
                SliderRow("Displace", $store.s.mediaDisplace, 0...1, "%.2f")
                    .help("Warps the visuals using the media as a map: edges push sideways, bright parts push outward.")
                if isVideo {
                    SliderRow("Speed", $store.s.mediaSpeed, 0...4, "%.2f×")
                        .help("Playback speed (0 = paused). Can be driven by the music in the Nodes window.")
                }
            }
        }
        if !path.isEmpty {
            FoldSection("Media transform", icon: "crop.rotate") {
                SliderRow("Scale", logScale, log10(0.1)...log10(8)) { String(format: "%.2f×", store.s.mediaScale) }
                SliderRow("X", $store.s.mediaX, -1...1, "%+.2f")
                SliderRow("Y", $store.s.mediaY, -1...1, "%+.2f")
                SliderRow("Rotate", $store.s.mediaRotate, 0...1) { String(format: "%.0f°", store.s.mediaRotate * 360) }
                Picker("Tile", selection: $store.s.mediaTile) {
                    ForEach(MediaTile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Repeat the media to fill the screen when it's scaled down or moved. Mirror flips every other copy, so the seams disappear.")
                SliderRow("Kaleido", $store.s.mediaKaleido, 0...16) {
                    store.s.mediaKaleido < 1.5 ? "off" : String(format: "%.0f", store.s.mediaKaleido.rounded())
                }
                .help("Folds the media into a kaleidoscope with this many mirrored segments.")
                Button("Reset transform") {
                    let d = VizSettings()
                    store.s.mediaScale = d.mediaScale; store.s.mediaX = d.mediaX; store.s.mediaY = d.mediaY
                    store.s.mediaRotate = d.mediaRotate; store.s.mediaTile = d.mediaTile; store.s.mediaKaleido = d.mediaKaleido
                    app.mediaMotionReset += 1
                }
            }
            FoldSection("Media motion", icon: "wind") {
                SliderRow("Drift", $store.s.mediaDrift, 0...1, "%.2f")
                    .help("Scrolls the media steadily. Turn on Tile for an endless scroll.")
                SliderRow("Direction", $store.s.mediaDriftDir, 0...1) { String(format: "%.0f°", store.s.mediaDriftDir * 360) }
                SliderRow("Spin", $store.s.mediaSpin, -1...1, "%+.2f")
                SliderRow("Wander", $store.s.mediaWander, 0...1, "%.2f")
                    .help("A slow, aimless pan, zoom and tilt over the picture (Ken Burns).")
                SliderRow("Beat zoom", $store.s.mediaBeatZoom, 0...1, "%.2f")
                    .help("Each beat punches the media in, then it eases back.")
                SliderRow("Breathe", $store.s.mediaBreathe, 0...1, "%.2f")
                    .help("Scale follows the bass level.")
                SliderRow("Shake", $store.s.mediaShake, 0...1, "%.2f")
                    .help("Snares and hats jolt the media off-centre; it wobbles back.")
                SliderRow("Beat jump", $store.s.mediaJump, 0...1, "%.2f")
                    .help("Chance per beat of a cut: a video jumps to a random moment, a picture to a new spot and orientation.")
                Button("Stop all motion") {
                    let d = VizSettings()
                    store.s.mediaDrift = d.mediaDrift; store.s.mediaSpin = d.mediaSpin; store.s.mediaWander = d.mediaWander
                    store.s.mediaBeatZoom = d.mediaBeatZoom; store.s.mediaBreathe = d.mediaBreathe
                    store.s.mediaShake = d.mediaShake; store.s.mediaJump = d.mediaJump
                    app.mediaMotionReset += 1   // and put back what spin / drift / wander had moved
                }
            }
        }
    }

    private var logScale: Binding<Double> {
        Binding(get: { log10(max(0.1, store.s.mediaScale)) },
                set: { store.s.mediaScale = (pow(10, $0) * 100).rounded() / 100 })
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image or a video to combine with the visuals"
        if panel.runModal() == .OK, let url = panel.url { store.s.mediaPath = url.path }
    }
}

/// A settings group that folds away. Groups start collapsed unless `open` is set; changes are remembered.
struct FoldSection<Content: View>: View {
    let title: String
    let icon: String
    let defaultOpen: Bool
    @ViewBuilder var content: () -> Content
    /// "Title=1|Title=0": each group's last open/closed state; groups never touched use their default.
    @AppStorage("AudioViz.settingsGroupState.v3") private var stateList = ""
    @State private var hovered = false

    init(_ title: String, icon: String, open: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.defaultOpen = open
        self.content = content
    }

    private var saved: [String: Bool] {
        Dictionary(stateList.components(separatedBy: "|").compactMap { item -> (String, Bool)? in
            guard let eq = item.lastIndex(of: "=") else { return nil }
            return (String(item[..<eq]), item[item.index(after: eq)...] == "1")
        }, uniquingKeysWith: { _, b in b })
    }
    private var isOpen: Bool { saved[title] ?? defaultOpen }

    var body: some View {
        Section {
            if isOpen {
                content()
                    .listRowBackground(Color.black.opacity(0.10))   // group contents a touch darker than the panel
            }
        } header: {
            // Mail-style header: icon + title on the left, disclosure chevron on the right; the whole row toggles.
            Button {
                var state = saved
                state[title] = !isOpen
                let list = state.keys.sorted().map { "\($0)=\(state[$0]! ? 1 : 0)" }.joined(separator: "|")
                withAnimation(.easeInOut(duration: 0.18)) { stateList = list }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 14)
                    Text(title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .foregroundStyle(.primary)   // icon, title and chevron in the normal text colour
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovered ? 0.08 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .padding(.horizontal, -10)   // same width as the group box below (rows are inset 10 pt)
        }
    }
}
