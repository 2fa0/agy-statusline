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
  assert.match(usageSection.innerHTML, /2\/3 次请求/);
  assert.match(usageSection.innerHTML, /缓存命中 50.0%/);
  assert.match(modelsSection.innerHTML, /&lt;img/);
  assert.doesNotMatch(modelsSection.innerHTML, /<img/);
  assert.match(modelsSection.innerHTML, /title="0 个有效速度样本">--<\/span>/);
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
    settingsSaving: false,
    ...Object.fromEntries([
      'cfgLayoutEl', 'cfgModSessionEl', 'cfgModHistoryEl', 'cfgModContextEl', 'cfgModModelsEl',
      'cfgModQuotaEl', 'cfgLowSpeedEl', 'cfgWaitSecEl', 'cfgStallSecEl', 'cfgToolGraceEl',
      'notchEnabledEl', 'notchHideIdleEl', 'notchScreenModeEl', 'notchAvoidanceModeEl',
    ].map((key) => [key, null])),
    cfgPollSecEl: {
      options: [{ value: '0' }, { value: '3' }, { value: '5' }, { value: '10' }],
      appendChild(opt) { this.options.push(opt); },
      set value(v) { this.selected = this.options.some((opt) => opt.value === v) ? v : ''; },
      get value() { return this.selected; },
    },
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
  assert.equal(ctx.cfgPollSecEl.value, '7');
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

test('settings changes submit only their own fields and saves remain ordered after failure', async () => {
  const controls = Object.fromEntries([
    'cfgLayoutEl', 'cfgPollSecEl', 'cfgLowSpeedEl', 'cfgWaitSecEl', 'cfgStallSecEl', 'cfgToolGraceEl',
    'cfgModSessionEl', 'cfgModHistoryEl', 'cfgModContextEl', 'cfgModModelsEl', 'cfgModQuotaEl',
    'notchEnabledEl', 'notchHideIdleEl', 'notchScreenModeEl', 'notchAvoidanceModeEl',
  ].map((key) => [key, { value: '3', checked: true, addEventListener(_, fn) { this.change = fn; } }]));
  const requests = [];
  const releases = [];
  const applied = [];
  const ctx = {
    ...controls, settingsSaving: false, settingsPending: 0, settingsQueue: Promise.resolve(),
    settingsSaveStatusEl: { textContent: '' },
    settingsEpoch: 0, latestSavedConfig: null, lastSnapshot: null,
    window: { sidecar: { fetch: async (_, options) => {
      requests.push(JSON.parse(options.body));
      await new Promise((resolve) => releases.push(resolve));
      return { ok: requests.length > 1, json: async () => ({ layout: 'detailed' }) };
    } } },
    applyPanelConfig(config) { applied.push(config); },
  };
  const source = app.slice(app.indexOf('function readClampedNum('), app.indexOf('async function boot('));
  vm.runInNewContext(source, ctx);
  controls.cfgModQuotaEl.checked = false;
  controls.cfgModQuotaEl.change();
  controls.cfgLayoutEl.value = 'detailed';
  controls.cfgLayoutEl.change();
  await new Promise(setImmediate);
  assert.deepEqual(requests, [{ modules: { quota: false } }]);
  assert.equal(ctx.settingsSaving, true);
  releases.shift()();
  await new Promise(setImmediate);
  assert.deepEqual(requests, [{ modules: { quota: false } }, { layout: 'detailed' }]);
  assert.equal(ctx.settingsSaving, true);
  releases.shift()();
  await ctx.settingsQueue;
  assert.equal(ctx.settingsSaving, false);
  assert.deepEqual(applied, [{ layout: 'detailed' }]);
  assert.equal(ctx.settingsSaveStatusEl.textContent, '已保存');
  assert.deepEqual(ctx.latestSavedConfig, { layout: 'detailed' });
});

