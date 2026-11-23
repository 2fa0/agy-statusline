export {};

interface GenHistoryItem {
  idx: number;
  speedTokS: number | null;
  outputTokens: number | null;
  durationSec: number | null;
  model: string;
}

interface RecentConversation {
  conversationId: string;
  shortId: string;
  modelName: string;
  workspace: string;
  updatedAt: string;
  isActive: boolean;
}

interface QuotaWindow {
  pool: string;
  window: string;
  bucket?: string;
  remainingPct?: number | null;
  resetAt?: string | null;
  resetAtEpoch?: number | null;
  resetInSec?: number | null;
  approx?: boolean;
}

interface QuotaSnapshot {
  source?: string;
  observedAt?: string;
  observedAgeSec?: number;
  stale?: boolean;
  windows?: QuotaWindow[];
}

interface LiveState {
  active: boolean;
  stepIdx?: number | null;
  stepType?: number | null;
  status?: number | null;
  outputChars?: number | null;
  charsPerSec?: number | null;
  charsPerToken?: number | null;
  estTokPerSec?: number | null;
  elapsedSec?: number | null;
  observedAt?: string;
}

type SessionState = 'idle' | 'running' | 'waiting' | 'error';

/** Backend-computed session state; the UI only renders it. */
interface SessionInfo {
  state: SessionState;
  code: string;
  label: string;
  detail: string;
  waitSec?: number | null;
  sinceEvent?: string;
  evidence?: Record<string, unknown>;
}

interface PanelModules {
  session?: boolean;
  quota?: boolean;
  history?: boolean;
  models?: boolean;
  context?: boolean;
}

/** Mirrors ~/.gemini/agy-statusline/config.json, echoed on every snapshot. */
interface SourceNote {
  code: string;
  label?: string;
  text: string;
}

/** Which evidence the numbers came from, and what was unavailable. */
interface DataSources {
  degraded?: boolean;
  db?: string;
  transcript?: string;
  hooks?: string;
  quota?: string;
  notes?: SourceNote[];
}

interface NotchConfig {
  supported?: boolean;
  enabled?: boolean;
  hideWhenIdle?: boolean;
  screenMode?: 'notchOrMain' | 'followActive' | 'allScreens';
  avoidanceMode?: 'autoStackBelow' | 'forceNotch' | 'topRight';
}

interface PanelConfig {
  enabled?: boolean;
  layout?: 'compact' | 'detailed';
  pollSec?: number;
  lowSpeedWarnTokS?: number;
  waitSec?: number;
  stallSec?: number;
  toolGraceSec?: number;
  modules?: PanelModules;
  notch?: NotchConfig;
}

interface UsageSummary {
  inputTokens: number | null;
  cacheReadTokens: number | null;
  outputTokens: number | null;
  totalTokens: number | null;
  cacheHitPct: number | null;
  requestCount?: number;
  recordedCount?: number;
}

interface ModelUsage extends UsageSummary {
  model: string;
  avgSpeedTokS?: number | null;
  speedSamples?: number;
}

interface ContextPoint {
  request: number;
  stepIdx: number | null;
  at: string | null;
  model: string;
  contextUsed: number | null;
  compaction: boolean;
}

interface StatusSnapshot {
  found: boolean;
  conversationId: string;
  shortId?: string;
  isActiveSession?: boolean;
  hookConnected?: boolean;
  modelName?: string;
  workspaceName?: string;
  lastAvgSpeed?: number | null;
  lowSpeedWarning?: boolean;
  lastGenDurationSec?: number | null;
  turnDurationSec?: number | null;
  sessionDurationSec?: number | null;
  turnCount?: number | null;
  stepCount?: number | null;
  contextUsed?: number | null;
  contextTotal?: number | null;
  contextPct?: number | null;
  cacheHitPct?: number | null;
  cacheReadTokens?: number | null;
  cacheWriteTokens?: number | null;
  inputTokens?: number | null;
  outputTokens?: number | null;
  usageSource?: string;
  latestUsage?: UsageSummary | null;
  sessionUsage?: UsageSummary | null;
  modelUsage?: ModelUsage[];
  contextHistory?: ContextPoint[];
  compactionCount?: number | null;
  history?: GenHistoryItem[];
  recentConversations?: RecentConversation[];
  quota?: QuotaSnapshot | null;
  live?: LiveState | null;
  session?: SessionInfo | null;
  sources?: DataSources;
  config?: PanelConfig;
  disabled?: boolean;
  generatedAt?: string;
  lastActivityAt?: string | null;
  cacheHit?: boolean;
  message?: string;
}

declare global {
  interface Window {
    sidecar?: {
      conversationId?: string | null;
      fetch?: typeof fetch;
    };
  }
}

const STORAGE_KEY_INTERVAL = 'agy_status_refresh_sec';
const STORAGE_KEY_TAB = 'agy_status_active_tab';
const ALLOWED_INTERVALS = new Set([0, 3, 5, 10]);
const ALLOWED_TABS = new Set(['trends', 'usage', 'quota', 'settings']);
// Adaptive polling: follow the session closely while it is generating and back
// off when it is idle to reduce repeated reads and rendering.
const IDLE_POLL_MS = 15000;
const IDLE_AFTER_SEC = 45;
const LIVE_POLL_MS = 1000;

const sessionSelect = document.getElementById('session-select') as HTMLSelectElement;
const refreshSelect = document.getElementById('refresh-select') as HTMLSelectElement;
const liveDot = document.getElementById('live-dot') as HTMLSpanElement;
const metaStrip = document.getElementById('meta-strip') as HTMLDivElement;
const cardsEl = document.getElementById('cards') as HTMLDivElement;
const tabBar = document.getElementById('tab-bar') as HTMLDivElement;
const tabPanels = Array.from(document.querySelectorAll<HTMLElement>('.tab-panel'));
const quotaSection = document.getElementById('quota-section') as HTMLDivElement;
const quotaEmpty = document.getElementById('quota-empty') as HTMLDivElement;
const quotaNote = document.getElementById('quota-note') as HTMLSpanElement;
const quotaListEl = document.getElementById('quota-list') as HTMLDivElement;
const historySection = document.getElementById('history-section') as HTMLDivElement;
const historyCount = document.getElementById('history-count') as HTMLSpanElement;
const sparkDetailEl = document.getElementById('spark-detail') as HTMLDivElement;
const sparkEl = document.getElementById('spark') as HTMLDivElement;
const historyListEl = document.getElementById('history-list') as HTMLDivElement;
const emptyBox = document.getElementById('empty-box') as HTMLDivElement;
const usageSection = document.getElementById('usage-section') as HTMLDivElement;
const contextSection = document.getElementById('context-section') as HTMLDivElement;
const modelsSection = document.getElementById('models-section') as HTMLDivElement;
const cfgLayoutEl = document.getElementById('cfg-layout') as HTMLSelectElement | null;
const cfgPollSecEl = document.getElementById('cfg-poll-sec') as HTMLSelectElement | null;
const cfgModSessionEl = document.getElementById('cfg-mod-session') as HTMLInputElement | null;
const cfgModHistoryEl = document.getElementById('cfg-mod-history') as HTMLInputElement | null;
const cfgModContextEl = document.getElementById('cfg-mod-context') as HTMLInputElement | null;
const cfgModModelsEl = document.getElementById('cfg-mod-models') as HTMLInputElement | null;
const cfgModQuotaEl = document.getElementById('cfg-mod-quota') as HTMLInputElement | null;
const cfgLowSpeedEl = document.getElementById('cfg-low-speed') as HTMLInputElement | null;
const cfgWaitSecEl = document.getElementById('cfg-wait-sec') as HTMLInputElement | null;
const cfgStallSecEl = document.getElementById('cfg-stall-sec') as HTMLInputElement | null;
const cfgToolGraceEl = document.getElementById('cfg-tool-grace') as HTMLInputElement | null;
const notchEnabledEl = document.getElementById('notch-enabled') as HTMLInputElement | null;
const notchHideIdleEl = document.getElementById('notch-hide-idle') as HTMLInputElement | null;
const notchScreenModeEl = document.getElementById('notch-screen-mode') as HTMLSelectElement | null;
const notchAvoidanceModeEl = document.getElementById('notch-avoidance-mode') as HTMLSelectElement | null;
const settingsSaveStatusEl = document.getElementById('settings-save-status') as HTMLSpanElement | null;
let settingsSaving = false;
let settingsPending = 0;
let settingsQueue: Promise<void> = Promise.resolve();

