import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';
import { transformSync } from '../ui/node_modules/esbuild/lib/main.js';

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
