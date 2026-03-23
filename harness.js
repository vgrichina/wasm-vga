// Load wabt.js for in-browser WAT->WASM compilation
const wabtReady = WabtModule();

// VGA Mode 13h Harness
// Memory layout:
//   0x0000 - 0x003F  control block (64 bytes)
//   0x0040 - 0x033F  palette (256 * 3 = 768 bytes)
//   0x0340 - 0x103F  framebuffer (320*200 = 64000 bytes)
//   0x10040+         free for guest
//

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
let frameCount = 0, fpsFrames = 0, lastFpsTime = 0;
let paused = false;

// --- Sound engine ---
let audioCtx = null, masterGain = null, isMuted = false, audioDest = null;
let noiseBuffer = null;
let musicInterval = null, musicStep = 0;

// --- Recording ---
let recorder = null, recordChunks = [];
const REC_SCALE = 4;
let recCanvas = null, recCtx = null;

function startRecording() {
  ensureAudio();
  if (!audioDest) {
    audioDest = audioCtx.createMediaStreamDestination();
    masterGain.connect(audioDest);
  }
  if (!recCanvas) {
    recCanvas = document.createElement('canvas');
    recCanvas.width = WIDTH * REC_SCALE;
    recCanvas.height = HEIGHT * REC_SCALE;
    recCtx = recCanvas.getContext('2d');
    recCtx.imageSmoothingEnabled = false;
  }
  const stream = new MediaStream([
    ...recCanvas.captureStream(30).getVideoTracks(),
    ...audioDest.stream.getAudioTracks()
  ]);
  const types = ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm', 'video/mp4'];
  const mimeType = types.find(t => MediaRecorder.isTypeSupported(t));
  const opts = mimeType ? { mimeType } : {};
  recorder = new MediaRecorder(stream, opts);
  recordChunks = [];
  const recMime = recorder.mimeType;
  const recName = document.getElementById('demo').value;
  recorder.ondataavailable = e => { if (e.data.size) recordChunks.push(e.data); };
  recorder.onstop = () => {
    const blob = new Blob(recordChunks, { type: recMime });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    const ext = recMime.includes('mp4') ? 'mp4' : 'webm';
    a.download = `${recName}-${Date.now()}.${ext}`;
    a.click();
    URL.revokeObjectURL(a.href);
  };
  recorder.start(1000);
  document.getElementById('rec-btn').classList.add('recording');
  document.getElementById('rec-btn').textContent = 'STOP';
}

function stopRecording() {
  if (recorder && recorder.state !== 'inactive') recorder.stop();
  recorder = null;
  document.getElementById('rec-btn').classList.remove('recording');
  document.getElementById('rec-btn').textContent = 'REC';
}

function toggleRecord() {
  if (recorder) stopRecording(); else startRecording();
}

function ensureAudio() {
  if (audioCtx) {
    if (audioCtx.state === 'suspended') {
      audioCtx.resume().then(() => {
        // re-start music that was requested while suspended
        if (currentMusicAddr && !musicInterval && !isMuted) music(currentMusicAddr);
      });
    }
    return audioCtx.state === 'running';
  }
  audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  masterGain = audioCtx.createGain();
  masterGain.connect(audioCtx.destination);
  if (isMuted) masterGain.gain.value = 0;
  // pre-generate noise buffer
  noiseBuffer = audioCtx.createBuffer(1, audioCtx.sampleRate / 5, audioCtx.sampleRate);
  const data = noiseBuffer.getChannelData(0);
  for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
  return audioCtx.state === 'running';
}

function playNoise(duration, vol) {
  const src = audioCtx.createBufferSource();
  src.buffer = noiseBuffer;
  const g = audioCtx.createGain();
  const t = audioCtx.currentTime;
  g.gain.setValueAtTime(vol, t);
  g.gain.exponentialRampToValueAtTime(0.001, t + duration);
  src.connect(g); g.connect(masterGain);
  src.start(t); src.stop(t + duration);
}