let selectedConversation = 'auto';
let refreshIntervalSec = loadSavedInterval();
let activeTab = loadSavedTab();
let inFlight = false;
let timerId: number | null = null;
let currentHistory: GenHistoryItem[] = [];
let currentContextPoints: ContextPoint[] = [];
let currentDefaultModel = '';
let activeHistoryIdx: number | null = null;
let lastSnapshot: StatusSnapshot | null = null;
let appliedPollSec: number | null = null;
let lastSuccessAt = 0;
let consecutiveFailures = 0;

function loadSavedTab(): string {
  try {
    const saved = localStorage.getItem(STORAGE_KEY_TAB);
    if (saved && ALLOWED_TABS.has(saved)) return saved;
  } catch {
    // ignore storage errors
  }
  return 'trends';
}

function setActiveTab(tab: string): void {
  activeTab = ALLOWED_TABS.has(tab) ? tab : 'trends';
  try {
    localStorage.setItem(STORAGE_KEY_TAB, activeTab);
  } catch {
    // ignore storage errors
  }
  tabBar.querySelectorAll<HTMLButtonElement>('.tab-btn').forEach((btn) => {
    const isActive = btn.dataset.tab === activeTab;
    btn.classList.toggle('active', isActive);
    btn.setAttribute('aria-selected', isActive ? 'true' : 'false');
  });
  tabPanels.forEach((panel) => {
    panel.classList.toggle('active', panel.dataset.panel === activeTab);
  });
}

function loadSavedInterval(): number {
  try {
    const raw = window.localStorage?.getItem(STORAGE_KEY_INTERVAL);
    if (raw !== null) {
      const n = Number.parseInt(raw, 10);
      if (ALLOWED_INTERVALS.has(n)) {
        return n;
      }
    }
  } catch {
    // Ignore localStorage errors in restricted iframe sandboxes
  }
  return 3;
}

function saveInterval(sec: number): void {
  try {
    window.localStorage?.setItem(STORAGE_KEY_INTERVAL, String(sec));
  } catch {
    // Ignore localStorage errors
  }
}

refreshSelect.value = String(refreshIntervalSec);
refreshSelect.classList.toggle('active', refreshIntervalSec > 0);
refreshSelect.title =
  '自适应刷新：活跃时按所选间隔刷新，空闲时降到 15s，面板隐藏时暂停';

function formatTokens(val: number | null | undefined): string {
  if (val === null || val === undefined || val < 0) return '--';
  if (val >= 1000) {
    return `${Math.trunc(val / 1000).toLocaleString('en-US')}K`;
  }
  return val.toLocaleString('en-US');
}

function formatExactTokens(val: number | null | undefined): string {
  if (val === null || val === undefined || val < 0) return '--';
  return `${val.toLocaleString('en-US')} tok`;
}

function formatDuration(sec: number | null | undefined): string {
  if (sec === null || sec === undefined || sec < 0) return '--';
  if (sec < 60) return `${sec.toFixed(1)}s`;
  const mins = Math.floor(sec / 60);
  const rem = Math.round(sec % 60);
  if (mins < 60) return `${mins}m ${rem}s`;
  const hrs = Math.floor(mins / 60);
  return `${hrs}h ${mins % 60}m`;
}

function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
const QUOTA_POOL_LABELS: Record<string, string> = { gemini: 'Gemini', argon: 'Argon', claude: 'Claude' };
const QUOTA_WINDOW_LABELS: Record<string, string> = { '5h': '5小时', weekly: '周限', other: '额度' };
const QUOTA_WINDOW_ORDER: Record<string, number> = { '5h': 0, weekly: 1, other: 2 };

function formatClock(d: Date): string {
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

function dayStart(offsetDays = 0): number {
  const d = new Date();
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + offsetDays).getTime();
}

/** Absolute local reset time, so nobody has to add "3d 4h" to the clock. */
function formatResetAt(epochSec: number | null | undefined): string {
  if (epochSec === null || epochSec === undefined) return '--';
  const d = new Date(epochSec * 1000);
  if (Number.isNaN(d.getTime())) return '--';
  const hm = formatClock(d);
  const resetDay = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diffDays = Math.round((resetDay - dayStart()) / 86400000);
  if (diffDays === 0) return `今天 ${hm}`;
  if (diffDays === 1) return `明天 ${hm}`;
  return `${WEEKDAYS[d.getDay()]} ${d.getMonth() + 1}/${d.getDate()} ${hm}`;
}

function formatRemaining(sec: number | null | undefined): string {
  if (sec === null || sec === undefined) return '';
  if (sec <= 0) return '即将重置';
  const days = Math.floor(sec / 86400);
  const hours = Math.floor((sec % 86400) / 3600);
  const mins = Math.floor((sec % 3600) / 60);
  if (days > 0) return `${days}天 ${hours}小时`;
  if (hours > 0) return `${hours}小时 ${mins}分钟`;
  return `${mins}分钟`;
}

function formatAge(sec: number | undefined): string {
  if (sec === undefined) return '';
  if (sec < 60) return '刚刚';
  if (sec < 3600) return `${Math.floor(sec / 60)} 分钟前`;
  if (sec < 86400) return `${Math.floor(sec / 3600)} 小时前`;
  return `${Math.floor(sec / 86400)} 天前`;
}

/** Clock label for the moment the quota snapshot was observed (local time). */
function formatSnapshotTime(iso?: string): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const sameDay = d.toDateString() === new Date().toDateString();
  return sameDay ? formatClock(d) : `${d.getMonth() + 1}/${d.getDate()} ${formatClock(d)}`;
}

