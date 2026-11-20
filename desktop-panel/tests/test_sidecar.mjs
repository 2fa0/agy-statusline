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