function playTone(type, freq, duration, vol, freqEnd) {
  const osc = audioCtx.createOscillator();
  const g = audioCtx.createGain();
  const t = audioCtx.currentTime;
  osc.type = type;
  osc.frequency.setValueAtTime(freq, t);
  if (freqEnd) osc.frequency.exponentialRampToValueAtTime(freqEnd, t + duration);
  g.gain.setValueAtTime(vol, t);
  g.gain.exponentialRampToValueAtTime(0.001, t + duration);
  osc.connect(g); g.connect(masterGain);
  osc.start(t); osc.stop(t + duration);
}

// SFX — reads voice definitions from WASM memory
// Format at addr:
//   +0: num_voices (u8, 1-8)
//   +1: pad
//   Per voice (8 bytes, starting at +2):
//     +0: type (u8): 0=sine,1=square,2=sawtooth,3=triangle,4=noise
//     +1: vol (u8, 0-255 → 0-0.4)
//     +2: dur_centisec (u8)
//     +3: freq_start MIDI (u8, ignored for noise)
//     +4: freq_end MIDI (u8, 0=same as start)
//     +5: delay_ms (u8)
//     +6-7: pad
const midiToFreq = n => n ? 440 * Math.pow(2, (n - 69) / 12) : 0;

function sfx(addr) {
  if (!ensureAudio()) return;
  if (!addr || !memU8) return;
  const numVoices = Math.min(memU8[addr], 8);
  for (let v = 0; v < numVoices; v++) {
    const o = addr + 2 + v * 8;
    const type = memU8[o];
    const vol = memU8[o + 1] / 255 * 0.4;
    const dur = memU8[o + 2] / 100;
    const freqStart = midiToFreq(memU8[o + 3]);
    const freqEnd = midiToFreq(memU8[o + 4]);
    const delay = memU8[o + 5];
    const play = () => {
      if (!audioCtx) return;
      if (type === 4) {
        playNoise(dur, vol);
      } else {
        playTone(oscTypes[type & 3], freqStart || 440, dur, vol, freqEnd || undefined);
      }
    };
    if (delay > 0) setTimeout(play, delay);
    else play();
  }
}

function note(oscType, freq, durMs, vol255) {
  if (!ensureAudio()) return;
  const types = ['sine', 'square', 'sawtooth', 'triangle'];
  playTone(types[oscType & 3] || 'sine', freq || 440, (durMs || 100) / 1000, (vol255 || 128) / 255 * 0.3);
}

// Music sequencer — reads pattern data from WASM memory
// Pattern format in memory:
//   +0: bpm (u16 LE)
//   +2: steps (u8) — notes per track
//   +3: num_tracks (u8, 1-3)
//   +4,+8,+12: per track — type(u8), vol(u8), dur_centisec(u8), pad(u8)
//   +16: note data — MIDI note numbers (u8), 0=rest
//         track0[steps], track1[steps], track2[steps]
// MIDI to Hz: 440 * 2^((note-69)/12)
let currentMusicAddr = 0;
const oscTypes = ['sine', 'square', 'sawtooth', 'triangle'];

function music(addr) {
  currentMusicAddr = addr;
  if (!ensureAudio()) return;
  if (musicInterval) { clearInterval(musicInterval); musicInterval = null; }
  if (addr === 0 || !memU8) return;
  // read pattern header from WASM memory
  const bpm = memU8[addr] | (memU8[addr + 1] << 8);
  const steps = memU8[addr + 2];
  const numTracks = Math.min(memU8[addr + 3], 3);
  if (!bpm || !steps || !numTracks) return;
  const tracks = [];
  for (let t = 0; t < numTracks; t++) {
    const h = addr + 4 + t * 4;
    tracks.push({
      type: oscTypes[memU8[h] & 3],
      vol: memU8[h + 1] / 255 * 0.3,
      dur: memU8[h + 2] / 100,
      noteOff: addr + 16 + t * steps,
    });
  }
  const interval = 60000 / bpm / 4;
  // sync to elapsed demo time so late-starting music is in phase
  const tickMs = memU8 ? (memU8[0x0C] | (memU8[0x0D] << 8) | (memU8[0x0E] << 16) | (memU8[0x0F] << 24)) : 0;
  musicStep = tickMs > 0 ? Math.floor(tickMs / interval) : 0;
  musicInterval = setInterval(() => {
    if (!audioCtx || isMuted || !memU8) return;
    const s = musicStep % steps;
    for (const tr of tracks) {
      const midi = memU8[tr.noteOff + s];
      if (midi) {
        const freq = 440 * Math.pow(2, (midi - 69) / 12);
        playTone(tr.type, freq, tr.dur, tr.vol);
      }
    }
    musicStep++;
  }, interval);
}

