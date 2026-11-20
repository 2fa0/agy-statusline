/**
 * AGY Desktop Status sidecar server for Antigravity Desktop.
 *
 * Serves the single-file UI bundle with sidecar_sdk's /preload.js injected and
 * exposes GET /api/status backed by desktop-panel/telemetry.py.
 *
 * telemetry.py runs as one long-lived worker (`--serve`, JSON-lines over
 * stdin/stdout). Paying Python startup once instead of once per poll takes a
 * 3s-interval poll from ~40ms to well under 1ms. A one-shot `execFile` fallback
 * keeps the panel working if the worker cannot start.
 */

import { execFile, spawn } from 'node:child_process';
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

function queryTelemetryOneShot(conversationId, appData) {
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

const WORKER_REQUEST_TIMEOUT_MS = 8000;
const WORKER_MAX_RESTARTS = 3;

class TelemetryWorker {
  constructor(scriptPath, appData) {
    this.scriptPath = scriptPath;
    this.appData = appData;
    this.child = null;
    this.pending = [];
    this.stdoutBuffer = '';
    this.stderrTail = '';
    this.restarts = 0;
    this.disabled = false;
  }

  start() {
    if (this.child || this.disabled) return this.child;
    const child = spawn(
      PYTHON_BIN,
      [
        '-u',
        this.scriptPath,
        '--serve',
        '--data-dir',
        join(this.appData, 'plugin_data', 'agy-desktop-status'),
        '--desktop-root',
        this.appData,
      ],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    this.child = child;
    this.stdoutBuffer = '';
    this.stderrTail = '';

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      if (this.child !== child) return;
      this.stdoutBuffer += chunk;
      let newline = this.stdoutBuffer.indexOf('\n');
      while (newline !== -1) {
        const line = this.stdoutBuffer.slice(0, newline).trim();
        this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
        if (line) this._settleNext(line);
        newline = this.stdoutBuffer.indexOf('\n');
      }
    });

    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      this.stderrTail = (this.stderrTail + chunk).slice(-2000);
    });

    child.stdin.on('error', (error) => this._stop(child, `telemetry worker pipe failed: ${error.message}`));
    child.on('error', (error) => this._stop(child, `telemetry worker failed: ${error.message}`));
    child.on('exit', (code) => this._stop(child, `telemetry worker exited (code ${code})`));
    return child;
  }

  _stop(child, reason) {
    if (this.child !== child) return;
    this.child = null;
    this.stdoutBuffer = '';
    this.restarts += 1;
    if (this.restarts >= WORKER_MAX_RESTARTS) this.disabled = true;
    const error = new Error(reason || this.stderrTail.trim() || 'telemetry worker stopped');
    while (this.pending.length) {
      const entry = this.pending.shift();
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    child.kill('SIGTERM');
  }

  _settleNext(line) {
    const entry = this.pending.shift();
    if (!entry) return;
    clearTimeout(entry.timer);
    try {
      const parsed = JSON.parse(line);
      if (parsed && typeof parsed === 'object' && typeof parsed.error === 'string') {
        entry.reject(new Error(parsed.error));
      } else {
        entry.resolve(parsed);
      }
    } catch (error) {
      entry.reject(new Error(`Invalid telemetry JSON: ${error.message}`));
    }
  }

  query(conversationId) {
    if (this.disabled) return Promise.reject(new Error('telemetry worker disabled'));
    const child = this.start();
    if (!child) return Promise.reject(new Error('telemetry worker unavailable'));
    return new Promise((resolvePromise, rejectPromise) => {
      const entry = {
        resolve: resolvePromise,
        reject: rejectPromise,
        timer: setTimeout(() => {
          // A late reply cannot be paired safely after any request times out.
          this._stop(child, 'telemetry worker request timed out');
        }, WORKER_REQUEST_TIMEOUT_MS),
      };
      entry.timer.unref?.();
      this.pending.push(entry);
      try {
        child.stdin.write(`${JSON.stringify({ conversationId: conversationId || 'auto' })}\n`);
      } catch (error) {
        this._stop(child, error.message);
      }
    });
  }

  dispose() {
    if (this.child) this._stop(this.child, 'telemetry worker disposed');
  }
}

const appData = resolveAppDataDir();
const worker = new TelemetryWorker(TELEMETRY_SCRIPT, appData);
const inflight = new Map();

async function queryTelemetry(conversationId) {
  const key = conversationId || 'auto';
  const existing = inflight.get(key);
  if (existing) return existing;
  const promise = worker
    .query(key)
    .catch(() => {
      // Worker unavailable or crashed: fall back to a one-shot process.
      return queryTelemetryOneShot(key, appData);
    })
    .finally(() => {
      inflight.delete(key);
    });
  inflight.set(key, promise);
  return promise;
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    worker.dispose();
    process.exit(0);
  });
}
process.on('exit', () => worker.dispose());

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
    return queryTelemetry(convId);
  },
  'GET',
);

await app.run();
