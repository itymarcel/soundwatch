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
open build/soundwatch.app       # normal launch (quit the running copy first)
swift Resources/make_icon.swift _input/icon.png   # regenerate Resources/AppIcon.icns (+ AppIcon.png) from square artwork
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

## Code map (`Sources/AudioWatch`)

| File | What it is |
|---|---|
| `AudioWatchApp.swift` | App, menus, windows (main + `Window("Nodes", id: "nodes")`) |
| `ContentView.swift` | Main view + HUD buttons |
| `SystemAudioTap.swift`, `AudioRing.swift`, `Analyzer.swift` | Audio capture → FFT bands, loudness, beat, onsets, pitch |
| `VizEngine.swift` | Per-frame `prepare(settings:)`: analyzer update, then `NodeRuntime.apply` → modulated settings `rc.s` |
| `Settings.swift` | `VizSettings` (everything saved/presets, incl. node graph), enums, `AppState` |
| `SettingsPanel.swift` | Settings sidebar: Presets (top), mode settings, Post-processing, Media layer/transform/motion |
| `Camera.swift` | Orbit camera |
| `Visualizers/*.swift` | One file per mode family (Canvas = mushrooms etc., Scope, Sphere, Halo, …). `ShaderModesViz.swift` = Membrane / Spectral Fan / Glass Stack / Diamond: CPU keeps the music state, a full-screen fragment shader draws them (`ShaderModeUniforms` ↔ `ShaderModeU`) |
| `Metal/Renderer.swift` | Frame loop: media blur → (Glass raymarch ⅓ res, Diamond raytrace ½ res) → scene → feedback → bloom / soft-focus / streak blurs → composite |
| `Metal/Shaders.swift` | All MSL source (runtime-compiled). `CompU` must match Swift `CompositeUniforms` in `FrameBuilder.swift` field-for-field |
| `Metal/MediaLayer.swift` | User image/video → texture (AVPlayer muted + looping), media motion (drift, spin, wander, shake, beat jump) |
| `Metal/DebugSnapshot.swift` | The env-var snapshot harness |
| `Nodes/NodeGraph.swift` | Node model, node kinds, `ModParam` list (what can be modulated), `NodeRuntime` evaluator |
| `Nodes/NodeEditorView.swift` | Node editor UI (grid, wires, cards, scrub/number fields) |

## Conventions & gotchas

- **Adding a modulatable parameter:** add it to `VizSettings`, then a `ModParam` in `NodeGraph.swift`
  (mark `cyclic` for angles/hues so they wrap instead of pinning at the range end; `isLog` for scale-like).
- **3D modes:** view matrix order is `rotX(modeTilt) * rc.camera.rotation * …` (tilt before camera = proper turntable).
- **Single-key menu shortcuts** are suppressed while a text field is active via `app.textEditing`.
- **Media blur** pads the image into a transparent margin before blurring so edges soften; the shader
  samples the padded texture (`media2.zw` = pad fraction). With Tile on, no padding.
- **Media motion** accumulates (spin angle, drift). It's cleared by bumping `app.mediaMotionReset`
  (Reset transform / Stop all motion) or loading a new file — setting a slider to 0 deliberately keeps the pose.
- Mushrooms (Canvas): no bounce; they grow slowly toward a `target` raised by hits in their frequency band.
- **Shader modes** (Membrane, Spectral Fan, Glass Stack, Diamond): the visualizer fills `f.shaderMode` with
  `ShaderModeUniforms` + a float list; the renderer draws one full-screen fragment pass. Glass (⅓ res) and Diamond (½ res)
  render off-screen first, then are added into the scene. Membrane/Fan are 2D (tilt via `camInv`, not volumetric).
- **Diamond** = a convex solid, i.e. a list of facet planes `n·x ≤ w` (raytraced: entry = max over front planes,
  exit = min over back planes; RGB traced at 3 IORs for "Rainbow"). Facets 5–50 = total count, split into rings by
  `DiamondViz.rings(total:)`; every cut is rescaled to outer radius 1.05. Movement = how much the music reshapes it
  (per-side tilt/push from 16 bands, stretch, bass drift, slow turn). Rotate/stretch the *planes*, not the view, so
  the stone moves under the lights. Keep the shader's bounding sphere (√4.4) larger than the stone can grow.
- **Removed / renamed settings:** the CRT `grain` is gone (node patches targeting "grain" are aliased to `filmGrain`);
  Diamond's facet count is `diamondFacets` (the old `diamondCut` key meant symmetry and is ignored).
- **Performance** (GPU ms at 3600×2250, `AUDIOWATCH_PERF=1`): baseline ~5, Membrane ~9, Glass ~13, Diamond 8–18
  (Movement and Rainbow cost the most). Keep new per-pixel work under ~16 ms there.
- Commit only when the user asks. Commit messages so far are short ("update").

## Where things stand (2026-11-11)

Committed on `master` up to the 2026-11-06 work (Nodes, presets, post-processing, media layer).
**Uncommitted** (this session): app renamed to soundwatch (lowercase); HUD toolbar (no flask, centre icon `scope`,
nodes before settings); new modes Membrane, Spectral Fan, Glass Stack, Diamond; post effects soft focus, streak,
edge fringe, film grain (Screen section merged into Post-processing, old grain removed); palettes Glass, Cobalt,
Spectral; README rewritten short with the user's Instagram/SoundCloud links and the Gatekeeper "Open Anyway" steps;
build.sh signs with `codesign --force --deep --sign -`. `build/` is no longer tracked (git-ignored); downloads go through GitHub releases (`release.sh`).

Not yet confirmed by the user / possible next steps:
- Diamond Movement responsiveness (~0.4 s glide now; the user earlier asked for much slower movement).
- Motion over time of the new modes was only checked in still frames.
- Presets UI and camera position being saved in presets — never explicitly confirmed.
- Ideas (nothing agreed): a light "paper" background mode (ink-on-white compositing, from the reference video),
  text layer, several media layers, MIDI/OSC input nodes, recording/exporting the output.