function renderQuota(quota: QuotaSnapshot | null | undefined): void {
  const windows = (quota?.windows || []).filter((w) => w && typeof w === 'object');
  if (!quota || windows.length === 0) {
    quotaSection.style.display = 'none';
    quotaEmpty.style.display = 'block';
    quotaListEl.innerHTML = '';
    return;
  }
  quotaSection.style.display = 'flex';
  quotaEmpty.style.display = 'none';

  const age = formatAge(quota.observedAgeSec);
  const observedAt = formatSnapshotTime(quota.observedAt);
  quotaNote.textContent = quota.stale
    ? `${observedAt || age} · 推算`
    : `${observedAt || age} 更新`;
  quotaNote.title = quota.stale
    ? `上次采到额度是 ${observedAt}（${age}）；重置时间已按 5h / 7 天周期推算到下一次`
    : '额度来自上一次 agy CLI 渲染时的状态栏数据';

  const groups = new Map<string, QuotaWindow[]>();
  for (const item of windows) {
    const list = groups.get(item.pool) || [];
    list.push(item);
    groups.set(item.pool, list);
  }

  quotaListEl.innerHTML = Array.from(groups.entries())
    .map(([poolKey, items]) => {
      const pool = QUOTA_POOL_LABELS[poolKey] || poolKey;
      const sorted = [...items].sort(
        (a, b) => (QUOTA_WINDOW_ORDER[a.window] ?? 99) - (QUOTA_WINDOW_ORDER[b.window] ?? 99),
      );
      const cellsHtml = sorted
        .map((item) => {
          const windowLabel = QUOTA_WINDOW_LABELS[item.window] || item.window;
          const hasReset = item.resetAtEpoch !== null && item.resetAtEpoch !== undefined;
          const approxMark = hasReset && item.approx ? '≈ ' : '';
          const remaining = hasReset ? formatRemaining(item.resetInSec) : '';
          const resetAt = hasReset ? formatResetAt(item.resetAtEpoch) : '未知';
          const fullLocal = hasReset ? new Date((item.resetAtEpoch as number) * 1000).toLocaleString() : '--';
          const tip = [
            `${pool} ${windowLabel}`,
            hasReset ? `重置于 ${fullLocal}` : '重置时间未知',
            hasReset && remaining ? `距重置 ${remaining}` : '',
            item.approx ? '按 5h / 7 天周期推算' : '',
            age ? `采集于 ${age}` : '',
          ]
            .filter(Boolean)
            .join(' · ');
          return `
            <div class="quota-cell" title="${escapeHtml(tip)}">
              <span class="quota-label">${escapeHtml(windowLabel)}</span>
              <span class="quota-time">${escapeHtml(approxMark + resetAt)}</span>
            </div>
          `;
        })
        .join('');
      return `
        <div class="quota-group">
          <div class="quota-group-title">${escapeHtml(pool)}</div>
          <div class="quota-windows">${cellsHtml}</div>
        </div>
      `;
    })
    .join('');
}

function syncSessionSelect(recent: RecentConversation[] = []): void {
  const previous = selectedConversation;
  const options: string[] = ['<option value="auto">自动跟随当前活跃会话</option>'];
  for (const item of recent) {
    const labelParts = [item.shortId];
    if (item.workspace) labelParts.push(item.workspace);
    if (item.modelName) labelParts.push(item.modelName);
    if (item.isActive) labelParts.push('活跃');
    options.push(
      `<option value="${escapeHtml(item.conversationId)}">${escapeHtml(labelParts.join(' · '))}</option>`,
    );
  }
  sessionSelect.innerHTML = options.join('');
  const exists = Array.from(sessionSelect.options).some((opt) => opt.value === previous);
  sessionSelect.value = exists ? previous : 'auto';
  selectedConversation = sessionSelect.value;
}

function highlightHistoryItem(targetIdx: number | null): void {
  if (currentHistory.length === 0) return;
  const fallback = currentHistory[0];
  const item =
    (targetIdx !== null ? currentHistory.find((h) => h.idx === targetIdx) : undefined) || fallback;
  activeHistoryIdx = item.idx;

  const isWarn = item.speedTokS !== null && item.speedTokS < (lastSnapshot?.config?.lowSpeedWarnTokS ?? 50);
  const speedStr = item.speedTokS !== null ? `${item.speedTokS.toFixed(1)} tok/s` : '--';
  const modelStr = item.model || currentDefaultModel || '未知模型';
  const outStr =
    item.outputTokens !== null && item.outputTokens !== undefined
      ? `${item.outputTokens.toLocaleString('en-US')} tok`
      : '--';
  const durStr =
    item.durationSec !== null && item.durationSec !== undefined
      ? `${item.durationSec.toFixed(2)}s`
      : '--';

  sparkDetailEl.innerHTML = `
    <span>
      <strong>#${item.idx}</strong>
      <span class="muted"> · ${escapeHtml(modelStr)}</span>
    </span>
    <span>
      <span class="tag ${isWarn ? 'warn' : ''}">${escapeHtml(speedStr)}</span>
      <span class="muted"> · 输出 ${escapeHtml(outStr)} · 耗时 ${escapeHtml(durStr)}</span>
    </span>
  `;

  sparkEl.querySelectorAll<HTMLElement>('.spark-col').forEach((el) => {
    const idx = Number(el.dataset.idx);
    el.classList.toggle('active', idx === item.idx);
  });

  historyListEl.querySelectorAll<HTMLElement>('.history-row').forEach((el) => {
    const idx = Number(el.dataset.idx);
    el.classList.toggle('active', idx === item.idx);
  });
}

const urlParams = new URLSearchParams(window.location.search);

function getPaneConversationId(): string {
  return (window.sidecar?.conversationId || urlParams.get('conversationId') || '').trim();
}

function usageBody(usage: UsageSummary | null | undefined): string {
  const pct = usage?.cacheHitPct;
  return `<div class="usage-total">${formatTokens(usage?.totalTokens)} <small>tok</small></div>
    <div class="stats-note">入 ${formatTokens(usage?.inputTokens)} · 读 ${formatTokens(usage?.cacheReadTokens)} · 出 ${formatTokens(usage?.outputTokens)}</div>
    <div class="stats-note">缓存命中 ${typeof pct === 'number' ? `${pct.toFixed(1)}%` : '--'}</div>`;
}

function pointLabel(point: ContextPoint): string {
  const time = point.at ? new Date(point.at).toLocaleString() : '时间未知';
  return `#${point.request} · ${time} · ${point.compaction ? '已压缩' : `${point.model} · ${formatExactTokens(point.contextUsed)}`}`;
}

