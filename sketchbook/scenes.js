// The artwork uses the repository's existing Spatula JavaScript curve port.
// Trajectories are composed curves. Flow integrates a spatial field rebuilt at
// the selected time, so scrubbing and exports do not depend on playback history.
import * as C from '../js_port/curve.js';
import { recipes, recipeSource, recipeStats } from './recipes.js';

export const WIDTH = 1584;
export const HEIGHT = 396;
const TAU = Math.PI * 2;

export const palettes = {
  ink: { bg: '#18221f', line: '#eedfbd', accent: '#d69170', text: '#ece8db', muted: '#a1ab98', grid: '#bcc7a2' },
  paper: { bg: '#e9e1d0', line: '#575d4c', accent: '#a5492f', text: '#303e33', muted: '#70745f', grid: '#5b6850' },
  moss: { bg: '#354a3d', line: '#dfdeb1', accent: '#efbc80', text: '#f0ead7', muted: '#b4bea5', grid: '#c7d4b4' },
};

export const studies = [
  { id: 'orbit', title: 'Orbit', subtitle: 'A little order.\nA little wonder.', description: 'Circles inside circles. Small shifts in phase turn a simple orbit into an intricate, living sculpture.', recipe: 'circle + phase + rotation', note: 'a collection of small revolutions', render: orbit },
  { id: 'bloom', title: 'Bloom', subtitle: 'Nature, in\na few lines.', description: 'Layered oscillations unfold into petals. A botanical drawing grown entirely from curves.', recipe: 'oscillation × radius + phase', note: 'nothing planted, everything grown', render: bloom },
  { id: 'flow', title: 'Flow', subtitle: 'Follow the\ninvisible.', description: 'Fine threads bend through a shifting field. Invisible sources leave their signature in every line.', recipe: 'distance → falloff → field gradient', note: 'a drawing of what cannot be seen', render: flow },
  { id: 'resonance', title: 'Resonance', subtitle: 'Small signals.\nShared rhythm.', description: 'Waves fall into and out of step, weaving a ribbon from the space between their frequencies.', recipe: 'wave + wave + phase', note: 'somewhere between order and noise', render: resonance },
  { id: 'convergence', title: 'Convergence', subtitle: 'Every point\nhas a place.', description: 'A cloud of individual points gathers into a name. A moment of clarity, before the next drift.', recipe: 'text form + distribution + easing', note: 'many small things, one idea', render: convergence },
];

const defaults = { time: 6, density: 1, palette: 'ink', signature: 'Julien Ribecco', lettering: true, showCode: false };

function path(ctx, x, y, start = 0, end = 1, steps = 240) {
  ctx.beginPath();
  for (let j = 0; j <= steps; j++) {
    const t = start + (end - start) * j / steps;
    const px = x(t), py = y(t);
    if (!j) ctx.moveTo(px, py); else ctx.lineTo(px, py);
  }
  ctx.stroke();
}

function pen(ctx, palette, i, alpha = .35) {
  ctx.strokeStyle = i % 6 < 2 ? palette.accent : palette.line;
  ctx.globalAlpha = alpha;
  ctx.lineWidth = i % 6 < 2 ? .82 : .6;
}

function orbit(ctx, p, o) {
  const count = Math.round(84 * o.density);
  const shift = o.time / 24;
  for (let i = 0; i < count; i++) {
    const phase = i / count * TAU;
    const [rx, ry] = recipes[0](phase, o.time);
    pen(ctx, p, i, .28 + (i % 5) * .05);
    path(ctx, rx, ry, shift * .08, 1 + shift * .08, 240);
    if (i % 9 === 0) {
      const t = (i / count + shift) % 1;
      ctx.fillStyle = p.accent; ctx.globalAlpha = .85;
      ctx.beginPath(); ctx.arc(rx(t), ry(t), 1.6, 0, TAU); ctx.fill();
    }
  }
}

function bloom(ctx, p, o) {
  const count = Math.round(94 * o.density);
  for (let i = 0; i < count; i++) {
    const layer = i / count;
    const [x, y] = recipes[1](layer, o.time);
    pen(ctx, p, i, .3 + layer * .22);
    path(ctx, x, y, 0, 1, 320);
  }
  ctx.globalAlpha = .7; ctx.fillStyle = p.accent;
  ctx.beginPath(); ctx.arc(0, 0, 2, 0, TAU); ctx.fill();
}

