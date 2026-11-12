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
| `SettingsPanel.swift` | Settings sidebar in foldable groups (`FoldSection`): Presets (+ auto-loop), Mode, Creative controls, Colour, Response, Shape & motion, Feedback & beat, Post-processing, Media, Window |
| `Camera.swift` | Orbit camera |
| `Visualizers/*.swift` | One file per mode family (Canvas = mushrooms etc., Scope, Sphere, Halo, …). `ShaderModesViz.swift` = Membrane / Spectral Fan / Glass Stack / Diamond / Orbs: CPU keeps the music state, a full-screen fragment shader draws them (`ShaderModeUniforms` ↔ `ShaderModeU`) |
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
- **Creative controls:** `colourMorph` (computed: palette index + `paletteMix` blend toward the next palette, wraps) and
  `intensity` (−1…1 macro, applied in `VizEngine.prepare` via `VizSettings.applyingIntensity()` after the node patch, render-time only).
  Anything that draws palette colours must use `s.effectivePalette` / `s.effectiveInk`, not `s.palette.palette`.
- **Intro overlay** (`IntroOverlay` in ContentView): `app.startIntro()` (first launch via `AudioViz.introSeen`, the ? button, Help menu) also opens the settings sidebar; the overlay covers the canvas only and scales its cards to the canvas size.
  Debug runs (any `AUDIOWATCH_*` input var) never show it or mark it seen.
- **Capturing SwiftUI UI:** `NSView.cacheDisplay` on the main window silently drops some SwiftUI layers (top-aligned views
  came out missing); `ImageRenderer` on the view itself gives the true layout (native controls show as placeholders).
- **Settings groups** fold (`FoldSection(title, icon:)`: SF Symbol left, chevron right, contents on a slightly darker row background); state per title in `AudioViz.settingsGroupState.v3`, all closed by default.
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
- Commit only when the user asks. Commit messages so far are short ("update").

## Where things stand (2026-11-12)

Everything up to here is committed on `master` (user commits "killer", "update"). Release prep is done: `./release.sh` makes
`build/soundwatch-1.0.zip` (~13 MB, mostly the 4 env maps); the user creates the GitHub release themselves (`gh` is logged in,
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
