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
  history?: GenHistoryItem[];
  recentConversations?: RecentConversation[];
  quota?: QuotaSnapshot | null;
  live?: LiveState | null;
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
const ALLOWED_INTERVALS = new Set([0, 3, 5, 10]);
// Adaptive polling: follow the session closely while it is generating and back
// off when it is idle, so an open-but-quiet panel stops costing anything.
const IDLE_POLL_MS = 15000;
const IDLE_AFTER_SEC = 45;
const LIVE_POLL_MS = 1000;

const sessionSelect = document.getElementById('session-select') as HTMLSelectElement;
const refreshSelect = document.getElementById('refresh-select') as HTMLSelectElement;
const liveDot = document.getElementById('live-dot') as HTMLSpanElement;
const metaStrip = document.getElementById('meta-strip') as HTMLDivElement;
const cardsEl = document.getElementById('cards') as HTMLDivElement;
const quotaSection = document.getElementById('quota-section') as HTMLDivElement;
const quotaNote = document.getElementById('quota-note') as HTMLSpanElement;
const quotaListEl = document.getElementById('quota-list') as HTMLDivElement;
const historySection = document.getElementById('history-section') as HTMLDivElement;
const historyCount = document.getElementById('history-count') as HTMLSpanElement;
const sparkDetailEl = document.getElementById('spark-detail') as HTMLDivElement;
const sparkEl = document.getElementById('spark') as HTMLDivElement;
const historyListEl = document.getElementById('history-list') as HTMLDivElement;
const emptyBox = document.getElementById('empty-box') as HTMLDivElement;

let selectedConversation = 'auto';
let refreshIntervalSec = loadSavedInterval();
let inFlight = false;
let timerId: number | null = null;
let currentHistory: GenHistoryItem[] = [];
let currentDefaultModel = '';
let activeHistoryIdx: number | null = null;
let lastSnapshot: StatusSnapshot | null = null;

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
    quotaListEl.innerHTML = '';
    return;
  }
  quotaSection.style.display = 'flex';

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

  const isWarn = item.speedTokS !== null && item.speedTokS < 50;
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