function flow(ctx, p, o) {
  const sources = [
    { x: -103 + C.sine(.035, 35)(o.time), y: C.cosine(.025, 27)(o.time), radius: 195, value: 1 },
    { x: 138 + C.cosine(.028, 28)(o.time), y: C.sine(.03, 51)(o.time), radius: 168, value: -.84 },
  ];
  const n = Math.round(108 * o.density);
  for (let i = 0; i < n; i++) {
    let x = -360, y = (i / (n - 1) - .5) * 324;
    const ripple = C.sine(1.25, 5, i * .016 + o.time * .05);
    const velocity = recipes[2](sources, ripple);
    pen(ctx, p, i, .39);
    ctx.beginPath(); ctx.moveTo(x, y);
    for (let s = 0; s < 390; s++) {
      const [vx, vy] = velocity(x, y, s / 390);
      x += vx; y += vy;
      ctx.lineTo(x, y);
      if (x > 366 || Math.abs(y) > 196) break;
    }
    ctx.stroke();
  }
  ctx.globalAlpha = .65;
  for (const s of sources) {
    ctx.strokeStyle = p.accent; ctx.lineWidth = .7;
    ctx.beginPath(); ctx.arc(s.x, s.y, 4, 0, TAU); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(s.x - 9, s.y); ctx.lineTo(s.x + 9, s.y);
    ctx.moveTo(s.x, s.y - 9); ctx.lineTo(s.x, s.y + 9); ctx.stroke();
  }
}

function resonance(ctx, p, o) {
  const n = Math.round(104 * o.density);
  for (let i = 0; i < n; i++) {
    const k = i / n;
    const [x, y] = recipes[3](k, o.time);
    pen(ctx, p, i, .44);
    path(ctx, x, y, 0, 1, 260);
  }
}

let textPoints;
function getTextPoints() {
  if (textPoints) return textPoints;
  const c = document.createElement('canvas'); c.width = 680; c.height = 140;
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.font = '104px Georgia'; ctx.textAlign = 'center'; ctx.fillText('SPATULA', 340, 106);
  const data = ctx.getImageData(0, 0, 680, 140).data;
  textPoints = [];
  for (let y = 16; y < 125; y += 2) for (let x = 28; x < 652; x += 2) {
    if (data[(y * 680 + x) * 4 + 3] > 120) textPoints.push([x - 340, y - 73]);
  }
  return textPoints;
}
function convergence(ctx, p, o) {
  const points = getTextPoints();
  const position = recipes[4](o.time);
  const step = o.density < .65 ? 2 : 1;
  for (let i = 0; i < points.length; i += step) {
    const [tx, ty] = points[i];
    const [x, y] = position(points[i], i);
    const dx = x - tx, dy = y - ty;
    ctx.globalAlpha = .6 + (i % 7) * .055;
    ctx.fillStyle = i % 7 < 2 ? p.accent : p.line;
    ctx.beginPath(); ctx.arc(x, y, i % 9 === 0 ? 1.35 : .86 * Math.sqrt(o.density), 0, TAU); ctx.fill();
    if (i % 17 === 0) {
      ctx.strokeStyle = p.accent; ctx.globalAlpha = .2; ctx.lineWidth = .55;
      ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(tx + dx * 1.5, ty + dy * 1.5); ctx.stroke();
    }
  }
}

