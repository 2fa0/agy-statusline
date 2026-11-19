/**
 * AGY Desktop Status sidecar server for Antigravity Desktop aux_pane.
 *
 * Serves the single-file UI bundle with sidecar_sdk's /preload.js injected
 * and exposes GET /api/status backed by desktop-panel/telemetry.py.
 */

import { execFile } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SidecarApp, Response } from 'sidecar_sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = resolve(__dirname, '..', '..');
const TELEMETRY_SCRIPT = join(PLUGIN_ROOT, 'telemetry.py');
const PYTHON_CANDIDATES =
  process.platform === 'win32'
    ? ['python3', 'python', 'py']
    : ['/usr/bin/python3', '/opt/homebrew/bin/python3', '/usr/local/bin/python3', 'python3', 'python'];
const PYTHON_BIN =
  PYTHON_CANDIDATES.find((bin) => (bin.startsWith('/') ? existsSync(bin) : true)) || 'python3';

function resolveAppDataDir() {
  const raw = process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR;
  if (raw) {
    for (let d = raw; d !== dirname(d); d = dirname(d)) {
      if (basename(d) === 'sidecar_data') {
        return dirname(d);
      }
    }
  }
  return join(homedir(), '.gemini', 'antigravity');
}

function loadHtmlWithPreload() {
  const override = process.env.AGY_DESKTOP_STATUS_HTML;
  const htmlPath = override ? resolve(override) : join(PLUGIN_ROOT, 'dist', 'index.html');
  let html;
  if (existsSync(htmlPath)) {
    html = readFileSync(htmlPath, 'utf8');
  } else {
    html =
      "<!doctype html><html><head><title>AGY Status</title></head>" +
      "<body style='font-family:sans-serif;padding:16px'>" +
      "<h3>AGY Status</h3>" +
      "<p>UI bundle missing. Run <code>npm run build</code> inside <code>desktop-panel/ui</code>.</p>" +
      "</body></html>";
  }
  if (!html.includes('/preload.js')) {
    if (html.includes('</head>')) {
      html = html.replace('</head>', '  <script src="/preload.js"></script>\n</head>');
    } else {
      html = `<script src="/preload.js"></script>${html}`;
    }
  }
  return html;
}

function queryTelemetry(conversationId, appData) {
  const args = [
    TELEMETRY_SCRIPT,
    '--conversation-id',
    conversationId || 'auto',
    '--data-dir',
    join(appData, 'plugin_data', 'agy-desktop-status'),
    '--desktop-root',
    appData,
  ];
  return new Promise((resolvePromise, rejectPromise) => {
    execFile(
      PYTHON_BIN,
      args,
      { encoding: 'utf8', timeout: 5000, maxBuffer: 2 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) {
          rejectPromise(new Error(stderr?.trim() || err.message));
          return;
        }
        try {
          resolvePromise(JSON.parse(stdout));
        } catch (parseErr) {
          rejectPromise(new Error(`Invalid telemetry JSON: ${parseErr.message}`));
        }
      },
    );
  });
}

const appData = resolveAppDataDir();
const app = new SidecarApp();

app.page('/', () => {
  return new Response(loadHtmlWithPreload(), {
    contentType: 'text/html; charset=utf-8',
  });
});

app.api(
  '/api/status',
  async (data) => {
    const convId =
      typeof data?.conversationId === 'string' && data.conversationId.trim()
        ? data.conversationId.trim()
        : 'auto';
    return queryTelemetry(convId, appData);
  },
  'GET',
);

await app.run();
