'use strict';

const params = new URLSearchParams(window.location.search);
const sessionToken = params.get('token') || '';

const el = {
  status: document.getElementById('status'),
  statusText: document.getElementById('status-text'),
  macos: document.getElementById('info-macos'),
  xcode: document.getElementById('info-xcode'),
  ios: document.getElementById('info-ios'),
  device: document.getElementById('info-device'),
  input: document.getElementById('info-input'),
  inputChip: document.querySelector('.chip-input'),
  expiry: document.getElementById('info-expiry'),
  canvas: document.getElementById('screen'),
  stage: document.getElementById('stage'),
  deviceFrame: document.getElementById('device'),
  overlay: document.getElementById('overlay'),
  overlayTitle: document.getElementById('overlay-title'),
  overlayBody: document.getElementById('overlay-body'),
  overlayRetry: document.getElementById('overlay-retry'),
  mockBadge: document.getElementById('mock-badge'),
  btnHome: document.getElementById('btn-home'),
  btnRotate: document.getElementById('btn-rotate'),
  btnKeyboard: document.getElementById('btn-keyboard'),
  btnFullscreen: document.getElementById('btn-fullscreen'),
  btnReconnect: document.getElementById('btn-reconnect'),
  btnSession: document.getElementById('btn-session'),
  keyboardTray: document.getElementById('keyboard-tray'),
  kbInput: document.getElementById('kb-input'),
  sendReturn: document.getElementById('btn-send-return'),
  dialog: document.getElementById('session-dialog'),
  sessionList: document.getElementById('session-list'),
  sessionNote: document.getElementById('session-note'),
  toast: document.getElementById('toast'),
  hint: document.getElementById('hint'),
};

const ctx = el.canvas.getContext('2d', { alpha: false });
let ws = null;
let status = null;
let reconnectDelay = 800;
let reconnectTimer = null;
let lastFrameAt = 0;
let pendingBitmap = false;
let viewRotated = false;
let closeRequested = false;
const mock = { active: false, start: performance.now(), taps: [] };

/* ------------------------------------------------------------- helpers --- */

function toast(message, kind) {
  el.toast.textContent = message;
  el.toast.dataset.kind = kind || 'info';
  el.toast.hidden = false;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { el.toast.hidden = true; }, 4200);
}

function setStatus(state, text) {
  el.status.dataset.state = state;
  el.statusText.textContent = text;
}

function fmtTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function send(msg) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    toast('Not connected to the simulator', 'error');
    return false;
  }
  ws.send(JSON.stringify(msg));
  return true;
}

/* ---------------------------------------------------------------- draw --- */