function renderSessionStats(snap: StatusSnapshot): void {
  for (const section of [usageSection, contextSection, modelsSection]) {
    section.style.display = snap.found ? 'flex' : 'none';
  }
  if (!snap.found) return;
  const usage = snap.sessionUsage;
  const coverage = usage ? `${usage.recordedCount}/${usage.requestCount} 次请求` : '日志未采集';
  const usageTip = '累计包含已完成的回复与压缩请求；按日志中的输入、缓存读取、输出相加，不含未记录的缓存写入。缓存命中率按总量加权。';
  usageSection.innerHTML = `<div class="section-title" title="${usageTip}"><span>Token 与缓存</span><span class="muted">${escapeHtml(coverage)}</span></div>
    <div class="usage-grid">
      <div><div class="stats-label">最近回复</div>${usageBody(snap.latestUsage)}</div>
      <div><div class="stats-label">会话累计</div>${usageBody(usage)}</div>
    </div>`;

  const points = snap.contextHistory || [];
  const count = snap.compactionCount;
  const values = points.filter((p) => typeof p.contextUsed === 'number');
  const max = Math.max(1, ...values.map((p) => p.contextUsed as number));
  const left = 10;
  const right = 350;
  const top = 16;
  const bottom = 92;
  const span = right - left;
  const x = (i: number) => (points.length <= 1 ? (left + right) / 2 : left + (i * span) / (points.length - 1));
  const y = (value: number) => bottom - (value / max) * (bottom - top);
  const paths: string[] = [];
  let run: string[] = [];
  const flush = () => {
    if (run.length) paths.push(`<polyline class="ctx-line" points="${run.join(' ')}"/>`);
    run = [];
  };
  points.forEach((point, i) => {
    if (point.contextUsed === null || point.compaction) { flush(); return; }
    run.push(`${x(i).toFixed(1)},${y(point.contextUsed).toFixed(1)}`);
  });
  flush();

  const savedReq = Number(contextSection.dataset?.activeReq);
  const activePoint =
    (Number.isFinite(savedReq) ? points.find((p) => p.request === savedReq) : undefined) ||
    points[points.length - 1];
  const activeReq = activePoint?.request ?? null;

  const guides = points.map((point, i) => {
    const px = x(i).toFixed(1);
    const isAct = point.request === activeReq ? ' active' : '';
    return `<line class="ctx-guide${isAct}" data-req="${point.request}" x1="${px}" x2="${px}" y1="${top}" y2="${bottom}"/>`;
  }).join('');

  const marks = points.map((point, i) => {
    const px = x(i).toFixed(1);
    const isAct = point.request === activeReq;
    if (point.compaction) {
      return `<line class="ctx-compaction" x1="${px}" x2="${px}" y1="${top}" y2="${bottom}" stroke-dasharray="3 3"><title>${escapeHtml(pointLabel(point))}</title></line>`;
    }
    if (point.contextUsed !== null) {
      const py = y(point.contextUsed).toFixed(1);
      return `<circle class="ctx-dot${isAct ? ' active' : ''}" data-req="${point.request}" cx="${px}" cy="${py}" r="${isAct ? 3.5 : 2}"><title>${escapeHtml(pointLabel(point))}</title></circle>`;
    }
    return '';
  }).join('');

  const stepW = points.length > 0 ? span / points.length : span;
  const hits = points.map((point, i) => {
    const px = x(i);
    const hx = Math.max(0, px - stepW / 2).toFixed(1);
    const hw = Math.max(6, stepW).toFixed(1);
    return `<rect class="ctx-hit" data-req="${point.request}" x="${hx}" y="${top - 4}" width="${hw}" height="${bottom - top + 8}"/>`;
  }).join('');

  const detailHtml = activePoint
    ? (() => {
        const timeStr = activePoint.at ? new Date(activePoint.at).toLocaleTimeString() : '';
        const modelStr = activePoint.model || '';
        const valStr = activePoint.compaction
          ? '已压缩'
          : activePoint.contextUsed !== null
            ? formatExactTokens(activePoint.contextUsed)
            : '--';
        return `<span><strong>#${activePoint.request}</strong>${modelStr ? `<span class="muted"> · ${escapeHtml(modelStr)}</span>` : ''}</span>
          <span><span class="tag ${activePoint.compaction ? 'warn' : ''}">${escapeHtml(valStr)}</span>${timeStr ? `<span class="muted"> · ${escapeHtml(timeStr)}</span>` : ''}</span>`;
      })()
    : '';

  const recordsOpen = contextSection.querySelector('details')?.open;
  const contextTip = '最近最多 120 次请求；纵轴自动缩放，不代表模型容量。虚线为日志明确记录的压缩。';
  contextSection.innerHTML = `<div class="section-title" title="${contextTip}"><span>上下文趋势</span><span>压缩 ${count ?? '--'} 次</span></div>
    ${points.length ? `<div id="context-detail" class="spark-detail">${detailHtml}</div>
    <svg class="context-chart" viewBox="0 0 360 112" role="img" aria-label="最近 ${points.length} 次请求的上下文使用趋势；虚线表示已发生的压缩，纵轴按记录自动缩放">
      <line class="ctx-grid" x1="${left}" x2="${right}" y1="${top}" y2="${top}"/>
      <line class="ctx-grid" x1="${left}" x2="${right}" y1="${((top + bottom) / 2).toFixed(1)}" y2="${((top + bottom) / 2).toFixed(1)}"/>
      <line class="ctx-grid" x1="${left}" x2="${right}" y1="${bottom}" y2="${bottom}"/>
      <text x="${left}" y="11">${values.length ? formatTokens(max) : '--'} tok</text>
      <text x="${right}" y="11" text-anchor="end">最近 ${points.length} 次</text>
      ${guides}${paths.join('')}${marks}${hits}
      <text x="${left}" y="106">#${points[0].request}</text>
      <text x="${right}" y="106" text-anchor="end">#${points[points.length - 1].request}</text>
    </svg>` : '<div class="stats-note">暂无上下文记录</div>'}
    <details ${recordsOpen ? 'open' : ''}><summary>近期记录</summary><div class="context-records">${points.slice(-12).reverse().map((p) => `<div>${escapeHtml(pointLabel(p))}</div>`).join('') || '暂无记录'}</div></details>`;

  const models = snap.modelUsage || [];
  const modelsTip = '同一模型的思考档位合并；速度按有效样本的输出总量 / 耗时总量计算。';
  modelsSection.innerHTML = `<div class="section-title" title="${modelsTip}"><span>按模型统计</span></div>
    ${models.map((model) => {
      const pct = model.cacheHitPct;
      const speedStr = typeof model.avgSpeedTokS === 'number' ? `${model.avgSpeedTokS.toFixed(1)} tok/s` : '--';
      return `<div class="model-stat">
        <div class="model-stat-head">
          <strong>${escapeHtml(model.model)}</strong>
          <span class="muted">${model.recordedCount}/${model.requestCount} 次请求</span>
        </div>
        <div class="model-stat-metrics">
          <div class="usage-total">${formatTokens(model.totalTokens)} <small>tok</small></div>
          <span class="muted" title="${model.speedSamples ?? 0} 个有效速度样本">${speedStr}</span>
        </div>
        <div class="stats-note">入 ${formatTokens(model.inputTokens)} · 读 ${formatTokens(model.cacheReadTokens)} · 出 ${formatTokens(model.outputTokens)} · 命中 ${typeof pct === 'number' ? `${pct.toFixed(1)}%` : '--'}</div>
      </div>`;
    }).join('') || '<div class="stats-note">暂无模型用量记录</div>'}`;
}

