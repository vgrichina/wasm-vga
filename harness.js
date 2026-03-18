// Load wabt.js for in-browser WAT->WASM compilation
const wabtReady = WabtModule();

// VGA Mode 13h Harness
// Memory layout:
//   0x0000 - 0x003F  control block (64 bytes)
//   0x0040 - 0x033F  palette (256 * 3 = 768 bytes)
//   0x0340 - 0x103F  framebuffer (320*200 = 64000 bytes)
//   0x10040+         free for guest

const CTL_OFFSET = 0x0000;
const PAL_OFFSET = 0x0040;
const FB_OFFSET  = 0x0340;
const FB_SIZE    = 320 * 200;
const WIDTH = 320, HEIGHT = 200;

const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
// canvas scaling handled by CSS

const imgData = ctx.createImageData(WIDTH, HEIGHT);
const rgba = imgData.data;

let memory, memU8, memU32, wasmInstance;
let animId = null;
let frameCount = 0, lastFpsTime = 0;

// default VGA palette (simplified — 6-bit VGA scaled to 8-bit)
function defaultPalette() {
  const pal = new Uint8Array(768);
  // first 16: CGA-ish
  const cga = [
    0,0,0, 0,0,170, 0,170,0, 0,170,170,
    170,0,0, 170,0,170, 170,85,0, 170,170,170,
    85,85,85, 85,85,255, 85,255,85, 85,255,255,
    255,85,85, 255,85,255, 255,255,85, 255,255,255
  ];
  for (let i = 0; i < 48; i++) pal[i] = cga[i];
  // 16-231: 6x6x6 color cube
  let idx = 48;
  for (let r = 0; r < 6; r++)
    for (let g = 0; g < 6; g++)
      for (let b = 0; b < 6; b++) {
        pal[idx++] = r * 51;
        pal[idx++] = g * 51;
        pal[idx++] = b * 51;
      }
  // 232-255: grayscale ramp
  for (let i = 0; i < 24; i++) {
    const v = 8 + i * 10;
    pal[idx++] = v; pal[idx++] = v; pal[idx++] = v;
  }
  return pal;
}

function blitFramebuffer() {
  const pal = memU8.subarray(PAL_OFFSET, PAL_OFFSET + 768);
  const fb  = memU8.subarray(FB_OFFSET, FB_OFFSET + FB_SIZE);
  for (let i = 0; i < FB_SIZE; i++) {
    const c = fb[i];
    const p = c * 3;
    const o = i * 4;
    rgba[o]     = pal[p];
    rgba[o + 1] = pal[p + 1];
    rgba[o + 2] = pal[p + 2];
    rgba[o + 3] = 255;
  }
  ctx.putImageData(imgData, 0, 0);
}

function loop(ts) {
  // write control block
  memU32[0] = frameCount++;         // frame counter
  memU32[3] = (ts | 0);            // tick_ms

  // call guest frame
  if (wasmInstance.exports.frame) {
    wasmInstance.exports.frame();
  }

  blitFramebuffer();

  // fps
  if (ts - lastFpsTime > 1000) {
    document.getElementById('info').textContent = `fps: ${frameCount} | frame: ${memU32[0]}`;
    frameCount = 0;
    lastFpsTime = ts;
  }

  animId = requestAnimationFrame(loop);
}

// mouse tracking
canvas.addEventListener('mousemove', (e) => {
  if (!memU8) return;
  const rect = canvas.getBoundingClientRect();
  const x = ((e.clientX - rect.left) / rect.width * WIDTH) | 0;
  const y = ((e.clientY - rect.top) / rect.height * HEIGHT) | 0;
  // store mouse at offset 4 as two u16
  memU8[CTL_OFFSET + 4] = x & 0xFF;
  memU8[CTL_OFFSET + 5] = (x >> 8) & 0xFF;
  memU8[CTL_OFFSET + 6] = y & 0xFF;
  memU8[CTL_OFFSET + 7] = (y >> 8) & 0xFF;
});
// mouse buttons at offset 8
canvas.addEventListener('mousedown', (e) => { if (memU8) memU8[CTL_OFFSET + 8] |= (1 << e.button); });
canvas.addEventListener('mouseup', (e) => { if (memU8) memU8[CTL_OFFSET + 8] &= ~(1 << e.button); });
canvas.addEventListener('contextmenu', (e) => e.preventDefault());

async function loadDemo() {
  if (animId) { cancelAnimationFrame(animId); animId = null; }

  const name = document.getElementById('demo').value;
  history.replaceState(null, '', '#' + name);

  // 4 pages = 256KB, plenty of room
  memory = new WebAssembly.Memory({ initial: 4 });
  memU8  = new Uint8Array(memory.buffer);
  memU32 = new Uint32Array(memory.buffer);

  // write default palette
  memU8.set(defaultPalette(), PAL_OFFSET);

  // clear framebuffer
  memU8.fill(0, FB_OFFSET, FB_OFFSET + FB_SIZE);

  const imports = {
    env: { memory }
  };

  try {
    // Load .wat source, compile in browser via wabt.js
    let mod;
    const watResp = await fetch(`demos/${name}.wat`);
    if (!watResp.ok) throw new Error(`Could not fetch demos/${name}.wat`);
    const watText = await watResp.text();
    const wabt = await wabtReady;
    const parsed = wabt.parseWat(`${name}.wat`, watText);
    parsed.resolveNames();
    parsed.validate();
    const { buffer } = parsed.toBinary({});
    parsed.destroy();
    mod = await WebAssembly.compile(buffer);
    wasmInstance = await WebAssembly.instantiate(mod, imports);

    if (wasmInstance.exports.init) {
      wasmInstance.exports.init();
    }

    frameCount = 0;
    lastFpsTime = performance.now();
    animId = requestAnimationFrame(loop);
  } catch (e) {
    console.error(e);
    alert('Error loading demo: ' + e.message);
  }
}

// auto-load on start, respect hash fragment
window.addEventListener('load', () => {
  const hash = location.hash.slice(1);
  if (hash) {
    const sel = document.getElementById('demo');
    const opt = [...sel.options].find(o => o.value === hash);
    if (opt) sel.value = hash;
  }
  loadDemo();
});
