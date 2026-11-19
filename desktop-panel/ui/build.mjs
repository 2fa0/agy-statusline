import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const here = dirname(fileURLToPath(import.meta.url));
const outFile = resolve(here, '..', 'dist', 'index.html');

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
