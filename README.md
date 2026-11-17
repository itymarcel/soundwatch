# soundwatch

A music visualizer for macOS. It listens to whatever your Mac is playing, on any output, and draws it.
No virtual audio driver needed, and the sound itself is never touched. Needs macOS 14.2 or later.

[![Instagram](https://img.shields.io/badge/Instagram-itisfinji-E4405F?logo=instagram&logoColor=white)](https://www.instagram.com/itisfinji/)
[![SoundCloud](https://img.shields.io/badge/SoundCloud-finji-FF5500?logo=soundcloud&logoColor=white)](https://soundcloud.com/finji-1)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-mcut3000-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/mcut3000)

<p align="center">
  <a href="docs/demo.mp4"><img src="docs/demo.gif" width="49%" alt="soundwatch cycling through its presets with the settings sidebar open"></a>
  <img src="docs/shot-field.jpg" width="49%" alt="Field mode: a glowing particle cloud, with the settings sidebar open">
</p>
<p align="center">
  <img src="docs/shot-ferrofluid.jpg" width="49%" alt="Ferrofluid mode: a chrome liquid pulled apart by magnets">
  <img src="docs/shot-overlay.jpg" width="49%" alt="Overlay mode: the visuals floating see-through above another app">
</p>

<p align="center"><sub><a href="docs/demo.mp4">Watch the full-quality video (with sound)</a></sub></p>

<p align="center">
  <a href="https://github.com/itymarcel/soundwatch/releases/latest">
    <img src="https://img.shields.io/badge/Download_for_macOS-latest_release-7B2FF7?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" height="56">
  </a>
</p>

## Download

Get `soundwatch-<version>.zip` from the [latest release](https://github.com/itymarcel/soundwatch/releases/latest),
unzip it and drag **soundwatch** into your Applications folder. Runs on Apple Silicon and Intel Macs.

**Updates:** soundwatch checks GitHub for a new release when it starts (at most once a day) and offers to install it;
**soundwatch → Check for Updates…** checks right away. Installing replaces the app and relaunches it. Your settings and
presets (including ones you deleted) are kept, and new built-in presets are added.

## First launch

soundwatch is indie and not notarized by Apple yet, so macOS blocks a downloaded copy the first time:

1. Open the app and click **Done**
2. Go to **System Settings → Privacy & Security** and scroll down
3. Click **Open Anyway**

Then allow **System Audio Recording** when asked (or later under Privacy & Security → Screen & System Audio Recording).
A copy you built yourself skips steps 1–3.

## Build

```bash
./build.sh                   # → build/soundwatch.app
open build/soundwatch.app
./release.sh                 # → build/soundwatch-<version>.zip (Apple Silicon + Intel, for GitHub releases)
```

`build.sh` signs the app ad-hoc at the end. If you put a bundle together some other way, sign it yourself:

```bash
codesign --force --deep --sign - soundwatch.app
```

After a rebuild macOS may ask for the audio permission again.

## Using it

`1`–`8` switch modes, `←` `→` previous / next preset, `S` settings, `N` nodes, `Space` freeze, `F` full screen, `T` overlay mode (only the picture, floating on top; `Esc` exits), `R` re-centre.
Drag to rotate, right-drag or two-finger scroll to pan, scroll or pinch to zoom, ⌘-drag to move the window.
The mode bar at the top and the help, nodes and settings buttons (top right) fade out when the mouse is idle. **?** shows a short intro again (it also appears on first launch).
Set the background opacity to 0 for a see-through overlay. **Anti-aliasing** (Window group, on by default) smooths edges; turn it off for speed on a slow Mac.
**Input** (Response group) chooses what soundwatch listens to: system audio (default) or a microphone / audio interface input (macOS asks for microphone access the first time).
The settings and the nodes can each be **detached** into a window of their own (the window button at their top right; the same button puts them back).

**Modes:** Sphere, Oscilloscope, Snippet, Vectorscope, Halo, Spectrogram, Cymatics (sand on a vibrating plate), Flow (particles in curl noise).
Experimental: Attractor, Harmonograph, Drumhead, Primitives, Field, Mushrooms, Membrane (a rubber sheet that hits push up through), Spectral Fan, Glass Stack, Diamond (a raytraced brilliant with adjustable facets, moving facets and rainbow dispersion) and Orbs (chrome metaballs: one orb per frequency band, melted together into one floating mass; loud bands swell their orb out of it) and Image Particles (choose a picture: it becomes up to a million particles on springs; each one's frequency band pushes it out and makes it shimmer, drum hits send shock waves through the picture; **Reacts by** picks which band each particle listens to: Position (left to right), Random, Brightness (dark = bass) or Colour (reds = bass … blues = treble), and the drum waves follow it (kicks shake the bass particles, hats the treble ones); Threshold leaves out the dark pixels, Colours from the image or the palette, Depth for a 3D relief), Splashs (a 3D pool of ferrofluid over an electromagnet driven by the bass: it gathers into a mound and, past the critical field, bristles into the hexagonal spikes of the Rosensweig instability; drum hits splash it; Detail = Fluid, Magnet, Splash) and Ferrofluid (ferrofluid in water inside a glass sphere, simulated as a real liquid on the GPU: tens of thousands of particles with surface tension, viscosity and slight sinking; 3–24 electromagnets around the sphere, each listening to its own slice of the spectrum (30 Hz – 17 kHz, shuffled around the sphere), magnetise the fluid and pull it towards them, so it stretches into arms, pinches off drops, spikes and splashes; Detail = Fluid, Magnet = the dial, Magnets = how many coils, Hold = how long they keep their strength, Centre pull = how strongly it floats back to the middle, Burst strength = how hard a sudden hit blows the liquid apart and yanks it towards that magnet (scaled by the size of the hit), Burst threshold = how sudden a hit must be to set one off, Coil lag (short = snappier). When the music stops, surface tension wins and it settles into a perfectly round, still ball. Only the black liquid is drawn). Both use the chrome Reflects / Turn / Blur / Tint for the oily reflections. Infinity is a flight between endless fractal castles (a Mandelbox mirrored into a lattice); Motion is the speed and the bass pushes it along, Detail = how many frequency bands are dealt out. Structure picks what it is built from (Castle = ornate fortress walls, Vault = a solid block with carved chambers, Bubbles = round shells nested inside each other, City = endless streets of towers with lit windows below you and an upside-down city above, each tower rising with its own band); Fold reshapes it (for the Castle from open monuments to dense machinery, for the City from low town to skyscrapers), Depth sets the fractal detail, Morph = how far kicks push the fold. Pattern picks what is drawn on the walls (Seams, Contours, Circuit, Blocks, Plain), each part lighting up with its band; Surface picks the material (Solid, Reflective, Glass, Milky glass; the chrome Reflects / Turn / Blur / Tint apply); Speakers scatters loudspeaker cones over the walls that pump with their own band. Landscape is an endless flight with two **Scenes**. Forest: a flight down a river valley through an endless forest, drawn like a game landscape (terrain with level of detail, tens of thousands of procedurally grown spruce and broadleaf trees placed on the GPU, sun shadows, clouds, mist, grass and wildflowers, boulders and river stones, light shafts through the trees, a winding river that mirrors the trees): bass gusts sweep through the trees and grass, the treble makes the leaves flutter and the water ripple, every tree glows with its own band (Band light), and hard hits set flocks of birds flying up from the trees (a hit while they fly makes the flock swerve); Detail = how dense the trees are, Sun = time of day, Mist, Clouds, Wind, Birds, Palette tint. City at night: a flight down an avenue through an endless ray-traced city (setback towers with spires, wet streets that mirror the lights, head and tail lights in four lanes, street lamps). Every tower listens to its own band and its lit windows climb up the facade like a level meter (Band light); light drones fly through the streets, each with its own band, lighting the facades and throwing moving shadows of the buildings; searchlights swing to new angles on every beat; a hard kick sends a ring of light running out along the streets; with Storm, hard snare hits set off lightning that throws hard shadows of every tower; the mids speed up the traffic and the treble makes windows flicker and puddles glitter. Detail = Towers (low town … skyscrapers), Camera height (street level … over the roofs), Gloom (a clear night … thick glowing haze, low clouds, muted colours and soft light bouncing between the buildings), Haze, Band light, Light drones, Searchlights, Traffic, Wet streets, Storm, Palette tint.

**Chrome:** Orbs, and Primitives and Mushrooms with Render set to Chrome, are drawn as polished metal. Pick what it reflects (four HDR photos: Studio, Wood, Moonrise, Night), turn it, and set Blur (sharp mirror to soft satin) and Tint (palette colour).
The HDRIs are from [Poly Haven](https://polyhaven.com) (CC0).

**Beat & tempo:** soundwatch finds the song's tempo and, with **Lock to tempo** (Feedback & beat), fires the beat exactly on time, predicted rather than detected late, and steady through fills and syncopated drums. It needs ~5 s of music to lock and falls back to plain bass hits when there's no steady beat. The FPS overlay shows the BPM; in Nodes, **Beat ramp** rises 0 → 1 over every beat for beat-synced motion.

**Quick controls** at the top of the settings: **Colours** morphs smoothly through all the palettes, **Intensity** calms down or winds up the whole look at once (motion, reach, glow, trails, warp, beat, colour) without moving your other sliders.

**Settings** are per look: palette, response (gain, floor, smoothing, frequency range), shape and motion, feedback warp, post-processing
(colour grade, aberration, pixelate, posterize, soft focus, streak, edge fringe, film grain, scanlines, vignette, flicker) and a media layer
(an image or looping video behind, blended with, masking or warping the visuals, with its own motion). Settings a mode doesn't use are greyed out.
**Presets** save all of it plus the camera view. The app comes with 15 built-in presets (it starts on Acid Garden); overwrite or delete them as you like.
**Always overwrite** (above Presets) holds a background colour and opacity that, while switched on, replace the ones saved in whatever preset is loaded.
**Auto-loop through presets** (in the Presets group) switches to the next preset on the beat, every N beats plus an optional random number of extra beats.

**Nodes** (`N`) wire the music to any setting: music inputs (bass, mids, highs, bands, loudness, beat, kick/snare/hat hits, pitch),
LFOs and random, modifiers (map, smooth, curve, threshold, math, accumulate…) into any parameter. Click **+** (or right-click the grid) to add a node,
drag between dots to connect, ⌫ to delete. **Add example patch…** offers a few ready-made patches to start from. The patch is saved with presets.

## Debugging

Environment variables for running the binary (`build/soundwatch.app/Contents/MacOS/soundwatch`) directly. Debug runs never save settings.

| Variable | Does |
|---|---|
| `AUDIOWATCH_WAV=file.wav` | plays a file into the analyser instead of the system audio |
| `AUDIOWATCH_SETTINGS='{"mode":"halo"}'` | overrides saved settings for that run |
| `AUDIOWATCH_SNAPSHOT=/tmp/shot` + `AUDIOWATCH_SNAPSHOT_FRAMES=10,240` | saves those frames as PNGs, then quits |
| `AUDIOWATCH_NODES_SNAPSHOT=/path.png` | saves a picture of the Nodes panel (rendered off-screen), then quits (`AUDIOWATCH_NODES_EXAMPLES=1`: shows the example patches) |
| `AUDIOWATCH_SIDEBAR_SNAPSHOT=/path.png` | saves a picture of the settings sidebar, then quits (`AUDIOWATCH_SIDEBAR_OPEN=1`: all groups open) |
| `AUDIOWATCH_PERF=1` | prints CPU and GPU time per frame |
| `AUDIOWATCH_TRACE=1` | prints the audio playhead and bass / snare levels per frame (for measuring reaction time) |
| `AUDIOWATCH_RMSCALE=0.5` | pins the render resolution of Glass Stack / Diamond / Orbs (normally adaptive) |
| `AUDIOWATCH_OVERLAY=1` | enters overlay mode after 1 s and leaves it after 2.5 s, printing the window state |
| `AUDIOWATCH_NOGAIN=1` | turns off the fast transient response of Low latency (for comparison) |