test('a failed save keeps the last successful config and a late GET cannot roll it back', async () => {
  const controls = Object.fromEntries([
    'cfgLayoutEl', 'cfgPollSecEl', 'cfgLowSpeedEl', 'cfgWaitSecEl', 'cfgStallSecEl', 'cfgToolGraceEl',
    'cfgModSessionEl', 'cfgModHistoryEl', 'cfgModContextEl', 'cfgModModelsEl', 'cfgModQuotaEl',
    'notchEnabledEl', 'notchHideIdleEl', 'notchScreenModeEl', 'notchAvoidanceModeEl',
  ].map((key) => [key, { value: '3', checked: true, addEventListener(_, fn) { this.change = fn; } }]));
  const saves = [];
  const applied = [];
  const renderedConfigs = [];
  let resolveStatus;
  const ctx = {
    ...controls,
    REQUEST_TIMEOUT_MS: 8000,
    refreshSeq: 0,
    inFlightSeq: null,
    activeRefreshController: null,
    selectedConversation: 'auto',
    switchingConversation: false,
    settingsSaving: false,
    settingsPending: 0,
    settingsQueue: Promise.resolve(),
    settingsSaveStatusEl: { textContent: '' },
    settingsEpoch: 0,
    latestSavedConfig: null,
    lastSnapshot: null,
    lastSuccessAt: 0,
    firstFailureAt: 0,
    consecutiveFailures: 0,
    refreshIntervalSec: 3,
    getPaneConversationId: () => '',
    metaStrip: { innerHTML: '' },
    emptyBox: { style: {}, textContent: '' },
    selectedConversationText: () => '自动跟随当前会话',
    renderConversationFailure() {},
    renderSnapshot(snap) { renderedConfigs.push(snap.config); },
    applyPanelConfig(cfg) { applied.push(cfg); },
    renderStateNote() {},
    renderSourcesNote() {},
    AbortController,
    setTimeout,
    clearTimeout,
    window: {
      sidecar: {
        fetch: (url, options) => {
          if (url.startsWith('/api/status')) {
            return new Promise((resolve) => { resolveStatus = resolve; });
          }
          saves.push(JSON.parse(options.body));
          if (saves.length === 1) return Promise.resolve({ ok: true, json: async () => ({ pollSec: 5 }) });
          return Promise.resolve({ ok: false, json: async () => ({}) });
        },
      },
    },
  };
  const fetchSource = app.slice(app.indexOf('async function fetchSidecarSnapshot('), app.indexOf('function msSinceLastActivity()'));
  const settingsSource = app.slice(app.indexOf('function readClampedNum('), app.indexOf('async function boot('));
  vm.runInNewContext(`${formatSource}; ${fetchSource}; ${settingsSource}`, ctx);
  const statusPromise = ctx.refreshSnapshot(false); // started before the saves
  await ctx.saveSettingsPatch({ pollSec: 5 });
  await ctx.saveSettingsPatch({ layout: 'detailed' });
  assert.deepEqual(saves, [{ pollSec: 5 }, { layout: 'detailed' }]);
  assert.deepEqual(ctx.latestSavedConfig, { pollSec: 5 });
  assert.ok(applied.length > 0 && applied.every((cfg) => JSON.stringify(cfg) === JSON.stringify({ pollSec: 5 })));
  assert.equal(ctx.settingsSaveStatusEl.textContent, '保存失败');
  // The GET that started before the saves now returns the old config.
  resolveStatus({ ok: true, json: async () => ({ found: true, config: { pollSec: 3 } }) });
  await statusPromise;
  assert.ok(applied.every((cfg) => JSON.stringify(cfg) === JSON.stringify({ pollSec: 5 })));
  assert.deepEqual(renderedConfigs[renderedConfigs.length - 1], { pollSec: 5 });
});

test('switching conversations clears the old data and attributes failures to the new one', () => {
  const node = (dataset = {}) => ({
    dataset, style: {}, innerHTML: '', textContent: '', title: '',
    classList: { toggle() {}, add() {} }, setAttribute() {}, querySelectorAll: () => [],
  });
  const sessionSelect = {
    _html: '',
    options: [],
    value: 'auto',
    get innerHTML() { return this._html; },
    set innerHTML(html) {
      this._html = html;
      this.options = [...html.matchAll(/<option value="([^"]*)">([^<]*)<\/option>/g)]
        .map((m) => ({ value: m[1], textContent: m[2] }));
    },
  };
  const ctx = {
    sessionSelect,
    selectedConversation: 'conv-b',
    selectedConversationLabel: 'conv-b · repo',
    lastSnapshot: { conversationId: 'conv-a', found: true },
    lastSuccessAt: 1234,
    firstFailureAt: 99,
    consecutiveFailures: 3,
    currentHistory: [{ idx: 1 }],
    currentContextPoints: [{ request: 1 }],
    activeHistoryIdx: 1,
    metaStrip: node(), cardsEl: node(), historySection: node(), sparkEl: node(),
    sparkDetailEl: node(), historyListEl: node(), emptyBox: node(),
    usageSection: node(), contextSection: node(), modelsSection: node(),
    historyCount: node(), usageInner: '',
    document: {
      getElementById: (id) => (id === 'state-note' ? stateNote : id === 'sources-note' ? sourcesNote : null),
    },
  };
  const stateNote = { hidden: false, textContent: 'A 的状态说明' };
  const sourcesNote = {
    hidden: false, textContent: 'A 的数据来源说明', title: 'A',
    removeAttribute(name) { if (name === 'title') delete this.title; },
  };
  const source = app.slice(app.indexOf('function syncSessionSelect('), app.indexOf('function highlightHistoryItem('));
  const parts = vm.runInNewContext(`${formatSource}; ${source}; ({ beginConversationSwitch, renderConversationFailure, syncSessionSelect })`, ctx);
  parts.beginConversationSwitch();
  assert.equal(ctx.lastSnapshot, null, 'the previous conversation must not stay on screen');
  assert.equal(ctx.lastSuccessAt, 0);
  assert.equal(ctx.currentHistory.length, 0);
  assert.equal(ctx.historySection.style.display, 'none');
  assert.match(ctx.metaStrip.innerHTML, /is-switching/);
  assert.match(ctx.metaStrip.innerHTML, /加载中 · conv-b/);
  assert.match(ctx.emptyBox.textContent, /正在读取会话 conv-b/);
  assert.equal(ctx.cardsEl.innerHTML, '');
  for (const section of [ctx.usageSection, ctx.contextSection, ctx.modelsSection]) {
    assert.equal(section.innerHTML, '', 'tab sections must not keep the previous conversation');
    assert.equal(section.style.display, 'none');
  }
  // The state/source explanations are evidence about the previous conversation.
  assert.equal(stateNote.hidden, true);
  assert.equal(stateNote.textContent, '');
  assert.equal(sourcesNote.hidden, true);
  assert.equal(sourcesNote.textContent, '');
  assert.equal(sourcesNote.title, undefined);

  parts.renderConversationFailure();
  assert.match(ctx.metaStrip.innerHTML, /会话读取失败 · conv-b/);
  assert.match(ctx.emptyBox.textContent, /无法读取会话 conv-b/);

  // A manually selected conversation that aged out of the recent list keeps its
  // option; silently snapping back to "auto" would look like nothing happened.
  ctx.selectedConversation = '99999999-1111-2222-3333-444444444444';
  ctx.selectedConversationLabel = '99999999 · repo';
  parts.syncSessionSelect([{ conversationId: 'aaaa', shortId: 'aaaa', workspace: 'w', modelName: 'm', isActive: true }]);
  assert.equal(sessionSelect.value, '99999999-1111-2222-3333-444444444444');
  assert.match(sessionSelect.innerHTML, /99999999 · repo（不在最近列表）/);
  assert.equal(ctx.selectedConversation, '99999999-1111-2222-3333-444444444444');
});

