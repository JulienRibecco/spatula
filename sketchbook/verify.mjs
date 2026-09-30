import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = resolve(root, 'sketchbook/exports');
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };
const server = createServer(async (req, res) => {
  try {
    let path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    if (path.endsWith('/')) path += 'index.html';
    const file = resolve(root, `.${path}`);
    if (!file.startsWith(root.endsWith(sep) ? root : root + sep)) throw new Error('Outside root');
    const content = await readFile(file);
    res.writeHead(200, { 'Content-Type': mime[extname(file)] || 'application/octet-stream' }); res.end(content);
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
await mkdir(output, { recursive: true });
let browser;
const errors = [];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const bytes = dataURL => Buffer.from(dataURL.split(',')[1], 'base64');
function checkPNG(buffer) {
  assert.equal(buffer.subarray(1, 4).toString(), 'PNG');
  assert.equal(buffer.readUInt32BE(16), 1584); assert.equal(buffer.readUInt32BE(20), 396);
  assert.ok(buffer.length < 8 * 1024 * 1024, 'PNG fits LinkedIn size limit');
}
function zipEntries(buffer) {
  const entries = new Map(); let offset = 0;
  while (buffer.readUInt32LE(offset) === 0x04034b50) {
    assert.equal(buffer.readUInt16LE(offset + 8), 0, 'Stored ZIP method');
    const size = buffer.readUInt32LE(offset + 18), nameLength = buffer.readUInt16LE(offset + 26), extraLength = buffer.readUInt16LE(offset + 28);
    const start = offset + 30 + nameLength + extraLength;
    entries.set(buffer.subarray(offset + 30, offset + 30 + nameLength).toString(), buffer.subarray(start, start + size));
    offset = start + size;
  }
  assert.equal(buffer.readUInt32LE(offset), 0x02014b50, 'ZIP includes a central directory');
  return entries;
}

try {
  browser = await chromium.launch({ channel: process.env.SKETCHBOOK_BROWSER || 'chrome', headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1150 }, reducedMotion: 'reduce', acceptDownloads: true });
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${origin}/sketchbook/`);
  await page.locator('.study-card').last().waitFor();
  assert.equal(await page.locator('.study-card').count(), 5);
  assert.equal(await page.locator('#play').getAttribute('aria-label'), 'Play motion');
  const snapshot = () => page.locator('#artwork').evaluate(c => c.toDataURL());
  const still = await snapshot(); await page.waitForTimeout(150); assert.equal(await snapshot(), still, 'Reduced motion holds the canvas');

  const studies = ['Orbit', 'Bloom', 'Flow', 'Resonance', 'Convergence'];
  const sceneHashes = new Set();
  for (const title of studies) {
    await page.getByRole('button', { name: `Select ${title} study`, exact: true }).click();
    assert.ok((await page.locator('#study-number').innerText()).includes(title.toUpperCase()));
    sceneHashes.add(hash(bytes(await snapshot())));
  }
  assert.equal(sceneHashes.size, 5, 'All five studies are visually distinct');
  const deterministic = await page.evaluate(async () => {
    const { makeBanner } = await import('./scenes.js');
    return Array.from({ length: 5 }, (_, i) => {
      const first = makeBanner(i, { time: 6 }).toDataURL();
      const later = makeBanner(i, { time: 9 }).toDataURL();
      return { repeat: first === makeBanner(i, { time: 6 }).toDataURL(), changes: first !== later };
    });
  });
  assert.ok(deterministic.every(x => x.repeat && x.changes), 'Every scene is deterministic and responds to time');

  const beforeGuide = await snapshot(); await page.locator('#guide').click();
  assert.equal(await page.locator('#profile-guide').isVisible(), true);
  assert.equal(await snapshot(), beforeGuide, 'Guide does not modify canvas exports');
  const oneDownload = page.waitForEvent('download'); await page.locator('#export-current').click();
  const one = await oneDownload; const onePath = await one.path();
  const singlePNG = await readFile(onePath); checkPNG(singlePNG);
  // toBlob and toDataURL may choose different PNG encodings; compare decoded pixels.
  const exportDifference = await page.evaluate(async ([a, b]) => {
    const decode = async data => {
      const image = await createImageBitmap(await (await fetch(data)).blob());
      const c = document.createElement('canvas'); c.width = image.width; c.height = image.height;
      const ctx = c.getContext('2d', { willReadFrequently: true }); ctx.drawImage(image, 0, 0);
      image.close(); return ctx.getImageData(0, 0, c.width, c.height).data;
    };
    const [left, right] = await Promise.all([decode(a), decode(b)]);
    let total = 0, max = 0;
    for (let i = 0; i < left.length; i++) { const delta = Math.abs(left[i] - right[i]); total += delta; max = Math.max(max, delta); }
    return { mean: total / left.length, max };
  }, [beforeGuide, `data:image/png;base64,${singlePNG.toString('base64')}`]);
  assert.equal(exportDifference.max, 0, 'Downloaded PNG pixels match the preview exactly');
  await page.locator('#guide').click();

  await page.getByRole('button', { name: 'Paper palette', exact: true }).click();
  assert.notEqual(await snapshot(), beforeGuide);
  await page.locator('#signature').fill('A personal study');
  await page.locator('#density').evaluate(el => { el.value = '1.5'; el.dispatchEvent(new Event('input')); el.dispatchEvent(new Event('change')); });
  assert.equal(await page.locator('#density-value').innerText(), '150%');
  await page.reload(); await page.locator('.study-card').last().waitFor();
  assert.equal(await page.locator('#signature').inputValue(), 'A personal study');
  assert.equal(await page.getByRole('button', { name: 'Paper palette', exact: true }).getAttribute('aria-pressed'), 'true');
  const lettered = await snapshot(); await page.locator('#lettering').uncheck();
  assert.notEqual(await snapshot(), lettered, 'Art-only mode changes the composition');

  await page.evaluate(() => localStorage.clear()); await page.reload(); await page.locator('.study-card').last().waitFor();
  await page.locator('#slideshow').click(); await page.waitForTimeout(3300);
  assert.equal(await page.locator('[data-study="1"]').getAttribute('aria-pressed'), 'true', 'Slideshow advances after three seconds');
  await page.locator('#slideshow').click(); await page.locator('[data-study="0"]').click();
  const paused = await snapshot(); await page.locator('#play').click(); await page.waitForTimeout(250); await page.locator('#play').click();
  assert.notEqual(await snapshot(), paused, 'Playback animates the canvas');

  // Reset again so the delivered files are the curated default moments.
  await page.reload(); await page.locator('.study-card').last().waitFor();
  const downloads = page.waitForEvent('download'); await page.locator('#export-all').click();
  const bundle = await downloads; const zipPath = resolve(output, 'spatula-motion-sketchbook.zip'); await bundle.saveAs(zipPath);
  const entries = zipEntries(await readFile(zipPath)); assert.equal(entries.size, 6);
  for (let i = 0; i < studies.length; i++) {
    const name = `spatula-0${i + 1}-${studies[i].toLowerCase()}.png`;
    const png = entries.get(name); assert.ok(png, `${name} is in the archive`); checkPNG(png);
    await writeFile(resolve(output, name), png);
  }
  const manifest = JSON.parse(entries.get('settings.json').toString()); assert.deepEqual(manifest.moments, [6, 6, 6, 6, 12]);
  await writeFile(resolve(output, 'settings.json'), entries.get('settings.json'));
  await page.locator('#status').evaluate(el => { el.textContent = ''; });
  await page.screenshot({ path: resolve(output, 'studio-preview.png'), fullPage: true });
  const sheet = await page.evaluate(async () => {
    const { makeBanner, studies } = await import('./scenes.js');
    const c = document.createElement('canvas'); c.width = 1584; c.height = 396 * 5 + 24 * 4;
    const ctx = c.getContext('2d'); ctx.fillStyle = '#eeeae1'; ctx.fillRect(0, 0, c.width, c.height);
    studies.forEach((_, i) => ctx.drawImage(makeBanner(i, { time: i === 4 ? 12 : 6 }), 0, i * 420));
    return c.toDataURL();
  });
  await writeFile(resolve(output, 'collection-preview.png'), bytes(sheet));

  // The code shown on the banner and in the inspector comes from the functions
  // the renderer executes; exercise it separately from the original art exports.
  await page.locator('#show-code').check();
  assert.equal(await page.locator('#source-panel').getAttribute('open'), '');
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.locator('#copy-code').click();
  assert.ok((await page.evaluate(() => navigator.clipboard.readText())).includes('export function orbitRecipe'));
  for (let i = 0; i < studies.length; i++) {
    await page.getByRole('button', { name: `Select ${studies[i]} study`, exact: true }).click();
    const exactSource = await page.evaluate(async i => (await import('./recipes.js')).recipeSource(i), i);
    assert.equal(await page.locator('#recipe-code').textContent(), exactSource, 'Displayed recipe is the executable source');
  }
  await page.locator('[data-study="0"]').click();
  await page.reload(); await page.locator('.study-card').last().waitFor();
  assert.equal(await page.locator('#show-code').isChecked(), true, 'Code preference persists');
  await mkdir(resolve(output, 'code'), { recursive: true });
  const codeDownload = page.waitForEvent('download'); await page.locator('#export-all').click();
  const codeZip = await codeDownload; const codePath = resolve(output, 'code/spatula-motion-sketchbook.zip'); await codeZip.saveAs(codePath);
  const codeEntries = zipEntries(await readFile(codePath)); assert.equal(codeEntries.size, 6);
  assert.equal(JSON.parse(codeEntries.get('settings.json')).settings.showCode, true);
  for (const [name, content] of codeEntries) {
    if (name.endsWith('.png')) { checkPNG(content); assert.notEqual(hash(content), hash(entries.get(name)), 'Code variant differs from art edition'); }
    await writeFile(resolve(output, 'code', name), content);
  }
  await page.screenshot({ path: resolve(output, 'code-studio-preview.png'), fullPage: true });
  await page.locator('#lettering').uncheck();
  assert.equal(await page.locator('#show-code').isChecked(), false, 'Art-only mode clears the code overlay');
  await page.locator('#show-code').check();
  assert.equal(await page.locator('#lettering').isChecked(), true, 'Code mode restores lettering');
  for (const width of [375, 390, 768]) {
    await page.setViewportSize({ width, height: 844 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), `No horizontal overflow at ${width}px`);
    await page.getByRole('button', { name: 'Select Convergence study', exact: true }).click();
    await page.getByRole('button', { name: 'Select Orbit study', exact: true }).click();
    if (width === 390) await page.screenshot({ path: resolve(output, 'mobile-preview.png'), fullPage: true });
  }
  assert.deepEqual(errors, [], 'No browser runtime errors');
  console.log('PASS: five scenes, deterministic motion, playback, slideshow, controls, persistence, exact PNG download, art/code ZIP exports, executable recipe source, clipboard, image dimensions/size, reduced motion, and responsive layouts.');
  console.log(`Banners and preview images saved to ${output}`);
} finally {
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
}
