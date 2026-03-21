# VGA Mode 13h — WASM Demos

WebAssembly demos running in a VGA Mode 13h harness (320×200, 256-color palette-indexed). All demos are WAT files compiled in-browser via wabt.js. No server-side compilation needed.

**Live:** https://wasmvga-demos.berrry.app

## Demos

- [arkanoid](https://wasmvga-demos.berrry.app#arkanoid) — Breakout-style game
- [bobs](https://wasmvga-demos.berrry.app#bobs) — Bouncing sprites
- [codeover](https://wasmvga-demos.berrry.app#codeover) — Code rain effect
- [fire](https://wasmvga-demos.berrry.app#fire) — Classic demoscene fire effect
- [gradient](https://wasmvga-demos.berrry.app#gradient) — Palette gradient test
- [interference](https://wasmvga-demos.berrry.app#interference) — Overlapping wave patterns
- [landscape](https://wasmvga-demos.berrry.app#landscape) — Voxel-style landscape
- [mandelbrot](https://wasmvga-demos.berrry.app#mandelbrot) — Animated Mandelbrot zoom
- [metaballs](https://wasmvga-demos.berrry.app#metaballs) — Blobby metaballs with palette
- [officefps](https://wasmvga-demos.berrry.app#officefps) — First-person shooter with lighting, enemies, doors
- [plasma](https://wasmvga-demos.berrry.app#plasma) — Sine-based plasma with palette cycling
- [raycaster](https://wasmvga-demos.berrry.app#raycaster) — Wolfenstein-style raycaster with textured walls/floors
- [scroller](https://wasmvga-demos.berrry.app#scroller) — Sine-wave text scroller
- [shooter](https://wasmvga-demos.berrry.app#shooter) — Vertical scrolling shoot-em-up with music
- [starfield](https://wasmvga-demos.berrry.app#starfield) — 3D starfield
- [tinyrts](https://wasmvga-demos.berrry.app#tinyrts) — Tiny real-time strategy game
- [torus](https://wasmvga-demos.berrry.app#torus) — Rotating 3D torus
- [tunnel](https://wasmvga-demos.berrry.app#tunnel) — Texture-mapped tunnel flythrough

## Running locally

```sh
python3 -m http.server 8080
```

## License

MIT