test('a failed refresh of a newly chosen conversation is blamed on that conversation', async () => {
  const node = () => ({ style: {}, innerHTML: '', textContent: '' });
  const fetchSource = app.slice(app.indexOf('async function fetchSidecarSnapshot('), app.indexOf('function msSinceLastActivity()'));
  let rendered = 0;
  let failures = 0;
  const ctx = {
    REQUEST_TIMEOUT_MS: 8000,
    refreshSeq: 0,
    inFlightSeq: null,
    activeRefreshController: null,
    selectedConversation: 'conv-b',
    switchingConversation: true,
    settingsSaving: false,
    settingsEpoch: 0,
    latestSavedConfig: null,
    lastSnapshot: null,
    lastSuccessAt: 0,
    firstFailureAt: 0,
    consecutiveFailures: 0,
    refreshIntervalSec: 3,
    getPaneConversationId: () => '',
    metaStrip: node(),
    emptyBox: node(),
    selectedConversationText: () => 'conv-b · repo',
    renderSnapshot() { rendered += 1; },
    renderConversationFailure() { failures += 1; },
    applyPanelConfig() {},
    renderStateNote() {},
    renderSourcesNote() {},
    AbortController,
    setTimeout,
    clearTimeout,
    window: { sidecar: { fetch: () => Promise.resolve({ ok: false, json: async () => ({}) }) } },
  };
  const refresh = vm.runInNewContext(`${formatSource}; ${fetchSource}; refreshSnapshot`, ctx);
  await refresh(true);
  assert.equal(rendered, 0, 'no snapshot must be rendered for a failed switch');
  assert.equal(failures, 1);
});

test('session module off keeps the live speed card and the one second poll', () => {
  const delay = vm.runInNewContext(`${pollingSource}; nextPollDelay()`, {
    refreshIntervalSec: 3,
    document: { hidden: false },
    // modules.session=false: the backend omits `session` entirely.
    lastSnapshot: { live: { active: true } },
    msSinceLastActivity: () => 0,
    IDLE_AFTER_SEC: 45,
    IDLE_POLL_MS: 15000,
    LIVE_POLL_MS: 1000,
  });
  assert.equal(delay, 1000);

  const node = (dataset = {}) => ({
    dataset, style: {}, innerHTML: '', textContent: '', title: '',
    classList: { toggle() {}, add() {} }, setAttribute() {}, querySelectorAll: () => [],
  });
  const panels = ['trends', 'usage', 'quota'].map((panel) => node({ panel }));
  const cardsEl = node();
  const metaStrip = node();
  const source = app.slice(app.indexOf('function formatTokens('), app.indexOf('function syncSessionSelect('));
  const snapshotSource = app.slice(app.indexOf('function renderSnapshot('), app.indexOf('sparkEl.addEventListener('));
  const render = vm.runInNewContext(`${source}; ${snapshotSource}; renderSnapshot`, {
    syncSessionSelect() {}, renderSessionStats() {}, renderQuota() {}, highlightHistoryItem() {},
    setActiveTab() {}, activeTab: 'trends', getPaneConversationId: () => '',
    liveDot: node(), metaStrip, cardsEl, tabBar: node(), tabPanels: panels,
    historySection: node(), historyCount: node(), sparkEl: node(), historyListEl: node(),
    emptyBox: node(), quotaSection: node(), quotaEmpty: node(), quotaListEl: node(), quotaNote: node(),
  });
  render({
    found: true,
    modelName: 'claude-demo',
    live: { active: true, estTokPerSec: 99, outputChars: 1234, charsPerSec: 40 },
    session: null,
    history: [],
    recentConversations: [],
    contextHistory: [],
    modelUsage: [],
    sessionUsage: null,
    latestUsage: null,
  });
  assert.match(cardsEl.innerHTML, /实时速度/);
  assert.match(cardsEl.innerHTML, /≈ 99\.0 tok\/s/);
  assert.doesNotMatch(metaStrip.innerHTML, /state-chip/, 'the session capsule stays hidden');
});