function toggleMute() {
  isMuted = !isMuted;
  if (masterGain) masterGain.gain.value = isMuted ? 0 : 1;
  if (isMuted) {
    if (musicInterval) { clearInterval(musicInterval); musicInterval = null; }
  } else if (currentMusicAddr) {
    music(currentMusicAddr);
  }
  const btn = document.getElementById('mute-btn');
  if (btn) btn.textContent = isMuted ? 'OFF' : 'SND';
}

// Standard VGA Mode 13h 256-color palette
function defaultPalette() {
  const pal = new Uint8Array(768);
  // 16 standard CGA/EGA colors (indices 0-15)
  const cga = [
    [0,0,0],[0,0,170],[0,170,0],[0,170,170],
    [170,0,0],[170,0,170],[170,85,0],[170,170,170],
    [85,85,85],[85,85,255],[85,255,85],[85,255,255],
    [255,85,85],[255,85,255],[255,255,85],[255,255,255]
  ];
  for (let i = 0; i < 16; i++) {
    pal[i*3] = cga[i][0]; pal[i*3+1] = cga[i][1]; pal[i*3+2] = cga[i][2];
  }
  // 16 grayscale (indices 16-31)
  for (let i = 0; i < 16; i++) {
    const v = Math.round(i * 255 / 15);
    pal[(16+i)*3] = v; pal[(16+i)*3+1] = v; pal[(16+i)*3+2] = v;
  }
  // 216 color cube (indices 32-247): 6x6x6 RGB
  for (let r = 0; r < 6; r++) {
    for (let g = 0; g < 6; g++) {
      for (let b = 0; b < 6; b++) {
        const idx = 32 + r*36 + g*6 + b;
        pal[idx*3]   = Math.round(r * 255 / 5);
        pal[idx*3+1] = Math.round(g * 255 / 5);
        pal[idx*3+2] = Math.round(b * 255 / 5);
      }
    }
  }
  // 24 additional grays (indices 248-255 — only 8 slots left, fill with grays)
  for (let i = 248; i < 256; i++) {
    const v = Math.round((i - 248) * 255 / 7);
    pal[i*3] = v; pal[i*3+1] = v; pal[i*3+2] = v;
  }
  return pal;
}