function drawMock(now) {
  const w = el.canvas.width;
  const h = el.canvas.height;
  const t = (now - mock.start) / 1000;
  const bg = ctx.createLinearGradient(0, 0, w, h);
  bg.addColorStop(0, '#1d2b53');
  bg.addColorStop(0.45, '#5b2a86');
  bg.addColorStop(1, '#0b1a33');
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, w, h);

  ctx.fillStyle = 'rgba(255,255,255,0.92)';
  ctx.font = '600 62px -apple-system, "SF Pro Text", sans-serif';
  ctx.textAlign = 'left';
  ctx.fillText('9:41', 70, 120);
  ctx.font = '500 40px -apple-system, sans-serif';
  ctx.textAlign = 'right';
  ctx.fillText('●●●  ⌁  ▮', w - 70, 120);

  ctx.textAlign = 'center';
  ctx.fillStyle = 'rgba(255,255,255,0.96)';
  ctx.font = '300 190px -apple-system, sans-serif';
  ctx.fillText('9:41', w / 2, 470);
  ctx.font = '500 46px -apple-system, sans-serif';
  ctx.fillStyle = 'rgba(255,255,255,0.8)';
  ctx.fillText('Friday, 21 November', w / 2, 540);

  const icons = [
    ['#ff9f0a', 'Settings'], ['#0a84ff', 'Safari'], ['#30d158', 'Phone'],
    ['#ff375f', 'Music'], ['#5e5ce6', 'Mail'], ['#64d2ff', 'Maps'],
    ['#bf5af2', 'Photos'], ['#ffd60a', 'Notes'], ['#ff453a', 'Health'],
    ['#32ade6', 'Files'], ['#ff9f0a', 'Clock'], ['#8e8e93', 'App Store'],
  ];
  const cols = 4;
  const size = 190;
  const gapX = (w - cols * size) / (cols + 1);
  const startY = 700;
  icons.forEach(([color, name], i) => {
    const col = i % cols;
    const row = Math.floor(i / cols);
    const x = gapX + col * (size + gapX);
    const y = startY + row * (size + 120);
    ctx.fillStyle = color;
    ctx.beginPath();
    const r = 42;
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + size, y, x + size, y + size, r);
    ctx.arcTo(x + size, y + size, x, y + size, r);
    ctx.arcTo(x, y + size, x, y, r);
    ctx.arcTo(x, y, x + size, y, r);
    ctx.fill();
    ctx.fillStyle = 'rgba(255,255,255,0.92)';
    ctx.font = '400 30px -apple-system, sans-serif';
    ctx.fillText(name, x + size / 2, y + size + 44);
  });

  const dockY = h - 300;
  ctx.fillStyle = 'rgba(255,255,255,0.16)';
  ctx.beginPath();
  ctx.roundRect(60, dockY, w - 120, 220, 56);
  ctx.fill();
  ['#30d158', '#0a84ff', '#ff9f0a', '#ff375f'].forEach((c, i) => {
    ctx.fillStyle = c;
    ctx.beginPath();
    ctx.roundRect(60 + 120 + i * 220, dockY + 26, 168, 168, 38);
    ctx.fill();
  });

  ctx.fillStyle = 'rgba(255,255,255,0.55)';
  ctx.font = '500 34px -apple-system, sans-serif';
  ctx.fillText('Demo preview · run the workflow for the live simulator', w / 2, h - 60);

  // A little pulse so it is obvious this is animated, not a still image.
  ctx.fillStyle = `rgba(61,220,151,${0.35 + 0.25 * Math.sin(t * 2)})`;
  ctx.beginPath();
  ctx.arc(w / 2, dockY - 80, 22, 0, Math.PI * 2);
  ctx.fill();
}

function renderLoop(now) {
  if (mock.active) {
    drawMock(now);
  }
  requestAnimationFrame(renderLoop);
}
requestAnimationFrame(renderLoop);

async function handleFrame(buf) {
  lastFrameAt = Date.now();
  if (mock.active) {
    mock.active = false;
    el.mockBadge.hidden = true;
    el.overlay.hidden = true;
  }
  if (pendingBitmap) return;
  pendingBitmap = true;
  try {
    const bitmap = await createImageBitmap(new Blob([buf], { type: 'image/jpeg' }));
    el.canvas.width = bitmap.width;
    el.canvas.height = bitmap.height;
    ctx.drawImage(bitmap, 0, 0);
    bitmap.close();
  } catch (_) {
    // Malformed frame: drop it and wait for the next one.
  } finally {
    pendingBitmap = false;
  }
}

/* ------------------------------------------------------------ websocket --- */

function wsUrl() {
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const q = sessionToken ? `?token=${encodeURIComponent(sessionToken)}` : '';
  return `${proto}//${window.location.host}/ws${q}`;
}

function connect() {
  closeRequested = false;
  clearTimeout(reconnectTimer);
  if (ws) {
    try { ws.close(); } catch (_) {}
  }
  setStatus('connecting', 'Connecting…');
  el.overlay.hidden = false;
  el.overlayTitle.textContent = 'Connecting to simulator';
  el.overlayBody.textContent = 'Waiting for the first frame from the macOS runner.';

  let opened = false;
  ws = new WebSocket(wsUrl());
  ws.binaryType = 'arraybuffer';

  ws.addEventListener('open', () => {
    opened = true;
    reconnectDelay = 800;
    setStatus('live', 'Connected');
    loadStatus();
  });

  ws.addEventListener('message', (event) => {
    if (typeof event.data === 'string') {
      let msg;
      try { msg = JSON.parse(event.data); } catch (_) { return; }
      if (msg.type === 'hello') {
        applyStatus(msg.status);
        if (msg.status && msg.status.mock) {
          mock.active = true;
          el.mockBadge.hidden = false;
        }
      } else if (msg.type === 'input-result' && !msg.ok) {
        toast(`Input failed: ${msg.error || 'unknown error'}`, 'error');
      } else if (msg.type === 'input-unavailable') {
        toast('This session has no input driver; the stream is view-only.', 'error');
      }
      return;
    }
    handleFrame(event.data);
  });

  ws.addEventListener('close', () => {
    if (closeRequested) return;
    setStatus('error', 'Disconnected');
    el.overlay.hidden = false;
    el.overlayTitle.textContent = 'Stream disconnected';
    el.overlayBody.textContent = 'The session may have ended, or the network dropped. Reconnecting…';
    reconnectTimer = setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(8000, reconnectDelay * 1.6);
  });

  ws.addEventListener('error', () => {
    if (!opened) {
      setStatus('error', 'Cannot reach session');
      el.overlayTitle.textContent = 'Cannot reach the session';
      el.overlayBody.textContent = 'Check the session URL and token, then retry.';
    }
  });
}