function renderSnapshot(snap: StatusSnapshot): void {
  syncSessionSelect(snap.recentConversations);
  currentContextPoints = snap.contextHistory || [];
  renderSessionStats(snap);
  const paneConv = getPaneConversationId();
  const isLive = Boolean(snap.hookConnected || paneConv);
  liveDot.classList.toggle('live', isLive);
  liveDot.title = paneConv
    ? `已绑定当前面板会话 ${paneConv.slice(0, 8)}`
    : snap.hookConnected
      ? 'Hook 已关联实时活跃会话'
      : '等待 Hook 事件，当前按最近会话展示';

  let updatedText = '';
  if (snap.generatedAt) {
    const d = new Date(snap.generatedAt);
    updatedText = Number.isNaN(d.getTime()) ? '' : d.toLocaleTimeString();
  }

  if (!snap.found) {
    metaStrip.innerHTML = '';
    cardsEl.innerHTML = '';
    historySection.style.display = 'none';
    if (snap.disabled) {
      tabBar.style.display = 'none';
      tabPanels.forEach((p) => { p.style.display = 'none'; });
    }
    emptyBox.style.display = 'block';
    emptyBox.textContent = snap.message || '暂未发现本地 Antigravity 桌面端会话记录。';
    renderQuota(snap.quota);
    return;
  }

  emptyBox.style.display = 'none';
  tabBar.style.display = 'grid';
  tabPanels.forEach((p) => { p.style.display = ''; });
  setActiveTab(activeTab);

  const metaParts: string[] = [];
  if (snap.workspaceName) metaParts.push(snap.workspaceName);
  if (snap.modelName) metaParts.push(snap.modelName);
  if (typeof snap.turnCount === 'number' && snap.turnCount > 0) {
    metaParts.push(`${snap.turnCount} 轮`);
  }
  const live = snap.live;
  const liveActive = Boolean(live?.active);
  const session = snap.session || null;
  // The backend already resolved the state and its reason; the panel must not
  // re-derive thresholds locally or the two will drift apart.
  const stateKey: SessionState =
    session && (['idle', 'running', 'waiting', 'error'] as string[]).includes(session.state)
      ? session.state
      : 'idle';
  const waitText =
    session && typeof session.waitSec === 'number' && session.waitSec >= 1
      ? formatDuration(session.waitSec)
      : '';
  const showWait =
    snap.config?.layout === 'detailed' && waitText !== '' && (stateKey === 'waiting' || stateKey === 'running');
  // A permanent "ready" label is noise; keep the dot (and its tooltip) and only
  // spell out the label when the panel actually has something to say.
  const showLabel = Boolean(session) && !(stateKey === 'idle' && session?.code === 'idle');
  const stateChip = session
    ? `<span class="state-chip is-${stateKey}" title="${escapeHtml(session.detail)}"><i class="state-dot"></i>${
        showLabel ? escapeHtml(session.label) : ''
      }${showWait ? ` ${escapeHtml(waitText)}` : ''}</span>`
    : '';
  const liveBadge = liveActive
    ? `<span class="pill live" title="正在生成：第 ${live?.stepIdx ?? '?'} 步，已流式输出 ${live?.outputChars ?? '?'} 字"><i class="live-pulse"></i>生成中${
        typeof live?.elapsedSec === 'number' ? ` · ${live.elapsedSec.toFixed(0)}s` : ''
      }</span>`
    : '';
  const statusBadge = stateChip || liveBadge;
  const warnTokS = typeof snap.config?.lowSpeedWarnTokS === 'number' ? snap.config.lowSpeedWarnTokS : 50;
  const updatedHtml = updatedText ? `<span class="updated-tag" title="上次刷新时间">${escapeHtml(updatedText)}</span>` : '';
  const metaTip = [
    snap.shortId ? `会话 ${snap.shortId}` : '',
    snap.stepCount ? `${snap.stepCount} 步` : '',
  ].filter(Boolean).join(' · ');
  metaStrip.innerHTML = `<div class="meta-main" title="${escapeHtml(metaTip)}">${statusBadge}<span class="meta-text">${escapeHtml(metaParts.join(' · ') || '活跃会话')}</span></div>${updatedHtml}`;

  const speedText =
    snap.lastAvgSpeed !== null && snap.lastAvgSpeed !== undefined
      ? `${snap.lastAvgSpeed.toFixed(1)} tok/s`
      : '--';
  const genDurText = formatDuration(snap.lastGenDurationSec);
  const outTokText = formatTokens(snap.outputTokens);
  const speedCardTip = `最近一次生成：输出 ${formatExactTokens(snap.outputTokens)}，生成耗时 ${
    snap.lastGenDurationSec !== null && snap.lastGenDurationSec !== undefined
      ? `${snap.lastGenDurationSec.toFixed(2)}s`
      : '--'
  }`;

  // While the agent is replying, the DB row for the in-flight step grows with
  // the streamed text; show that instead of the previous turn's average.
  const liveEst = live?.estTokPerSec;
  const liveChars = live?.outputChars;
  const liveSpeedText =
    typeof liveEst === 'number'
      ? `≈ ${liveEst.toFixed(1)} tok/s`
      : typeof liveChars === 'number'
        ? `${liveChars} 字`
        : '生成中…';
  const liveSubParts = [
    typeof liveChars === 'number' ? `${liveChars} 字` : '',
    typeof live?.charsPerSec === 'number' ? `${live.charsPerSec.toFixed(0)} 字/s` : '',
    typeof live?.elapsedSec === 'number' ? `${live.elapsedSec.toFixed(1)}s` : '',
  ].filter(Boolean);
  const liveCardTip = `生成中实时估算：流式文本 ${liveChars ?? '?'} 字 · ${
    live?.charsPerSec !== null && live?.charsPerSec !== undefined ? `${live.charsPerSec.toFixed(1)} 字/s` : '速率待测'
  }\n按 ${live?.charsPerToken ?? '--'} 字/token 换算为 tok/s；精确 token 数在整步完成后落库`;

  const speedCard = liveActive
    ? `<div class="card live" title="${escapeHtml(liveCardTip)}">
      <div class="card-label">
        <span><i class="live-pulse"></i>实时速度</span>
      </div>
      <div class="card-value">${escapeHtml(liveSpeedText)}</div>
      <div class="card-sub">${escapeHtml(liveSubParts.join(' · ') || '正在接收输出…')}</div>
    </div>`
    : `<div class="card ${snap.lowSpeedWarning ? 'warn' : ''}" title="${escapeHtml(speedCardTip)}">
      <div class="card-label">
        <span>输出速度</span>
        ${snap.lowSpeedWarning ? '<span>偏慢</span>' : ''}
      </div>
      <div class="card-value">${escapeHtml(speedText)}</div>
      <div class="card-sub">${escapeHtml(outTokText)} · ${escapeHtml(genDurText)}</div>
    </div>`;

  const turnDurText = formatDuration(snap.turnDurationSec);
  const sessionDurText = formatDuration(snap.sessionDurationSec);
  const turnCardTip = `当前轮次耗时 ${turnDurText} · 会话累计耗时 ${sessionDurText}（共 ${
    snap.turnCount ?? 0
  } 轮 / ${snap.stepCount ?? 0} 步）`;

  const ctxUsedStr = formatTokens(snap.contextUsed);
  const ctxTotalStr = formatTokens(snap.contextTotal);
  const ctxMain =
    snap.contextUsed !== null && snap.contextUsed !== undefined
      ? `${ctxUsedStr}/${ctxTotalStr}`
      : '--';
  const ctxPct = snap.contextPct ?? 0;
  const ctxCardTip = `已用上下文: ${formatExactTokens(snap.contextUsed)} / 容量: ${formatExactTokens(
    snap.contextTotal,
  )} (${ctxPct.toFixed(2)}%)${liveActive ? '\n生成中：上下文占用是 prompt 侧实测值，每步完成后刷新' : ''}`;

  const cacheHitMain =
    snap.cacheHitPct !== null && snap.cacheHitPct !== undefined
      ? `${snap.cacheHitPct.toFixed(1)}%`
      : '--';
  const cacheSub =
    snap.cacheReadTokens !== null && snap.cacheReadTokens !== undefined
      ? `读 ${formatTokens(snap.cacheReadTokens)} · 入 ${formatTokens(snap.inputTokens)}`
      : '--';
  const cacheCardTip = `缓存读取: ${formatExactTokens(snap.cacheReadTokens)} · 未缓存输入: ${formatExactTokens(
    snap.inputTokens,
  )} · 缓存写入: ${formatExactTokens(snap.cacheWriteTokens)}`;

  cardsEl.innerHTML = `
    ${speedCard}

    <div class="card" title="${escapeHtml(ctxCardTip)}">
      <div class="card-label">
        <span>上下文</span>
        <span>${snap.contextPct !== null && snap.contextPct !== undefined ? `${snap.contextPct.toFixed(1)}%` : ''}</span>
      </div>
      <div class="card-value">${escapeHtml(ctxMain)}</div>
      <div class="bar-track">
        <div class="bar-fill ${ctxPct >= 80 ? 'high' : ''}" style="width: ${Math.min(100, Math.max(0, ctxPct))}%"></div>
      </div>
    </div>

    <div class="card" title="${escapeHtml(cacheCardTip)}">
      <div class="card-label">
        <span>缓存命中</span>
      </div>
      <div class="card-value">${escapeHtml(cacheHitMain)}</div>
      <div class="card-sub">${escapeHtml(cacheSub)}</div>
    </div>

    <div class="card" title="${escapeHtml(turnCardTip)}">
      <div class="card-label">
        <span>轮次耗时</span>
      </div>
      <div class="card-value">${escapeHtml(turnDurText)}</div>
      <div class="card-sub">累计 ${escapeHtml(sessionDurText)}</div>
    </div>
  `;

  const history = (snap.history || []).filter((h) => h.speedTokS !== null || h.outputTokens !== null);
  currentHistory = history;
  currentDefaultModel = snap.modelName || '';
  renderQuota(snap.quota);

  if (history.length > 0) {
    historySection.style.display = 'flex';
    const validSpeeds = history
      .map((h) => h.speedTokS)
      .filter((s): s is number => s !== null && s !== undefined);
    const avgSpeed =
      validSpeeds.length > 0
        ? `${(validSpeeds.reduce((a, b) => a + b, 0) / validSpeeds.length).toFixed(1)} tok/s`
        : '--';
    historyCount.textContent = `最近 ${history.length} 次 · 均值 ${avgSpeed}`;

    const chronological = [...history].reverse();
    const maxSpeed = Math.max(
      80,
      ...chronological.map((item) => item.speedTokS ?? 0),
    );
    sparkEl.innerHTML = chronological
      .map((item) => {
        const s = item.speedTokS ?? 0;
        const hPct = Math.max(12, Math.round((s / maxSpeed) * 100));
        const warnCls = item.speedTokS !== null && item.speedTokS < warnTokS ? 'warn' : '';
        const tip = `#${item.idx} · ${item.speedTokS !== null ? `${item.speedTokS.toFixed(1)} tok/s` : '--'} · 输出 ${formatExactTokens(item.outputTokens)} · 耗时 ${formatDuration(item.durationSec)}`;
        return `
          <div class="spark-col" data-idx="${item.idx}" title="${escapeHtml(tip)}">
            <div class="spark-bar ${warnCls}" style="height:${hPct}%"></div>
          </div>
        `;
      })
      .join('');

    historyListEl.innerHTML = history
      .slice(0, 6)
      .map((item) => {
        const isWarn = item.speedTokS !== null && item.speedTokS < warnTokS;
        return `
          <div class="history-row" data-idx="${item.idx}">
            <span class="muted">#${item.idx}</span>
            <span class="muted">${escapeHtml(item.model || snap.modelName || '')}</span>
            <span class="speed-badge ${isWarn ? 'warn' : ''}">${item.speedTokS !== null ? `${item.speedTokS.toFixed(1)} tok/s` : '--'}</span>
            <span class="muted">${formatTokens(item.outputTokens)} / ${formatDuration(item.durationSec)}</span>
          </div>
        `;
      })
      .join('');

    const keepIdx =
      activeHistoryIdx !== null && history.some((h) => h.idx === activeHistoryIdx)
        ? activeHistoryIdx
        : history[0].idx;
    highlightHistoryItem(keepIdx);
  } else {
    historySection.style.display = 'none';
  }
}