// ============================================================
// VGACraft enhanced palette: 14 hues × 16 shades + 32 grays = 256
// ============================================================
// Physically-based sinusoidal saturation: S(shade) = sin(shade/15 * π) * 0.95
// Non-uniform hue placement: warm tones clustered (human vision sensitivity),
// cool tones spread more loosely.
// ============================================================
function vgacraftPalette() {
  const pal = new Uint8Array(768);

  // --- 32 grayscale entries (indices 0-31) ---
  for (let i = 0; i < 32; i++) {
    const v = Math.round(i * 255 / 31);
    pal[i * 3] = v;
    pal[i * 3 + 1] = v;
    pal[i * 3 + 2] = v;
  }

  // --- 14 hue ramps × 16 shades (indices 32-255) ---
  // Non-uniform hue placement: reds/warm tones clustered tightly,
  // blues/violets spread loosely (perceptual uniformity)
  const hues = [
    0,    // 0: pure red
    25,   // 1: red-orange
    45,   // 2: orange
    65,   // 3: amber/gold
    90,   // 4: yellow-green
    120,  // 5: green
    150,  // 6: teal
    180,  // 7: cyan
    210,  // 8: sky blue
    240,  // 9: blue
    270,  // 10: indigo
    300,  // 11: magenta
    330,  // 12: rose/pink
    15    // 13: warm red-orange (skin tones / firelight)
  ];

  function hslToRgb(h, s, l) {
    h = ((h % 360) + 360) % 360;
    const c = (1 - Math.abs(2 * l - 1)) * s;
    const x = c * (1 - Math.abs((h / 60) % 2 - 1));
    const m = l - c / 2;
    let r, g, b;
    if (h < 60) { r = c; g = x; b = 0; }
    else if (h < 120) { r = x; g = c; b = 0; }
    else if (h < 180) { r = 0; g = c; b = x; }
    else if (h < 240) { r = 0; g = x; b = c; }
    else if (h < 300) { r = x; g = 0; b = c; }
    else { r = c; g = 0; b = x; }
    return [
      Math.round((r + m) * 255),
      Math.round((g + m) * 255),
      Math.round((b + m) * 255)
    ];
  }

  for (let hi = 0; hi < 14; hi++) {
    const hue = hues[hi];
    for (let sh = 0; sh < 16; sh++) {
      const idx = 32 + hi * 16 + sh;
      // Lightness: shade 0 = black, shade 15 = white
      const lightness = sh / 15;
      // Sinusoidal saturation curve: peaks at mid-lightness, drops at extremes
      // S(shade) = sin(shade/15 * π) * 0.95
      const saturation = Math.sin(sh / 15 * Math.PI) * 0.95;
      const [r, g, b] = hslToRgb(hue, saturation, lightness);
      pal[idx * 3] = r;
      pal[idx * 3 + 1] = g;
      pal[idx * 3 + 2] = b;
    }
  }

  return pal;
}

// Build a nearest-color lookup table (32KB: 32×32×32 RGB cube → palette index)
// Written into WASM memory so the WAT code can do fast lookups
function buildColorLUT(pal) {
  const lut = new Uint8Array(32768); // 32*32*32
  // Pre-extract palette RGB
  const palR = new Uint8Array(256);
  const palG = new Uint8Array(256);
  const palB = new Uint8Array(256);
  for (let i = 0; i < 256; i++) {
    palR[i] = pal[i * 3];
    palG[i] = pal[i * 3 + 1];
    palB[i] = pal[i * 3 + 2];
  }
  for (let ri = 0; ri < 32; ri++) {
    const r = ri * 255 / 31;
    for (let gi = 0; gi < 32; gi++) {
      const g = gi * 255 / 31;
      for (let bi = 0; bi < 32; bi++) {
        const b = bi * 255 / 31;
        let bestIdx = 0, bestDist = Infinity;
        for (let p = 0; p < 256; p++) {
          const dr = r - palR[p];
          const dg = g - palG[p];
          const db = b - palB[p];
          // Weighted perceptual distance (approximate)
          const dist = dr * dr * 2 + dg * dg * 4 + db * db;
          if (dist < bestDist) { bestDist = dist; bestIdx = p; }
        }
        lut[(ri << 10) | (gi << 5) | bi] = bestIdx;
      }
    }
  }
  return lut;
}