/* --------------------------------------------------------------- status --- */

async function loadStatus() {
  try {
    const res = await fetch('/api/status', { headers: sessionToken ? { Authorization: `Bearer ${sessionToken}` } : {} });
    if (res.ok) applyStatus(await res.json());
  } catch (_) { /* ignore */ }
}

function applyStatus(s) {
  if (!s) return;
  status = s;
  el.macos.textContent = s.host && s.host.macos ? s.host.macos : '—';
  el.xcode.textContent = s.host && s.host.xcode ? s.host.xcode : '—';
  el.ios.textContent = s.device && s.device.iosVersion ? `iOS ${s.device.iosVersion}` : '—';
  el.device.textContent = s.device ? s.device.name : '—';
  el.expiry.textContent = fmtTime(s.session && s.session.expiresAt);

  const input = s.input || {};
  const label = input.touchVerified
    ? `Interactive · ${input.driver}`
    : input.touch
      ? `Interactive · ${input.driver} (unverified)`
      : 'View only';
  el.input.textContent = label;
  el.inputChip.dataset.mode = input.touch ? 'interactive' : 'view';
  el.btnHome.disabled = !input.home;
  el.btnRotate.disabled = !input.home;
  el.btnKeyboard.disabled = !input.keyboard;

  if (s.mock) {
    mock.active = true;
    el.mockBadge.hidden = false;
    el.overlay.hidden = true;
    setStatus('live', 'Demo preview');
  } else if (Date.now() - lastFrameAt < 4000) {
    setStatus('live', 'Live');
  }
  renderSession(s);
}

function renderSession(s) {
  const rows = [
    ['Status', s.mock ? 'Demo preview (no simulator)' : (s.connected ? 'Live' : 'Waiting for frames')],
    ['Device', s.device ? s.device.name : '—'],
    ['Device UDID', s.device ? s.device.udid || '—' : '—'],
    ['iOS runtime', s.device ? s.device.iosVersion : '—'],
    ['App', s.device && s.device.app ? s.device.app : '—'],
    ['macOS runner', s.host ? s.host.macos : '—'],
    ['Xcode', s.host ? s.host.xcode : '—'],
    ['Stream', `${s.stream ? s.stream.fps : 0} fps target · ${s.stream ? s.stream.frameSeq : 0} frames`],
    ['Input driver', s.input ? s.input.driver : '—'],
    ['Touch verified', s.input ? (s.input.touchVerified ? 'yes' : 'not verified') : '—'],
    ['Session started', fmtTime(s.session && s.session.startedAt)],
    ['Session ends', fmtTime(s.session && s.session.expiresAt)],
  ];
  el.sessionList.innerHTML = '';
  rows.forEach(([k, v]) => {
    const dt = document.createElement('dt');
    dt.textContent = k;
    const dd = document.createElement('dd');
    dd.textContent = String(v);
    el.sessionList.append(dt, dd);
  });
  const notes = [];
  if (s.input && s.input.note) notes.push(s.input.note);
  if (s.input && s.input.driverAttempts && s.input.driverAttempts.length) {
    notes.push('Driver probes: ' + s.input.driverAttempts.map((a) => `${a.driver}: ${a.ok ? 'ok' : a.reason}`).join(' · '));
  }
  if (s.session && s.session.publicUrl) notes.push(`Public URL: ${s.session.publicUrl}`);
  el.sessionNote.textContent = notes.join(' ') || '';
}

/* ------------------------------------------------------------ interaction --- */

const HID_KEYS = { Enter: 40, Backspace: 42, Tab: 43, Escape: 41, ' ': 44, ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82 };

