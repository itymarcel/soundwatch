# Drum detector training & evaluation

Offline tools behind `Sources/AudioWatch/DrumDetector.swift` / `DrumModel.swift`. Not part of the app build.

## Data (not in the repo; put it under `data/` or set `DRUMDATA`)

- `data/mdb/mix/*.wav`, `data/mdb/ann/*_class.txt`: [MDB Drums](https://github.com/CarlSouthall/MDBDrums) full mixes +
  class annotations (CC BY-NC-SA 4.0). Training + cross-validation.
- `data/idmt/t/*.wav|.txt`: [IDMT-SMT-Drums V2](https://zenodo.org/records/7544164) `#MIX.wav` loops with their XML
  annotations converted to `time CLASS` lines (CC BY-NC-ND 4.0: **test only, never train on it**).
- `data/syn`: `gen` (hand-made electronic tracks: house, hip-hop, dnb, trap, no drums, drums only; loud + −30 dB copies).
- `data/rtrain` (seeds 1000…, 8 used for training), `data/rtest` (seeds 5000…): `gen-random` (randomised kits, patterns,
  basses, stabs, arps, risers, sidechain, levels).

## Build & run

```bash
SRC=../../Sources/AudioWatch
swiftc -O -o drums harness/*.swift $SRC/DrumDetector.swift $SRC/DrumModel.swift $SRC/Analyzer.swift $SRC/AudioRing.swift $SRC/BeatTracker.swift
swiftc -O gen/main.swift -o gen/gen && gen/gen data/syn
swiftc -O gen-random/*.swift -o gen-random/gen2 && gen-random/gen2 data/rtrain 60 1000 && gen-random/gen2 data/rtest 20 5000

./drums new                  # the shipped detector on MDB (optimistic: it was trained on MDB); V=1 per track
./drums old                  # the old frame-based detector through the real Analyzer (GAIN / FLOOR / TILT / FFT / FPS env)
BEATMODE=1 ./drums old       # the Analyzer's unlocked Beat against annotated kicks
./drums sets                 # unseen sets (IDMT real / techno / wave, syn, rtest)
NEXTRA=8 POSW=0.1 SEED=1 OUT=net1.txt ./drums mix   # 2-fold MDB cross-validation, then train on all + report unseen sets
```

Env: `WAVS=a.wav,b.wav` (annotation = same name `.txt`), `NET=n1.txt,n2.txt` (average these instead of the embedded
model), `P='{"floor0":0.82,"floor1":0.7,"floor2":0.65}'` (thresholds), `LEVEL=0…4`, `FPINFO=1` (what false positives sit
next to), `STRENGTH=1` (strength percentiles). Scoring: ±50 ms; hats = HH + CY; toms don't count as kick/snare errors.

`DrumModel.swift` = three nets (SEED 1, 2, 3, `NEXTRA=8 POSW=0.1`), each `OUT` file's 2 lines (`nIn nHid`, base64) pasted
as one `(nIn, nHid, "base64")` entry. Features or band layout changed in DrumDetector → retrain (the nets check `nIn`).
