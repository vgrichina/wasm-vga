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
- `0x10340+` — Free for guest use (192KB, up to `0x40000`)

## Guest Memory Layout Best Practices

Pack **const data** (sin tables, font, strings, lookup tables) at the bottom of guest area (`0x10340+` growing up) and **dynamic data** (buffers, state, PRNG) at the top (`0x40000` growing down). This prevents overlapping regions as demos grow:

```
0x10340  ┌──────────────────┐  guest area start
         │  CONST DATA      │  data segments, lookup tables
         │  (grows →)       │  written once in init, read-only after
         ├──────────────────┤
         │                  │
         │  ~180KB gap      │  room to grow either direction
         │                  │
         ├──────────────────┤
         │  DYNAMIC DATA    │  PRNG state, fire buffers, particle state
         │  (← grows)       │  mutated every frame
0x40000  └──────────────────┘  end of 4 pages
```

## WAT Demo Contract

Each demo exports:
- `init()` — Called once on load
- `frame()` — Called each animation frame

Memory is imported as `env.memory` (4 pages = 256KB).

Use `(data (i32.const ADDR) "...")` segments for static data (fonts, strings, maps) instead of `i32.store8` chains. Data segments are initialized at instantiation and keep WAT files compact.

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

## Input Handling in Demos

The harness writes keyboard/mouse state to the control block every frame. Demos read it directly from shared memory.

### Rising Edge Detection Pattern

For one-shot actions (skip section, fire weapon), detect newly-pressed bits using `input & ~prev_input`:

```wat
;; Read current input state
(local.set $input (i32.or
  (i32.and (i32.load8_u (i32.const 0x10)) (i32.const 28))   ;; keyboard: left|right|space
  (i32.and (i32.load8_u (i32.const 0x08)) (i32.const 1))))  ;; mouse click
(local.set $prev_input (i32.load (i32.const 0x3800C)))       ;; from dynamic area
(i32.store (i32.const 0x3800C) (local.get $input))

;; Newly-pressed bits = input & ~prev_input
;; Check if any target bits (e.g. 25 = space|right|click) are newly on
(if (i32.and
  (i32.and (local.get $input) (i32.xor (local.get $prev_input) (i32.const 0xFFFFFFFF)))
  (i32.const 25))
  (then ...))
```

This is per-bit rising edge — a held mouse click won't block a keyboard press from triggering.

### Harness Keyboard Capture

`harness.js` uses capture-phase (`window.addEventListener(..., true)`) + `stopPropagation()` to intercept arrow keys and space before UI elements (select dropdown, buttons) can consume them. The canvas auto-focuses after `loadDemo()`.

## Adding a New Demo

1. Create `demos/newdemo.wat` implementing `init` and `frame` exports
2. Add `<option value="newdemo">newdemo</option>` to the select in `index.html`
3. Deploy both files
