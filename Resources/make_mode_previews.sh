#!/bin/bash
# Renders a preview of every mode with the app's snapshot harness (default settings, a test tone WAV) and saves
# Resources/modes/<mode>.jpg (4:3, 360×270) for the mode picker. Needs ffmpeg and a built app (./build.sh).
#   Resources/make_mode_previews.sh                 all modes
#   Resources/make_mode_previews.sh forest orbs     only these
# Per-mode setting overrides (so each preview shows the mode at its best) are in EXTRA below.
set -uo pipefail
cd "$(dirname "$0")/.."
APP=build/soundwatch.app/Contents/MacOS/soundwatch
OUT=Resources/modes
TMP=$(mktemp -d)
mkdir -p "$OUT"
MODES=("$@")
[ ${#MODES[@]} -eq 0 ] && MODES=(sphere oscilloscope snippet vectorscope halo spectrogram cymatics flow attractor harmonograph
    drumhead primitives field mushrooms membrane fan glass diamond orbs imageParticles ferro metaballs infinity forest)

# music: a kick, a bass line and a chord, 40 s
WAV="$TMP/music.wav"
ffmpeg -loglevel error -y -f lavfi -i "aevalsrc='0.8*sin(2*PI*55*t)*exp(-8*mod(t,0.5))+0.25*sin(2*PI*110*(1+floor(mod(t,2))*0.5)*t)+0.12*(sin(2*PI*440*t)+sin(2*PI*554*t)+sin(2*PI*659*t))*(0.6+0.4*sin(2*PI*0.5*t))+0.05*(random(0)-0.5)*exp(-30*mod(t+0.25,0.5))|0.8*sin(2*PI*55*t)*exp(-8*mod(t,0.5))+0.25*sin(2*PI*110*(1+floor(mod(t,2))*0.5)*t)+0.12*(sin(2*PI*443*t)+sin(2*PI*550*t)+sin(2*PI*662*t))*(0.6+0.4*cos(2*PI*0.5*t))+0.05*(random(1)-0.5)*exp(-30*mod(t+0.25,0.5))':s=48000:d=40" "$WAV"

extra() {
    case "$1" in
        sphere)         echo '"palette":"aurora","gain":2.2,"zoom":0.72,"glow":0.8' ;;
        oscilloscope)   echo '"palette":"fire","gain":1.8,"glow":0.8,"zoom":0.58' ;;
        snippet)        echo '"palette":"neon","gain":6,"glow":1,"zoom":1.0,"style":"lines"' ;;
        vectorscope)    echo '"palette":"sunset","gain":2,"zoom":0.86,"glow":0.8' ;;
        halo)           echo '"palette":"hologram","gain":2,"zoom":0.72,"glow":0.8' ;;
        spectrogram)    echo '"palette":"ocean","gain":2.5,"glow":0.6,"zoom":0.58' ;;
        cymatics)       echo '"palette":"acid","gain":2,"zoom":1.0' ;;
        flow)           echo '"palette":"rainbow","gain":2,"zoom":0.58' ;;
        attractor)      echo '"palette":"aurora","gain":3,"zoom":1.4,"glow":0.9' ;;
        harmonograph)   echo '"palette":"neon","gain":2,"zoom":0.90,"glow":0.9' ;;
        drumhead)       echo '"palette":"sunset","gain":2,"zoom":0.68,"glow":0.8' ;;
        primitives)     echo '"palette":"neon","gain":2,"zoom":0.61,"glow":0.8' ;;
        field)          echo '"palette":"ocean","gain":2,"zoom":0.79,"glow":0.8' ;;
        mushrooms)      echo '"palette":"acid","gain":2.5,"glow":0.9,"zoom":0.54' ;;
        membrane)       echo '"palette":"sunset","gain":2,"zoom":0.58' ;;
        fan)            echo '"palette":"rainbow","gain":2,"zoom":0.58' ;;
        glass)          echo '"palette":"hologram","gain":2,"zoom":1.1' ;;
        orbs)           echo '"palette":"sunset","gain":2,"zoom":1.3' ;;
        imageParticles) echo '"palette":"rainbow","gain":2,"zoom":0.7,"glow":0.15' ;;
        ferro)          echo '"palette":"amber","gain":2.5,"zoom":2.4' ;;
        metaballs)      echo '"palette":"neon","gain":2,"zoom":1.6' ;;
        infinity)       echo '"palette":"aurora","gain":2' ;;
        *) echo '' ;;
    esac
}

for m in "${MODES[@]}"; do
    X=$(extra "$m")
    AUDIOWATCH_CLEAN=1 AUDIOWATCH_WAV="$WAV" \
    AUDIOWATCH_SETTINGS="{\"mode\":\"$m\",\"nodes\":{\"nodes\":[],\"links\":[],\"enabled\":false},\"mediaPath\":\"\"${X:+,$X}}" \
    AUDIOWATCH_SNAPSHOT="$TMP/$m" AUDIOWATCH_SNAPSHOT_FRAMES="${FRAME:-900}" "$APP" > "$TMP/$m.log" 2>&1 &
    PID=$!
    for _ in $(seq 70); do sleep 1; kill -0 $PID 2>/dev/null || break; done
    kill $PID 2>/dev/null
    SHOT=$(ls "$TMP/$m"-*.png 2>/dev/null | head -1)
    if [ -z "$SHOT" ]; then echo "no frame for $m (see $TMP/$m.log)"; continue; fi
    ffmpeg -loglevel error -y -i "$SHOT" -vf "crop='min(iw,ih*4/3)':'min(ih,iw*3/4)',scale=360:270:flags=lanczos" -q:v 3 "$OUT/$m.jpg"
    echo "$m"
done
rm -rf "$TMP"
