// Load wabt.js for in-browser WAT->WASM compilation
const wabtReady = WabtModule();

// VGA Mode 13h Harness
// Memory layout:
//   0x0000 - 0x003F  control block (64 bytes)
//   0x0040 - 0x033F  palette (256 * 3 = 768 bytes)
//   0x0340 - 0x103F  framebuffer (320*200 = 64000 bytes)
//   0x10040+         free for guest
//
// ┌──────────────────────────────────────────────────────────────────────────┐
// │                  VGACraft Architecture — ASCII Diagrams                  │
// └──────────────────────────────────────────────────────────────────────────┘
//
// ═══════════════════════════════════════════════════════════════════════════
//  WASM MEMORY MAP (512KB linear memory — 8 pages)
// ═══════════════════════════════════════════════════════════════════════════
//
//  0x00000 ┌──────────────────────────────────┐
//          │  Harness Control Block (64B)     │  ← frame counter, tick_ms
//          │  [frame_ct|mouse_xy|btn|keys]    │    mouse pos, buttons, keyboard
//  0x00040 ├──────────────────────────────────┤
//          │  VGA Palette (768B)              │  ← 256 entries × 3 bytes (RGB)
//          │  [R G B] × 256 colors            │    Indices: 0-15 CGA, 16-95 terrain,
//          │                                  │    96-111 deco/water/floor,
//          │                                  │    128-175 monsters, 240-255 HUD
//  0x00340 ├──────────────────────────────────┤
//          │  Framebuffer (64000B)            │  ← 320×200 pixels, 1 byte each
//          │  ┌────────────────────320────┐   │    Written by WASM frame() export
//          │  │ sky gradient              │   │
//          │  │ ─ ─ ─ horizon ─ ─ ─ ─ ─  │   │
//          │  │ DDA raycasted terrain     │   │
//          │  │ billboard sprites         │   │
//          │  │ crosshair + HUD overlay   │   │
//          │  └───────────────────────200─┘   │
//  0x10340 ├──────────────────────────────────┤ ← Guest area starts
//          │  PRNG State (4B)                 │    xorshift32 seed
//  0x10344 ├──────────────────────────────────┤
//          │  Player State (64B)              │
//          │  px(f64) py(f64) angle(f64)      │    world position + facing
//          │  pz(f64) vz(f64) on_ground(i32)  │    height, velocity, grounded
//          │  bob_phase(f64)                  │    head bob animation
//  0x10390 ├──────────────────────────────────┤
//          │  Game State (32B)                │
//          │  mod_count, max_mods, gods_angry │    block modification tracking
//          │  msg_timer, dig_cooldown         │    UI timers
//          │  prev_mouse, selected_block      │    input state
//          │  look_y                          │    vertical look (y-shearing)
//  0x103B0 ├──────────────────────────────────┤
//          │  Z-Buffer (2560B)                │  ← 320 columns × f64 (8 bytes)
//          │  Per-column depth for sprite     │    Used for billboard occlusion
//          │  occlusion testing               │
//  0x10DB0 ├──────────────────────────────────┤
//          │  (gap)                           │
//  0x10E00 ├──────────────────────────────────┤
//          │  Monster Array (1024B)           │  ← 32 monsters × 32 bytes each
//          │  [active|type|wx(f64)|wy(f64)    │    3 types: creeper/zombie/skeleton
//          │   hp|anim_frame]                 │    Simple chase AI
//  0x11200 ├──────────────────────────────────┤
//          │  Modification Table (~30KB)      │  ← up to 1900 entries × 16 bytes
//          │  [wx(i32)|wy(i32)|wz(i32)|type]  │    Player-placed/dug blocks
//          │  Checked before procedural gen   │    Overlay on infinite terrain
//  0x19000 ├──────────────────────────────────┤
//          │  String Data                     │  ← null-terminated C strings
//          │  "VGACRAFT", control hints,      │    title, HUD labels, messages
//          │  "You angered the MC gods..."    │
//  0x19200 ├──────────────────────────────────┤
//          │  Font Data (4×6 bitmap font)     │  ← glyph bitmaps for HUD text
//  0x80000 └──────────────────────────────────┘
//
// ═══════════════════════════════════════════════════════════════════════════
//  RENDERING PIPELINE (per frame)
// ═══════════════════════════════════════════════════════════════════════════
//
//  ┌─────────────┐     ┌──────────────┐     ┌──────────────────────────┐
//  │ Read Inputs │────▶│ Update Player│────▶│ Physics & Collision      │
//  │ keys, mouse │     │ move, turn,  │     │ gravity, ground check,   │
//  │ from CTL blk│     │ look up/down │     │ terrain height query     │
//  └─────────────┘     └──────────────┘     └────────────┬─────────────┘
//                                                        │
//                                                        ▼
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │                    SKY GRADIENT FILL                                │
//  │  8-color palette gradient (pal 1-7) from top to horizon            │
//  │  Horizon line shifts with look_y (Duke3D y-shearing)               │
//  └────────────────────────────────┬────────────────────────────────────┘
//                                   │
//                                   ▼
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │              DDA RAYCASTER (320 columns)                           │
//  │                                                                    │
//  │  For each screen column:                                           │
//  │  ┌───────────────────────────────────────────────────────┐         │
//  │  │ 1. Compute ray angle (FOV ≈ 60°)                     │         │
//  │  │ 2. DDA grid traversal (Wolf3D-style stepping)         │         │
//  │  │ 3. At each cell hit:                                  │         │
//  │  │    ├─ get_column_top(map_x, map_y)                    │         │
//  │  │    ├─ For each block top→bottom:                      │         │
//  │  │    │   ├─ get_block(x,y,z) → check mod table first   │         │
//  │  │    │   │                    → then procedural gen      │         │
//  │  │    │   ├─ Project block to screen (variable height)   │         │
//  │  │    │   ├─ Apply face shading (top/bright/dim)         │         │
//  │  │    │   ├─ Apply distance fog                          │         │
//  │  │    │   └─ Texture pattern via block_texture()         │         │
//  │  │    └─ Store min depth in z-buffer                     │         │
//  │  │ 4. Max 40 DDA steps per ray                           │         │
//  │  └───────────────────────────────────────────────────────┘         │
//  └────────────────────────────────┬────────────────────────────────────┘
//                                   │
//                                   ▼
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │            BILLBOARD SPRITE RENDERER (24 monsters)                 │
//  │                                                                    │
//  │  For each active monster:                                          │
//  │  ┌───────────────────────────────────────────────────────┐         │
//  │  │ 1. AI update: walk toward player if dist > 3.0        │         │
//  │  │ 2. View-space transform:                              │         │
//  │  │    cx = dx·cos(θ) + dy·sin(θ)  (forward depth)       │         │
//  │  │    cy = -dx·sin(θ) + dy·cos(θ) (lateral offset)      │         │
//  │  │ 3. Perspective projection → screen_x, sprite_h       │         │
//  │  │ 4. Z-buffer test per column (depth occlusion)         │         │
//  │  │ 5. Procedural body rendering:                         │         │
//  │  │    ┌────┐                                             │         │
//  │  │    │head│  ← top 25% of sprite                       │         │
//  │  │    │body│  ← middle 50%, colored by type              │         │
//  │  │    │legs│  ← bottom 25%, animated bob                 │         │
//  │  │    └────┘  Creeper=green(128+), Zombie=brown(144+),   │         │
//  │  │            Skeleton=bone(160+)                        │         │
//  │  └───────────────────────────────────────────────────────┘         │
//  └────────────────────────────────┬────────────────────────────────────┘
//                                   │
//                                   ▼
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │                   HUD OVERLAY                                      │
//  │  ┌─ Crosshair (8 pixels, center screen) ──────────────────┐       │
//  │  │  Mods: N / MaxN  (block modification counter)          │       │
//  │  │  Title card (first 180 frames)                         │       │
//  │  │  "Gods angry" message box (when dig limit exceeded)    │       │
//  │  └────────────────────────────────────────────────────────┘       │
//  └─────────────────────────────────────────────────────────────────────┘
//
// ═══════════════════════════════════════════════════════════════════════════
//  PROCEDURAL TERRAIN GENERATION
// ═══════════════════════════════════════════════════════════════════════════
//
//  World coordinates (wx, wy) ──► terrain_height(wx, wy) ──► height 2-14
//
//        ┌───────────────────────────────────────────┐
//        │  smooth_hash(wx,wy,16) >> 5  (large hills)│
//        │  + smooth_hash(+1000,+2000,7) >> 6 (fine) │
//        │  + hash2d(+5000,+7000) & 1   (noise)      │
//        │  + base height 2                          │
//        │  clamped to [2, 14]                       │
//        └───────────────────────────────────────────┘
//
//  Block types at (wx, wy, wz):
//  ┌────────┐
//  │ leaves │ z = th+3 to th+6  (if has_tree nearby)
//  │  wood  │ z = th+1 to th+4  (if has_tree at exact pos)
//  │ grass  │ z = th            (top surface, height > 4)
//  │  sand  │ z = th            (top surface, height ≤ 4)
//  │  dirt  │ z = th-1, th-2    (subsurface)
//  │ stone  │ z < th-2          (deep underground)
//  │  coal  │ z < th-2          (random ore, ~3% chance)
//  │ water  │ z ≤ 4, th ≤ 4    (fills low areas)
//  │  air   │ z > th            (above terrain, no tree)
//  └────────┘
//
//  Modification overlay:
//  ┌──────────────────────────────────────────────────┐
//  │  get_block() checks mod table FIRST (linear scan)│
//  │  If (wx,wy,wz) found → return stored type        │
//  │  Else → procedural generation as above            │
//  │                                                   │
//  │  set_block() appends to mod table (or updates)    │
//  │  When mods > threshold → "gods angry" mechanic    │
//  └──────────────────────────────────────────────────┘
//
// ═══════════════════════════════════════════════════════════════════════════
//  PALETTE LAYOUT (256 colors)
// ═══════════════════════════════════════════════════════════════════════════
//
//  Index    Usage
//  ─────    ──────────────────────────────────────
//  0        Black (sky top / void)
//  1-7      Sky gradient (dark blue → light blue)
//  8-15     ─── (CGA legacy)
//  16-31    Grass tones (4 shades × light/face variants)
//  32-47    Dirt tones
//  48-63    Stone tones
//  64-79    Sand tones
//  80-95    Wood / Leaf tones
//  96-103   Decoration (flowers, dark foliage)
//  104-107  Water shimmer (animated via frame count)
//  108-111  Floor palette (ground between blocks)
//  128-143  Creeper sprite (green ramp, 16 shades)
//  144-159  Zombie sprite (brown ramp, 16 shades)
//  160-175  Skeleton sprite (bone-white ramp, 16 shades)
//  176-180  Special (white, yellow, dark, red, green)
//  240-247  HUD white text ramp
//  248-255  HUD red text ramp
//
// ═══════════════════════════════════════════════════════════════════════════
//  HARNESS ←→ WASM INTERFACE
// ═══════════════════════════════════════════════════════════════════════════
//
//  ┌─────────────┐                      ┌──────────────────┐
//  │   Browser    │                      │  WASM Module     │
//  │  (harness.js)│                      │  (vgacraft.wat)  │
//  │              │   shared memory      │                  │
//  │  writes CTL ─┼──────────────────────┼─► reads CTL      │
//  │  block every │   0x0000-0x003F      │   (input state)  │
//  │  rAF frame   │                      │                  │
//  │              │                      │  exports:        │
//  │  calls ──────┼──────────────────────┼─► init()         │
//  │  frame()     │                      │   frame()        │
//  │              │                      │                  │
//  │  reads FB  ◄─┼──────────────────────┼── writes FB      │
//  │  + palette   │   0x0040-0x103F      │   + palette      │
//  │              │                      │                  │
//  │  imports: ◄──┼──────────────────────┼── calls:         │
//  │  sfx()       │                      │   sfx(addr)      │
//  │  note()      │                      │   note(t,f,d,v)  │
//  │  music()     │                      │   music(addr)    │
//  │              │                      │                  │
//  │  blits to    │                      │                  │
//  │  canvas via  │                      │                  │
//  │  ImageData   │                      │                  │
//  └─────────────┘                      └──────────────────┘
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
  if (btn) btn.innerHTML = paused ? '&#9654;' : '&#9208;';
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

canvas.addEventListener('mousemove', (e) => {
  const rect = canvas.getBoundingClientRect();
  setMousePos((e.clientX - rect.left) / rect.width * WIDTH,
              (e.clientY - rect.top) / rect.height * HEIGHT);
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
  setMousePos((t.clientX - rect.left) / rect.width * WIDTH,
              (t.clientY - rect.top) / rect.height * HEIGHT);
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

  // 8 pages = 512KB
  memory = new WebAssembly.Memory({ initial: 8 });
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