// Write VGACraft palette + LUT into WASM memory after init
// LUT goes at 0x20000 (32KB), palette at 0x0040
// Also writes block-type base RGB table at 0x19500 (9*3=27 bytes)
function installVgacraftPalette() {
  const pal = vgacraftPalette();
  const lut = buildColorLUT(pal);

  // Write palette
  memU8.set(pal, PAL_OFFSET);

  // Write LUT at 0x20000 (safe area past caches)
  memU8.set(lut, 0x20000);

  // Write channel levels table at 0x19600 for sky palette updates
  // The new palette stores actual RGB, so sky palette is set via $set_pal
  // which writes directly to palette memory. We keep the channel table
  // for backward compat but it's not used for the main dithering anymore.
  // Store hue ramp info for the WASM-side palette updater:
  // At 0x19608: 14 hue values (as degrees, u16 each) = 28 bytes
  const hues = [0, 25, 45, 65, 90, 120, 150, 180, 210, 240, 270, 300, 330, 15];
  for (let i = 0; i < 14; i++) {
    memU8[0x19608 + i * 2] = hues[i] & 0xFF;
    memU8[0x19608 + i * 2 + 1] = (hues[i] >> 8) & 0xFF;
  }

  // Block type base colors as 24-bit RGB at 0x19500 (9 entries × 3 bytes = 27 bytes)
  // These replace the old RGBL base indices
  const blockColors = [
    [0, 0, 0],       // 0: air (unused)
    [50, 180, 50],    // 1: grass - vivid green
    [140, 90, 50],    // 2: dirt - brown
    [130, 130, 130],  // 3: stone - gray
    [220, 210, 120],  // 4: sand - warm yellow
    [30, 80, 200],    // 5: water - blue
    [110, 80, 40],    // 6: wood - dark brown
    [30, 120, 30],    // 7: leaves - dark green
    [60, 60, 60],     // 8: coal - dark gray
  ];
  for (let i = 0; i < 9; i++) {
    memU8[0x19500 + i * 3] = blockColors[i][0];
    memU8[0x19500 + i * 3 + 1] = blockColors[i][1];
    memU8[0x19500 + i * 3 + 2] = blockColors[i][2];
  }

  // Monster base colors as 24-bit RGB at 0x1951B (3 entries × 3 bytes)
  const monsterColors = [
    [30, 120, 30],    // creeper: dark green
    [100, 140, 40],   // zombie: olive
    [220, 215, 190],  // skeleton: bone
  ];
  for (let i = 0; i < 3; i++) {
    memU8[0x1951B + i * 3] = monsterColors[i][0];
    memU8[0x1951B + i * 3 + 1] = monsterColors[i][1];
    memU8[0x1951B + i * 3 + 2] = monsterColors[i][2];
  }
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
  if (recorder) recCtx.drawImage(canvas, 0, 0, recCanvas.width, recCanvas.height);
}

function loop(ts) {
  if (paused) { animId = requestAnimationFrame(loop); return; }

  // write control block
  memU32[0] = frameCount++;         // frame counter (monotonic)
  fpsFrames++;
  memU32[3] = (ts | 0);            // tick_ms

  // call guest frame
  if (wasmInstance.exports.frame) {
    wasmInstance.exports.frame();
  }

  blitFramebuffer();

  // fps
  if (ts - lastFpsTime > 1000) {
    document.getElementById('info').textContent = `fps: ${fpsFrames} | frame: ${memU32[0]}`;
    fpsFrames = 0;
    lastFpsTime = ts;
  }

  animId = requestAnimationFrame(loop);
}

