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
- `AUDIOWATCH_NODES_SNAPSHOT=/path.png` saves a picture of the Nodes window (wait ~9 s).
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
| `AudioWatchApp.swift` | App, menus, windows (main + `Window("Nodes", id: "nodes")`) |
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
- **Settings groups** fold (`FoldSection(title, icon:)`: SF Symbol left, bold title, chevron right, contents in a darker rounded box); state per title in `AudioViz.settingsGroupState.v3`, all closed by default.
  The panel is a `ScrollView` + `VStack`, **not** a grouped `Form`: Form rows keep a minimum height, so a group couldn't really shrink.
  Folding animates `FoldReveal`/`RevealLayout` (height × progress, clipped, top pinned): open = insert at 0 then animate to 1 on the
  next runloop; close = animate to 0, remove in the `withAnimation` completion. A removal *transition* doesn't work here (the box
  stays full height while the next group slides over it).
- **Sidebar snapshot:** `AUDIOWATCH_SIDEBAR_SNAPSHOT=/path.png` (+ `AUDIOWATCH_SIDEBAR_OPEN=1` for all groups open) renders the
  settings panel in an off-screen window, saves it and quits. Mid-animation frames can only be checked in a standalone prototype.
- **Main-thread rendering:** `Renderer.draw` runs on the main thread; it skips a tick (no blocking wait) when both frames are still
  in flight, so the sidebar keeps scrolling in heavy modes. Settings saves are debounced (0.4 s, flushed on quit).
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
  settings `mbFluid` (= Detail, volume ∝ Fluid^0.75), `mbMagnet` (the dial), `mbMagnets` (3…13 coils on a Fibonacci sphere of radius 1.6 around
  the glass sphere, each pointing at the centre), `mbHold`, `mbBand` (rotates which coil gets which slice of 40 Hz–16 kHz, log-spaced), `mbLag`).
  References: the user's videos `_input/videoplayback.mp4`, `_input/ferro.mp4`. **History:** CPU particle fluid (rejected: jittery, same-size
  bubbles) → parametric blob `FerroBlobSim` (rejected: "always the same shapes", too flat) → CPU thin-film fluid (fragile, slow) → 2026-11-14 the
  user chose a real fluid on the GPU with magnets on a sphere in 3D. Old sims are in the session scratchpad `old/`.
  **FerroGPU** = position-based fluid (Macklin & Müller), d0 = 0.017 → ~23k particles at Fluid 1, h = 2 d0, fixed substeps 1/180 s (a tiny
  first-frame dt blew it up: PBF velocity = Δx/dt), 2 Jacobi iterations; once per frame a GPU counting sort by cell (scan of cell counts) - the
  shuffled order made neighbour reads random (~99 ms → ~6 ms); bucket grid (cap 16) per substep. Forces: gravity 0.08 (the user: liquid in
  liquid, near-neutral buoyancy), drag, XSPH 0.3, Akinci cohesion 15 + **surface tension inside the solve** (negative pressure × 0.7; explicit
  cohesion ≥ 100 shattered it into sand, tension 1.0 too), coil dipole fields (softened, coilW 0.5, normalised |H| = 1 at the centre for one coil),
  Langevin M, Kelvin M∇|H| (kelvin 0.6), dipole–dipole between neighbours (0.25), clamps maxAccel 40 / maxVel 4 (strong fields collapsed it to a
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
  **Bursts** (`mbBurst`, default 0.35): the user liked what happens when Fluid jumps (new particles inside the old ones → over-dense → the
  pressure solve blows it apart) and wanted music to do that "sometimes". Per coil a hit = envelope jump above a 50 ms follower, relative to
  its peak; only the hardest one fires, cool-down 2.2 − 1.6·Bursts s; it overdrives that coil (+1.5 × pulse, τ 0.12 s) and multiplies the
  density target by 1 + 0.22·pulse⁴ (a short kick; a long or strong one shattered the fluid into dust). Trace prints `MBALLS burst`.
  Slider ranges narrowed around the user's values at their request: Magnet 1…1.8 (default 1.4), Centre pull 0.25…0.65 (0.45).
  d0 = 0.017 (Fluid 2.1 ≈ 40k particles). The raymarch scale is floored at 0.5 for metaballs: the fluid's GPU load made the pass look slow
  and the scale fell to 0.2 (user: "very pixelated").
  **Black needs coverage**: `CompU.mediaKal.z = 1` (set for metaballs and Splashs) makes the scene's alpha cover the background colour.
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