test('formatTokens rounds accurately and keeps sub-10K readable to 0.1K', () => {
  const fn = vm.runInNewContext(`${formatSource}; formatTokens`, {});
  assert.equal(fn(null), '--');
  assert.equal(fn(999), '999');
  assert.equal(fn(1000), '1.0K');
  assert.equal(fn(2455), '2.5K');
  assert.equal(fn(9950), '10K');
  assert.equal(fn(10000), '10K');
  assert.equal(fn(195960), '196K');
  assert.equal(fn(1048576), '1,049K');
  assert.equal(fn(2660075), '2,660K');
});

test('speed card aligns primary speed with matching output/duration and falls back cleanly', () => {
  const node = (dataset = {}) => ({
    dataset, style: {}, innerHTML: '', textContent: '', title: '',
    classList: { toggle() {}, add() {} }, setAttribute() {}, querySelectorAll: () => [],
  });
  const panels = ['trends', 'usage', 'quota'].map((panel) => node({ panel }));
  const cardsEl = node();
  const metaStrip = node();
  const source = app.slice(app.indexOf('function formatTokens('), app.indexOf('function syncSessionSelect('));
  const snapshotSource = app.slice(app.indexOf('function renderSnapshot('), app.indexOf('sparkEl.addEventListener('));
  const render = vm.runInNewContext(`${source}; ${snapshotSource}; renderSnapshot`, {
    syncSessionSelect() {}, renderSessionStats() {}, renderQuota() {}, highlightHistoryItem() {},
    setActiveTab() {}, activeTab: 'trends', getPaneConversationId: () => '',
    liveDot: node(), metaStrip, cardsEl, tabBar: node(), tabPanels: panels,
    historySection: node(), historyCount: node(), sparkEl: node(), historyListEl: node(),
    emptyBox: node(), quotaSection: node(), quotaEmpty: node(), quotaListEl: node(), quotaNote: node(),
  });

  render({
    found: true,
    lastGenSpeed: 276.5,
    lastAvgSpeed: 312.1,
    outputTokens: 2455,
    lastGenDurationSec: 8.88,
    lastGenTtftSec: 3.92,
    history: [],
    recentConversations: [],
    contextHistory: [],
    modelUsage: [],
    sessionUsage: null,
    latestUsage: null,
  });
  assert.match(cardsEl.innerHTML, /276\.5 tok\/s/);
  assert.match(cardsEl.innerHTML, /均 312\.1/);
  assert.match(cardsEl.innerHTML, /2\.5K · 8\.9s/);
  assert.match(cardsEl.innerHTML, /首字 3\.92s/);
  assert.match(cardsEl.innerHTML, /最近生成模型 近期均速：312\.1 tok\/s/);

  render({
    found: true,
    lastGenSpeed: null,
    lastAvgSpeed: 312.1,
    outputTokens: 2455,
    lastGenDurationSec: null,
    history: [],
    recentConversations: [],
    contextHistory: [],
    modelUsage: [],
    sessionUsage: null,
    latestUsage: null,
  });
  assert.match(cardsEl.innerHTML, /312\.1 tok\/s/);
  assert.match(cardsEl.innerHTML, /近期均速/);
  assert.doesNotMatch(cardsEl.innerHTML, /2\.5K · --/);

  // A switch just happened: the average still belongs to the previous model, so
  // it must be labelled with that model instead of "current model".
  render({
    found: true,
    modelName: 'gemini-4-hydrogen',
    turnModel: 'claude-sonnet-4',
    lastGenSpeed: null,
    lastAvgSpeed: 200,
    lastAvgSpeedModel: 'gemini-4-hydrogen',
    outputTokens: 2455,
    history: [],
    recentConversations: [],
    contextHistory: [],
    modelUsage: [],
    sessionUsage: null,
    latestUsage: null,
  });
  assert.match(cardsEl.innerHTML, /gemini-4-hydrogen 均速/);
  assert.match(cardsEl.innerHTML, /gemini-4-hydrogen 近期均速：200\.0 tok\/s/);
  assert.doesNotMatch(cardsEl.innerHTML, /当前模型/);
  assert.match(metaStrip.innerHTML, /gemini-4-hydrogen → claude-sonnet-4/);

  // No observed model name: stay generic rather than borrowing a known name.
  render({
    found: true,
    lastGenSpeed: null,
    lastAvgSpeed: 200,
    lastAvgSpeedModel: '',
    history: [],
    recentConversations: [],
    contextHistory: [],
    modelUsage: [],
    sessionUsage: null,
    latestUsage: null,
  });
  assert.match(cardsEl.innerHTML, /近期均速/);
  assert.doesNotMatch(cardsEl.innerHTML, /claude|gemini/);
});

