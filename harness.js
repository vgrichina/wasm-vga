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

// --- Mouse tracking ---
function setMousePos(x, y) {
  if (!memU8) return;
  const cx = Math.max(0, Math.min(WIDTH - 1, x | 0));
  const cy = Math.max(0, Math.min(HEIGHT - 1, y | 0));
  memU8[CTL_OFFSET + 4] = cx & 0xFF;
  memU8[CTL_OFFSET + 5] = (cx >> 8) & 0xFF;
  memU8[CTL_OFFSET + 6] = cy & 0xFF;
  memU8[CTL_OFFSET + 7] = (cy >> 8) & 0xFF;
}
function setMouseBtn(bit, down) {
  if (!memU8) return;
  if (down) memU8[CTL_OFFSET + 8] |= (1 << bit);
  else memU8[CTL_OFFSET + 8] &= ~(1 << bit);
}

canvas.addEventListener('mousemove', (e) => {
  const rect = canvas.getBoundingClientRect();
  setMousePos((e.clientX - rect.left) / rect.width * WIDTH,
              (e.clientY - rect.top) / rect.height * HEIGHT);
});
canvas.addEventListener('mousedown', (e) => { setMouseBtn(e.button, true); canvas.focus(); });
canvas.addEventListener('mouseup', (e) => setMouseBtn(e.button, false));
canvas.addEventListener('contextmenu', (e) => e.preventDefault());

// --- Touch → mouse mapping on canvas ---
function touchToMouse(e) {
  const t = e.touches[0] || e.changedTouches[0];
  if (!t) return;
  const rect = canvas.getBoundingClientRect();
  setMousePos((t.clientX - rect.left) / rect.width * WIDTH,
              (t.clientY - rect.top) / rect.height * HEIGHT);
}
canvas.addEventListener('touchstart', (e) => { e.preventDefault(); touchToMouse(e); setMouseBtn(0, true); }, { passive: false });
canvas.addEventListener('touchmove', (e) => { e.preventDefault(); touchToMouse(e); }, { passive: false });
canvas.addEventListener('touchend', (e) => { e.preventDefault(); setMouseBtn(0, false); }, { passive: false });
canvas.addEventListener('touchcancel', () => setMouseBtn(0, false));

// --- Keyboard → control block at 0x10 ---
// Bitfield: bit0=Up/W, bit1=Down/S, bit2=Left/A, bit3=Right/D,
//           bit4=Space, bit5=Enter, bit6=Esc, bit7=Shift
const KEY_MAP = {
  'ArrowUp': 0, 'KeyW': 0,
  'ArrowDown': 1, 'KeyS': 1,
  'ArrowLeft': 2, 'KeyA': 2,
  'ArrowRight': 3, 'KeyD': 3,
  'Space': 4, 'Enter': 5, 'Escape': 6, 'ShiftLeft': 7, 'ShiftRight': 7
};
function setKeyBit(bit, down) {
  if (!memU8) return;
  if (down) memU8[CTL_OFFSET + 16] |= (1 << bit);
  else memU8[CTL_OFFSET + 16] &= ~(1 << bit);
}
// Use capture phase so we get keys before select/button elements consume them
window.addEventListener('keydown', (e) => {
  const bit = KEY_MAP[e.code];
  if (bit !== undefined) {
    e.preventDefault();
    e.stopPropagation();
    // pull focus away from select/buttons so they don't eat keys
    if (document.activeElement && document.activeElement !== document.body
        && document.activeElement !== document.getElementById('screen')) {
      document.activeElement.blur();
    }
    setKeyBit(bit, true);
  }
}, true);
window.addEventListener('keyup', (e) => {
  const bit = KEY_MAP[e.code];
  if (bit !== undefined) { e.preventDefault(); setKeyBit(bit, false); }
}, true);

// --- Virtual controls (touch devices) ---
const isTouchDevice = ('ontouchstart' in window) || (navigator.maxTouchPoints > 0);

function setupVirtualControls() {
  const el = document.getElementById('virtual-controls');
  if (!el) return;
  if (!isTouchDevice) { el.style.display = 'none'; return; }
  el.style.display = '';

  // D-pad buttons
  el.querySelectorAll('[data-key]').forEach(btn => {
    const bit = parseInt(btn.dataset.key);
    btn.addEventListener('touchstart', (e) => { e.preventDefault(); btn.classList.add('active'); setKeyBit(bit, true); }, { passive: false });
    btn.addEventListener('touchend', (e) => { e.preventDefault(); btn.classList.remove('active'); setKeyBit(bit, false); }, { passive: false });
    btn.addEventListener('touchcancel', () => { btn.classList.remove('active'); setKeyBit(bit, false); });
  });

  // Fire button → mouse left click
  el.querySelectorAll('[data-mouse]').forEach(btn => {
    const bit = parseInt(btn.dataset.mouse);
    btn.addEventListener('touchstart', (e) => { e.preventDefault(); btn.classList.add('active'); setMouseBtn(bit, true); }, { passive: false });
    btn.addEventListener('touchend', (e) => { e.preventDefault(); btn.classList.remove('active'); setMouseBtn(bit, false); }, { passive: false });
    btn.addEventListener('touchcancel', () => { btn.classList.remove('active'); setMouseBtn(bit, false); });
  });
}

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
    document.getElementById('screen').focus();
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
  setupVirtualControls();
  loadDemo();
});
