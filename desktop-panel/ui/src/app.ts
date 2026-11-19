import {
  App,
  applyDocumentTheme,
  applyHostStyleVariables,
} from '@modelcontextprotocol/ext-apps';

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
  generatedAt?: string;
  message?: string;
}

const sessionSelect = document.getElementById('session-select') as HTMLSelectElement;
const toggleAutoBtn = document.getElementById('toggle-auto') as HTMLButtonElement;
const refreshBtn = document.getElementById('refresh-btn') as HTMLButtonElement;
const liveDot = document.getElementById('live-dot') as HTMLSpanElement;
const metaStrip = document.getElementById('meta-strip') as HTMLDivElement;
const cardsEl = document.getElementById('cards') as HTMLDivElement;
const historySection = document.getElementById('history-section') as HTMLDivElement;
const historyCount = document.getElementById('history-count') as HTMLSpanElement;
const sparkEl = document.getElementById('spark') as HTMLDivElement;
const historyListEl = document.getElementById('history-list') as HTMLDivElement;
const emptyBox = document.getElementById('empty-box') as HTMLDivElement;
const updatedAtEl = document.getElementById('updated-at') as HTMLSpanElement;

let selectedConversation = 'auto';
let autoRefresh = true;
let inFlight = false;
let timerId: number | null = null;

function formatTokens(val: number | null | undefined): string {
  if (val === null || val === undefined || val < 0) return '--';
  if (val >= 1000) {
    return `${Math.trunc(val / 1000).toLocaleString('en-US')}K`;
  }
  return val.toLocaleString('en-US');
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

  if (snap.generatedAt) {
    const d = new Date(snap.generatedAt);
    updatedAtEl.textContent = Number.isNaN(d.getTime())
      ? snap.generatedAt
      : `更新于 ${d.toLocaleTimeString()}`;
  }

  if (!snap.found) {
    metaStrip.innerHTML = '';
    cardsEl.innerHTML = '';
    historySection.style.display = 'none';
    emptyBox.style.display = 'block';
    emptyBox.textContent = snap.message || '暂未发现本地 Antigravity 桌面端会话记录。';
    return;
  }

  emptyBox.style.display = 'none';

  const pills: string[] = [];
  if (snap.shortId) pills.push(`<span class="pill">会话 ${escapeHtml(snap.shortId)}</span>`);
  if (snap.modelName) pills.push(`<span class="pill">${escapeHtml(snap.modelName)}</span>`);
  if (snap.workspaceName) pills.push(`<span class="pill">${escapeHtml(snap.workspaceName)}</span>`);
  if (typeof snap.turnCount === 'number' && snap.turnCount > 0) {
    pills.push(`<span class="pill">${snap.turnCount} 轮</span>`);
  }
  metaStrip.innerHTML = pills.join('');

  const speedText =
    snap.lastAvgSpeed !== null && snap.lastAvgSpeed !== undefined
      ? `${snap.lastAvgSpeed.toFixed(1)} tok/s`
      : '--';
  const genDurText = formatDuration(snap.lastGenDurationSec);
  const outTokText = formatTokens(snap.outputTokens);

  const turnDurText = formatDuration(snap.turnDurationSec);
  const sessionDurText = formatDuration(snap.sessionDurationSec);

  const ctxUsedStr = formatTokens(snap.contextUsed);
  const ctxTotalStr = formatTokens(snap.contextTotal);
  const ctxMain =
    snap.contextUsed !== null && snap.contextUsed !== undefined
      ? `${ctxUsedStr}/${ctxTotalStr}`
      : '--';
  const ctxPct = snap.contextPct ?? 0;

  const cacheHitMain =
    snap.cacheHitPct !== null && snap.cacheHitPct !== undefined
      ? `${snap.cacheHitPct.toFixed(1)}%`
      : '--';
  const cacheSub =
    snap.cacheReadTokens !== null && snap.cacheReadTokens !== undefined
      ? `Read ${formatTokens(snap.cacheReadTokens)} · In ${formatTokens(snap.inputTokens)}`
      : '本地库暂无输入/缓存字段';

  cardsEl.innerHTML = `
    <div class="card ${snap.lowSpeedWarning ? 'warn' : ''}">
      <div class="card-label">
        <span>平均输出速度</span>
        <span>${snap.lowSpeedWarning ? '偏慢' : 'tok/s'}</span>
      </div>
      <div class="card-value">${escapeHtml(speedText)}</div>
      <div class="card-sub">输出 ${escapeHtml(outTokText)} · 耗时 ${escapeHtml(genDurText)}</div>
    </div>

    <div class="card">
      <div class="card-label">
        <span>轮次 / 会话耗时</span>
      </div>
      <div class="card-value">${escapeHtml(turnDurText)}</div>
      <div class="card-sub">会话总计 ${escapeHtml(sessionDurText)}</div>
    </div>

    <div class="card">
      <div class="card-label">
        <span>上下文占用</span>
        <span>${snap.contextPct !== null && snap.contextPct !== undefined ? `${snap.contextPct.toFixed(1)}%` : ''}</span>
      </div>
      <div class="card-value">${escapeHtml(ctxMain)}</div>
      <div class="bar-track">
        <div class="bar-fill ${ctxPct >= 80 ? 'high' : ''}" style="width: ${Math.min(100, Math.max(0, ctxPct))}%"></div>
      </div>
    </div>

    <div class="card">
      <div class="card-label">
        <span>Cache 命中率</span>
      </div>
      <div class="card-value">${escapeHtml(cacheHitMain)}</div>
      <div class="card-sub">${escapeHtml(cacheSub)}</div>
    </div>
  `;

  const history = (snap.history || []).filter((h) => h.speedTokS !== null || h.outputTokens !== null);
  if (history.length > 0) {
    historySection.style.display = 'flex';
    historyCount.textContent = `最近 ${history.length} 次生成`;
    const chronological = [...history].reverse();
    const maxSpeed = Math.max(
      80,
      ...chronological.map((item) => item.speedTokS ?? 0),
    );
    sparkEl.innerHTML = chronological
      .map((item) => {
        const s = item.speedTokS ?? 0;
        const hPct = Math.max(10, Math.round((s / maxSpeed) * 100));
        const warnCls = item.speedTokS !== null && item.speedTokS < 50 ? 'warn' : '';
        const tip = `#${item.idx}: ${item.speedTokS ?? '--'} tok/s`;
        return `<div class="spark-bar ${warnCls}" style="height:${hPct}%" title="${escapeHtml(tip)}"></div>`;
      })
      .join('');

    historyListEl.innerHTML = history
      .slice(0, 6)
      .map(
        (item) => `
          <div class="history-row">
            <span class="muted">#${item.idx}</span>
            <span class="muted">${escapeHtml(item.model || snap.modelName || '')}</span>
            <span>${item.speedTokS !== null ? `${item.speedTokS.toFixed(1)} tok/s` : '--'}</span>
            <span class="muted">${formatTokens(item.outputTokens)} / ${formatDuration(item.durationSec)}</span>
          </div>
        `,
      )
      .join('');
  } else {
    historySection.style.display = 'none';
  }
}