test('usage tab simplifies complete coverage, renders composition bar, and sorts models by total', () => {
  const section = () => ({ style: {}, innerHTML: '', querySelector: () => ({ open: false }) });
  const usageSection = section();
  const contextSection = section();
  const modelsSection = section();
  const render = vm.runInNewContext(`${formatSource}; ${sessionUiSource}; renderSessionStats`, {
    usageSection, contextSection, modelsSection,
  });
  render({
    found: true,
    compactionCount: 0,
    config: { lowSpeedWarnTokS: 50 },
    latestUsage: {
      inputTokens: 3302,
      cacheReadTokens: 192658,
      outputTokens: 2455,
      totalTokens: 198415,
      cacheHitPct: 98.3,
    },
    sessionUsage: {
      requestCount: 19,
      recordedCount: 19,
      inputTokens: 375000,
      cacheReadTokens: 2257000,
      outputTokens: 27100,
      totalTokens: 2659100,
      cacheHitPct: 85.7,
    },
    modelUsage: [
      {
        model: 'gemini-4-hydrogen',
        requestCount: 6,
        recordedCount: 6,
        inputTokens: 202000,
        cacheReadTokens: 944000,
        outputTokens: 4500,
        totalTokens: 1150500,
        cacheHitPct: 82.4,
        avgSpeedTokS: 312.1,
        speedSamples: 6,
      },
      {
        model: 'gemini-4-neon',
        requestCount: 13,
        recordedCount: 13,
        inputTokens: 173000,
        cacheReadTokens: 1312500,
        outputTokens: 22600,
        totalTokens: 1508100,
        cacheHitPct: 88.3,
        avgSpeedTokS: 42.0,
        speedSamples: 13,
      },
    ],
    contextHistory: [],
  });
  assert.match(usageSection.innerHTML, />19 次请求</);
  assert.doesNotMatch(usageSection.innerHTML, /19\/19 次请求/);
  assert.match(usageSection.innerHTML, /usage-hit-pill good/);
  assert.match(usageSection.innerHTML, /usage-bar/);
  assert.match(usageSection.innerHTML, /seg-cache/);
  assert.match(usageSection.innerHTML, /seg-input/);
  assert.match(usageSection.innerHTML, /seg-out/);
  assert.match(usageSection.innerHTML, /最近回复/);
  assert.match(usageSection.innerHTML, /198K/);

  assert.match(modelsSection.innerHTML, /2 个模型/);
  assert.match(modelsSection.innerHTML, /model-share-fill/);
  assert.match(modelsSection.innerHTML, /model-speed warn/);
  const neonPos = modelsSection.innerHTML.indexOf('gemini-4-neon');
  const hydroPos = modelsSection.innerHTML.indexOf('gemini-4-hydrogen');
  assert.ok(neonPos >= 0 && hydroPos > neonPos, 'models should be sorted descending by totalTokens');
});

