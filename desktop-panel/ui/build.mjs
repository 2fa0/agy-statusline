import { createHash } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync, statSync } from 'node:fs';
import { dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const here = dirname(fileURLToPath(import.meta.url));
const panel = resolve(here, '..');
// AGY_UI_OUT lets tests rebuild into a temp path without touching the repo.
const outFile = process.env.AGY_UI_OUT
  ? resolve(process.env.AGY_UI_OUT)
  : resolve(panel, 'dist', 'index.html');
const writeManifest = !process.env.AGY_UI_OUT && process.env.AGY_UI_NO_MANIFEST !== '1';

const SOURCES = ['ui/src/app.ts', 'ui/src/template.html', 'ui/src/preload.js'];

const result = await esbuild.build({
  entryPoints: [resolve(here, 'src', 'app.ts')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['es2022'],
  write: false,
});

const bundledJs = result.outputFiles[0].text.replace(/<\/script>/gi, '<\\/script>');
const template = readFileSync(resolve(here, 'src', 'template.html'), 'utf8');
const html = template.replace('<!-- INLINE_SCRIPT -->', () => `<script>${bundledJs}</script>`);

mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, html, 'utf8');
console.log(`Built ${outFile} (${Buffer.byteLength(html, 'utf8')} bytes)`);

function digest(relPath) {
  const buf = readFileSync(resolve(panel, relPath));
  return { sha256: createHash('sha256').update(buf).digest('hex'), bytes: buf.byteLength };
}

// The panel ships a pre-built bundle inside the native binary. A stale
// dist/index.html is invisible at runtime (the binary keeps serving the old
// HTML), so the hashes are recorded and checked by tests/test_assets.py.
if (writeManifest) {
  const manifest = {
    version: readFileSync(resolve(panel, '..', 'VERSION'), 'utf8').trim(),
    bundle: { path: 'dist/index.html', ...digest('dist/index.html') },
    sources: Object.fromEntries(SOURCES.map((rel) => [rel, digest(rel)])),
  };
  writeFileSync(resolve(panel, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n', 'utf8');
  const bundleBytes = statSync(outFile).size;
  console.log(`Wrote ${relative(process.cwd(), resolve(panel, 'manifest.json'))} (bundle ${bundleBytes} bytes)`);
}
