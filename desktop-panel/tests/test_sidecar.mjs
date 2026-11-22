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

test('session chip renders the backend reason, escapes it and honours layout', () => {
  const node = (dataset = {}) => ({
    dataset, style: {}, innerHTML: '', textContent: '', title: '',
    classList: { toggle() {}, add() {} }, setAttribute() {}, querySelectorAll: () => [],
  });
  const panels = ['trends', 'usage', 'quota'].map((panel) => node({ panel }));
  const metaStrip = node();
  const source = app.slice(app.indexOf('function formatTokens('), app.indexOf('function syncSessionSelect('));
  const snapshotSource = app.slice(app.indexOf('function renderSnapshot('), app.indexOf('sparkEl.addEventListener('));
  const render = vm.runInNewContext(`${source}; ${snapshotSource}; renderSnapshot`, {
    syncSessionSelect() {}, renderSessionStats() {}, renderQuota() {}, highlightHistoryItem() {},
    setActiveTab() {}, activeTab: 'trends', getPaneConversationId: () => '',
    liveDot: node(), metaStrip, cardsEl: node(), tabBar: node(), tabPanels: panels,
    historySection: node(), historyCount: node(), sparkEl: node(), historyListEl: node(),
    emptyBox: node(), quotaSection: node(), quotaEmpty: node(), quotaListEl: node(), quotaNote: node(),
  });
  const snapshot = (session, config) => ({
    found: true, config, session, history: [], recentConversations: [],
    contextHistory: [], modelUsage: [], sessionUsage: null, latestUsage: null,
  });
  render(snapshot({
    state: 'waiting', code: 'first_token_wait', label: '首字等待',
    detail: '<img src=x onerror=alert(1)> 已等待 34s', waitSec: 34,
  }, { layout: 'compact' }));
  assert.match(metaStrip.innerHTML, /state-chip is-waiting/);
  assert.match(metaStrip.innerHTML, /首字等待/);
  assert.doesNotMatch(metaStrip.innerHTML, /34\.0s/);
  assert.match(metaStrip.innerHTML, /&lt;img/);
  assert.doesNotMatch(metaStrip.innerHTML, /<img/);

  // Detailed layout adds the wait duration next to the label.
  render(snapshot({
    state: 'waiting', code: 'first_token_wait', label: '首字等待', detail: '等待中', waitSec: 34,
  }, { layout: 'detailed' }));
  assert.match(metaStrip.innerHTML, /首字等待 34\.0s/);

  // Idle keeps the dot but drops the redundant label.
  render(snapshot({ state: 'idle', code: 'idle', label: '就绪', detail: '会话空闲', waitSec: null }, {}));
  assert.match(metaStrip.innerHTML, /state-chip is-idle/);
  assert.doesNotMatch(metaStrip.innerHTML, /就绪/);
  // ...but an idle session without hooks still has something worth saying.
  render(snapshot({ state: 'idle', code: 'hook_missing', label: '无 Hook', detail: '未收到 Hook 事件', waitSec: null }, {}));
  assert.match(metaStrip.innerHTML, /无 Hook/);

  // Unknown states fall back to the neutral class instead of injecting it.
  render(snapshot({ state: 'x" onmouseover="alert(1)', code: 'idle', label: '就绪', detail: '', waitSec: 0 }, {}));
  assert.match(metaStrip.innerHTML, /state-chip is-idle/);
  assert.doesNotMatch(metaStrip.innerHTML, /onmouseover/);
});

test('unavailable data sources are surfaced instead of showing silent zeros', () => {
  const node = {
    hidden: true, textContent: '', className: '', title: '',
    removeAttribute(name) { if (name === 'title') this.title = ''; },
  };
  const source = app.slice(app.indexOf('function renderSourcesNote('), app.indexOf('async function fetchSidecarSnapshot('));
  const render = vm.runInNewContext(`${source}; renderSourcesNote`, {
    document: { getElementById: (id) => (id === 'sources-note' ? node : null) },
  });
  const snapshot = (notes, config, degraded = true) => ({ sources: { degraded, notes }, config });

  render(snapshot([], {}));
  assert.equal(node.hidden, true, 'a healthy panel shows no banner');

  const locked = {
    code: 'db_locked', label: '数据库被占用',
    text: '<b>会话数据库正被其他进程占用</b>，本轮数值暂未刷新。',
  };
  render(snapshot([locked], { layout: 'compact' }));
  assert.equal(node.hidden, false);
  assert.equal(node.textContent, '数据不完整 · 数据库被占用');
  assert.doesNotMatch(node.textContent, /<b>/, 'tooltip copy must stay text, not markup');
  assert.match(node.title, /会话数据库正被其他进程占用/);

  // Detailed layout spells the reason out inline; compact keeps one line.
  render(snapshot([locked], { layout: 'detailed' }));
  assert.match(node.textContent, /^数据不完整 · 数据库被占用：/);
  assert.match(node.textContent, /本轮数值暂未刷新/);

  // Every note is reachable from the tooltip even when only labels are inline.
  const failed = { code: 'transcript_error', label: '日志读取失败', text: '对话日志读取失败。' };
  render(snapshot([locked, failed], { layout: 'compact' }));
  assert.match(node.textContent, /数据库被占用 \/ 日志读取失败/);
  assert.match(node.title, /会话数据库正被其他进程占用[\s\S]*对话日志读取失败/);

  render(snapshot([locked], {}, false));
  assert.equal(node.hidden, true, 'degraded=false hides the banner again');
});