function renderSnapshot(snap: StatusSnapshot): void {
  syncSessionSelect(snap.recentConversations);
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
    emptyBox.style.display = 'block';
    emptyBox.textContent = snap.message || '暂未发现本地 Antigravity 桌面端会话记录。';
    renderQuota(snap.quota);
    return;
  }

  emptyBox.style.display = 'none';

  const pills: string[] = [];
  if (snap.shortId) pills.push(`<span class="pill" title="会话 UUID: ${escapeHtml(snap.conversationId)}">会话 ${escapeHtml(snap.shortId)}</span>`);
  if (snap.modelName) pills.push(`<span class="pill">${escapeHtml(snap.modelName)}</span>`);
  if (snap.workspaceName) pills.push(`<span class="pill">${escapeHtml(snap.workspaceName)}</span>`);
  if (typeof snap.turnCount === 'number' && snap.turnCount > 0) {
    const stepTip = snap.stepCount ? `共 ${snap.stepCount} 个执行步骤` : '';
    pills.push(`<span class="pill" title="${escapeHtml(stepTip)}">${snap.turnCount} 轮</span>`);
  }
  const live = snap.live;
  const liveActive = Boolean(live?.active);
  if (liveActive) {
    const secs = live?.elapsedSec;
    const liveTip = `正在生成：第 ${live?.stepIdx ?? '?'} 步，已流式输出 ${live?.outputChars ?? '?'} 字`;
    pills.push(
      `<span class="pill live" title="${escapeHtml(liveTip)}"><i class="live-pulse"></i>生成中${
        typeof secs === 'number' ? ` · ${secs.toFixed(0)}s` : ''
      }</span>`,
    );
  }
  const updatedHtml = updatedText ? `<span class="updated-tag" title="上次刷新时间">${escapeHtml(updatedText)}</span>` : '';
  metaStrip.innerHTML = `<div class="pills-wrap">${pills.join('')}</div>${updatedHtml}`;

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
    typeof liveChars === 'number' ? `已输出 ${liveChars} 字` : '',
    typeof live?.charsPerSec === 'number' ? `${live.charsPerSec.toFixed(0)} 字/s` : '',
    typeof live?.elapsedSec === 'number' ? `${live.elapsedSec.toFixed(1)}s` : '',
  ].filter(Boolean);
  const liveCardTip = `生成中实时估算：流式文本 ${liveChars ?? '?'} 字 · ${
    live?.charsPerSec !== null && live?.charsPerSec !== undefined ? `${live.charsPerSec.toFixed(1)} 字/s` : '速率待测'
  }\n按 ${live?.charsPerToken ?? '--'} 字/token 换算为 tok/s；精确 token 数在整步完成后落库`;

  const speedCard = liveActive
    ? `<div class="card live" title="${escapeHtml(liveCardTip)}">
      <div class="card-label">
        <span><i class="live-pulse"></i>实时输出速度</span>
        <span>${typeof liveEst === 'number' ? 'tok/s' : 'streaming'}</span>
      </div>
      <div class="card-value">${escapeHtml(liveSpeedText)}</div>
      <div class="card-sub">${escapeHtml(liveSubParts.join(' · ') || '正在接收输出…')}</div>
    </div>`
    : `<div class="card ${snap.lowSpeedWarning ? 'warn' : ''}" title="${escapeHtml(speedCardTip)}">
      <div class="card-label">
        <span>平均输出速度</span>
        <span>${snap.lowSpeedWarning ? '偏慢' : 'tok/s'}</span>
      </div>
      <div class="card-value">${escapeHtml(speedText)}</div>
      <div class="card-sub">输出 ${escapeHtml(outTokText)} · 耗时 ${escapeHtml(genDurText)}</div>
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
      ? `Read ${formatTokens(snap.cacheReadTokens)} · In ${formatTokens(snap.inputTokens)}`
      : '本地库暂无输入/缓存字段';
  const cacheCardTip = `缓存读取: ${formatExactTokens(snap.cacheReadTokens)} · 未缓存输入: ${formatExactTokens(
    snap.inputTokens,
  )} · 缓存写入: ${formatExactTokens(snap.cacheWriteTokens)}`;

  cardsEl.innerHTML = `
    ${speedCard}

    <div class="card" title="${escapeHtml(turnCardTip)}">
      <div class="card-label">
        <span>轮次 / 会话耗时</span>
      </div>
      <div class="card-value">${escapeHtml(turnDurText)}</div>
      <div class="card-sub">会话总计 ${escapeHtml(sessionDurText)}</div>
    </div>

    <div class="card" title="${escapeHtml(ctxCardTip)}">
      <div class="card-label">
        <span>上下文占用</span>
        <span>${snap.contextPct !== null && snap.contextPct !== undefined ? `${snap.contextPct.toFixed(1)}%` : ''}</span>
      </div>
      <div class="card-value">${escapeHtml(ctxMain)}</div>
      <div class="bar-track">
        <div class="bar-fill ${ctxPct >= 80 ? 'high' : ''}" style="width: ${Math.min(100, Math.max(0, ctxPct))}%"></div>
      </div>
    </div>

    <div class="card" title="${escapeHtml(cacheCardTip)}">
      <div class="card-label">
        <span>Cache 命中率</span>
      </div>
      <div class="card-value">${escapeHtml(cacheHitMain)}</div>
      <div class="card-sub">${escapeHtml(cacheSub)}</div>
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
        const warnCls = item.speedTokS !== null && item.speedTokS < 50 ? 'warn' : '';
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
        const isWarn = item.speedTokS !== null && item.speedTokS < 50;
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

async function fetchSidecarSnapshot(convId: string): Promise<StatusSnapshot | null> {
  const f = window.sidecar?.fetch ? window.sidecar.fetch.bind(window.sidecar) : fetch;
  const qs = convId ? `?conversationId=${encodeURIComponent(convId)}` : '';
  const res = await f(`/api/status${qs}`, { method: 'GET' });
  if (!res.ok) return null;
  return (await res.json()) as StatusSnapshot;
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
      renderSnapshot(snap);
    }
  } catch {
    // Keep last rendered state if host aborts an in-flight refresh on close/reload.
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

async function boot(): Promise<void> {
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