sparkEl.addEventListener('mouseover', (e) => {
  const col = (e.target as HTMLElement).closest<HTMLElement>('.spark-col');
  if (col && col.dataset.idx) {
    highlightHistoryItem(Number(col.dataset.idx));
  }
});

sparkEl.addEventListener('click', (e) => {
  const col = (e.target as HTMLElement).closest<HTMLElement>('.spark-col');
  if (col && col.dataset.idx) {
    highlightHistoryItem(Number(col.dataset.idx));
  }
});

historyListEl.addEventListener('mouseover', (e) => {
  const row = (e.target as HTMLElement).closest<HTMLElement>('.history-row');
  if (row && row.dataset.idx) {
    highlightHistoryItem(Number(row.dataset.idx));
  }
});

historyListEl.addEventListener('click', (e) => {
  const row = (e.target as HTMLElement).closest<HTMLElement>('.history-row');
  if (row && row.dataset.idx) {
    highlightHistoryItem(Number(row.dataset.idx));
  }
});

function highlightContextPoint(req: number): void {
  const point = currentContextPoints.find((p) => p.request === req);
  if (!point) return;
  contextSection.dataset.activeReq = String(req);
  const detail = document.getElementById('context-detail');
  if (detail) {
    const timeStr = point.at ? new Date(point.at).toLocaleTimeString() : '';
    const modelStr = point.model || '';
    const valStr = point.compaction
      ? '已压缩'
      : point.contextUsed !== null
        ? formatExactTokens(point.contextUsed)
        : '--';
    detail.innerHTML = `<span><strong>#${point.request}</strong>${modelStr ? `<span class="muted"> · ${escapeHtml(modelStr)}</span>` : ''}</span>
      <span><span class="tag ${point.compaction ? 'warn' : ''}">${escapeHtml(valStr)}</span>${timeStr ? `<span class="muted"> · ${escapeHtml(timeStr)}</span>` : ''}</span>`;
  }
  contextSection.querySelectorAll<SVGElement>('.ctx-guide').forEach((el) => {
    el.classList.toggle('active', Number(el.dataset.req) === req);
  });
  contextSection.querySelectorAll<SVGCircleElement>('.ctx-dot').forEach((el) => {
    const isAct = Number(el.dataset.req) === req;
    el.classList.toggle('active', isAct);
    el.setAttribute('r', isAct ? '3.5' : '2');
  });
}

contextSection.addEventListener('mouseover', (e) => {
  const hit = (e.target as Element).closest<SVGElement>('.ctx-hit');
  if (hit && hit.dataset.req) {
    highlightContextPoint(Number(hit.dataset.req));
  }
});

contextSection.addEventListener('click', (e) => {
  const hit = (e.target as Element).closest<SVGElement>('.ctx-hit');
  if (hit && hit.dataset.req) {
    highlightContextPoint(Number(hit.dataset.req));
  }
});

