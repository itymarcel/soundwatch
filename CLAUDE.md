# soundwatch — notes for picking the work back up

Native macOS audio visualizer (Swift + SwiftUI + Metal). Captures system audio through a Core Audio
process tap and renders music-reactive scenes. Named "soundwatch" (lowercase) since 2026-11-11; formerly AudioViz, then AudioWatch.
The bundle id and UserDefaults keys still say `audioviz` **on purpose** (renaming them would wipe saved settings/presets).
The Swift target/module, `Sources/AudioWatch` and the `AUDIOWATCH_*` debug env vars keep the AudioWatch name (internal only).

User-facing docs are in `README.md` (modes, settings, Nodes, media layer, debug variables).

## Build & run

```bash
./build.sh                      # swift build -c release → build/soundwatch.app (codesign --force --deep --sign -); --universal = arm64+x86_64
./release.sh                    # universal build → build/soundwatch-<CFBundleShortVersionString>.zip for GitHub releases
open build/soundwatch.app       # normal launch — quit the running copy first, or the user keeps seeing the old build
swift Resources/make_icon.swift _input/icon.png   # regenerate Resources/AppIcon.icns (+ AppIcon.png) from square artwork
swift Resources/make_envmaps.swift                # Resources/hdr/*.exr → Resources/env/*.envmap (chrome environments)
```

There are no tests. "It builds" is **not** enough: the Metal shaders in `Metal/Shaders.swift` are
compiled at runtime, so a shader error only shows up when the app runs (no frame is produced).
A Swift/MSL struct mismatch compiles fine and fails silently (e.g. a post effect that does nothing), so check field order.

## Checking visuals from the terminal

`screencapture` is blocked here (no Screen Recording permission). Use the app's own harness, running the
binary directly:

```bash
AUDIOWATCH_WAV=/path/test.wav \
AUDIOWATCH_SETTINGS='{"mode":"canvas","zoom":1}' \
AUDIOWATCH_SNAPSHOT=/tmp/claude-…/scratchpad/shot AUDIOWATCH_SNAPSHOT_FRAMES=10,240 \
build/soundwatch.app/Contents/MacOS/soundwatch
```

- `AUDIOWATCH_SETTINGS` is merged over the user's **saved** settings and never persisted. Their saved
  values leak in (zoom, gain, post-processing, media layer, node patch…), so override what matters —
  e.g. `"nodes":{"nodes":[],"links":[],"enabled":false}`, `"mediaPath":""`. Always pass at least `'{}'`.
- `AUDIOWATCH_WAV` feeds a file instead of the system tap (nothing plays on the speakers).
- `AUDIOWATCH_NODES_SNAPSHOT=/path.png` renders the Nodes panel off-screen, saves it after ~3 s and quits.
- `AUDIOWATCH_PERF=1` prints CPU/GPU ms per frame. There is no `timeout` command on this Mac.
- Don't use the user's personal files (e.g. Desktop videos) as test media; generate test clips with ffmpeg.
- Things a still frame can't prove (motion over time, button clicks, typing) — say so when reporting.
- Also test with the user's **own** saved settings (`AUDIOWATCH_SETTINGS='{}'`), not only clean overrides: their values
  (e.g. Motion 0, Gain 3.6, small Size/Zoom, Goo 1, Blur 1) have hidden problems that clean tests missed.
- Several frames a fraction of a second apart (`AUDIOWATCH_SNAPSHOT_FRAMES=200,215,230,…`), tiled with ffmpeg `hstack`/`vstack`,
  show whether something actually reacts to the music.

## Code map (`Sources/AudioWatch`)

| File | What it is |
|---|---|
| `AudioWatchApp.swift` | App, menus, the main window |
| `ContentView.swift` | Main view, HUD (mode bar, top centre) + corner buttons ? / Nodes / Settings (top right), all fade when idle; `IntroOverlay` |
| `DefaultPresets.swift` | Built-in presets as JSON; `SettingsStore.seedDefaultPresets` adds each once (`AudioViz.defaultPresetsSeeded.v1`), so deleted ones stay gone |
| `SystemAudioTap.swift`, `AudioRing.swift`, `Analyzer.swift` | Audio capture → FFT bands, loudness, beat, onsets, pitch |
| `VizEngine.swift` | Per-frame `prepare(settings:)`: analyzer update, then `NodeRuntime.apply` → modulated settings `rc.s` |
| `Settings.swift` | `VizSettings` (everything saved/presets, incl. node graph), enums, `AppState` |
| `SettingsPanel.swift` | Settings sidebar in foldable groups (`FoldSection`): Presets (+ auto-loop), Quick controls, Mode, Shape & motion, Response, Colour, Feedback & beat, Media, Post-processing, Window |
| `Camera.swift` | Orbit camera |
| `Visualizers/*.swift` | One file per mode family (Canvas = mushrooms etc., Scope, Sphere, Halo, …). `ImageParticlesViz.swift` = Image Particles. `FerroViz.swift` = Splashs, `MetaballsViz.swift` + `Metal/FerroGPU.swift` = Real Metaballs. `ShaderModesViz.swift` = Membrane / Spectral Fan / Glass Stack / Diamond / Orbs: CPU keeps the music state, a full-screen fragment shader draws them (`ShaderModeUniforms` ↔ `ShaderModeU`) |
| `Metal/Renderer.swift` | Frame loop: preset auto-loop step → media blur → (Glass / Orbs raymarch ⅓ res, Diamond raytrace ½ res) → scene → feedback → bloom / soft-focus / streak blurs → composite |
| `Metal/Shaders.swift` | All MSL source (runtime-compiled). `CompU` must match Swift `CompositeUniforms` in `FrameBuilder.swift` field-for-field |
| `Metal/EnvMaps.swift` | Loads the chrome HDR environments (`*.envmap` in the app's Resources) into mipmapped textures, lazily |
| `Metal/MediaLayer.swift` | User image/video → texture (AVPlayer muted + looping), media motion (drift, spin, wander, shake, beat jump) |
| `Metal/DebugSnapshot.swift` | The env-var snapshot harness |
| `Nodes/NodeGraph.swift` | Node model, node kinds, `ModParam` list (what can be modulated), `NodeRuntime` evaluator |
| `Nodes/NodeEditorView.swift` | Node editor UI (grid, wires, cards, scrub/number fields) |

## Conventions & gotchas

- **Adding a modulatable parameter:** add it to `VizSettings`, then a `ModParam` in `NodeGraph.swift`
  (mark `cyclic` for angles/hues so they wrap instead of pinning at the range end; `isLog` for scale-like).
- **3D modes:** view matrix order is `rotX(modeTilt) * rc.camera.rotation * …` (tilt before camera = proper turntable).
- **Single-key menu shortcuts** are suppressed while a text field is active via `app.textEditing`.
- **Quick controls** (formerly Creative controls): `colourMorph` (computed: palette index + `paletteMix` blend toward the next palette, wraps) and
  `intensity` (−1…1 macro, applied in `VizEngine.prepare` via `VizSettings.applyingIntensity()` after the node patch, render-time only).
  Anything that draws palette colours must use `s.effectivePalette` / `s.effectiveInk`, not `s.palette.palette`.
- **Intro overlay** (`IntroOverlay` in ContentView): `app.startIntro()` (first launch via `AudioViz.introSeen`, the ? button, Help menu) also opens the settings sidebar; the overlay covers the canvas only and scales its cards to the canvas size.
  Debug runs (any `AUDIOWATCH_*` input var) never show it or mark it seen.
- **Capturing SwiftUI UI:** `NSView.cacheDisplay` on the main window silently drops some SwiftUI layers (top-aligned views
  came out missing); `ImageRenderer` on the view itself gives the true layout (native controls show as placeholders).
- **Mode name:** `VizMode.metaballs` is shown as **Ferrofluid** since 2026-11-15 (was "Real Metaballs"; raw value, `mb*` settings and these notes keep the old name).
- **Double-click a slider or its label** = back to its default (labels: plain `onTapGesture(count: 2)`; sliders: `resetOnDoubleClick` in SettingsPanel: an NSView behind the slider with a local
  mouse-down monitor, since SwiftUI gestures don't reach NSSlider; the default is read through the binding while the store briefly holds
  `VizSettings()`). Not testable from the terminal (needs real clicks).
- **Settings groups** fold (`FoldSection(title, icon:)`: SF Symbol left, bold title, chevron right, contents in a darker rounded box); state per title in `AudioViz.settingsGroupState.v3`, all closed by default.
  The panel is a `ScrollView` + `VStack`, **not** a grouped `Form`: Form rows keep a minimum height, so a group couldn't really shrink.
  Folding animates `FoldReveal`/`RevealLayout` (height × progress, clipped, top pinned): open = insert at 0 then animate to 1 on the
  next runloop; close = animate to 0, remove in the `withAnimation` completion. A removal *transition* doesn't work here (the box
  stays full height while the next group slides over it).
