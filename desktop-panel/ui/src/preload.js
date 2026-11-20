// Frontend bridge for the read-only native sidecar. No agent or credential APIs.
(() => {
  const query = new URLSearchParams(location.search);
  const token = query.get('token');
  window.sidecar = {
    conversationId: query.get('conversationId') || '',
    fetch(url, options = {}) {
      const headers = new Headers(options.headers);
      if (token) headers.set('X-Sidecar-Token', token);
      return fetch(url, { ...options, headers });
    },
  };
  window.addEventListener('message', (event) => {
    if (event.source !== window.parent || event.data?.type !== 'theme-change') return;
    const variables = event.data.payload?.cssVariables;
    if (!variables || typeof variables !== 'object') return;
    for (const [key, value] of Object.entries(variables)) {
      if (key.startsWith('--') && typeof value === 'string') document.documentElement.style.setProperty(key, value);
    }
  });
  const tracked = new Set();
  function forward(event) {
    window.parent.postMessage({ type: 'sidecar-key-event', payload: {
      eventType: event.type, key: event.key, code: event.code || '',
      ctrlKey: event.ctrlKey, metaKey: event.metaKey, altKey: event.altKey,
      shiftKey: event.shiftKey, repeat: event.repeat,
    } }, '*');
  }
  window.addEventListener('keydown', (event) => {
    if (parent === window || event.defaultPrevented || event.isComposing || event.keyCode === 229 || event.getModifierState?.('AltGraph')) return;
    if (!event.ctrlKey && !event.metaKey && !event.altKey) return;
    if (['Control', 'Meta', 'Alt', 'Shift', 'AltGraph'].includes(event.key)) return;
    const key = event.key.toLowerCase();
    if ((event.ctrlKey || event.metaKey) && !event.altKey && ((!event.shiftKey && ['c', 'x'].includes(key)) || key === 'v')) return;
    const target = event.composedPath()[0];
    const editable = target?.closest?.('input, textarea, select, [contenteditable], [role="textbox"]');
    if (editable) {
      if (!event.ctrlKey && !event.metaKey && (!event.altKey || event.key.length <= 1)) return;
      if (['arrowleft', 'arrowright', 'arrowup', 'arrowdown', 'home', 'end'].includes(key)) return;
      if (!event.shiftKey && ['backspace', 'delete'].includes(key)) return;
      if ((event.ctrlKey || event.metaKey) && !event.altKey && (key === 'z' || (!event.shiftKey && ['a', 'y'].includes(key)))) return;
      if (editable.isContentEditable && (event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey && ['b', 'i', 'u'].includes(key)) return;
    }
    tracked.add(event.code || key); forward(event);
  });
  window.addEventListener('keyup', (event) => {
    if (event.isComposing || event.keyCode === 229) return;
    const wasTracked = tracked.delete(event.code || event.key.toLowerCase());
    if (wasTracked || (event.key === 'Meta' && tracked.size)) { if (event.key === 'Meta') tracked.clear(); forward(event); }
  });
  window.addEventListener('blur', () => tracked.clear());
})();
