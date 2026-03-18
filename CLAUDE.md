# VGA Mode 13h — WASM Demos

WebAssembly demos running in a VGA Mode 13h harness (320x200, 256-color palette-indexed).
All demos are WAT files compiled in-browser via wabt.js. No server-side compilation needed.

## Architecture

- `index.html` — UI with demo picker, fullscreen, responsive layout
- `harness.js` — VGA harness: memory layout, palette, framebuffer blit, mouse/keyboard/touch input, virtual controls, animation loop
- `demos/*.wat` — WAT source files (WebAssembly Text format)
- `demos/*.wasm` — Compiled binaries (gitignored, built by `build.sh`)

## Memory Layout (harness-owned)

- `0x0000-0x003F` — Control block:
  - `0x00`: frame counter (u32)
  - `0x04`: mouse x (u16), `0x06`: mouse y (u16)
  - `0x08`: mouse buttons (u8, bit0=left, bit1=right, bit2=middle)
  - `0x0C`: tick_ms (u32)
  - `0x10`: keyboard state (u8 bitfield: bit0=Up/W, bit1=Down/S, bit2=Left/A, bit3=Right/D, bit4=Space, bit5=Enter, bit6=Esc, bit7=Shift)
- `0x0040-0x033F` — Palette (256 * 3 RGB bytes)
- `0x0340-0x1033F` — Framebuffer (320*200 = 64000 bytes, each byte = palette index)
- `0x10340+` — Free for guest use

## WAT Demo Contract

Each demo exports:
- `init()` — Called once on load
- `frame()` — Called each animation frame

Memory is imported as `env.memory` (4 pages = 256KB).

## Building

```sh
bash build.sh  # Compiles all .wat -> .wasm via wat2wasm (wabt)
```

## Local Dev

```sh
python3 -m http.server 8080
# Open http://localhost:8080
```

## Deploying to Berrry

Hosted at https://wasmvga-demos.berrry.app

API key is in `.env.nomcp` (gitignored). Deploy with:

```sh
# Full deploy (all files)
source .env.nomcp
python3 -c "
import json, os
files = []
with open('index.html') as f: files.append({'name': 'index.html', 'content': f.read()})
with open('harness.js') as f: files.append({'name': 'harness.js', 'content': f.read()})
for name in sorted(os.listdir('demos')):
    if name.endswith('.wat'):
        with open(f'demos/{name}') as f:
            files.append({'name': f'demos/{name}', 'content': f.read()})
with open('/tmp/deploy.json', 'w') as f: json.dump({'files': files, 'message': 'description of change'}, f)
"
curl -s -X PUT "$BERRRY_API/apps/wasmvga-demos" \
  -H "Content-Type: application/json" \
  -d @/tmp/deploy.json

# Quick deploy (single file update)
source .env.nomcp
curl -s -X PUT "$BERRRY_API/apps/wasmvga-demos" \
  -H "Content-Type: application/json" \
  -d '{"files":[{"name":"index.html","content":'"$(python3 -c "import json;print(json.dumps(open('index.html').read()))")"'}],"message":"what changed"}'
```

## Adding a New Demo

1. Create `demos/newdemo.wat` implementing `init` and `frame` exports
2. Add `<option value="newdemo">newdemo</option>` to the select in `index.html`
3. Deploy both files