function syncSidecarThemeFromBackground(): void {
  const probe = document.createElement('span');
  probe.style.cssText = 'position:absolute;visibility:hidden;color:var(--background, #f7f7f8)';
  document.documentElement.appendChild(probe);
  const c = getComputedStyle(probe).color;
  probe.remove();
  const nums = (c.match(/[\d.]+/g) || []).map(Number);
  if (nums.length < 3) return;
  const scale = c.startsWith('color(') ? 1 : 255;
  const [r, g, b] = nums.slice(0, 3).map((v) => v / scale);
  const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  const theme = lum < 0.5 ? 'dark' : 'light';
  if (document.documentElement.dataset.theme !== theme) {
    document.documentElement.dataset.theme = theme;
  }
}

/**
 * Applies config.json without a reload: layout, module switches and the
 * configured poll interval all follow the file on the next poll.
 */
function applyPanelConfig(config: PanelConfig | undefined): void {
  const root = document.documentElement;
  const cfg = config || {};
  const layout = cfg.layout === 'detailed' ? 'detailed' : 'compact';
  if (root.dataset.layout !== layout) root.dataset.layout = layout;
  const modules = cfg.modules || {};
  for (const key of ['session', 'quota', 'history', 'models', 'context'] as const) {
    root.classList.toggle(`hide-${key}`, modules[key] === false);
  }
  if (modules.quota === false && activeTab === 'quota') {
    setActiveTab('trends');
  }
  const notch = cfg.notch;
  const notchSupported = notch?.supported === true;
  root.classList.toggle('hide-notch', !notchSupported);
  if (!settingsSaving) {
    if (cfgLayoutEl) cfgLayoutEl.value = layout;
    if (cfgPollSecEl) {
      const value = String(typeof cfg.pollSec === 'number' ? Math.round(cfg.pollSec) : 0);
      if (!Array.from(cfgPollSecEl.options).some((opt) => opt.value === value)) {
        const option = document.createElement('option');
        option.value = value;
        option.textContent = `${value}s`;
        cfgPollSecEl.appendChild(option);
      }
      cfgPollSecEl.value = value;
    }
    if (cfgModSessionEl) cfgModSessionEl.checked = modules.session !== false;
    if (cfgModHistoryEl) cfgModHistoryEl.checked = modules.history !== false;
    if (cfgModContextEl) cfgModContextEl.checked = modules.context !== false;
    if (cfgModModelsEl) cfgModModelsEl.checked = modules.models !== false;
    if (cfgModQuotaEl) cfgModQuotaEl.checked = modules.quota !== false;
    if (cfgLowSpeedEl && document.activeElement !== cfgLowSpeedEl && typeof cfg.lowSpeedWarnTokS === 'number') {
      cfgLowSpeedEl.value = String(Math.round(cfg.lowSpeedWarnTokS));
    }
    if (cfgWaitSecEl && document.activeElement !== cfgWaitSecEl && typeof cfg.waitSec === 'number') {
      cfgWaitSecEl.value = String(Math.round(cfg.waitSec));
    }
    if (cfgStallSecEl && document.activeElement !== cfgStallSecEl && typeof cfg.stallSec === 'number') {
      cfgStallSecEl.value = String(Math.round(cfg.stallSec));
    }
    if (cfgToolGraceEl && document.activeElement !== cfgToolGraceEl && typeof cfg.toolGraceSec === 'number') {
      cfgToolGraceEl.value = String(Math.round(cfg.toolGraceSec));
    }
    if (notch) {
      if (notchEnabledEl && typeof notch.enabled === 'boolean') notchEnabledEl.checked = notch.enabled;
      if (notchHideIdleEl && typeof notch.hideWhenIdle === 'boolean') notchHideIdleEl.checked = notch.hideWhenIdle;
      if (notchScreenModeEl && typeof notch.screenMode === 'string') notchScreenModeEl.value = notch.screenMode;
      if (notchAvoidanceModeEl && typeof notch.avoidanceMode === 'string') notchAvoidanceModeEl.value = notch.avoidanceMode;
    }
  }
  const pollSec = typeof cfg.pollSec === 'number' ? Math.round(cfg.pollSec) : 0;
  if (pollSec !== appliedPollSec) {
    const prevApplied = appliedPollSec;
    appliedPollSec = pollSec;
    let saved: string | null = null;
    try {
      saved = window.localStorage?.getItem(STORAGE_KEY_INTERVAL) ?? null;
    } catch {
      saved = null;
    }
    // An explicit choice in the dropdown always wins over the config default.
    if (saved === null) {
      if (pollSec > 0) {
        const value = Math.min(60, Math.max(1, pollSec));
        ALLOWED_INTERVALS.add(value);
        const known = Array.from(refreshSelect.options).some((opt) => Number(opt.value) === value);
        if (!known) {
          const option = document.createElement('option');
          option.value = String(value);
          option.textContent = `${value}s`;
          refreshSelect.insertBefore(option, refreshSelect.lastElementChild);
        }
        refreshIntervalSec = value;
        refreshSelect.value = String(value);
        refreshSelect.classList.add('active');
        resetTimer();
      } else if (prevApplied !== null && prevApplied > 0) {
        refreshIntervalSec = 3;
        refreshSelect.value = '3';
        refreshSelect.classList.add('active');
        resetTimer();
      }
    }
  }
}

/** The full reason line, shown under the strip in the detailed layout. */
function renderStateNote(snap: StatusSnapshot): void {
  const note = document.getElementById('state-note');
  if (!note) return;
  const session = snap.session;
  const detailed = snap.config?.layout === 'detailed';
  if (!detailed || !session || session.state === 'idle') {
    note.hidden = true;
    note.textContent = '';
    return;
  }
  note.hidden = false;
  note.className = `state-note is-${session.state}`;
  note.textContent = session.detail;
}

/**
 * Never let a missing source look like real zeros. Compacting this into one line
 * keeps the panel quiet when everything is fine, and explicit when it is not.
 */
function renderSourcesNote(snap: StatusSnapshot): void {
  const node = document.getElementById('sources-note');
  if (!node) return;
  const sources = snap.sources;
  const notes = (sources?.notes || []).filter((note) => note && typeof note.text === 'string');
  if (!sources?.degraded || notes.length === 0) {
    node.hidden = true;
    node.textContent = '';
    node.removeAttribute('title');
    return;
  }
  const labels = notes.map((note) => note.label || '数据不可用');
  const head = `数据不完整 · ${labels.join(' / ')}`;
  // Compact keeps one short line; detailed spells the reason out inline. The
  // tooltip always carries every reason, so nothing is only available in one
  // layout.
  const detailed = snap.config?.layout === 'detailed';
  node.hidden = false;
  node.textContent = detailed ? `${head}：${notes[0].text}` : head;
  node.title = notes.map((note) => note.text).join('\n');
}

async function fetchSidecarSnapshot(convId: string): Promise<StatusSnapshot | null> {
  const f = window.sidecar?.fetch ? window.sidecar.fetch.bind(window.sidecar) : fetch;
  const qs = convId ? `?conversationId=${encodeURIComponent(convId)}` : '';
  const res = await f(`/api/status${qs}`, { method: 'GET' });
  if (!res.ok) return null;
  return (await res.json()) as StatusSnapshot;
}

/**
 * A sidecar can be restarted or wedged while the panel keeps its last numbers on
 * screen. Saying "no response" is better than looking live and lying.
 */