test('session switch discards stale response and forced refresh works while paused', async () => {
  const fetchSource = app.slice(app.indexOf('async function fetchSidecarSnapshot('), app.indexOf('function msSinceLastActivity()'));
  const formatSnippet = app.slice(app.indexOf('function formatTokens('), app.indexOf('const WEEKDAYS'));
  const resolvers = new Map();
  const rendered = [];
  const ctx = {
    REQUEST_TIMEOUT_MS: 8000,
    refreshSeq: 0,
    inFlightSeq: null,
    activeRefreshController: null,
    selectedConversation: 'conv-a',
    switchingConversation: false,
    settingsSaving: false,
    settingsEpoch: 0,
    latestSavedConfig: null,
    lastSnapshot: null,
    lastSuccessAt: 0,
    firstFailureAt: 0,
    consecutiveFailures: 0,
    refreshIntervalSec: 0,
    getPaneConversationId: () => '',
    metaStrip: { innerHTML: '' },
    emptyBox: { style: {}, textContent: '' },
    selectedConversationText: () => 'conv-a',
    renderConversationFailure() {},
    renderSnapshot(snap) { rendered.push(snap.conversationId); },
    applyPanelConfig() {},
    renderStateNote() {},
    renderSourcesNote() {},
    AbortController,
    setTimeout,
    clearTimeout,
    window: {
      sidecar: {
        fetch: (url, opts) => new Promise((resolve, reject) => {
          const id = new URL('http://localhost' + url).searchParams.get('conversationId');
          resolvers.set(id, { resolve, reject, signal: opts.signal });
        }),
      },
    },
  };
  const refresh = vm.runInNewContext(`${formatSnippet}; ${fetchSource}; refreshSnapshot`, ctx);
  const pA = refresh(false);
  ctx.selectedConversation = 'conv-b';
  const pB = refresh(true);
  assert.equal(resolvers.get('conv-a').signal.aborted, true);
  resolvers.get('conv-b').resolve({ ok: true, json: async () => ({ found: true, conversationId: 'conv-b' }) });
  await pB;
  resolvers.get('conv-a').resolve({ ok: true, json: async () => ({ found: true, conversationId: 'conv-a' }) });
  await pA;
  assert.deepEqual(rendered, ['conv-b']);
  assert.equal(ctx.lastSnapshot.conversationId, 'conv-b');
});

test('hung request times out and cold-start failures surface offline chip', async () => {
  const fetchSource = app.slice(app.indexOf('async function fetchSidecarSnapshot('), app.indexOf('function msSinceLastActivity()'));
  const formatSnippet = app.slice(app.indexOf('function formatTokens('), app.indexOf('const WEEKDAYS'));
  const ctx = {
    REQUEST_TIMEOUT_MS: 30,
    refreshSeq: 0,
    inFlightSeq: null,
    activeRefreshController: null,
    selectedConversation: 'auto',
    switchingConversation: false,
    settingsSaving: false,
    settingsEpoch: 0,
    latestSavedConfig: null,
    lastSnapshot: null,
    lastSuccessAt: 0,
    firstFailureAt: 0,
    consecutiveFailures: 0,
    refreshIntervalSec: 3,
    getPaneConversationId: () => '',
    metaStrip: { innerHTML: '' },
    emptyBox: { style: {}, textContent: '' },
    selectedConversationText: () => '自动跟随当前会话',
    renderConversationFailure() {},
    renderSnapshot() {},
    applyPanelConfig() {},
    renderStateNote() {},
    renderSourcesNote() {},
    AbortController,
    setTimeout,
    clearTimeout,
    window: { sidecar: { fetch: () => new Promise(() => {}) } },
  };
  const refresh = vm.runInNewContext(`${formatSnippet}; ${fetchSource}; refreshSnapshot`, ctx);
  await refresh(false);
  assert.equal(ctx.inFlightSeq, null);
  assert.equal(ctx.consecutiveFailures, 1);
  await refresh(false);
  assert.equal(ctx.inFlightSeq, null);
  assert.equal(ctx.consecutiveFailures, 2);
  assert.match(ctx.metaStrip.innerHTML, /后台无响应/);
  assert.match(ctx.emptyBox.textContent, /侧车后台无响应/);
});

test('idle or error session suppresses live polling and live card rendering', () => {
  const delayIdle = vm.runInNewContext(`${pollingSource}; nextPollDelay()`, {
    refreshIntervalSec: 3,
    document: { hidden: false },
    lastSnapshot: { live: { active: true }, session: { state: 'idle' } },
    msSinceLastActivity: () => 0,
    IDLE_AFTER_SEC: 45,
    IDLE_POLL_MS: 15000,
    LIVE_POLL_MS: 1000,
  });
  assert.equal(delayIdle, 3000);

  const node = (dataset = {}) => ({
    dataset, style: {}, innerHTML: '', textContent: '', title: '',
    classList: { toggle() {}, add() {} }, setAttribute() {}, querySelectorAll: () => [],
  });
  const panels = ['trends', 'usage', 'quota'].map((panel) => node({ panel }));
  const cardsEl = node();
  const historyListEl = node();
  const source = app.slice(app.indexOf('function formatTokens('), app.indexOf('function syncSessionSelect('));
  const snapshotSource = app.slice(app.indexOf('function renderSnapshot('), app.indexOf('sparkEl.addEventListener('));
  const render = vm.runInNewContext(`${source}; ${snapshotSource}; renderSnapshot`, {
    syncSessionSelect() {}, renderSessionStats() {}, renderQuota() {}, highlightHistoryItem() {},
    setActiveTab() {}, activeTab: 'trends', activeHistoryIdx: null, currentHistory: [], currentDefaultModel: '',
    getPaneConversationId: () => '',
    liveDot: node(), metaStrip: node(), cardsEl, tabBar: node(), tabPanels: panels,
    historySection: node(), historyCount: node(), sparkEl: node(), historyListEl,
    emptyBox: node(), quotaSection: node(), quotaEmpty: node(), quotaListEl: node(), quotaNote: node(),
  });
  render({
    found: true,
    modelName: 'claude-demo',
    live: { active: true, estTokPerSec: 99 },
    session: { state: 'idle', code: 'user_cancelled', label: '已取消', detail: '已取消' },
    history: [{ idx: 1, speedTokS: 50, outputTokens: 100, durationSec: 2, model: '' }],
    recentConversations: [], contextHistory: [], modelUsage: [], sessionUsage: null, latestUsage: null,
  });
  assert.doesNotMatch(cardsEl.innerHTML, /实时速度/);
  assert.match(historyListEl.innerHTML, /未知模型/);
  assert.doesNotMatch(historyListEl.innerHTML, /claude-demo/);
});