test('applyPanelConfig handles custom pollSec, reset to 0 and hiding active quota tab', () => {
  const classes = new Set();
  const root = {
    dataset: {},
    classList: { toggle(name, force) { if (force) classes.add(name); else classes.delete(name); } },
  };
  const options = [{ value: '3', textContent: '3s' }, { value: '0', textContent: '暂停' }];
  const refreshSelect = {
    options,
    value: '3',
    lastElementChild: options[1],
    insertBefore(opt) { options.splice(options.length - 1, 0, opt); },
    classList: { add() {}, toggle() {} },
  };
  let activeTab = 'quota';
  let resetCalls = 0;
  const ctx = {
    document: {
      documentElement: root,
      createElement: () => ({ value: '', textContent: '' }),
    },
    window: { localStorage: { getItem: () => null } },
    STORAGE_KEY_INTERVAL: 'agy_status_refresh_sec',
    ALLOWED_INTERVALS: new Set([0, 3, 5, 10]),
    appliedPollSec: null,
    refreshSelect,
    refreshIntervalSec: 3,
    activeTab,
    setActiveTab(t) { activeTab = t; ctx.activeTab = t; },
    resetTimer() { resetCalls += 1; },
  };
  const cfgSource = app.slice(app.indexOf('function applyPanelConfig('), app.indexOf('function renderStateNote('));
  const apply = vm.runInNewContext(`${cfgSource}; applyPanelConfig`, ctx);

  apply({ pollSec: 7, modules: { quota: false } });
  assert.equal(ctx.refreshIntervalSec, 7);
  assert.equal(ctx.ALLOWED_INTERVALS.has(7), true);
  assert.equal(activeTab, 'trends');
  assert.equal(classes.has('hide-quota'), true);
  assert.equal(resetCalls, 1);

  apply({ pollSec: 0, modules: { quota: true } });
  assert.equal(ctx.refreshIntervalSec, 3);
  assert.equal(refreshSelect.value, '3');
  assert.equal(classes.has('hide-quota'), false);
  assert.equal(resetCalls, 2);
});

test('disabled panel hides tabs and offline chip survives hide-session & single-blip failures', () => {
  const node = (dataset = {}) => ({
    dataset, style: {}, innerHTML: '', textContent: '',
    classList: { toggle() {} }, setAttribute() {},
  });
  const panels = ['trends', 'usage', 'quota'].map((panel) => node({ panel }));
  const tabBar = node();
  const emptyBox = node();
  const source = app.slice(app.indexOf('function formatTokens('), app.indexOf('function syncSessionSelect('));
  const snapshotSource = app.slice(app.indexOf('function renderSnapshot('), app.indexOf('sparkEl.addEventListener('));
  const render = vm.runInNewContext(`${source}; ${snapshotSource}; renderSnapshot`, {
    syncSessionSelect() {}, renderSessionStats() {}, getPaneConversationId: () => '',
    liveDot: node(), metaStrip: node(), cardsEl: node(), tabBar, tabPanels: panels,
    historySection: node(), emptyBox, quotaSection: node(), quotaEmpty: node(),
    quotaListEl: node(), quotaNote: node(),
  });
  render({ found: false, disabled: true, message: '面板已关闭' });
  assert.equal(tabBar.style.display, 'none');
  for (const p of panels) assert.equal(p.style.display, 'none');
  assert.equal(emptyBox.textContent, '面板已关闭');

  const metaStrip = node();
  const offlineSource = app.slice(app.indexOf('function markBackendUnresponsive('), app.indexOf('async function refreshSnapshot('));
  const offlineCtx = {
    lastSuccessAt: Date.now() - 30000,
    consecutiveFailures: 0,
    refreshIntervalSec: 3,
    metaStrip,
  };
  const mark = vm.runInNewContext(`${formatSource}; ${offlineSource}; markBackendUnresponsive`, offlineCtx);
  mark();
  assert.equal(metaStrip.innerHTML, '', 'first failure after wake must not immediately flag offline');
  mark();
  assert.match(metaStrip.innerHTML, /state-chip is-error is-offline/);
  assert.match(metaStrip.innerHTML, /后台无响应/);
});