function markBackendUnresponsive(): void {
  consecutiveFailures += 1;
  if (lastSuccessAt === 0 || consecutiveFailures < 2) return;
  const silentMs = Date.now() - lastSuccessAt;
  const loudAfter = Math.max(6000, 3 * Math.max(1, refreshIntervalSec) * 1000);
  if (silentMs < loudAfter) return;
  metaStrip.innerHTML = `<div class="meta-main"><span class="state-chip is-error is-offline" title="侧车后台已经 ${Math.round(
    silentMs / 1000,
  )}s 没有响应，屏幕上的数字是最后一次成功读取的值"><i class="state-dot"></i>后台无响应 · ${escapeHtml(
    formatDuration(silentMs / 1000),
  )}</span></div>`;
}

async function refreshSnapshot(): Promise<void> {
  if (inFlight) return;
  inFlight = true;
  try {
    const targetId =
      selectedConversation && selectedConversation !== 'auto'
        ? selectedConversation
        : getPaneConversationId() || 'auto';
    const snap = await fetchSidecarSnapshot(targetId);
    if (snap) {
      lastSnapshot = snap;
      lastSuccessAt = Date.now();
      consecutiveFailures = 0;
      renderSnapshot(snap);
      applyPanelConfig(snap.config);
      renderStateNote(snap);
      renderSourcesNote(snap);
    } else {
      markBackendUnresponsive();
    }
  } catch {
    // Keep last rendered state if host aborts an in-flight refresh on close/reload,
    // but surface a backend that stayed silent across several cycles.
    markBackendUnresponsive();
  } finally {
    inFlight = false;
  }
}

function msSinceLastActivity(): number {
  const raw = lastSnapshot?.lastActivityAt;
  if (!raw) return Number.POSITIVE_INFINITY;
  const ts = Date.parse(raw);
  if (Number.isNaN(ts)) return Number.POSITIVE_INFINITY;
  return Math.max(0, Date.now() - ts);
}

function nextPollDelay(): number {
  if (refreshIntervalSec <= 0) return 0;
  if (document.hidden) return 0;
  const base = refreshIntervalSec * 1000;
  // While the agent is streaming, poll faster so the live numbers move.
  if (lastSnapshot?.live?.active) {
    return Math.min(base, LIVE_POLL_MS);
  }
  if (msSinceLastActivity() / 1000 < IDLE_AFTER_SEC) {
    return base;
  }
  return Math.max(base, IDLE_POLL_MS);
}

function resetTimer(): void {
  if (timerId !== null) {
    window.clearTimeout(timerId);
    timerId = null;
  }
  const delay = nextPollDelay();
  if (delay <= 0) return;
  timerId = window.setTimeout(() => {
    timerId = null;
    void refreshSnapshot().then(() => {
      resetTimer();
    });
  }, delay);
}

sessionSelect.addEventListener('change', () => {
  selectedConversation = sessionSelect.value;
  activeHistoryIdx = null;
  void refreshSnapshot();
});

refreshSelect.addEventListener('change', () => {
  const parsed = Number.parseInt(refreshSelect.value, 10);
  refreshIntervalSec = ALLOWED_INTERVALS.has(parsed) ? parsed : 3;
  refreshSelect.value = String(refreshIntervalSec);
  refreshSelect.classList.toggle('active', refreshIntervalSec > 0);
  saveInterval(refreshIntervalSec);
  if (refreshIntervalSec > 0) {
    void refreshSnapshot();
  }
  resetTimer();
});

tabBar.addEventListener('click', (e) => {
  const btn = (e.target as HTMLElement).closest<HTMLButtonElement>('.tab-btn');
  if (btn && btn.dataset.tab) {
    setActiveTab(btn.dataset.tab);
  }
});

function readClampedNum(el: HTMLInputElement | null, min: number, max: number, fallback: number): number {
  const raw = el ? Number(el.value) : fallback;
  if (!Number.isFinite(raw)) return fallback;
  return Math.min(max, Math.max(min, Math.round(raw)));
}

function saveSettingsPatch(payload: object): Promise<void> {
  settingsPending += 1;
  settingsSaving = true;
  settingsQueue = settingsQueue.then(async () => {
    let updated: PanelConfig | undefined;
    if (settingsSaveStatusEl) settingsSaveStatusEl.textContent = '保存中…';
    try {
      const f = window.sidecar?.fetch ? window.sidecar.fetch.bind(window.sidecar) : fetch;
      const res = await f('/api/settings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      if (!res.ok) throw new Error('save failed');
      updated = (await res.json()) as PanelConfig;
      if (settingsSaveStatusEl) settingsSaveStatusEl.textContent = '已保存';
    } catch {
      if (settingsSaveStatusEl) settingsSaveStatusEl.textContent = '保存失败';
    } finally {
      settingsPending -= 1;
      settingsSaving = settingsPending > 0;
      if (!settingsSaving && updated) applyPanelConfig(updated);
    }
  });
  return settingsQueue;
}

const settingsBindings: [HTMLInputElement | HTMLSelectElement | null, () => object][] = [
  [cfgLayoutEl, () => ({ layout: cfgLayoutEl?.value })],
  [cfgPollSecEl, () => ({ pollSec: Number(cfgPollSecEl?.value) })],
  [cfgLowSpeedEl, () => ({ lowSpeedWarnTokS: readClampedNum(cfgLowSpeedEl, 1, 10000, 50) })],
  [cfgWaitSecEl, () => ({ thresholds: { waitSec: readClampedNum(cfgWaitSecEl, 1, 3600, 20) } })],
  [cfgStallSecEl, () => ({ thresholds: { stallSec: readClampedNum(cfgStallSecEl, 1, 3600, 25) } })],
  [cfgToolGraceEl, () => ({ thresholds: { toolGraceSec: readClampedNum(cfgToolGraceEl, 1, 3600, 120) } })],
  [cfgModSessionEl, () => ({ modules: { session: cfgModSessionEl?.checked } })],
  [cfgModHistoryEl, () => ({ modules: { history: cfgModHistoryEl?.checked } })],
  [cfgModContextEl, () => ({ modules: { context: cfgModContextEl?.checked } })],
  [cfgModModelsEl, () => ({ modules: { models: cfgModModelsEl?.checked } })],
  [cfgModQuotaEl, () => ({ modules: { quota: cfgModQuotaEl?.checked } })],
  [notchEnabledEl, () => ({ notch: { enabled: notchEnabledEl?.checked } })],
  [notchHideIdleEl, () => ({ notch: { hideWhenIdle: notchHideIdleEl?.checked } })],
  [notchScreenModeEl, () => ({ notch: { screenMode: notchScreenModeEl?.value } })],
  [notchAvoidanceModeEl, () => ({ notch: { avoidanceMode: notchAvoidanceModeEl?.value } })],
];
for (const [el, patch] of settingsBindings) {
  el?.addEventListener('change', () => { void saveSettingsPatch(patch()); });
}

async function boot(): Promise<void> {
  setActiveTab(activeTab);
  syncSidecarThemeFromBackground();
  new MutationObserver(() => {
    syncSidecarThemeFromBackground();
  }).observe(document.documentElement, { attributes: true, attributeFilter: ['style'] });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      if (timerId !== null) {
        window.clearTimeout(timerId);
        timerId = null;
      }
      return;
    }
    void refreshSnapshot().then(() => {
      resetTimer();
    });
  });
  await refreshSnapshot();
  resetTimer();
}

void boot();