- **Sidebar snapshot:** `AUDIOWATCH_SIDEBAR_SNAPSHOT=/path.png` (+ `AUDIOWATCH_SIDEBAR_OPEN=1` for all groups open) renders the
  settings panel in an off-screen window, saves it and quits. Mid-animation frames can only be checked in a standalone prototype.
- **Main-thread rendering:** `Renderer.draw` runs on the main thread; it skips a tick (no blocking wait) when both frames are still
  in flight, so the sidebar keeps scrolling in heavy modes. Settings saves are debounced (0.4 s, flushed on quit).
- **Nodes panel** (2026-11-15, was a separate window): `app.showNodes` (not saved; N / corner button / the panel's ✕, `app.toggleNodes()`
  animates) puts `NodesPanel` (ContentView) under the canvas in a `VStack`, sliding in from the bottom; the canvas shrinks. Its top edge
  drags to resize (`AudioViz.nodesPanelHeight`, 160 pt … window − 140). Hidden in overlay mode. The slide and the drag were not checked
  live (only an off-screen still of the panel).
- **Preset stepping:** ← / → (Visualizer menu items, off while `app.textEditing`) and the chevron buttons beside the preset menu call
  `app.stepPreset(dir, store)` → `store.stepPreset` (list order, wraps, applies the camera); auto-loop uses the same function.
  Sidebar order is Presets, Mode, Quick controls, … (Mode and Quick controls swapped 2026-11-15).