function togglePause() {
  paused = !paused;
  const btn = document.getElementById('pause-btn');
  if (btn) btn.textContent = paused ? '|>' : '||';
  const overlay = document.getElementById('pause-overlay');
  if (overlay) overlay.style.display = paused ? 'flex' : 'none';
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

// Detect if canvas is CSS-rotated (portrait mode toggled by user)
function isCanvasRotated() {
  return document.body.classList.contains('portrait-mode');
}

canvas.addEventListener('mousemove', (e) => {
  const rect = canvas.getBoundingClientRect();
  if (isCanvasRotated()) {
    // CSS rotate(-90deg): visual X maps to canvas Y (inverted), visual Y maps to canvas X
    const relX = (e.clientX - rect.left) / rect.width;
    const relY = (e.clientY - rect.top) / rect.height;
    setMousePos(relY * WIDTH, (1 - relX) * HEIGHT);
  } else {
    setMousePos((e.clientX - rect.left) / rect.width * WIDTH,
                (e.clientY - rect.top) / rect.height * HEIGHT);
  }
});
canvas.addEventListener('mousedown', (e) => {
  e.preventDefault(); ensureAudio();
  const btn = (e.button === 0 && e.ctrlKey) ? 2 : e.button;
  setMouseBtn(btn, true); canvas.focus();
});
canvas.addEventListener('mouseup', (e) => {
  e.preventDefault();
  const btn = (e.button === 0 && e.ctrlKey) ? 2 : e.button;
  setMouseBtn(btn, false);
});
canvas.addEventListener('contextmenu', (e) => e.preventDefault());

// --- Touch → mouse mapping on canvas ---
function touchToMouse(e) {
  const t = e.touches[0] || e.changedTouches[0];
  if (!t) return;
  const rect = canvas.getBoundingClientRect();
  if (isCanvasRotated()) {
    // CSS rotate(-90deg): visual X maps to canvas Y (inverted), visual Y maps to canvas X
    const relX = (t.clientX - rect.left) / rect.width;
    const relY = (t.clientY - rect.top) / rect.height;
    setMousePos(relY * WIDTH, (1 - relX) * HEIGHT);
  } else {
    setMousePos((t.clientX - rect.left) / rect.width * WIDTH,
                (t.clientY - rect.top) / rect.height * HEIGHT);
  }
}
canvas.addEventListener('touchstart', (e) => { e.preventDefault(); ensureAudio(); touchToMouse(e); }, { passive: false });
canvas.addEventListener('touchmove', (e) => { e.preventDefault(); touchToMouse(e); }, { passive: false });
canvas.addEventListener('touchend', (e) => { e.preventDefault(); }, { passive: false });
canvas.addEventListener('touchcancel', () => {});

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
  if (e.code === 'KeyP' || e.key === 'p' || e.key === 'P') {
    e.preventDefault(); e.stopPropagation();
    if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    togglePause(); return;
  }
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
    btn.addEventListener('touchstart', (e) => { e.preventDefault(); e.stopPropagation(); btn.classList.add('active'); setKeyBit(bit, true); }, { passive: false });
    btn.addEventListener('touchend', (e) => { e.preventDefault(); e.stopPropagation(); btn.classList.remove('active'); setKeyBit(bit, false); }, { passive: false });
    btn.addEventListener('touchcancel', (e) => { e.stopPropagation(); btn.classList.remove('active'); setKeyBit(bit, false); });
  });

  // Fire button → mouse left click
  el.querySelectorAll('[data-mouse]').forEach(btn => {
    const bit = parseInt(btn.dataset.mouse);
    btn.addEventListener('touchstart', (e) => { e.preventDefault(); e.stopPropagation(); btn.classList.add('active'); setMouseBtn(bit, true); }, { passive: false });
    btn.addEventListener('touchend', (e) => { e.preventDefault(); e.stopPropagation(); btn.classList.remove('active'); setMouseBtn(bit, false); }, { passive: false });
    btn.addEventListener('touchcancel', (e) => { e.stopPropagation(); btn.classList.remove('active'); setMouseBtn(bit, false); });
  });
}

async function loadDemo() {
  if (recorder) stopRecording();
  if (animId) { cancelAnimationFrame(animId); animId = null; }

  const name = document.getElementById('demo').value;
  history.replaceState(null, '', '#' + name);

  // 10 pages = 640KB (extra for octree cache in vgacraft)
  memory = new WebAssembly.Memory({ initial: 10 });
  memU8  = new Uint8Array(memory.buffer);
  memU32 = new Uint32Array(memory.buffer);

  // write default palette
  memU8.set(defaultPalette(), PAL_OFFSET);

  // clear framebuffer
  memU8.fill(0, FB_OFFSET, FB_OFFSET + FB_SIZE);

  // stop any playing music from previous demo
  if (musicInterval) { clearInterval(musicInterval); musicInterval = null; }

  const imports = {
    env: { memory, sfx, note, music }
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

    // Install enhanced palette for vgacraft after init
    if (name === 'vgacraft') {
      installVgacraftPalette();
    }

    frameCount = 0;
    fpsFrames = 0;
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
