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

// --- Sound engine ---
let audioCtx = null, masterGain = null, isMuted = false;
let noiseBuffer = null;
let musicInterval = null, musicStep = 0;

function ensureAudio() {
  if (audioCtx) { if (audioCtx.state === 'suspended') audioCtx.resume(); return; }
  audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  masterGain = audioCtx.createGain();
  masterGain.connect(audioCtx.destination);
  // pre-generate noise buffer
  noiseBuffer = audioCtx.createBuffer(1, audioCtx.sampleRate / 5, audioCtx.sampleRate);
  const data = noiseBuffer.getChannelData(0);
  for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
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

function sfx(id) {
  ensureAudio();
  switch (id) {
    case 0: // laser
      playTone('square', 880, 0.08, 0.15, 220);
      break;
    case 1: // explosion
      playNoise(0.12, 0.3);
      playTone('sine', 60, 0.15, 0.2);
      break;
    case 2: // pickup — triumphant rising arpeggio
      playTone('square', 523, 0.06, 0.18);
      playTone('sine', 523, 0.06, 0.1);
      setTimeout(() => { if (audioCtx) { playTone('square', 659, 0.06, 0.18); playTone('sine', 659, 0.06, 0.1); } }, 60);
      setTimeout(() => { if (audioCtx) { playTone('square', 784, 0.06, 0.18); playTone('sine', 784, 0.06, 0.1); } }, 120);
      setTimeout(() => { if (audioCtx) { playTone('square', 1047, 0.12, 0.2); playTone('sine', 1047, 0.12, 0.12); } }, 180);
      break;
    case 3: // hit — heavy crunch, low rumble + noise
      playNoise(0.15, 0.35);
      playTone('square', 150, 0.12, 0.25, 30);
      playTone('sawtooth', 80, 0.2, 0.15, 20);
      setTimeout(() => { if (audioCtx) { playNoise(0.08, 0.2); playTone('sine', 40, 0.15, 0.15); } }, 80);
      break;
    case 4: // boss
      playTone('sawtooth', 110, 0.2, 0.2);
      break;
  }
}

function note(oscType, freq, durMs, vol255) {
  ensureAudio();
  const types = ['sine', 'square', 'sawtooth', 'triangle'];
  playTone(types[oscType & 3] || 'sine', freq || 440, (durMs || 100) / 1000, (vol255 || 128) / 255 * 0.3);
}

// Music — 3-track sequencer (bass, arp, lead) per song
// Each track: [freq, ...] where 0 = rest. Step = 16th note.
// Frequencies: C2=65 D2=73 E2=82 F2=87 G2=98 A2=110 B2=123
//   C3=131 D3=147 E3=165 F3=175 G3=196 A3=220 Bb3=233 B3=247
//   C4=262 D4=294 E4=330 F4=349 G4=392 A4=440 Bb4=466 B4=494
//   C5=523 D5=587 E5=659 F5=698 G5=784 A5=880

const musicPatterns = {
  1: { // INTRO — ominous space ambient, Am → Em → Dm → E
    bpm: 100,
    tracks: [
      { // bass — low octave pedal tones, slow pulse
        type: 'triangle', vol: 0.12, dur: 0.4,
        notes: [
          110,0,0,0, 0,0,110,0, 0,0,0,0, 110,0,0,0,  // Am pedal
          82,0,0,0,  0,0,82,0,  0,0,0,0, 82,0,0,0,    // Em pedal
          73,0,0,0,  0,0,73,0,  0,0,0,0, 73,0,0,0,    // Dm pedal
          82,0,0,0,  0,0,0,0,   82,0,82,0, 0,0,0,0,   // E with rhythm
        ],
      },
      { // pad — sustained minor chords, eerie
        type: 'sine', vol: 0.06, dur: 0.5,
        notes: [
          220,0,0,262, 0,0,220,0, 330,0,0,0, 262,0,220,0,  // Am tones
          165,0,0,196, 0,0,247,0, 0,0,196,0, 165,0,0,0,    // Em tones
          147,0,0,175, 0,0,220,0, 0,0,175,0, 147,0,0,0,    // Dm tones
          165,0,0,208, 0,0,247,0, 330,0,0,0, 247,0,208,0,  // E tones
        ],
      },
      { // high — sparse, haunting melody
        type: 'sine', vol: 0.05, dur: 0.3,
        notes: [
          0,0,0,0, 523,0,0,0, 0,0,0,0, 0,0,440,0,      // A minor hint
          0,0,0,0, 494,0,0,0, 0,0,0,0, 0,0,0,0,         // B over Em
          0,0,0,0, 440,0,0,0, 0,0,0,0, 0,0,349,0,       // F over Dm
          0,0,0,0, 0,0,416,0, 0,0,0,0, 494,0,0,0,       // G#→B over E
        ],
      },
    ],
  },

  2: { // GAMEPLAY — aggressive driving chiptune, Am: i-VII-VI-V
    bpm: 150,
    tracks: [
      { // bass — pumping eighth-note pattern
        type: 'square', vol: 0.15, dur: 0.08,
        notes: [
          110,0,110,0, 110,0,110,110, 110,0,110,0, 110,0,165,0,  // Am bass
          98,0,98,0,   98,0,98,98,    98,0,98,0,   98,0,147,0,   // G bass
          87,0,87,0,   87,0,87,87,    87,0,87,0,   87,0,131,0,   // F bass
          82,0,82,0,   82,0,82,82,    82,0,82,0,   82,0,110,0,   // E bass → back
        ],
      },
      { // arp — fast arpeggios cycling chord tones
        type: 'triangle', vol: 0.12, dur: 0.06,
        notes: [
          440,523,659,523, 440,523,659,784, 659,523,440,523, 659,784,659,523,  // Am arp
          392,494,587,494, 392,494,587,784, 587,494,392,494, 587,784,587,494,  // G arp
          349,440,523,440, 349,440,523,698, 523,440,349,440, 523,698,523,440,  // F arp
          330,416,494,416, 330,416,494,659, 494,416,330,416, 494,659,494,416,  // E arp
        ],
      },
      { // lead — catchy 8-bit melody
        type: 'square', vol: 0.10, dur: 0.12,
        notes: [
          880,0,784,880, 0,0,659,0, 784,0,659,0, 523,0,659,0,   // melody A
          784,0,659,784, 0,0,587,0, 494,0,587,0, 494,0,392,0,   // melody B
          698,0,659,698, 0,0,523,0, 440,0,523,0, 440,0,349,0,   // melody C
          659,0,0,494,   659,0,784,0, 880,0,784,659, 0,0,0,0,   // melody D (resolve)
        ],
      },
    ],
  },

  3: { // GAME OVER — slow, tragic, Dm → Bb → Gm → A
    bpm: 80,
    tracks: [
      { // bass — slow heartbeat
        type: 'triangle', vol: 0.12, dur: 0.35,
        notes: [
          73,0,0,0, 0,0,0,0, 73,0,0,0, 0,0,0,0,    // Dm
          58,0,0,0, 0,0,0,0, 58,0,0,0, 0,0,0,0,    // Bb (Bb1=58)
          49,0,0,0, 0,0,0,0, 49,0,0,0, 0,0,0,0,    // Gm (G1=49)
          55,0,0,0, 0,0,0,0, 55,0,55,0, 0,0,0,0,   // A (A1=55)
        ],
      },
      { // chords — descending minor
        type: 'sine', vol: 0.08, dur: 0.4,
        notes: [
          294,0,0,349, 0,0,0,0, 262,0,0,0, 0,0,0,0,   // Dm chord
          233,0,0,294, 0,0,0,0, 233,0,0,0, 0,0,0,0,   // Bb chord
          196,0,0,233, 0,0,0,0, 196,0,0,0, 0,0,0,0,   // Gm chord
          220,0,0,277, 0,0,0,0, 220,0,0,0, 0,0,0,0,   // A chord
        ],
      },
      { // melody — descending lament
        type: 'sine', vol: 0.07, dur: 0.3,
        notes: [
          587,0,0,0, 523,0,0,0, 440,0,0,0, 0,0,0,0,   // D5 C5 A4
          466,0,0,0, 440,0,0,0, 349,0,0,0, 0,0,0,0,   // Bb4 A4 F4
          392,0,0,0, 349,0,0,0, 294,0,0,0, 0,0,0,0,   // G4 F4 D4
          330,0,0,0, 277,0,0,0, 220,0,0,0, 0,0,0,0,   // E4 C#4 A3
        ],
      },
    ],
  },

  4: { // BOSS FIGHT — fast, intense, dissonant. Em → F → G → Ab (chromatic tension)
    bpm: 180,
    tracks: [
      { // bass — relentless pounding
        type: 'sawtooth', vol: 0.18, dur: 0.07,
        notes: [
          82,82,0,82, 82,0,82,0, 82,82,0,82, 0,82,82,0,   // Em pounding
          87,87,0,87, 87,0,87,0, 87,87,0,87, 0,87,87,0,   // F
          98,98,0,98, 98,0,98,0, 98,98,0,98, 0,98,98,0,   // G
          104,104,0,104, 104,0,104,0, 104,104,0,104, 0,82,82,0, // Ab→Em
        ],
      },
      { // arp — frantic dissonant arpeggios
        type: 'square', vol: 0.12, dur: 0.05,
        notes: [
          330,494,659,494, 330,659,494,659, 330,494,659,784, 659,494,330,494,  // Em
          349,523,698,523, 349,698,523,698, 349,523,698,880, 698,523,349,523,  // F
          392,587,784,587, 392,784,587,784, 392,587,784,988, 784,587,392,587,  // G
          415,622,831,622, 415,831,622,831, 415,622,831,1047, 831,622,330,494, // Ab→Em
        ],
      },
      { // lead — menacing descending riff
        type: 'sawtooth', vol: 0.10, dur: 0.1,
        notes: [
          659,0,622,0, 659,0,784,0, 659,0,494,0, 0,0,330,0,   // Em riff
          698,0,659,0, 698,0,880,0, 698,0,523,0, 0,0,349,0,   // F riff
          784,0,698,0, 784,0,988,0, 784,0,587,0, 0,0,392,0,   // G riff
          831,0,784,0, 880,0,1047,0, 880,0,659,0, 0,0,0,0,    // Ab climax
        ],
      },
    ],
  },
};
let currentMusicCmd = 0;

function music(cmd) {
  ensureAudio();
  if (musicInterval) { clearInterval(musicInterval); musicInterval = null; }
  currentMusicCmd = cmd;
  if (cmd === 0) return;
  const p = musicPatterns[cmd];
  if (!p) return;
  musicStep = 0;
  const interval = 60000 / p.bpm / 4;
  musicInterval = setInterval(() => {
    if (!audioCtx || isMuted) return;
    for (const tr of p.tracks) {
      const freq = tr.notes[musicStep % tr.notes.length];
      if (freq) playTone(tr.type, freq, tr.dur, tr.vol);
    }
    musicStep++;
  }, interval);
}

function toggleMute() {
  isMuted = !isMuted;
  if (masterGain) masterGain.gain.value = isMuted ? 0 : 1;
  if (isMuted) {
    if (musicInterval) { clearInterval(musicInterval); musicInterval = null; }
  } else if (currentMusicCmd) {
    const saved = currentMusicCmd;
    currentMusicCmd = 0; // reset so music() doesn't skip
    music(saved);
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
canvas.addEventListener('mousedown', (e) => { ensureAudio(); setMouseBtn(e.button, true); canvas.focus(); });
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
canvas.addEventListener('touchstart', (e) => { e.preventDefault(); ensureAudio(); touchToMouse(e); setMouseBtn(0, true); }, { passive: false });
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