test('quota header and expired window tooltips stay consistent with per-window state', () => {
  const node = () => ({ style: {}, innerHTML: '', textContent: '', title: '' });
  const quotaSection = node();
  const quotaEmpty = node();
  const quotaNote = node();
  const quotaListEl = node();
  const source = app.slice(app.indexOf('function formatTokens('), app.indexOf('function syncSessionSelect('));
  const render = vm.runInNewContext(`${source}; renderQuota`, {
    quotaSection, quotaEmpty, quotaNote, quotaListEl,
  });
  const futureEpoch = Math.floor(Date.now() / 1000) + 7200;
  const pastEpoch = Math.floor(Date.now() / 1000) - 300;
  render({
    observedAt: new Date().toISOString(),
    observedAgeSec: 1200,
    stale: false,
    windows: [
      { pool: 'gemini', window: '5h', resetAtEpoch: futureEpoch, resetInSec: 7200, approx: true },
      { pool: 'gemini', window: 'weekly', resetAtEpoch: futureEpoch, resetInSec: 7200, approx: false },
    ],
  });
  assert.match(quotaNote.textContent, /部分推算/);

  render({
    observedAt: new Date(Date.now() - 8 * 3600 * 1000).toISOString(),
    observedAgeSec: 8 * 3600,
    stale: true,
    windows: [
      { pool: 'claude', window: 'weekly', resetAtEpoch: futureEpoch, resetInSec: 7200, approx: false },
    ],
  });
  assert.match(quotaNote.textContent, /快照较旧/);
  assert.doesNotMatch(quotaNote.textContent, /· 推算/);

  render({
    observedAt: new Date().toISOString(),
    observedAgeSec: 600,
    stale: false,
    windows: [
      { pool: 'claude', window: 'other', resetAtEpoch: pastEpoch, resetInSec: -300, approx: false },
    ],
  });
  assert.match(quotaNote.textContent, /部分已过/);
  assert.match(quotaListEl.innerHTML, /（已过）/);
  assert.doesNotMatch(quotaListEl.innerHTML, /即将重置/);
});

