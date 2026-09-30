import { studies, render, makeBanner, pngBlob, palettes } from './scenes.js';
import { createZip } from './zip.js';
import { recipeSource, recipeNotes, recipeStats } from './recipes.js';

const $ = selector => document.querySelector(selector);
const canvas = $('#artwork');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const storageKey = 'spatula-sketchbook-v1';
const state = { study: 0, time: 6, palette: 'ink', density: 1, signature: 'Julien Ribecco', lettering: true, showCode: false };
const moments = [6, 6, 6, 6, 12];
let playing = !reducedMotion.matches, slideshow = false, slideElapsed = 0, lastFrame = 0, lastDraw = 0;
let exporting = false;

try {
  const saved = JSON.parse(localStorage.getItem(storageKey));
  if (saved && typeof saved === 'object') {
    if (palettes[saved.palette]) state.palette = saved.palette;
    if (Number.isFinite(saved.density)) state.density = Math.max(.5, Math.min(1.5, saved.density));
    if (typeof saved.signature === 'string') state.signature = saved.signature.slice(0, 32);
    if (typeof saved.lettering === 'boolean') state.lettering = saved.lettering;
    if (typeof saved.showCode === 'boolean') state.showCode = saved.showCode && state.lettering;
  }
} catch { /* Storage is optional, including in private browser sessions. */ }
if (new URLSearchParams(window.location.search).get('code') === '1') {
  state.showCode = true; state.lettering = true;
}
if (state.showCode) $('#source-panel').open = true;

function savePreferences() {
  try { localStorage.setItem(storageKey, JSON.stringify(state)); } catch { /* optional */ }
}
function draw() {
  render(canvas, state.study, state);
  $('#time').value = state.time;
  $('#time-value').textContent = `${state.time.toFixed(2).padStart(5, '0')} s`;
}
function drawThumbnails() {
  for (let i = 0; i < studies.length; i++) {
    render(document.querySelector(`[data-study="${i}"] canvas`), i, { ...state, time: moments[i] }, true);
  }
}
function updatePlayback() {
  $('#play').setAttribute('aria-pressed', String(playing));
  $('#play').setAttribute('aria-label', playing ? 'Pause motion' : 'Play motion');
  $('#play-icon').textContent = playing ? 'Ⅱ' : '▷';
  $('#preview-state').textContent = slideshow ? 'SLIDESHOW / 3s' : playing ? 'LIVE CANVAS' : 'A MOMENT, HELD';
  $('.live-dot').style.background = playing || slideshow ? '#8b9a74' : '#b7ad9c';
  $('#slideshow').setAttribute('aria-pressed', String(slideshow));
  $('#slideshow span:last-child').textContent = slideshow ? 'Stop slideshow' : 'Preview slideshow';
}
function selectStudy(index, manual = true) {
  moments[state.study] = state.time;
  state.study = index; state.time = moments[index];
  if (manual) { slideshow = false; slideElapsed = 0; }
  for (const button of document.querySelectorAll('.study-card')) button.setAttribute('aria-pressed', String(Number(button.dataset.study) === index));
  const study = studies[index];
  $('#study-number').textContent = `STUDY ${String(index + 1).padStart(2, '0')} / ${study.title.toUpperCase()}`;
  $('#study-heading').replaceChildren();
  study.subtitle.split('\n').forEach((line, i) => { if (i) $('#study-heading').append(document.createElement('br')); $('#study-heading').append(document.createTextNode(`${line} `)); });
  $('#study-description').textContent = study.description;
  $('#study-recipe').textContent = study.recipe;
  updateSource();
  canvas.setAttribute('aria-label', `${study.title}: ${study.description}`);
  updatePlayback(); draw();
}

studies.forEach((study, index) => {
  const button = document.createElement('button');
  button.className = 'study-card'; button.dataset.study = index;
  button.setAttribute('aria-pressed', String(index === 0));
  button.setAttribute('aria-label', `Select ${study.title} study`);
  const frame = document.createElement('div'); frame.className = 'thumb-wrap';
  const thumb = document.createElement('canvas'); thumb.width = 480; thumb.height = 180; thumb.setAttribute('aria-hidden', 'true');
  frame.append(thumb);
  const caption = document.createElement('div'); caption.className = 'card-caption';
  for (const [name, value] of [['card-number', String(index + 1).padStart(2, '0')], ['card-title', study.title], ['card-check', '↗']]) {
    const span = document.createElement('span'); span.className = name; span.textContent = value; caption.append(span);
  }
  button.append(frame, caption); button.addEventListener('click', () => selectStudy(index));
  button.addEventListener('keydown', event => {
    if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
      event.preventDefault(); const next = (index + (event.key === 'ArrowRight' ? 1 : 4)) % 5;
      selectStudy(next); document.querySelector(`[data-study="${next}"]`).focus();
    }
  });
  $('#study-grid').append(button);
});