- **Preset auto-loop:** `presetLoop`/`presetLoopBeats`/`presetLoopRandom` in VizSettings (kept across preset changes by `keepWindow`); `SettingsStore.presetLoopStep(beatCount:)` runs per frame from `Renderer.draw` and applies the next preset in list order. The picked preset is `store.selectedPreset` (the picker's setter applies; setting it elsewhere only shows it).
- **First launch** (no saved settings) applies the built-in preset `SettingsStore.firstLaunchPresetName` (Acid Garden) and its camera; the preset picker shows it selected.
- **Media blur** pads the image into a transparent margin before blurring so edges soften; the shader
  samples the padded texture (`media2.zw` = pad fraction). With Tile on, no padding.
- **Media motion** accumulates (spin angle, drift). It's cleared by bumping `app.mediaMotionReset`
  (Reset transform / Stop all motion) or loading a new file — setting a slider to 0 deliberately keeps the pose.
- Mushrooms (Canvas): no bounce; they grow slowly toward a `target` raised by hits in their frequency band.
- **Shader modes** (Membrane, Spectral Fan, Glass Stack, Diamond, Orbs): the visualizer fills `f.shaderMode` with
  `ShaderModeUniforms` + a float list; the renderer draws one full-screen fragment pass. Glass and Orbs (⅓ res) and Diamond (½ res)
  render off-screen first, then are added into the scene. Membrane/Fan are 2D (tilt via `camInv`, not volumetric).
- **Diamond** = a convex solid, i.e. a list of facet planes `n·x ≤ w` (raytraced: entry = max over front planes,
  exit = min over back planes; RGB traced at 3 IORs for "Rainbow"). Facets 5–50 = total count, split into rings by
  `DiamondViz.rings(total:)`; every cut is rescaled to outer radius 1.05. Movement = how much the music reshapes it
  (per-side tilt/push from 16 bands, stretch, bass drift, slow turn). Rotate/stretch the *planes*, not the view, so
  the stone moves under the lights. Keep the shader's bounding sphere (√4.4) larger than the stone can grow.
- **Chrome** (Shaders.swift, "chrome" section): reflects an HDRI (equirectangular, view space, `chromeTurn` rotates it).
  Source HDRIs (Poly Haven, CC0) live in `Resources/hdr` (git-ignored, ~90 MB); `swift Resources/make_envmaps.swift` makes
  `Resources/env/*.envmap` (1024×512 half floats, LZFSE, median-normalised; ~2.5 MB each), which build.sh copies into the app.
  `EnvMaps.swift` loads one lazily into a mipmapped texture; the shader gamma-encodes it (maps are linear, the scene is display-referred).
  `chromeShade` = Schlick Fresnel + Blur (mip level + 4 jittered samples; the user wanted blurred, not brushed).
  Used by `triFrag` (SurfaceLook `.chrome`, saved as "shaded"; Painter passes view normal + eye vector per vertex, the rest via
  `ChromeU` ↔ `ChromeUniforms` at fragment buffer 0 + env texture 0 — keep it all floats, a float3's 16-byte alignment breaks the
  match) and by `orbsFrag` (env texture 1). Settings: chromeEnv / chromeTurn / chromeBlur / chromeTint.
- **Orbs** = chrome metaballs (⅓ res, in `halfTex`): SDF = smooth-min of the orbs only (no central sphere: `R0` = 0; blend radius
  ∝ orb size, from Goo). Orbs wander (per-orb phase, faster when the band is loud, so they move even at Motion 0) and swell / push
  out when their band rises above its own running average (relative to its peak), so they react whatever Gain is.
  Reflections: 1 ray (Blur 0) or 3–4 jittered rays in a cone, each hitting another blob (one blurred env sample × Fresnel) or the
  environment (mip level ∝ Blur), averaged: real blur of the inter-reflections (the user asked for this). Per-ray orb mask culls
  the marches; start reflection rays `eps*6` off the surface or they re-hit it (ring artefacts); AO in the necks.
  GPU: ~5 ms with typical settings, ~14 ms zoomed in with 12 big orbs at Blur 1 (Retina).
- **Removed / renamed settings:** the CRT `grain` is gone (node patches targeting "grain" are aliased to `filmGrain`);
  Diamond's facet count is `diamondFacets` (the old `diamondCut` key meant symmetry and is ignored).
- **Performance** (GPU ms at 3600×2250, `AUDIOWATCH_PERF=1`): baseline ~5, Membrane ~9, Glass ~13, Diamond 8–18
  (Movement and Rainbow cost the most), Orbs 5–14. Keep new per-pixel work under ~16 ms there.
- **Intel builds:** no `Float16` on x86_64 — `./build.sh` (arm64) passes but `./release.sh` (universal) fails. Use raw `UInt16` half bits.
- **Mushrooms** chrome/fresnel meshes: stem 20×18, cap 16×48 (× lod for small ones); 150 mushrooms ≈ 2 ms CPU.
- **Beat tracker** (`BeatTracker.swift`, fed per 256-sample chunk from `Analyzer.processColumns`): onset strength = rectified
  log-energy rise in low/mid/high (averaged 48/32/16 ms - shorter windows read chord-tone beating as onsets; rises < 0.25 ln
  ignored); tempo 4×/s = autocorrelation of 8 s (recent ~4 s weighted more), comb over 1…4 periods × broad 120 BPM prior,
  a new tempo must win 4 estimates in a row (3 when unlocked); phase = 8-beat comb template + PLL beat clock (2nd order:
  nudges the period), `odfDelay` 13 ms corrects the onset-measure lag. Confidence = min(template sharpness, onsets on ≥ ~6 of
  8 beats standing out ×1.8 from the gaps, autocorrelation at the period, newest-bar agreement); lock > 0.5, unlock < 0.25.
  `Analyzer.updateBeats`: with `beatLock` (setting "Lock to tempo", kept across presets) and locked, `beatCount`/`beatPulse`
  come from the clock evaluated at `beatLookahead` (= buffer + 1.5 frames − outputLatency − avSync: the sound heard when the
  frame shows), else from the old bass-hit detector. `beatRamp` 0→1 per beat → Tempo node (Beat ramp / BPM / Confidence).
  Tested only on synthetic WAVs (kit at 124, breakbeat 90, 128→140 change, beatless pads; generator + evaluator were in the
  session scratchpad): beats within ±2 ms once locked, lock after ~5 s, tempo change re-locked in ~4 s (~1.5 s of drifting
  beats first), pads still false-lock ~10-20 % of the time. Downbeats were tried (kick-band accent) and dropped as unreliable.
  `AUDIOWATCH_TRACE=1` prints `BEAT readEnd= pos= phase= bpm= conf= per= hits= locked= count= look=` per frame.
- **Overlay mode** (`app.overlay`, not saved; replaced the saved "Always on top" setting, whose key is gone): T / Window toggle
  enter, only Esc leaves (local key monitor in `ContentView.installEscape`). `applyOverlay` sets level .floating, no shadow,
  hidden traffic lights, all Spaces, and removes `.titled` (a titled window keeps a 1 px highlight rim on its top edge).
  Untitled windows can't become key, so `OverlayKey` patches `canBecomeKey/Main` on SwiftUI's window class (the instance
  is already KVO-subclassed - don't isa-swizzle it) to say yes for the overlay window. HUD, corner buttons, FPS, status and
  the sidebar are hidden (sidebar restored on exit). `AUDIOWATCH_OVERLAY=1` enters at 1 s, leaves at 2.5 s, prints window state.
- **Image Particles** (`Visualizers/ImageParticlesViz.swift`, settings `img*`): the image is decoded (≤ 1600 px, EXIF-rotated,
  un-premultiplied) and sampled on a background queue; the grid is sized from the share of pixels passing the threshold, so
  the count is right for any image. Threshold uses the strongest channel (luminance dropped pure blue). A "Keep dark parts"
  option was removed at the user's request. No / unreadable image →
  "soundwatch" lettering. New samples: old particles fly to the new homes. Physics per particle on all cores (`step`, a
  static func: the nested-closure version made the type checker give up): spring to home + Depth·luminance + band level
  (band by x, Mirror = by |x|) toward the viewer + shimmer; onsets spawn expanding ring waves (kick 1.0 / snare 0.6 /
  hats 0.3). **Reacts by** (`imgBandMap`): Position (x; Mirror = |x|), Random (splitmix hash of the index), Brightness /
  Colour (rank of luminance / hue among all particles, computed with the sample, so every band gets its share; greys sort
  after the colours). Except for Position, waves push 5× harder on their own band group (kick → bass particles).
  `AUDIOWATCH_TRACE=1` prints `IMGP bass= mid= treble=` (mean distance from home per group) every 30 frames; with a
  bass-only WAV, Colour/Brightness/Random gave bass 0.30 vs treble 0.05, Position 0.32 vs 0.19. Lines style: still particles must still draw as dots (the user's saved style is Lines). 1M particles ≈ 8 ms CPU,
  10-15 ms GPU. Checked in stills only (test pattern, the lettering, palette colours, user settings).
- **Cymatics modes:** each (n, m) exists as cos(nπx)cos(mπy) + s·cos(mπx)cos(nπy) with s = −1, −0.5, 0.5, 1 (same resonant
  frequency). Picking "the first of equals" always chose s = −1, which is antisymmetric about the diagonal → a diagonal nodal
  line in every figure (user: "the diagonal line is always there"). Now the equals are rotated on each mode change (`switches`).
  Square plate: no true circles. Debug: `AUDIOWATCH_CYMATICS_MODE="n,m,s"` pins a mode; TRACE prints `CYMATICS mode`.
- **Capture:** the aggregate device lists its sub-device's own inputs (an interface's mic/line ins) before the tap, so
  `AudioRing.write` reads the tap from the **last** buffer(s). The FPS overlay says "(mono: left = right)" when L and R are identical
  (`Analyzer.stereoWidth`): a one-line vectorscope then means the audio itself is mono.
- **Splashs** (`VizMode.ferro`, raw value still "ferro"; was called Real Metaballs until 2026-11-13; `Visualizers/FerroViz.swift` + `ferroFrag`;
  settings `ferroFluid` (= Detail), `ferroSpikes` (shown as "Magnet"), `ferroSplash`, plus the chrome environment / turn / blur / tint).
  A pool of ferrofluid as a height field, only the fluid is drawn (the white dish was removed at the user's request). Model, radius 1, y up, grid 128² over ±0.72 (`FerroViz.extent`):
  coil current = bass rise over its own average; Langevin magnetisation L(4·H), dipole falloff (1 + r²/0.16)^-1.5. Mound
  (1 − r²/w²)^1.5 with fixed volume narrows as the field rises (fluid gathers over the coil), slumps back with a lag.
  Ripples η: Cowley–Rosensweig dispersion ω² = g k + s k³ − m k² (g 17, s 0.0063 → k꜀ ≈ 52, spikes ~0.12 apart), linear part per
  Fourier mode (vDSP 2D FFT, exact oscillator rotation, damping 2.5 + 0.0015 k²), forcing in real space low-passed at 2.6 k꜀:
  −m(x)(1 + 50 η)∇²η − 2·10⁶ η³ + noise. **The (1 + βη) field-focusing term is what makes hexagonal spikes** (tested offline in a
  numpy copy: an η² term only lifts the whole fluid, nothing at all gives stripes). m peak = 0.9…1.6 × critical (Magnet 0…1).
  CPU ~2-3 ms (main thread). `AUDIOWATCH_TRACE=1` → `FERRO coil= width= eta= hmax=`; `AUDIOWATCH_FERRO_DUMP=/path.pgm` dumps the height map.
- **Real Metaballs** (`VizMode.metaballs`, `Visualizers/MetaballsViz.swift` (drive) + `Metal/FerroGPU.swift` (GPU fluid) + `metaballsFrag`;
  settings `mbFluid` (= Detail, volume ∝ Fluid^0.75), `mbMagnet` (the dial), `mbMagnets` (3…24 coils on a Fibonacci sphere of radius 1.6 around
  the glass sphere, each pointing at the centre), `mbHold`, bands = 30 Hz–17 kHz log-spaced, one slice per coil in a fixed shuffled order (`MetaballsViz.shuffledBands`, seeded by the count; the Band slider / `mbBand` was removed at the user's request), `mbLag`, `mbHome` (Centre pull),
  `mbBurstAmt` / `mbBurstThr` (Burst strength / threshold)).
  References: the user's videos `_input/videoplayback.mp4`, `_input/ferro.mp4`. **History:** CPU particle fluid (rejected: jittery, same-size
  bubbles) → parametric blob `FerroBlobSim` (rejected: "always the same shapes", too flat) → CPU thin-film fluid (fragile, slow) → 2026-11-14 the
  user chose a real fluid on the GPU with magnets on a sphere in 3D. Old sims are in the session scratchpad `old/`.
  **FerroGPU** = position-based fluid (Macklin & Müller), d0 = 0.017 → ~23k particles at Fluid 1, h = 2 d0, fixed substeps (now 1/120 s, see below; a tiny
  first-frame dt blew it up: PBF velocity = Δx/dt), 2 Jacobi iterations; once per frame a GPU counting sort by cell (scan of cell counts) - the
  shuffled order made neighbour reads random (~99 ms → ~6 ms); bucket grid (cap 16) per substep. Forces: gravity 0.08 (the user: liquid in
  liquid, near-neutral buoyancy), drag, XSPH 0.3, Akinci cohesion 15 + **surface tension inside the solve** (negative pressure × 0.7; explicit
  cohesion ≥ 100 shattered it into sand, tension 1.0 too), coil dipole fields (softened, coilW 0.5, normalised |H| = 1 at the centre for one coil),
  Langevin M, Kelvin M∇|H| (kelvin 0.6), dipole–dipole between neighbours (0.25), clamps maxAccel 10 / maxVel 4 (strong fields collapsed it to a
  point → NaN). s_corr must be scaled into λ's units (`lamScale`), unscaled it exploded. Physics note: |H| of outside coils has no maximum inside the
  sphere and inward-facing coils cancel at the centre, so strong coils always pull the fluid onto the glass.
  Drawing: splat (fixed-point atomics) into 128³ r16F, `metaballsFrag` raymarches it inside the unit sphere. The fluid runs in its own command
  buffer **after** the raymarch (draws last frame's volume) so the adaptive raymarch scale isn't fooled by the fluid's time. `AUDIOWATCH_PERF`
  prints `fluid=` (GPU ms); `AUDIOWATCH_TRACE` prints `FERRO` particle stats; `AUDIOWATCH_FERRO='{"kelvin":1,"test":0.8,…}'` overrides tunables
  (`test` = one coil at a time, seconds each). Harness scripts: scratchpad `grun.sh`, `tile.sh`. Cost (harness, ~1.5× live): fluid 5–8 ms,
  raymarch 1–3 ms. **Centre pull** (`mbHome` 0…1 → home = 6·value, a spring −home·p per particle; maxAccel 10): without it the coils
  dragged the fluid onto the glass and it stayed there (user: "it really is just going to the outside"); with it the fluid floats as a mass,
  stretches into arms/dumbbells towards the coils, threads snap into drops and come back. Debug runs can't hear the system audio from the
  terminal (all coil currents 0) - test with `AUDIOWATCH_WAV` and the user's saved values instead.
  **Bursts** (`mbBurstAmt` strength 0…2, default 1; `mbBurstThr` threshold 0…1, default 0.4; replaced `mbBurst`): the user liked what happens when Fluid jumps (new particles inside the old ones → over-dense → the
  pressure solve blows it apart) and wanted music to do that "sometimes". Per coil a hit = envelope jump above a 50 ms follower, relative to
  its peak; only the hardest one fires above 0.25 + 0.9·threshold, cool-down 0.5 + 2·threshold s; it overdrives that coil (+1.5 × pulse, τ 0.12 s) and multiplies the
  density target by 1 + 0.22·pulse⁴ (a short kick; a long or strong one shattered the fluid into dust). Strength scales the coil overdrive and the pulse sent to FerroGPU,
  but the density kick is capped at the strength-1 level (strength 2 with an uncapped kick turned the liquid into lasting sand). Trace prints `MBALLS burst`.
  Slider ranges narrowed around the user's values at their request, later raised slightly: Magnet 1…2 (default 1.4; the dial's tanh limit is flat by 1.8, so 1.8…2 adds 0.75·(m − 1.8) on top), Centre pull 0.25…0.75 (0.45), Fluid up to 5 (≈ 77k particles, fluid ~15 ms in the harness).
  **Performance/smoothness pass:** the coils' field is built once per frame into a 32³ texture (H, ∇|H|) and sampled per particle (was
  13 coils × 7 evaluations per particle per substep); the dipole forces and the velocity update are folded into `fe_final` (one neighbour loop,
  dipole force applied next substep; `dip` is reordered with the sort); substeps 1/120 s (stable with the user's settings, Fluid 3 = 52k
  particles: fluid 16.4 → 10.6 ms). Smoothness: particles are splatted at Laplacian-smoothed positions (`spos` = mix(p, neighbour mean, 0.6))
  and the 128³ volume gets a separable [1 4 6 4 1] blur (3 passes). Drawing skips empty 16³ blocks (`occupancy`, marked in `fe_splat` incl.
  the blur's reach, fragment buffer 3 — the name `occ` clashed with the AO variable in the shader). Harness at 40k: volume 2.7 ms, raymarch
  1.3 ms alone; the rest is the solver (~1.3 ms per iteration per substep). The rest of the frame (bloom, composite) is ~9 ms in the harness.
  **"Less wavy, more surface tension"** (user): Akinci curvature term (normal n = h·Σ∇W/ρ0, computed in `fe_lambda`, force −curv·Σ(nᵢ−nⱼ)
  in `fe_final`, curv 1; 2+ got lumpier) + the **wide 9-tap blur** of the volume (`blurPasses = 2`, by far the biggest visual win). More
  cohesion barely helped; stronger position smoothing (0.9) opened holes. Remaining pits/foam come from bursts (they heal in ~0.5 s).
  Overrides: `curv`, `blur` (1/2), `smooth`. Compare surfaces with `mbBurstAmt` 0 (bursts make runs incomparable).
  d0 = 0.017 (Fluid 2.1 ≈ 40k particles). The raymarch scale is floored at 0.5 for metaballs: the fluid's GPU load made the pass look slow
  and the scale fell to 0.2 (user: "very pixelated").
  **At rest = a perfect sphere** (user: no audio → "absolutely not moving" and "perfectly smooth sphere, this is what i mean by
  tension"). PBF never settles by itself (mean speed ~0.4 at rest: half-solved constraints; drag doesn't help, 4 iterations only halve it).
  A dead band that froze slow particles was tried and rejected ("stops in a weird shape"; code kept, off: overrides `still`/`stillBase`).
  Now: `MetaballsViz` counts how long every coil current + pulse is < 0.05; `rest` rises 0 → 1 from 0.3 s to 2.5 s of quiet (smoothstep)
  and drops in 0.12 s at the first current. FerroGPU at rest: home × (1 + 4·rest), drag + 8·rest (the liquid gathers into a ball);
  `metaballsFrag` blends the density into an analytic sphere (`ShaderModeU.p2` y = rest, z = radius, w = centre y), radius =
  cbrt(3n/4π)·d0·1.02 (`restScale`, calibrated against the settled particles' silhouette; `restDraw` 0 hides the sphere for that).
  Trace: `MBALLS f= rest=`, `FERRO vmean=`.
  **Black needs coverage**: `CompU.mediaKal.z = 1` (set for metaballs and Splashs) makes the scene's alpha cover the background colour.
- **Infinity** (`VizMode.infinity`, `Visualizers/InfinityViz.swift` + `infinityFrag`, one raymarch pass in `rmTex`, `mediaKal.z = 1`):
  a flight between endless Mandelbox castles, inspired by photism.app's Citadel (own code). First version (2026-11-16) had three scenes
  (Diamonds = log-polar gem rosette, Castle, Heads = SDF busts); the user had Diamonds and Heads removed the same day ("only leave castle"),
  they are in git history only if committed before (they were not: see the session scratchpad `inf.metal` for the old shader).
  Motion = speed with a base (0.3 + Motion: the user keeps Motion at 0) pushed by the bass; Detail = Bands (`infBands`; levels relative to
  each band's own average / peak like Orbs, sent as the float list). Mandelbox scale 2…2.9 = Fold; a kick pushes the fold one way and it
  eases back (Morph; the slider's 0…1 = 0…0.3 of the first version, above that was "way too crazy"). Mirrored tiling with half period =
  box half-size 2(S+1)/(S−1) + 0.22: the camera flies in that always-free gap (inside the box is solid = black). The camera's z is kept
  as a fraction of the period (`castleU`): in world units every kick rescaled its place and the scenery lurched back and forth.
  `infPattern` (Seams / Contours / Circuit / Blocks / Plain: all drawn from the orbit trap = min r², min axis-plane distance, fold index),
  `infSurface` (Solid / Reflective = one reflection ray into the castle or the env map / Glass = up to 3 surfaces along the ray, walking
  through the solid with fixed steps since the DE is useless inside / Milky = the same with thickness scattering and depth jitter),
  `infSpeakers` (drivers in a 0.3 grid of the folded coordinate, 45 % of cells; where a driver's sphere cuts the surface the SDF is
  displaced into cone + cap + surround and pumped by its band; march step ×0.75 then). Uniforms: p0 = pattern, scale, minR², iterations;
  p1 = half, surface, speakers; `view*.w` = eye; `M.bass` = chrome tint, `p2.yz` = chrome turn / blur. MSL: reference parameters need
  `thread float &x` (no `out`). `rmVariant` restarts the adaptive scale when the surface changes. `AUDIOWATCH_TRACE=1` prints `INF …`.
  **Structure** (`infStructure`, `p2.w`; 2026-11-17, user: "another dropdown … what kind of structure"): Castle = Mandelbox scale 2…2.9;
  Vault = Mandelbox scale −1.5…−2.4 (×2.2 in size). 2026-11-17 later: the user kept Castle + Vault, Sponge / Shards (Menger variants)
  were removed, and asked for "actual different types of core structure": **Bubbles** = Apollonian sphere inversion (fract fold + `reach`/r²,
  `reach` 1.08…1.3 = Fold; low values are sparse spikes on flat sheets, high = round arches), shells thickened by 0.004, clipped to the 4.4 box.
  **City** = `infCity`: lots 0.5775 (16 per period), street every 2nd lot line, setback towers (3 tiers over 1.3, a mast over 2.8), 8 % squares,
  height = Fold (`reach`) + band level × `p0.z` (= Morph slider × 2 × Reach); x/z from p (not mirrored), y mirrored, another city per
  ground plane (`m`); z hashed mod 256 lots and the camera wraps after 16 periods (`wrap` in InfinityViz), so the jump is seamless.
  Steps are capped at the lot edge + 0.035 (neighbours may be taller) unless above `hMax` (the tallest tower possible now): without that cap
  the City cost 1.6× Castle, with it less than Castle. trap: x = height² (Seams = floor bands), y = window rectangles (Circuit = lit windows), z = tower hash.
  `p0.y` = per-fold scale for `infLod` (2 for Bubbles). All write the same trap triple, so every Pattern works on each.
  Bubbles barely morphed (a kick moved its strength by ~0.015): now + 0.6 × the kick's fold push + 0.12 × Morph × the smoothed bass push.
  A raymarched Forest structure was tried and removed the same day; the user wanted AAA detail → its own mode (Forest, below).
  Seen in stills only; Vault is mostly a flat patterned face with pits at Fold 0.4.
  **Performance pass** (user: "quite jaggy", then "improve the performance rather than making visual quality worse"). The jaggies were
  the adaptive scale sitting near 0.2: the castle fills every pixel with ~23 DE evaluations × 8 folds. What worked, measured back-to-back
  at a pinned scale (timings between sessions differ 2-3× with machine load: only compare runs made together, `med.sh`-style medians):
  (1) `infStart`: the camera's gap slab (±0.18 around the mirror plane) is empty by construction, rays jump to its exit (horizon rays
  crawled along it for 100 steps): −25 %. (2) **Quarter-size pre-pass** `infinityPreFrag` → `infPreTex` (r32Float, same command buffer):
  one cone per 4×4 block marched until the castle is within 1.5 of its pixels; the main pass starts at the min of the 4 nearest texels
  (`gather`) × 0.99: −27 %, and exact (debug view 7: 99.99 % of pixels identical once both marches converge; the differences before were
  the old path running out of steps at the horizon). (3) Reflection ray: 18 steps, pixel footprint × (3 + 16·Blur) for hit test and
  `infLod`, 3-tap normal: mirror + speakers 28 → 17 ms at 0.4. (4) Speakers: one hash per cell, step factor 0.82.
  What did nothing (removed): skipping folds when a coarse DE says "far", stretching steps along grazing walls. `infLod` (fewer folds for
  far walls) is kept: no speed at Depth 8, less shimmer. Scale floor 0.4 (0.3 glass / milky) in `updateRaymarchScale`.
  Debug: `AUDIOWATCH_INF_STEPS=1` step count / hit / depth view, `5` no pre-pass (timing A/B), `7` pre-pass error view.
  Harness at 3600×2250 (bigger than the user's 3024×1964 screen), pinned 0.4, same session: solid 6.5 ms, solid + speakers ~9,
  reflective 10.5, reflective + speakers 17, glass ~30 (the glass layers get no pre-pass and are still the heavy ones).
  **Example patch dialog** (node editor) "not really showing anything": the system runs in light mode and the sheet's backdrop is the
  system's, so the dark-scheme white text sat on a light sheet; the dialog now has its own dark background (not seen live).
  Checked in stills only. Cost in the (loaded) harness at scale 0.2: solid ~6 ms, reflective ~9, glass / milky ~26: the glass modes are
  heavy. Speakers sometimes show as saucers where a driver's sphere cuts a thin feature. The user asked for "new modes" from photism.app
  and so far named only this one.
- **Forest** (`VizMode.forest`, 2026-11-17, user: "remove forest from infinity and make new mode forest"; reference
  github.com/Braffolk/fable5-world-demo, "make it our own"). **Rasterised, not raymarched**: `Visualizers/ForestViz.swift` (music,
  flight, sun/sky colours) → `ShaderModeDraw.forest: ForestInput` → `Metal/ForestGPU.swift` draws the whole frame into `rmTex` inside the
  raymarch command buffer (so the adaptive scale and timing work as for the other modes; floor 0.5, max 1 since it has 4× MSAA).
  MSL in `Metal/ForestShaders.swift` (own library), assets generated in code in `Metal/ForestAssets.swift`.
  World: metres, y up, flight towards −z, everything periodic in z with 8192 m (noise texture tiles, `valley(z)` = sum of sines
  with whole periods, tree hashes use the cell z mod 2048) so the camera's z wraps without a jump; positions camera-relative.
  - Noise: 1024² rgba32Float periodic Perlin (32 cells) with its **analytic derivatives** in g/b (smooth exact normals from bilinear
    samples) + a second noise in a. Terrain = eroded fbm (iq) → hills (180·u²) beyond a meadow and river bed along `valley(z)`
    (also in `ForestViz.valley`: keep equal). Vertex height always 8 octaves (same everywhere: no cracks); fragment normals up to 11.
  - Terrain mesh: CDLOD on the CPU (`selectNodes`: 16 m leaf patches, ranges 40 m × 2^L, 3×3 roots of 4096 m), 32² grid per patch or 16²
    over a quarter drawn at the parent's level; vertex shader morphs odd vertices near a level's outer range. Non-indexed, vertex_id → grid.
  - Trees: compute `forestScatter` (one thread per 4 m cell, ±900 m): density noise, no trees within 12 m of the river, slope < 1, species
    by height, frustum cull (planes widened 25 m for shadow casters), 4 LODs (45 / 160 / 380 m; beyond 380 m up to 60 % thinned out), atomic
    counts → `forestFinalize` writes the indirect args (bark + leaves per species × LOD, 16 draws). Spruce = trunk + whorls of drooping
    frond cards (2 crossed per branch near), broadleaf = trunk + limbs + crossed leaf-cluster cards; leaf normals spherical (soft volume).
    Foliage = alpha to coverage with the alpha sharpened by fwidth (keeps far density). Atlas 1024×512 (frond | leaves).
  - Light: 2 shadow cascades (2048², ±45 m ahead, ±420 m), texel-snapped; near cascade = trees only, far = coarse terrain (range × 0.25)
    + leaf cards, LOD 2/3 cast as solid cards (no alpha test). Sky drawn **last** where the depth is still cleared; trees before the
    terrain (early-Z). Reversed-Z infinite projection. Filmic (ACES fit) + gamma in each shader.
  - Music: bass gusts roll over the canopy (vertex bend × a travelling wave), treble = leaf flutter + water roughness, each tree's band ×
    Band light brightens it, the beat lifts the sun 12 %. Motion / Reach = speed (2.5 + 10·Motion m/s, bass push × Reach), like Infinity.
  - Settings `forTrees` (Detail), `forSun` (elevation 2 + 55·sin(πt)³: most of the range is low sun), `forMist`, `forClouds`, `forWind`,
    `forGlow`, `forTint` (palette into sun / sky / mist). **Brightness** goes into the Forest's exposure and **Glow** × 0.2 (Renderer): the
    user's look (Brightness 0.9, Glow 0.75, made for dark scenes) turned the daylight picture pure white.
  - Cost (harness 3600×2250, scale 0.5, noisy): ~9 ms min / ~14 median; shadows ~3.5 (were ~12 with full terrain in both cascades),
    leaves ~4, terrain ~2.5, sky ~1-3. `AUDIOWATCH_FOREST_SKIP=shadow,terrain,bark,leaves,water,sky` drops passes for A/B timing.
  - **Round 2** (user: "DO next steps. Wind movement is unnatural… edge from water to land too straight… bird swarms… on audio input"):
    - River: its middle line = valley + 6 m of noise, width 6.5…10 m (noise), the bank's distance frayed by two noise octaves (7 m, 2.3 m):
      `riverDist` in the shader, `ForestTerrain.riverCenter / riverWidth / height` on the CPU (`Metal/ForestTerrain.swift` owns the noise
      array now; ForestAssets only uploads it — keep the CPU formulas equal to the shader's). The camera follows `riverCenter`.
      Shore: thin pebble strip, wet darkening, a dark river bed; foam only within ~3.5 cm of the waterline (at 18 cm it was a wide grey band).
      Water mirrors the tree wall along the banks (the reflected ray's height where it reaches the tree line vs. ~13-18 m treetops).
    - Wind: a gust field = noise drifting downwind (neighbouring trees move alike), × (0.3 + 1.2 × the bass gust, smoothed with omega 1.6
      on the CPU; 6 made the trees twitch); trunks lean + rock at their own frequency (0.42 Hz × (12 m / H)^½), branches bob with a phase
      travelling through the crown, only broadleaf leaves flutter (small). The old version: one sine shear for all trees + 7 Hz flutter.
    - Grass: compute `grassScatter` (0.32 m cells, ±38 m, thinner at the edge and under trees, none in water / on steep ground) → indirect
      draw of 3-blade clumps (27 vertices), same gust field, colours matched to the meadow. Costs ~nothing measurable.
    - Birds (`forBirds`, panel "Birds"): CPU boids in ForestViz (`Flock`: separation 2.4 m, neighbours 8 m, goal sweeping over the river
      ~70 m ahead at 26 m up, ground avoidance via `ForestTerrain.height`, leave after 14-28 s). A hit (onset > 0.6) starts a flock
      (30…290 birds by Birds × hit strength; cooldown 6-30 s; one comes anyway after 40-80 s), hits during the flight swerve it.
      Drawn as 7-triangle birds with beating wings (outer part lags; glide when diving). The camera's z wrap moves them along.
  - **Round 3** (user: "visual quality can be improved more… floor and water and trees… keep performance. Also trees are changing,
    appearing/re-appearing while they're in view"):
    - **Popping**: caps were never hit (`AUDIOWATCH_TRACE` prints `FORESTGPU trees=[per species × LOD] grass=`). Causes were the hard
      LOD swaps (each LOD was also grown from a different seed = a different tree: now one seed per species), the hard far thinning
      and the scatter edge. Now `TreeI.f` = (threshold, side, visibility): within ±6 / 16 / 35 m of the 45 / 160 / 380 m boundaries a
      tree is emitted into both LOD lists and `fadeKeep` (interleaved gradient noise) draws complementary pixels of the two meshes;
      thinning and the far edge fade the same way. Bark and leaves (and rocks) use alpha to coverage with alpha-to-one, so the dither
      costs no discard. Shadows: only the near mesh (side +1) and visible (> 0.5) instances cast.
    - Trees: per-cluster leaf tint (TreeV p.w = 1 + tint), slight sheen on broadleaf, bluer darker spruces.
    - Ground: 45 m dry / lush patches, a meadow glow towards the sun, flowers (5 % of grass clumps: white / yellow / violet tips).
      Shore: pebbles = nearest of 4 jittered points in a 12 cm grid (only some cells hold a stone, the rest wet sand), within 60 m.
      Underwater the river bed colour must win over the "rock on steep slopes" rule (that showed through the shallows as a grey band).
    - Water: three ripple layers (one stretched along the current), clouds in the reflection, glare + small glitter, no glare where
      the bank's trees are mirrored.
    - Rocks: `rockScatter` (8 m cells, 4 candidates each, ±320 m; river stones on the banks, mossy boulders on slopes / under trees),
      icosphere mesh with lumps, fractured flat cuts and bumps (`ForestAssets.rockMesh`), sunk deeper on slopes, near shadow cascade.
    - Light shafts: the sky pass writes alpha 0.98 (everything else 1, alpha-to-one on the A2C pipelines) → quarter-size mask of bright
      sky near the sun → 48-tap radial blur towards the sun → added to the picture; strength ∝ low sun × sun on / near screen × beat.
    - Timing could not be measured cleanly in that session: the GPU was busy with something else (Castle, 22-27 ms before, took 107);
      shafts + rocks looked like ~2 ms in a same-moment A/B. `AUDIOWATCH_FOREST_SKIP` also takes `grass`, `rocks`, `shafts`.
  - **Performance pass** (2026-11-17, user: "improve performance without making visual quality worse"): rm median 20 → 11.8 ms
    (harness 6016×3334, scale 0.5, same-session A/B). What worked: noise texture rgba32Float → **rgba16Float** (vImage
    conversion; ~15 %); `terrain()` skips the fbm in the river bed / banks (ae ≤ 1.6·width and |x − valley| ≤ 30: hills and
    meadow bumps are multiplied by zero there, so it's exact) and hands back its river distance (terrainFrag / waterFrag no
    longer call riverDist again); clouds stop adding octaves once the rest (≤ 2a, noise is within ±1) can't reach the cover's edge;
    scatter kernels reject cells with a conservative column-vs-frustum test (`columnOutside`) before any noise (compute 0.52 →
    0.23 ms); terrain grids are indexed (16-bit) instead of 6 vertices per quad. **Tried and reverted:** a depth-only leaf
    pre-pass + depth-equal shading (6.7 → 8.0 ms: the cost of the leaves is the alpha-to-coverage layers, not their shading).
    `AUDIOWATCH_FOREST_PROFILE=1` prints per-pass GPU medians (`FORESTPROF compute= shadow0= m2leaves= m4terrain= …`, stage-
    boundary timestamps; it splits the main pass into stored segments, so the total is a bit above the normal path). Last
    split (ms): leaves ~2, terrain ~1.7, water ~1 (+ resolve), sky ~1.1, near shadows ~1, trees' bark 0.4, rocks/grass 0.45.
  - Not done: spruce silhouettes could be fuller, AO under trees. Seen in stills only; fades, wind, birds and foam only show moving.
- **Landscape** (2026-11-17): `VizMode.forest` is shown as **Landscape** (raw value, `for*` settings and ForestViz keep the old name);
  `landScene` (Forest / City at night) picks the scene. ForestViz hands the City scene to `CityViz` (its own `city` instance).
  Forest-only controls are hidden in the City and vice versa; Mist (= Haze), Band light and Palette tint are shared. The Detail
  slider for the City is `VizMode.cityDetail` (Towers, `cityTowers`), chosen in `SettingsPanel.detailRow`.
- **City at night** (`Visualizers/CityViz.swift` + `Metal/CityGPU.swift` + `Metal/CityShaders.swift`, own library; `ShaderModeKind.city`,
  `ShaderModeDraw.city: CityInput`, drawn into `rmTex` in its own command buffer like the Forest; adaptive scale floor 0.45, may supersample).
  User: "city at night, lights that illuminate and cast shadows, camera travelling through it"; the reference image was for the look
  (dark glassy towers, lit windows, colourful glowing streets), **not** the perspective (it was a floating diorama). Then: "gloomy, with a
  slider … kinda global illumination style. windows way too big. slider for camera height".
  - **One full-screen ray-traced pass**: rays walk a 2D grid of 16 m lots (DDA); blocks = 4×4 lots + a 16 m street (period 5). A lot
    holds one building of up to 3 nested boxes (setbacks) + a spire, or (5 %) a park; a 2×2 quadrant may merge into one tower
    (more likely downtown: `district()` = smooth noise over blocks). All from integer hashes of the world cell; positions are relative
    to the camera's cell (`U.cell`), so floats stay small. Shadows = the same walk towards the light (drones: 24 steps, lightning: 48).
  - Speed: whole blocks the ray passes over are skipped (`blockBound` from the district); `building()` computes geometry only,
    `bldLook` adds id / style / band for shading; rays stop where the haze hides everything (`tFar`); drone shadows only when the
    light's contribution is ≥ 0.004. Integer division in the walk was replaced by `blockOf` (no measurable change).
    `AUDIOWATCH_CITY_DEBUG=1` draws only the walk, `2` skips the lighting (timing A/B).
    Timing (that session the harness was ~4× slower than documented: Infinity solid at 0.4 measured 26.7 ms vs 6.5): City at 0.5 with
    everything on ~35 ms there, walk alone ~19 → roughly 9 ms normally, about the cost of Infinity solid.
  - Camera: down the avenue at x = 4.5 lots (street column 4), y = 3 + 160·alt^1.6 m (`cityAlt`, "Camera height"), pitched down more
    the higher it flies; the user's orbit turns the view as in the Forest. Speed (4 + 14·Motion) m/s × (1 + 1.5·bass·Reach).
  - Music: 8 bands (relative to own average / peak, like Forest) → each tower's band: lit windows below the band's level turn the band's
    palette colour and brighten (meter; Band light = `forGlow`); light drones (`cityLights` × 8, one band each: brightness, speed, height)
    fly along street lines (never inside buildings) and are shadowed point lights + core glow + haze in-scattering (closed form);
    searchlights (`cityBeams` × 4) at crossings ahead, new angles on each beat (glow = closest approach of ray and beam, only if in front
    of the hit); kick onsets → rings of light running out from a crossing ahead (ground emission + lower facades); snare onsets with
    `cityStorm` → lightning (2–3 flickers, random high direction, hard shadows; cooldown shorter with Storm); mids → traffic speed;
    treble → window flicker + puddle ripples; beat → crown lights.
  - Look: windows are procedural per bay (14–30 bays per 16 m lot, floors 2.3–2.8 m; the user found ~3 m windows "way too big"),
    fading to their average when smaller than ~a pixel; crowns on some tall towers' top tier, neon corners on a few. Traffic = pairs
    of head / tail light spots in 4 lanes, smeared towards the viewer on wet streets (brightness normalised without the smear, or they
    vanished). Wet streets: puddle mask + one reflection walk (56 steps, windows at their average). **Gloom** (`cityGloom`): denser,
    greyer haze, low overcast, fewer and dimmer windows, desaturation, exposure × (1 − 0.3·gloom), and bounce-light terms (window
    light spilling onto the wall, the street's warm glow on the lower floors, haze ambient, canyon AO) — a first version made it
    pastel and bright; keep the bounce small. Lightning lifting the haze washed the picture white: the flash mostly lights surfaces.
  - **Facade variety** (2026-11-17, user: "more details varying between buildings, portrait / landscape windows, reflections"):
    `Look lookOf(Bld)` (hashes 21–31 of the owner cell) = window kind (portrait 10–13 bays per lot / landscape 5–7 / square 7–9 /
    curtain wall 20–30), floor height, margins, mullions (centre bar, 3 panes, cross), solid piers every 3–5 bays, louvred plant
    floors on tall towers, spandrel band, wall material (brick / concrete / pale stone / dark), glass tint + reflectivity, shop
    fronts (70 %: 2–3 shops per lot, bars, door, ceiling-lit interiors with shelves, signs on the band, shutters when closed).
    Also blinds, aircraft lights, blade signs, roofs (plant boxes, skylights, parapet, garden terraces, helipad ring).
    Lights go on in **zones** (~6 bays of a floor: dark / normal / busy). Far field: bays and floors fade to their averages
    separately (`farU` / `farV`); a single 2D fade turned distant curtain walls into flat grey slabs.
  - **Window reflections** (`cityReflect`, "Window reflections", `cfg3.z`): glass panes (each tilted by `jit`, so the mirror image
    breaks up) shoot one ray (18 steps, ≤ 350 m, traced only for facades within ~220–310 m, else sky / haze) through the same
    shared reflection block as the wet streets; hits shaded cheaply (no shadows). 0 = the old faint sky sheen only. Cost in the
    harness (scale 0.5, street level): ~+8–10 ms over 20 (any amount > 0); step count barely matters — a 6-step walk cost nearly the same.
  - **Loudness → lit windows** (user: silence = almost all windows off, quiet = a few): `CityViz.lightsOn` = RMS (2048 samples)
    × Gain in dBFS, −70 dB → 0.02, ≥ −12 dB → 1 (smoothstep), on in 0.4 s / off in 1.5 s → `music2.w`; scales `occ` (windows,
    their far averages, spill), open shops and the band meter (× √). Band levels are relative, so without that the meter lit quiet music.
  - **Fly-bys** (`cityFlyby`): extra drones (≤ 2) after the regular ones in the light buffer (now 10 drone slots: DRONES 4…23,
    BEAMS 24…31, `CityGPU.lightCount` 32, `CityViz.maxDrones`): across the next cross street, overtaking from behind or head-on,
    2.5–7.5 m above / 3–7 m beside the camera; interval (2 + 28·(1−f)^1.5) × 0.5…1.5 s, hard hits shorten it. Close passes not seen moving.
  - **Reflection blur** (`cityReflBlur`, `cfg3.w`): cone footprint (`rCone` 0.3·blur added to the reflected hit's fp and to rayGlow) +
    pane tilt × (1 + 2.5·blur) + a small per-pixel jitter (0.04·blur). A big per-pixel jitter (0.22) made speckles (one ray per pixel);
    stars fade out of blurred reflections (`sky(…, stars)`) for the same reason.
  - Seen in stills only (incl. the user's own saved settings, a frame sequence and one lightning frame); motion, drones passing close
    and the shadows sweeping were not seen moving. No mode preview change (the Landscape thumbnail is still the forest).
- **Mode picker** (2026-11-17, `ModePicker.swift`, replaced the Mode `Picker` in the Mode group): a select with the current mode's
  thumbnail; it opens a light popover (`ModeGallery`, forced `.light`): search field (Return picks the first match) + Thumbs / List
  (`AudioViz.modePickerList`), 3-column grid of 4:3 rounded thumbnails with the name below, "Experimental" as a section, scrolled to
  the current mode. `app.textEditing` is on while it's open. Previews: `Resources/modes/<raw value>.jpg` (360×270), made by
  `Resources/make_mode_previews.sh [modes…]` (default settings via `AUDIOWATCH_CLEAN=1` = ignore saved settings, a generated
  40 s WAV, frame 900, per-mode palette / gain / zoom in its `extra()`); build.sh copies them to Contents/Resources/modes.
  A new mode needs a line there and a rerun. `AUDIOWATCH_MODEPICKER_SNAPSHOT=/path.png` (+ `AUDIOWATCH_MODEPICKER_LIST=1`)
  renders the gallery off-screen. The popover opening, hover and clicks were not checked live.
- **Window drag / node pan** (2026-11-17): a mouse-down in the transparent title-bar strip (`locationInWindow.y ≥ contentLayoutRect.maxY`,
  titled windows only) moves the window in `DraggableMTKView.mouseDown`; a double-click there zooms / minimises per `AppleActionOnDoubleClick`.
  The node editor pans with two-finger scroll / the wheel via a local `.scrollWheel` monitor limited to its global frame. Not checked live.
  City **Kick pulses** (`cityPulse`, 0…1, default 1) scales the kick rings' strength and the fog lift (`kickGlow`).
- **City Architecture** (`cityArch`, 0…1, default 0.6, `CityU.cfg4.x`; 2026-11-17, user: "more details to the buildings and a slider … architectural
  details"): the slider is the share of suitable buildings that get each detail (`Look` fields from hashes 32–43 of the owner cell, 0 = the old look).
  Geometry: rooftop penthouse / plant room (box, louvres, door + lamp, lit window strip) on towers, water tank (cylinder on a dark base) on low
  buildings (`Bld.rk/rb/ry`, `Hit.part` 4, `roofBox`); the walk tests `b.bound` (incl. them), shading keeps `b.top`. Helipad roofs stay clear.
  Facade (shading only, in `facade`, fake relief by bending the lighting normal `nB` + albedo; own colours via `ov`): cornice with dentils and
  soffit shadow at every tier top, pilasters, curtain-wall glass fins / sunshades, balconies with railings (some with a lamp), AC units with drip
  stains, fire escapes on brick buildings (platforms, railings, zigzag stairs), quoins, rusticated base + string course, floodlights washing up the
  facade (breathing with the building's band). Every detail fades by `vis(size, fp)` before it aliases.
  Cost: arch 1 ≈ +12 % rm time vs 0 (harness). `AUDIOWATCH_CITY_Z=<m>` pins the camera z for A/B stills. Seen in stills only.
- **City: camera-cell-relative coordinates** (2026-11-17 fix, user: "floor texture seems to move … like cloud shadows"): shader positions are
  relative to the camera's 16 m lot, so any pattern sampled from raw `p` jumps 16 m whenever the camera enters the next lot. The puddle noise
  did. Textures must use `worldXZ(p, U)` (wrapped every 4096 m) with `vnoiseP` (integer-hash noise, lattice period = 4096 × frequency, so
  frequency × 4096 must be whole), or cell-indexed hashes. Same for patterns along facades (`uW`).
- **City cars** (2026-11-17, user: "flat floating boxes slightly above ground … should illuminate light", then "not completely flat"): replaced the
  painted head/tail-light spots (`traffic()` is gone). Glowing boxes 4.4 × 1.7 × 0.74 m hovering 0.38 m up (`CAR_*`), same lanes / 14 m slots /
  hashes as before (`CAR_LOOP` macro, variadic: the body has commas). Hit kind 3 in the walk (street cells, only when the ray is below the car tops),
  so they show in wet-street and window reflections; `carShade` = dim body + light band round the sides + lit top rim; `carLight` = soft area light
  on the road / sidewalks (no light on facades, no shadows). Warm white / red by direction, 20 % palette colours. Not timed; stills only.
- **Harness caution:** never `pkill -f MacOS/soundwatch` (it also kills the user's running app); kill the PID you started.
- **Updater** (`Updater.swift`): on launch (3 s in, at most every 20 h; never in `AUDIOWATCH_*` runs) or *Check for Updates…*
  reads GitHub `releases/latest`, compares `tag_name` (minus `v`) with CFBundleShortVersionString, asks (Install / Later / Skip),
  downloads the `soundwatch*.zip` asset, unzips next to the app, checks bundle id + version + `codesign --verify` (and, when the
  running app isn't ad-hoc, that the new one meets its designated requirement), swaps the bundles, quits; a detached `sh` waits
  for the pid, `open`s the new app and deletes the old copy. Presets live in UserDefaults, so they survive. Translocated /
  read-only locations → opens the release page instead. Headless test: copy the app, lower its version, re-sign,
  `AUDIOWATCH_UPDATE_SELFTEST=1 <copy>/Contents/MacOS/soundwatch` (runs the whole pipeline on the copy, no relaunch).
  **Release tag must be `v<CFBundleShortVersionString>`** and the zip must be attached, or the updater can't install it.
- **Anti-aliasing** (`antialias`, Window group, default on, kept across presets / Reset look): 4× MSAA for frames with shaded triangles
  (before: always); the raymarched modes' adaptive scale may go up to 1.5 (supersampling, reduced by `copyFrag`) when the budget allows,
  else max 1. Lines/dots are soft in their own shaders; the other scene pipelines have no 4× variants, so don't widen the MSAA condition.
- **Signing:** `build.sh` signs with the keychain identity "soundwatch self-signed" (`Resources/make_signing_cert.sh`, one-time,
  needs the user's password to trust it) or `SOUNDWATCH_SIGN_ID`, else ad-hoc. Ad-hoc = new identity every build = macOS asks
  for the audio permission again after each update. codesign refuses an untrusted self-signed cert ("item could not be found").
- Commit only when the user asks. Commit messages so far are short ("update").

## Where things stand (2026-11-12)

Everything up to here is committed on `master` (user commits "killer", "update"). Release prep is done: `./release.sh` makes
`build/soundwatch-<version>.zip` (~13 MB, mostly the 4 env maps); the user creates the GitHub release themselves (`gh` is logged in,
but only run `gh release create` when asked).

Done in the 2026-11-11/12 sessions: README (screenshot, download button, Buy Me a Coffee), app icon (`make_icon.swift`), universal
build, corner buttons + intro overlay, 15 built-in presets (fresh install starts on Acid Garden), foldable settings groups with
icons (all closed by default), creative controls (Colours morph, Intensity), film grain size, preset auto-loop on the beat,
Orbs mode (chrome metaballs), Chrome surface look (replaced "Shaded") with HDR environments, Blur, Turn and Tint.

Not yet confirmed by the user / possible next steps:
- Orbs motion and blurred inter-reflections were last changed after the user said they barely reacted; confirmed only in
  stills with the user's own settings (frames 0.25 s apart clearly differed). Grain at high Blur may need more rays.
- Auto-loop switches presets instantly (no crossfade); offered a blend if it feels abrupt.
- The user's own presets 018/019 (Desktop photos + node patches) were left out of the built-ins and not renamed.
- Diamond Movement responsiveness (~0.4 s glide); presets saving the camera view — never explicitly confirmed.
- Ideas (nothing agreed): a light "paper" background mode, text layer, several media layers, MIDI/OSC input nodes,
  recording/exporting the output.

## 2026-11-14/15 session (uncommitted at the time of writing; the last commits are "real metaballs", "fluids", "good")

- Real Metaballs rebuilt as the GPU fluid (`FerroGPU`, above): magnets on a sphere, Centre pull, Bursts (strength + threshold),
  surface-tension/smoothness pass, at rest a perfect sphere. User reactions: "quite sick", bursts "sick"; the cymatics fix confirmed live.
- Oscilloscope Time window now 1…300 ms (was 5…300; also the node range).
- Cymatics diagonal fixed (see Cymatics modes). Vectorscope "only one line": the code is fine with stereo input (tested with a 220/330 Hz
  L/R WAV); live L = R was not explained yet. Added the mono flag in the FPS overlay and the last-buffer tap read; waiting for the user
  to report whether the overlay says mono with stereo music.
- Anti-aliasing setting (Window group), see Conventions.
- Not done: no commit, no v1.3 release (only on request). Ideas left open: a round Chladni plate (real circles), less foamy bursts,
  Rosensweig spikes on the metaballs, per-substep sorting for more fluid speed.

## 2026-11-12 performance / quality / latency pass (uncommitted; checked in stills and timings only, not yet by the user's eye)

- Dots (Sphere dots, Cymatics/Flow points) are point sprites (`makeDot` / `dotFrag`, slim flat varyings); quads are only `hw + 0.5` px
  wide; Flow streaks use the slim `StreakOut`. The GPU cost of millions of primitives is the tiler, so keep per-vertex output tiny.
  A compute-shader splatter was tried and was slower (random atomic writes) - don't retry it. A fragment can't read `[[point_size]]`.
- Flow streak length is time-based (`d.streak` ∝ 1/dtScale): per-frame length made slow frames draw longer streaks → even slower frames.
- Glass / Diamond / Orbs render into `rmTex` at an adaptive scale (`Renderer.updateRaymarchScale`: own command buffer so the pass is timed
  alone, budget 3.3 ms for 120 fps else 9.5 ms, drops at once, rises slowly and not above a remembered ceiling - without the ceiling it
  hunted up and down every ~30 frames). `AUDIOWATCH_RMSCALE=0.5` pins it; PERF lines print `rm=` and `scale=`. Upsampled bicubic
  (`copyFrag`). Orbs and Diamond have antialiased silhouettes (no `fwidth` in Diamond: it made every pixel run the full trace).
  `ShaderModeU.p2.x` = target pixels per point.
- Bloom is a pyramid (`box4Frag` → `bloomDownFrag` → `bloomUpFrag` / `bloomTopFrag`); soft focus and streak start from the ¼-size copy.
  Composite dithers to 8 bit. Frames with shaded triangles use 4× MSAA (`*Pipe4`, `msaaTex`).
- Field: simulation and dot building run on all cores (points style). Caps raised: particles 8M, sphere 4M, field 1M, orbs 16.
- **Sound → picture delay** (measured from a hit entering the ring until the analysis shows half of it; the user's FFT is 16384):
  kick 157 → 27 ms, snare 44 → 20 ms, beat pulse 35 → 16 ms, buffering 17 → 6 ms. How:
  - `Analyzer` transient gain (only with Low latency on): each part of the spectrum is scaled by (band energy over the last few chunks) /
    (band energy as the FFT window weights it), for low / mid / high bands from the 256-sample chunks. Steady sounds: ratio 1.
    `AUDIOWATCH_NOGAIN=1` turns it off. `processColumns()` now runs before the FFT (the gains need the newest chunks).
  - **Never shrink the aggregate device's IO buffer.** 128 frames was tried: the aggregate wraps the real output device, so
    the speakers ran at 128 frames for every app and playback glitched (shipped in 1.1/1.2, removed). Analyzer margin = burst × 1.25 + 2 ms.
  - Renderer: 2 frames in flight (was 3) and the drawable is taken before the audio is analysed.
  - **A/V sync** (`Analyzer.update`): the tap hears audio before the speaker plays it (`AudioRing.outputLatency` = device + safety +
    stream latency + buffer; built-in MacBook Pro speakers 28 ms at a 512 buffer). The picture's own path is estimated as buffer
    margin + 8 ms analysis (Low latency; 35 ms without) + 1.5 smoothed frame intervals ≈ 26 ms, measured: a snare shows ~5 ms after
    it's read. Hold-back = max(0, outputLatency − own path) + the user's `avSync` (ms, slider in Response, −30…+200, kept across
    presets / Reset look); total clamped ≥ −margin (can't show audio that hasn't arrived). Built-in speakers → auto ≈ 0, so the
    slider does the work there; Bluetooth → latency − 26 ms. The old rule (hold only above a fixed 45 ms) predated the latency pass.
    TRACE lines print `hold=` and `out=`. Untested on a real Bluetooth device; the user's preferred offset isn't known yet.
  - To measure: a WAV with a kick every second, `AUDIOWATCH_TRACE=1` prints `LEVEL written= readEnd= snare= bass= beats=` per frame.
- Snapshot runs draw from a timer, so the harness works with the screen locked (GPU times are then ~1.5× higher than on a live display).
- Not done: Glass per-pixel cost unchanged (only the adaptive scale helps it); Flow lines at 4M is still ~130 ms.

## 2026-11-15 session: released v1.3

Committed, pushed and released as v1.3 (`gh release create v1.3` with `build/soundwatch-1.3.zip`, at the user's request). In it: everything
from the 11-14/15 session plus: mode renamed Ferrofluid (Band slider removed, shuffled bands, up to 24 magnets, Fluid up to 5), double-click
reset on sliders and labels, preset stepping (← / →, chevrons), Nodes as a bottom panel, hints removed under the mode / warp / media controls,
Mode above Quick controls. `StickmenViz.swift.disabled` is a leftover of an undone session (doesn't compile: its `stick*` settings are gone).

## 2026-11-17: released v1.41 (City at night: loudness-lit windows, Fly-bys, Reflection blur; versions now have two decimals — the updater compares parts as integers, so always 1.50, never 1.5)

## 2026-11-16 session: released v1.4 (at the user's request; checked in off-screen stills only, nothing clicked live)

- **Node ports follow a dragged card** (`ports` used the stored position while wires/cards used `node()` with the drag offset).
- **Node editor toolbar:** `+` menu (same list as right-click; drops in the middle of the visible grid) and **Add example patch…**
  (sheet `ExamplePatchDialog`; `ExamplePatch.all` in NodeGraph.swift, 5 patches; appended below the existing nodes, patch switched on,
  view panned to it). `AUDIOWATCH_NODES_EXAMPLES=1` with the nodes snapshot shows them.
- **Detach** (`app.settingsDetached` / `app.nodesDetached`, UserDefaults `AudioViz.settingsDetached` / `.nodesDetached`): the button at the
  top of the settings panel / in the nodes toolbar moves them into an `NSWindow` (`DetachedPanel.swift`, frame autosaved) and back.
  `ContentView.syncDetached` opens/closes the windows from the flags; `showSettings` / `showNodes` (S / N) still mean "visible", the red
  button hides. Detached windows stay open (floating) in overlay mode; closing the main window closes them. The intro's sidebar tip is
  hidden while the settings are detached.
- **Always overwrite** (first settings group, closed by default): `owOn` + `owRed/Green/Blue` + `owOpacity`, kept across presets / Reset
  look; applied render-time in `VizEngine.prepare` (`applyingOverwrite()`), so the look's own `bg*` values stay untouched. The Window
  group's Background / Opacity are greyed while it's on.
- **Input source** (`audioInput` = device UID, "" = system audio; `audioInputName`; kept across presets / Reset look; picker at the top of
  Response): `SystemAudioTap.startInput` runs an IOProc directly on the input device (`AudioRing.write(_, first: true)` = first stream /
  first two channels; output latency 0). Needs the microphone permission (`NSMicrophoneUsageDescription`, `AVCaptureDevice.requestAccess`).
  A device-list listener restarts capture when the chosen input comes back and refreshes the picker (`AudioInputs.changed`).
  **Not tested with real input**: the terminal has no microphone permission, so only the device list and the UI were checked.
- The repo folder was moved (was `temp-work/audio-analyser`): a stale `.build` fails with "PCH was compiled with module cache path…"; delete `.build`.
- README: 2-column grid of the demo GIF + three screenshots (`docs/shot-*.jpg`).
