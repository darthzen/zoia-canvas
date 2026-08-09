# ZOIA Canvas

A native macOS visual patch designer for the Empress Effects ZOIA / Euroburo —
Bespoke Synth-style node canvas for designing patches off-device, exporting
real `.bin` patch files the pedal loads from its SD card.

SwiftUI, multiplatform-ready (macOS first; iOS/iPadOS/visionOS targets planned).

## Status

Scaffold plus a working `.bin` codec (`Sources/ZoiaCanvas/Format/`):

- Decoder parses all 127 device-format factory patches in the test corpus
  (64 ZOIA + 64 Euroburo, minus one all-zero placeholder slot).
- Encoder round-trips every one of them byte-identically through the
  declared size, and its from-scratch exports parse correctly in zoia_lib.
- Ground truth for the decoder tests is `Tests/ZoiaCanvasTests/Corpus/
  manifest.json`, generated from zoia_lib's Python parser by
  `tools/build_manifest.py`.

The canvas node editor is functional: searchable module palette, nodes with
port-typed blocks (option-dependent layout ported from zoia_lib's
`_calc_blocks`, oracle-tested over the corpus), cable creation by port drag
(output→input enforced; audio↔cv mismatches warned, not blocked), node drag,
drag-from-palette placement, selection and delete, an inspector (name, color,
options, params — options re-layout blocks and resize the param list live,
matching device behavior verified across the corpus), Bespoke-style animated
cables, Empress-spreadsheet category colors, DSP estimate meter, and `.bin`
open/export.

An audio/MIDI preview engine (AVAudioEngine + CoreMIDI virtual "ZoiaCanvas
In/Out" ports) renders a first module set offline-testably: audio in/out,
sequencer (track 1; other tracks await saved_data decoding), LFO, oscillator,
VCA, MIDI notes in/out. Unimplemented modules are silent. Pitch/LFO curves
are documented assumptions pending hardware calibration.

Still missing: cable selection/deletion, page management, starred params,
live audio input capture, sequencer tracks 2–8.

## Building

```
xcodegen        # generates ZoiaCanvas.xcodeproj from project.yml
xcodebuild -scheme ZoiaCanvas build
```

## Format references

Patch binary format ported from [zoia_lib](https://github.com/meanmedianmoge/zoia_lib)
(GPL-3.0), whose Python parser also serves as the validation oracle
(`tools/build_manifest.py`). Module metadata merges zoia_lib's module index with
Empress's firmware-5 module index spreadsheet.

## License

GPL-3.0 — see LICENSE.