$('#play').addEventListener('click', () => { playing = !playing; if (slideshow) slideshow = false; updatePlayback(); });
$('#time').addEventListener('input', event => {
  state.time = Number(event.target.value); moments[state.study] = state.time;
  playing = false; slideshow = false; updatePlayback(); draw();
});
$('#slideshow').addEventListener('click', () => {
  slideshow = !slideshow; slideElapsed = 0;
  if (slideshow) playing = false; // LinkedIn changes still images, so preview held moments.
  updatePlayback();
});
$('#guide').addEventListener('click', () => {
  const visible = $('#profile-guide').hidden;
  $('#profile-guide').hidden = !visible; $('#guide').setAttribute('aria-pressed', String(visible));
});
for (const button of document.querySelectorAll('[data-palette]')) {
  button.addEventListener('click', () => {
    state.palette = button.dataset.palette;
    syncControls(); draw(); drawThumbnails(); savePreferences();
  });
}
$('#density').addEventListener('input', event => {
  state.density = Number(event.target.value); $('#density-value').textContent = `${Math.round(state.density * 100)}%`; draw();
});
$('#density').addEventListener('change', () => { drawThumbnails(); savePreferences(); });
$('#signature').addEventListener('input', event => { state.signature = event.target.value; draw(); savePreferences(); });
$('#lettering').addEventListener('change', event => {
  state.lettering = event.target.checked;
  if (!state.lettering) state.showCode = false;
  syncControls(); draw(); savePreferences();
});
$('#show-code').addEventListener('change', event => {
  state.showCode = event.target.checked;
  if (state.showCode) { state.lettering = true; $('#source-panel').open = true; }
  syncControls(); draw(); savePreferences();
});

function updateSource() {
  const stats = recipeStats(state.study);
  $('#source-title').textContent = studies[state.study].title;
  $('#source-summary').textContent = `${stats.lines} lines of composition`;
  $('#source-stats').textContent = `${stats.lines} lines · ${stats.characters} characters · ${stats.operations} Curve operations`;
  $('#recipe-code').textContent = recipeSource(state.study);
  $('#source-note').textContent = recipeNotes[state.study];
  $('#code-status').textContent = '';
}
$('#copy-code').addEventListener('click', async () => {
  const source = `import * as C from '../js_port/curve.js';\n\nexport ${recipeSource(state.study)}\n`;
  try {
    await navigator.clipboard.writeText(source);
    $('#code-status').textContent = 'Copied, including the Curve import.';
  } catch {
    const selection = window.getSelection(), range = document.createRange();
    range.selectNodeContents($('#recipe-code')); selection.removeAllRanges(); selection.addRange(range);
    $('#code-status').textContent = 'Recipe selected. Press ⌘C or Ctrl+C to copy.';
  }
});

function syncControls() {
  $('#signature').value = state.signature; $('#lettering').checked = state.lettering;
  $('#show-code').checked = state.showCode;
  $('#density').value = state.density; $('#density-value').textContent = `${Math.round(state.density * 100)}%`;
  for (const b of document.querySelectorAll('[data-palette]')) {
    const active = b.dataset.palette === state.palette;
    b.classList.toggle('active', active); b.setAttribute('aria-pressed', String(active));
  }
}
function download(blob, name) {
  const url = URL.createObjectURL(blob), link = document.createElement('a');
  link.href = url; link.download = name; document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
function filename(index) { return `spatula-${String(index + 1).padStart(2, '0')}-${studies[index].id}.png`; }
async function exportBanners(all) {
  if (exporting) return;
  exporting = true; playing = false; slideshow = false; moments[state.study] = state.time;
  updatePlayback(); draw();
  const options = { ...state }, times = [...moments];
  const captured = document.createElement('canvas');
  captured.width = canvas.width; captured.height = canvas.height;
  captured.getContext('2d').drawImage(canvas, 0, 0);
  $('#export-current').disabled = true; $('#export-all').disabled = true;
  $('#status').textContent = all ? 'Drawing your five studies…' : 'Saving this moment…';
  try {
    await new Promise(resolve => setTimeout(resolve, 30));
    if (all) {
      const files = [];
      for (let i = 0; i < studies.length; i++) {
        files.push({ name: filename(i), blob: await pngBlob(makeBanner(i, { ...options, time: times[i] })) });
        await new Promise(resolve => setTimeout(resolve, 0));
      }
      const manifest = { collection: 'Spatula — A motion sketchbook', width: 1584, height: 396, settings: options, moments: times };
      files.push({ name: 'settings.json', blob: new Blob([JSON.stringify(manifest, null, 2)], { type: 'application/json' }) });
      download(await createZip(files), 'spatula-motion-sketchbook.zip');
      $('#status').textContent = 'Five banners + your settings, saved together.';
    } else {
      // Snapshot the visible, paused canvas so font rasterization is identical.
      download(await pngBlob(captured), filename(options.study));
      $('#status').textContent = `${studies[options.study].title} is ready for your profile.`;
    }
  } catch (error) {
    $('#status').textContent = `Export failed: ${error.message} Please try again.`;
  } finally {
    exporting = false; $('#export-current').disabled = false; $('#export-all').disabled = false;
  }
}
$('#export-current').addEventListener('click', () => exportBanners(false));
$('#export-all').addEventListener('click', () => exportBanners(true));

function frame(now) {
  const dt = lastFrame ? Math.min((now - lastFrame) / 1000, .1) : 0;
  lastFrame = now;
  if (!document.hidden && !exporting) {
    if (slideshow) {
      slideElapsed += dt;
      if (slideElapsed >= 3) { slideElapsed -= 3; selectStudy((state.study + 1) % studies.length, false); }
    }
    if (playing) {
      state.time = (state.time + dt) % 24;
      if (now - lastDraw > 40) { draw(); lastDraw = now; }
    }
  }
  requestAnimationFrame(frame);
}
document.addEventListener('visibilitychange', () => { lastFrame = 0; });
reducedMotion.addEventListener('change', event => { if (event.matches) { playing = false; slideshow = false; updatePlayback(); } });

syncControls(); selectStudy(0); drawThumbnails(); requestAnimationFrame(frame);
