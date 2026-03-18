#!/usr/bin/env node
// Usage: node tools/screenshot.js <demo> <ms> [output.png]
// Loads a .wat demo, runs it to the given tick_ms, saves a screenshot.
// Requires: npm install wabt pngjs (or use npx)

const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');

const WIDTH = 320, HEIGHT = 200;
const PAL_OFFSET = 0x0040;
const FB_OFFSET = 0x0340;

async function main() {
  const [,, demoName, msStr, outFile] = process.argv;
  if (!demoName || !msStr) {
    console.error('Usage: node tools/screenshot.js <demo> <ms> [output.png]');
    process.exit(1);
  }
  const targetMs = parseInt(msStr);
  const output = outFile || `/tmp/vga_${demoName}_${targetMs}ms.png`;

  // Load and compile WAT
  const wabt = await require('wabt')();
  const watPath = path.join(__dirname, '..', 'demos', `${demoName}.wat`);
  const watSrc = fs.readFileSync(watPath, 'utf-8');
  const mod = wabt.parseWat(watPath, watSrc);
  const { buffer } = mod.toBinary({});

  // Set up memory (4 pages = 256KB)
  const memory = new WebAssembly.Memory({ initial: 4 });
  const memU8 = new Uint8Array(memory.buffer);
  const memU32 = new Uint32Array(memory.buffer);

  // Instantiate
  const { instance } = await WebAssembly.instantiate(buffer, { env: { memory } });

  // Write initial tick_ms before init (so init can capture start_tick)
  memU32[3] = targetMs; // tick_ms at offset 0x0C

  // Run init
  if (instance.exports.init) instance.exports.init();

  // Run frames: simulate ~60fps up to targetMs
  // The demo uses elapsed = (tick_ms - start_tick) % 64000
  // Since start_tick = targetMs (captured in init), we need to advance past it
  // Set tick_ms to targetMs + desired_elapsed
  const startTick = targetMs;
  const desiredElapsed = parseInt(process.argv[4]) || targetMs; // use ms arg as elapsed time

  // Actually: the demo captures start_tick = tick_ms at init time.
  // To get elapsed=E, we set tick_ms = start_tick + E and call frame().
  // But we need to run multiple frames for effects that accumulate (fire, rain).
  // Simulate at 60fps from elapsed=0 to elapsed=desiredElapsed.

  const fps = 60;
  const frameMs = 1000 / fps;
  const totalFrames = Math.ceil(targetMs / frameMs);

  for (let f = 0; f <= totalFrames; f++) {
    const elapsed = Math.min(f * frameMs, targetMs);
    memU32[0] = f;                    // frame counter
    memU32[3] = (startTick + elapsed) | 0; // tick_ms
    if (instance.exports.frame) instance.exports.frame();
  }

  // Read palette + framebuffer, produce PNG
  const png = new PNG({ width: WIDTH, height: HEIGHT });
  for (let i = 0; i < WIDTH * HEIGHT; i++) {
    const palIdx = memU8[FB_OFFSET + i];
    const p = PAL_OFFSET + palIdx * 3;
    const o = i * 4;
    png.data[o]     = memU8[p];
    png.data[o + 1] = memU8[p + 1];
    png.data[o + 2] = memU8[p + 2];
    png.data[o + 3] = 255;
  }

  const buf = PNG.sync.write(png);
  fs.writeFileSync(output, buf);
  console.log(`Saved ${output} (${totalFrames} frames simulated, elapsed=${targetMs}ms)`);
}

main().catch(e => { console.error(e); process.exit(1); });
