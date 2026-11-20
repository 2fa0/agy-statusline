import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';
import { transformSync } from '../ui/node_modules/esbuild/lib/main.js';

// Load the worker without the Antigravity-only SDK or starting the HTTP server.
const sidecar = readFileSync(new URL('../sidecars/status/main.mjs', import.meta.url), 'utf8');
const workerSource = sidecar.slice(sidecar.indexOf('class TelemetryWorker'), sidecar.indexOf('const appData ='));

function workerFixture() {
  const children = [];
  const timers = new Map();
  let nextTimer = 0;
  const Worker = vm.runInNewContext(`${workerSource}; TelemetryWorker`, {
    WORKER_REQUEST_TIMEOUT_MS: 8000,
    WORKER_MAX_RESTARTS: 3,
    PYTHON_BIN: 'python3',
    join: (...parts) => parts.join('/'),
    setTimeout: (callback) => { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout: (id) => timers.delete(id),
    spawn: () => {
      const child = new EventEmitter();
      for (const name of ['stdin', 'stdout', 'stderr']) {
        child[name] = new EventEmitter();
        child[name].setEncoding = () => {};
      }
      child.stdin.write = () => {};
      child.kill = () => { child.killed = true; };
      children.push(child);
      return child;
    },
  });
  return { worker: new Worker('telemetry.py', '/data'), children, timers };
}

test('timeout rejects the whole queue; old replies cannot satisfy a new request', async () => {
  const { worker, children, timers } = workerFixture();
  const first = assert.rejects(worker.query('A'), /timed out/);
  const second = assert.rejects(worker.query('B'), /timed out/);
  timers.values().next().value();
  await Promise.all([first, second]);
  assert.equal(children[0].killed, true);
  assert.equal(timers.size, 0);
  assert.equal(worker.restarts, 1);

  const next = worker.query('C');
  children[0].stdout.emit('data', '{"conversationId":"A"}\n');
  children[0].emit('exit', 1);
  assert.equal(worker.pending.length, 1);
  children[1].stdout.emit('data', '{"conversationId":"C"}\n');
  assert.equal((await next).conversationId, 'C');
  worker.dispose();
});

test('broken stdin rejects pending requests and stops retries after three failed workers', async () => {
  const { worker, children } = workerFixture();
  for (let i = 0; i < 3; i += 1) {
    const rejected = assert.rejects(worker.query('A'), /pipe failed/);
    children[i].stdin.emit('error', new Error('EPIPE'));
    children[i].emit('exit', 1);
    await rejected;
    assert.equal(worker.restarts, i + 1);
  }
  await assert.rejects(worker.query('B'), /disabled/);
  assert.equal(children.length, 3);
});

// Exercise the actual polling function without booting the DOM-based UI.
const app = transformSync(readFileSync(new URL('../ui/src/app.ts', import.meta.url), 'utf8'), {
  loader: 'ts',
}).code;
const pollingSource = app.slice(app.indexOf('function nextPollDelay()'), app.indexOf('function resetTimer()'));

test('polling respects each selected interval and pauses when hidden or disabled', () => {
  function delay(interval, age, hidden = false, liveActive = false) {
    return vm.runInNewContext(`${pollingSource}; nextPollDelay()`, {
      refreshIntervalSec: interval,
      document: { hidden },
      lastSnapshot: liveActive ? { live: { active: true } } : { live: { active: false } },
      msSinceLastActivity: () => age * 1000,
      IDLE_AFTER_SEC: 45,
      IDLE_POLL_MS: 15000,
      LIVE_POLL_MS: 1000,
    });
  }
  for (const interval of [3, 5, 10]) {
    assert.equal(delay(interval, 0), interval * 1000);
    assert.equal(delay(interval, 0, false, true), 1000);
    assert.equal(delay(interval, 45), 15000);
    assert.equal(delay(interval, 0, true), 0);
  }
  assert.equal(delay(0, 0), 0);
  assert.equal(delay(0, 60), 0);
});

const sessionUiSource = app.slice(app.indexOf('function usageBody('), app.indexOf('function renderSnapshot('));
const formatSource = app.slice(app.indexOf('function formatTokens('), app.indexOf('const WEEKDAYS'));

test('session panel escapes model names, marks compression and keeps data gaps visible', () => {
  const section = () => ({ style: {}, innerHTML: '', querySelector: () => ({ open: true }) });
  const usageSection = section();
  const contextSection = section();
  const modelsSection = section();
  const render = vm.runInNewContext(`${formatSource}; ${sessionUiSource}; renderSessionStats`, {
    usageSection, contextSection, modelsSection,
  });
  render({
    found: true,
    compactionCount: 1,
    sessionUsage: { requestCount: 3, recordedCount: 2, totalTokens: 1234, cacheHitPct: 50 },
    modelUsage: [{ model: '<img src=x onerror=alert(1)>', requestCount: 1, recordedCount: 0, avgSpeedTokS: null }],
    contextHistory: [
      { request: 1, contextUsed: 100, compaction: false, at: null, model: 'a' },
      { request: 2, contextUsed: null, compaction: true, at: null, model: '' },
      { request: 3, contextUsed: 10, compaction: false, at: null, model: 'b' },
    ],
  });
  assert.match(usageSection.innerHTML, /2\/3 次请求有完整用量/);
  assert.match(usageSection.innerHTML, /缓存命中 50.0%/);
  assert.match(modelsSection.innerHTML, /&lt;img/);
  assert.doesNotMatch(modelsSection.innerHTML, /<img/);
  assert.match(modelsSection.innerHTML, /平均输出速度 --/);
  assert.match(contextSection.innerHTML, /压缩 1 次/);
  assert.equal((contextSection.innerHTML.match(/<polyline/g) || []).length, 2);
  assert.match(contextSection.innerHTML, /stroke-dasharray/);
  assert.match(contextSection.innerHTML, /<details open>/);
  render({ found: false });
  for (const node of [usageSection, contextSection, modelsSection]) {
    assert.equal(node.style.display, 'none');
  }
});

test('quota tab stays accessible without a desktop conversation', () => {
  const node = (dataset = {}) => ({
    dataset, style: {}, innerHTML: '',
    classList: { toggle() {} }, setAttribute() {},
  });
  const panels = ['trends', 'usage', 'quota'].map((panel) => node({ panel }));
  const tabBar = node();
  const quotaSection = node();
  const quotaEmpty = node();
  const quotaListEl = node();
  const source = app.slice(app.indexOf('function formatTokens('), app.indexOf('function syncSessionSelect('));
  const snapshotSource = app.slice(app.indexOf('function renderSnapshot('), app.indexOf('sparkEl.addEventListener('));
  const render = vm.runInNewContext(`${source}; ${snapshotSource}; renderSnapshot`, {
    syncSessionSelect() {}, renderSessionStats() {}, getPaneConversationId: () => '',
    liveDot: node(), metaStrip: node(), cardsEl: node(), tabBar, tabPanels: panels,
    historySection: node(), emptyBox: node(), quotaSection, quotaEmpty, quotaListEl, quotaNote: node(),
  });
  render({ found: false, quota: { windows: [{ pool: 'gemini', window: '5h', resetAtEpoch: 1800000000 }] } });
  assert.notEqual(tabBar.style.display, 'none');
  assert.notEqual(panels[2].style.display, 'none');
  assert.equal(quotaSection.style.display, 'flex');
  assert.match(quotaListEl.innerHTML, /Gemini/);
  render({ found: false, quota: null });
  assert.equal(quotaSection.style.display, 'none');
  assert.equal(quotaEmpty.style.display, 'block');
});