function canvasPoint(event) {
  const rect = el.canvas.getBoundingClientRect();
  let nx = (event.clientX - rect.left) / rect.width;
  let ny = (event.clientY - rect.top) / rect.height;
  if (viewRotated) {
    const rx = nx;
    nx = 1 - ny;
    ny = rx;
  }
  return { x: Math.min(1, Math.max(0, nx)), y: Math.min(1, Math.max(0, ny)) };
}

let pointer = null;

el.canvas.addEventListener('pointerdown', (event) => {
  el.canvas.focus({ preventScroll: true });
  if (mock.active) {
    mock.taps.push(canvasPoint(event));
    toast('Demo preview: run the workflow to interact with a real simulator.');
    return;
  }
  el.canvas.setPointerCapture(event.pointerId);
  pointer = { ...canvasPoint(event), at: Date.now(), moved: 0 };
});

el.canvas.addEventListener('pointermove', (event) => {
  if (!pointer) return;
  const p = canvasPoint(event);
  pointer.moved = Math.max(pointer.moved, Math.hypot(p.x - pointer.x, p.y - pointer.y));
  pointer.last = p;
});

el.canvas.addEventListener('pointerup', (event) => {
  if (!pointer || mock.active) { pointer = null; return; }
  const p = canvasPoint(event);
  const duration = Date.now() - pointer.at;
  const distance = Math.hypot(p.x - pointer.x, p.y - pointer.y);
  if (distance < 0.012 && duration < 500) {
    send({ type: 'tap', x: p.x, y: p.y });
  } else {
    send({ type: 'swipe', x1: pointer.x, y1: pointer.y, x2: p.x, y2: p.y, durationMs: Math.min(1200, Math.max(80, duration)) });
  }
  pointer = null;
});

el.canvas.addEventListener('pointercancel', () => { pointer = null; });

/* ---------------------------------------------------------------- buttons --- */

el.btnHome.addEventListener('click', () => send({ type: 'home' }));

el.btnRotate.addEventListener('click', () => {
  const supported = status && status.input && status.input.rotate === 'device';
  if (supported) {
    send({ type: 'rotate', direction: 'right' });
    return;
  }
  // Device rotation is not exposed by this runner's driver: rotate the view only.
  viewRotated = !viewRotated;
  el.deviceFrame.classList.toggle('rotated', viewRotated);
  el.canvas.classList.toggle('rotated', viewRotated);
  toast('View rotated locally. Device rotation is unavailable with this input driver.');
});

el.btnKeyboard.addEventListener('click', () => {
  const on = el.keyboardTray.hidden;
  el.keyboardTray.hidden = !on;
  el.btnKeyboard.setAttribute('aria-pressed', String(on));
  if (on) el.kbInput.focus();
});

el.kbInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    send({ type: 'key', key: String(HID_KEYS.Enter) });
    return;
  }
  if (event.key === 'Backspace') {
    event.preventDefault();
    send({ type: 'key', key: String(HID_KEYS.Backspace) });
  }
});

el.kbInput.addEventListener('input', () => {
  const text = el.kbInput.value;
  if (text) send({ type: 'text', text });
  el.kbInput.value = '';
});

el.sendReturn.addEventListener('click', () => send({ type: 'key', key: String(HID_KEYS.Enter) }));

el.btnFullscreen.addEventListener('click', async () => {
  try {
    if (!document.fullscreenElement) {
      await document.documentElement.requestFullscreen();
    } else {
      await document.exitFullscreen();
    }
  } catch (_) {
    toast('Fullscreen was blocked by the browser', 'error');
  }
});

el.btnReconnect.addEventListener('click', () => {
  mock.active = false;
  el.mockBadge.hidden = true;
  connect();
});

el.overlayRetry.addEventListener('click', () => connect());

el.btnSession.addEventListener('click', () => {
  if (status) renderSession(status);
  if (typeof el.dialog.showModal === 'function') el.dialog.showModal();
  else el.dialog.setAttribute('open', '');
});

window.addEventListener('keydown', (event) => {
  if (event.target === el.kbInput) return;
  if (event.key === 'f' && !event.metaKey && !event.ctrlKey && !event.altKey) {
    el.btnFullscreen.click();
  }
  if (event.shiftKey && event.key === 'Home') {
    event.preventDefault();
    send({ type: 'home' });
  }
});

setInterval(() => {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ type: 'ping' }));
  if (Date.now() - lastFrameAt > 6000 && !mock.active) loadStatus();
}, 5000);

setInterval(loadStatus, 15000);

connect();