function background(ctx, p) {
  ctx.fillStyle = p.bg; ctx.fillRect(0, 0, WIDTH, HEIGHT);
  ctx.fillStyle = p.grid; ctx.globalAlpha = .055;
  // A fixed, sparse paper grain: stable across exports and playback.
  let seed = 413;
  for (let i = 0; i < 4100; i++) {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    const x = seed / 4294967296 * WIDTH;
    seed = (seed * 1664525 + 1013904223) >>> 0;
    ctx.fillRect(x, seed / 4294967296 * HEIGHT, .65, .65);
  }
  ctx.globalAlpha = .11; ctx.strokeStyle = p.grid; ctx.lineWidth = .6;
  for (let x = 50; x < WIDTH; x += 48) for (let y = 48; y < HEIGHT; y += 48) {
    ctx.beginPath(); ctx.moveTo(x - 2, y); ctx.lineTo(x + 2, y); ctx.moveTo(x, y - 2); ctx.lineTo(x, y + 2); ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

function text(ctx, value, x, y, size, color, family = 'monospace') {
  ctx.font = `${size}px ${family}`; ctx.fillStyle = color; ctx.globalAlpha = 1; ctx.fillText(value, x, y);
}

function drawRecipe(ctx, p, index) {
  const lines = recipeSource(index).split('\n');
  const stats = recipeStats(index);
  text(ctx, `${studies[index].title}, in ${stats.lines} lines.`, 343, 97, 29, p.text, 'Georgia');
  text(ctx, 'C = SPATULA CURVE / JAVASCRIPT PORT', 344, 116, 8, p.muted);
  const font = Math.min(12.5, 560 / (Math.max(...lines.map(line => line.length)) * .61));
  const step = Math.min(16, 155 / lines.length);
  lines.forEach((line, i) => {
    const y = 145 + i * step;
    text(ctx, String(i + 1).padStart(2, '0'), 343, y, 8, p.muted);
    let x = 367;
    for (const token of line.split(/(\b(?:function|const|return)\b|C\.\w+|\b\d*\.?\d+\b)/g)) {
      const color = token.startsWith('C.') ? p.accent : /^(function|const|return|[\d.]+)$/.test(token) ? p.muted : p.text;
      text(ctx, token, x, y, font, color);
      x += ctx.measureText(token).width;
    }
  });
  text(ctx, `${stats.operations} CURVE OPERATIONS / SAMPLING & DRAWING IN THE RENDERER`, 344, 310, 8, p.muted);
}

export function render(canvas, studyIndex = 0, options = {}, thumbnail = false) {
  const o = { ...defaults, ...options };
  const p = palettes[o.palette] || palettes.ink;
  const study = studies[studyIndex];
  const code = o.showCode && o.lettering;
  const ctx = canvas.getContext('2d');
  ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, canvas.width, canvas.height);
  if (thumbnail) {
    ctx.fillStyle = p.bg; ctx.fillRect(0, 0, canvas.width, canvas.height);
    const scale = Math.min(canvas.width / 750, canvas.height / 320);
    ctx.translate(canvas.width / 2, canvas.height / 2); ctx.scale(scale, scale);
    study.render(ctx, p, { ...o, density: o.density * (study.id === 'convergence' ? 1 : .72) });
    ctx.restore(); return;
  }
  ctx.scale(canvas.width / WIDTH, canvas.height / HEIGHT);
  background(ctx, p);
  ctx.save();
  ctx.beginPath(); ctx.rect(o.lettering ? (code ? 967 : 756) : 0, 12, o.lettering ? (code ? 589 : 800) : WIDTH, o.lettering ? 305 : 372); ctx.clip();
  ctx.translate(o.lettering ? (code ? 1250 : 1145) : WIDTH / 2, o.lettering ? 173 : HEIGHT / 2);
  if (!o.lettering) ctx.scale(1.5, 1.04); else ctx.scale(code ? .75 : 1, .88);
  study.render(ctx, p, o);
  ctx.restore();
  if (o.lettering) {
    text(ctx, 'S P A T U L A   /   M O T I O N   S K E T C H B O O K', 64, 53, 10, p.muted);
    if (code) drawRecipe(ctx, p, studyIndex);
    else {
      text(ctx, 'Simple rules.', 340, 151, 54, p.text, 'Georgia');
      ctx.font = 'italic 54px Georgia'; ctx.fillStyle = p.accent; ctx.fillText('Complex motion.', 340, 214);
      text(ctx, 'A few curves. A little curiosity.', 343, 252, 13, p.muted, 'Arial');
    }
    // Signature is measured to stay within its reserved area at maximum length.
    let size = 18;
    ctx.font = `${size}px Georgia`;
    while (ctx.measureText(o.signature).width > 366 && size > 10) ctx.font = `${--size}px Georgia`;
    text(ctx, o.signature, 343, 331, size, p.text, 'Georgia');
    text(ctx, 'CREATIVE CODING / GENERATIVE SYSTEMS', 343, 353, 8, p.muted);
    text(ctx, `${String(studyIndex + 1).padStart(2, '0')}  /  ${study.title.toUpperCase()}`, code ? 984 : 847, 350, 10, p.text);
    ctx.textAlign = 'right';
    text(ctx, study.note, 1519, 350, 11, p.muted, 'Georgia');
    text(ctx, 'FIVE STUDIES IN COMPOSITION', 1519, 53, 8, p.muted);
    ctx.textAlign = 'left';
    ctx.strokeStyle = p.muted; ctx.globalAlpha = .33; ctx.lineWidth = .6;
    ctx.beginPath(); ctx.moveTo(code ? 984 : 847, 326); ctx.lineTo(1519, 326); ctx.stroke();
  }
  ctx.restore();
}

export function makeBanner(studyIndex, options = {}) {
  const canvas = document.createElement('canvas'); canvas.width = WIDTH; canvas.height = HEIGHT;
  // Inherit the same font-smoothing environment as the visible canvas. Detached
  // canvases can rasterize text differently in Chromium on macOS.
  canvas.hidden = true; document.body.append(canvas);
  try { render(canvas, studyIndex, options); } finally { canvas.remove(); }
  return canvas;
}

export async function pngBlob(canvas) {
  return new Promise((resolve, reject) => canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error('The browser could not create the PNG.')), 'image/png'));
}
