#!/usr/bin/env node
// Usage:
//   node tools/parens.js <file> [startLine] [endLine]     — show range
//   node tools/parens.js <file> -s <pattern> [-C N]       — search lines matching pattern
//   node tools/parens.js <file> -d <depth>                — show lines at exact depth
//   node tools/parens.js <file> --neg                     — show lines where depth goes negative
//   node tools/parens.js <file> --drops                   — show lines where depth drops (closes > opens)
//   node tools/parens.js <file> --summary                 — count opens/closes per top-level block

const fs = require('fs');
const args = process.argv.slice(2);
const file = args.shift();
if (!file) { console.error('Usage: node tools/parens.js <file> [options]'); process.exit(1); }

const lines = fs.readFileSync(file, 'utf8').split('\n');

// Parse flags
let mode = 'range';
let searchPat = null;
let targetDepth = null;
let context = 2;
let start = 1, end = Infinity;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '-s') { mode = 'search'; searchPat = new RegExp(args[++i]); }
  else if (args[i] === '-d') { mode = 'depth'; targetDepth = parseInt(args[++i]); }
  else if (args[i] === '--neg') { mode = 'neg'; }
  else if (args[i] === '--drops') { mode = 'drops'; }
  else if (args[i] === '--summary') { mode = 'summary'; }
  else if (args[i] === '-C') { context = parseInt(args[++i]); }
  else if (!isNaN(parseInt(args[i])) && start === 1 && mode === 'range') { start = parseInt(args[i]); }
  else if (!isNaN(parseInt(args[i])) && mode === 'range') { end = parseInt(args[i]); }
}

// Compute depth for every line
const depths = [];
const deltas = [];
let depth = 0;
for (let i = 0; i < lines.length; i++) {
  const opens = (lines[i].match(/\(/g) || []).length;
  const closes = (lines[i].match(/\)/g) || []).length;
  const delta = opens - closes;
  depth += delta;
  depths.push(depth);
  deltas.push(delta);
}

function fmt(i) {
  const d = depths[i];
  const delta = deltas[i];
  const tag = delta > 0 ? `+${delta}` : delta < 0 ? `${delta}` : ' 0';
  return `${String(i + 1).padStart(5)} d=${String(d).padStart(3)} ${tag.padStart(3)} | ${lines[i]}`;
}

function printRange(from, to) {
  for (let i = Math.max(0, from); i <= Math.min(lines.length - 1, to); i++) {
    process.stdout.write(fmt(i) + '\n');
  }
}

if (mode === 'range') {
  printRange(start - 1, (end === Infinity ? lines.length - 1 : end - 1));
  if (end === Infinity || end >= lines.length) {
    process.stdout.write(`\nFinal depth: ${depths[depths.length - 1]}\n`);
  }
} else if (mode === 'search') {
  let lastPrinted = -10;
  for (let i = 0; i < lines.length; i++) {
    if (searchPat.test(lines[i])) {
      const from = Math.max(0, i - context);
      const to = Math.min(lines.length - 1, i + context);
      if (from > lastPrinted + 1) process.stdout.write('  ---\n');
      for (let j = Math.max(from, lastPrinted + 1); j <= to; j++) {
        const marker = j === i ? '>>>' : '   ';
        const d = depths[j];
        const delta = deltas[j];
        const tag = delta > 0 ? `+${delta}` : delta < 0 ? `${delta}` : ' 0';
        process.stdout.write(`${marker}${String(j + 1).padStart(5)} d=${String(d).padStart(3)} ${tag.padStart(3)} | ${lines[j]}\n`);
      }
      lastPrinted = to;
    }
  }
} else if (mode === 'depth') {
  for (let i = 0; i < lines.length; i++) {
    if (depths[i] === targetDepth && lines[i].trim()) process.stdout.write(fmt(i) + '\n');
  }
} else if (mode === 'neg') {
  for (let i = 0; i < lines.length; i++) {
    if (depths[i] < 0) {
      printRange(i - context, i + context);
      process.stdout.write('  ---\n');
    }
  }
} else if (mode === 'drops') {
  for (let i = 0; i < lines.length; i++) {
    if (deltas[i] < -3) process.stdout.write(fmt(i) + '\n');
  }
} else if (mode === 'summary') {
  // Show each func/data with its line range and depth change
  let blockStart = null;
  let blockName = '';
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/\((func|data|import|memory|export)\s*(\$\S+)?/);
    if (m && (depths[i] - deltas[i]) <= 1) {
      if (blockStart !== null) {
        process.stdout.write(`  ${String(blockStart + 1).padStart(5)}-${String(i).padStart(5)}: ${blockName}\n`);
      }
      blockName = m[0];
      blockStart = i;
    }
  }
  if (blockStart !== null) {
    process.stdout.write(`  ${String(blockStart + 1).padStart(5)}-${String(lines.length).padStart(5)}: ${blockName}\n`);
  }
  process.stdout.write(`\nFinal depth: ${depths[depths.length - 1]}\n`);
}