declare global {
  interface Window {
    sidecar?: {
      conversationId?: string | null;
      fetch?: typeof fetch;
    };
  }
}

const urlParams = new URLSearchParams(window.location.search);
const isSidecarHost =
  typeof window.sidecar !== 'undefined' ||
  window.location.protocol === 'http:' ||
  window.location.protocol === 'https:' ||
  window.location.protocol === 'plugin:';

function getPaneConversationId(): string {
  return (window.sidecar?.conversationId || urlParams.get('conversationId') || '').trim();
}

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

const app = isSidecarHost ? null : new App({ name: 'AGY Desktop Status', version: '0.1.0' }, {});

if (app) {
  app.ontoolresult = (result) => {
    if (result?.structuredContent) {
      renderSnapshot(result.structuredContent as unknown as StatusSnapshot);
    }
  };

  app.onhostcontextchanged = (ctx) => {
    if (ctx?.theme) applyDocumentTheme(ctx.theme);
    if (ctx?.styles?.variables) applyHostStyleVariables(ctx.styles.variables);
  };
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
    if (isSidecarHost) {
      const targetId =
        selectedConversation && selectedConversation !== 'auto'
          ? selectedConversation
          : getPaneConversationId() || 'auto';
      const snap = await fetchSidecarSnapshot(targetId);
      if (snap) {
        renderSnapshot(snap);
      }
      return;
    }

    if (!app) return;
    const args =
      selectedConversation && selectedConversation !== 'auto'
        ? { conversationId: selectedConversation }
        : {};
    const res = await app.callServerTool({
      name: 'get_status_snapshot',
      arguments: args,
    });
    if (res?.structuredContent) {
      renderSnapshot(res.structuredContent as unknown as StatusSnapshot);
    }
  } catch {
    // Keep last rendered state if host aborts an in-flight refresh on close/reload.
  } finally {
    inFlight = false;
  }
}

function resetTimer(): void {
  if (timerId !== null) {
    window.clearInterval(timerId);
    timerId = null;
  }
  if (autoRefresh) {
    timerId = window.setInterval(() => {
      void refreshSnapshot();
    }, 3000);
  }
}

sessionSelect.addEventListener('change', () => {
  selectedConversation = sessionSelect.value;
  void refreshSnapshot();
});

refreshBtn.addEventListener('click', () => {
  void refreshSnapshot();
});

toggleAutoBtn.addEventListener('click', () => {
  autoRefresh = !autoRefresh;
  toggleAutoBtn.classList.toggle('active', autoRefresh);
  toggleAutoBtn.textContent = autoRefresh ? '自动刷新 3s' : '已暂停';
  resetTimer();
});

async function boot(): Promise<void> {
  if (isSidecarHost) {
    syncSidecarThemeFromBackground();
    new MutationObserver(() => {
      syncSidecarThemeFromBackground();
    }).observe(document.documentElement, { attributes: true, attributeFilter: ['style'] });
    await refreshSnapshot();
    resetTimer();
    return;
  }

  if (!app) return;
  await app.connect();
  const ctx = app.getHostContext();
  if (ctx?.theme) applyDocumentTheme(ctx.theme);
  if (ctx?.styles?.variables) applyHostStyleVariables(ctx.styles.variables);
  await refreshSnapshot();
  resetTimer();
}

void boot();
