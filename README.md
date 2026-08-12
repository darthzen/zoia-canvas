# ZOIA Canvas

Design [Empress Effects ZOIA](https://empresseffects.com/products/zoia) patches
on your Mac — a full-screen node canvas instead of one button at a time on the
pedal. Open real `.bin` patch files, rewire and tweak them, hear them play, and
save files the pedal loads straight from its SD card.

![The canvas with a patch open](docs/canvas.png)

## Features

- **Node canvas** — every module is a node, every connection is a cable you can
  see. Pages appear as side-by-side framed bands, with an LED-grid preview of
  each page in the bar along the bottom.
- **Live playback** — press Play and hear the patch through a built-in audio
  engine. Signal animates through the canvas: audio wires draw the waveform
  they carry, CV cables pulse as gates travel, cables blush red/blue as values
  rise and fall, and modules glow with their output.
- **Full editing** — add modules from the searchable palette, wire by dragging
  between ports, set every option and parameter in the inspector, name and
  color modules, organize pages.
- **Pedal-true layout** — the inspector shows each page as the 8×5 button grid
  the pedal will display, and you drag modules to the buttons you want.
  Placement is sticky: nothing moves unless you move it or something you moved
  displaces it.
- **A window per patch** — open several patches side by side to compare them.
  Each window remembers its size and position, and every patch remembers your
  canvas arrangement, zoom, and pan for the next time you open it.
- **Real patch files** — the `.bin` format is byte-verified against the entire
  ZOIA and Euroburo factory patch libraries. What you save is what the pedal
  reads.

![Playback: waveforms travel the wires](docs/playing.png)


## License

GPL-3.0 — see LICENSE.