test('re-enabling panel without local sessions restores tabs, settings ignore stale snapshots, and custom poll interval loads', async () => {
  const node = (dataset = {}) => ({
    dataset, style: {}, innerHTML: '', textContent: '',
    classList: { toggle() {} }, setAttribute() {},
  });
  const panels = ['trends', 'usage', 'quota', 'settings'].map((panel) => node({ panel }));
  const tabBar = node();
  const emptyBox = node();
  const source = app.slice(app.indexOf('function formatTokens('), app.indexOf('function syncSessionSelect('));
  const snapshotSource = app.slice(app.indexOf('function renderSnapshot('), app.indexOf('sparkEl.addEventListener('));
  const render = vm.runInNewContext(`${source}; ${snapshotSource}; renderSnapshot`, {
    syncSessionSelect() {}, renderSessionStats() {}, setActiveTab() {}, activeTab: 'trends',
    getPaneConversationId: () => '', liveDot: node(), metaStrip: node(), cardsEl: node(),
    tabBar, tabPanels: panels, historySection: node(), emptyBox,
    quotaSection: node(), quotaEmpty: node(), quotaListEl: node(), quotaNote: node(),
  });
  render({ found: false, disabled: true, config: { enabled: false }, message: '已关闭' });
  assert.equal(tabBar.style.display, 'none');
  render({ found: false, disabled: false, config: { enabled: true }, message: '暂无会话' });
  assert.equal(tabBar.style.display, 'grid');
  for (const p of panels) assert.equal(p.style.display, '');

  const intervalSource = app.slice(app.indexOf('function loadSavedInterval('), app.indexOf('function saveInterval('));
  const allowed = new Set([0, 3, 5, 10]);
  const loaded = vm.runInNewContext(`${intervalSource}; loadSavedInterval()`, {
    STORAGE_KEY_INTERVAL: 'agy_status_refresh_sec',
    ALLOWED_INTERVALS: allowed,
    window: { localStorage: { getItem: () => '7' } },
  });
  assert.equal(loaded, 7);
  assert.equal(allowed.has(7), true);

  // Stale status response started before saveSettingsPatch must not snap config back.
  const fetchSource = app.slice(app.indexOf('async function fetchSidecarSnapshot('), app.indexOf('function msSinceLastActivity()'));
  const settingsSource = app.slice(app.indexOf('function readClampedNum('), app.indexOf('async function boot('));
  const controls = Object.fromEntries([
    'cfgLayoutEl', 'cfgPollSecEl', 'cfgLowSpeedEl', 'cfgWaitSecEl', 'cfgStallSecEl', 'cfgToolGraceEl',
    'cfgModSessionEl', 'cfgModHistoryEl', 'cfgModContextEl', 'cfgModModelsEl', 'cfgModQuotaEl',
    'notchEnabledEl', 'notchHideIdleEl', 'notchScreenModeEl', 'notchAvoidanceModeEl',
  ].map((key) => [key, { value: 'detailed', checked: true, addEventListener(_, fn) { this.change = fn; } }]));
  let resolveStatus;
  const appliedConfigs = [];
  const renderedConfigs = [];
  const raceCtx = {
    ...controls,
    REQUEST_TIMEOUT_MS: 8000,
    refreshSeq: 0,
    inFlightSeq: null,
    activeRefreshController: null,
    selectedConversation: 'auto',
    switchingConversation: false,
    settingsSaving: false,
    settingsPending: 0,
    settingsQueue: Promise.resolve(),
    settingsSaveStatusEl: { textContent: '' },
    settingsEpoch: 0,
    latestSavedConfig: null,
    lastSnapshot: null,
    selectedConversationText: () => '自动跟随当前会话',
    renderConversationFailure() {},
    lastSuccessAt: 0,
    firstFailureAt: 0,
    consecutiveFailures: 0,
    refreshIntervalSec: 3,
    getPaneConversationId: () => '',
    metaStrip: { innerHTML: '' },
    emptyBox: { style: {}, textContent: '' },
    renderSnapshot(snap) { renderedConfigs.push(snap.config); },
    applyPanelConfig(cfg) { appliedConfigs.push(cfg); },
    renderStateNote() {},
    renderSourcesNote() {},
    AbortController,
    setTimeout,
    clearTimeout,
    window: {
      sidecar: {
        fetch: (url) => {
          if (url.startsWith('/api/status')) {
            return new Promise((resolve) => { resolveStatus = resolve; });
          }
          return Promise.resolve({ ok: true, json: async () => ({ layout: 'detailed' }) });
        },
      },
    },
  };
  vm.runInNewContext(`${formatSource}; ${fetchSource}; ${settingsSource}`, raceCtx);
  const pStatus = raceCtx.refreshSnapshot(false);
  await raceCtx.saveSettingsPatch({ layout: 'detailed' });
  resolveStatus({ ok: true, json: async () => ({ found: true, config: { layout: 'compact' } }) });
  await pStatus;
  assert.deepEqual(appliedConfigs, [{ layout: 'detailed' }]);
  assert.deepEqual(renderedConfigs[renderedConfigs.length - 1], { layout: 'detailed' });
});

test('formatDuration avoids 1m 60s and context chart hit rects partition [0, 360] cleanly', () => {
  const fn = vm.runInNewContext(`${formatSource}; formatDuration`, {});
  assert.equal(fn(59.96), '1m 0s');
  assert.equal(fn(119.75), '2m 0s');
  assert.equal(fn(3599.6), '1h 0m');

  for (const count of [3, 120]) {
    const section = () => ({ style: {}, innerHTML: '', querySelector: () => ({ open: false }) });
    const contextSection = section();
    const render = vm.runInNewContext(`${formatSource}; ${sessionUiSource}; renderSessionStats`, {
      usageSection: section(), contextSection, modelsSection: section(),
    });
    const points = Array.from({ length: count }, (_, i) => ({
      request: i + 1, contextUsed: 1000 + i * 10, compaction: false, at: null, model: 'a',
    }));
    render({ found: true, compactionCount: 0, contextHistory: points, modelUsage: [], sessionUsage: null, latestUsage: null });
    const rects = [...contextSection.innerHTML.matchAll(/<rect class="ctx-hit"[^>]*x="([^"]+)"[^>]*width="([^"]+)"/g)]
      .map((m) => [Number(m[1]), Number(m[1]) + Number(m[2])]);
    assert.equal(rects.length, count);
    assert.equal(rects[0][0], 0);
    assert.ok(Math.abs(rects[rects.length - 1][1] - 360) <= 0.2);
    for (let i = 1; i < rects.length; i += 1) {
      assert.ok(Math.abs(rects[i][0] - rects[i - 1][1]) <= 0.2, `gap/overlap at ${i}: ${rects[i - 1]} vs ${rects[i]}`);
    }
  }
});
