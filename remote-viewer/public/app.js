'use strict';

const params = new URLSearchParams(window.location.search);
// Fall back to the token the server appended to this script's own URL, which is
// what happens when the page is embedded and its query string is not forwarded.
const scriptParams = new URLSearchParams(
  (document.currentScript && document.currentScript.src ? document.currentScript.src : window.location.href).split('?')[1] || ''
);
const sessionToken = params.get('token') || scriptParams.get('token') || '';

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
  cursor: document.getElementById('cursor'),
  streamStat: document.getElementById('stream-stat'),
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
let failedAttempts = 0;
const mock = { active: false, start: performance.now(), taps: [] };
let rxFrames = 0;
let rxFps = 0;

/* ------------------------------------------------------------ device fit --- */

// The frame is measured in pixels from the free space around it, so the
// simulator always fills the viewport at its own aspect ratio and the page
// never scrolls or crops the screen.
function layoutDevice() {
  const stage = el.stage;
  if (!stage) return;
  const cw = el.canvas.width || 1179;
  const ch = el.canvas.height || 2556;
  const displayLandscape = (cw > ch) !== viewRotated;
  const longSide = Math.max(cw, ch);
  const shortSide = Math.min(cw, ch);
  const ar = displayLandscape ? longSide / shortSide : shortSide / longSide;

  let stageW = stage.clientWidth;
  let stageH = stage.clientHeight;
  // A freshly rendered or collapsed layout can report no size; fall back to the
  // space left in the window so the screen is never left unmeasured.
  if (stageH < 40) {
    const rect = stage.getBoundingClientRect();
    stageH = Math.max(160, window.innerHeight - rect.top - 12);
  }
  if (stageW < 40) stageW = Math.max(160, window.innerWidth - 120);

  const root = getComputedStyle(document.documentElement);
  const pad = parseFloat(root.getPropertyValue('--frame-pad')) || 11;
  const chrome = pad * 2 + 2; // frame padding plus its 1px border on each side
  const availW = stageW - 4;
  const availH = stageH - 4;
  let innerH = Math.min(availH - chrome, (availW - chrome) / ar);
  innerH = Math.max(60, Math.floor(innerH));
  const innerW = Math.floor(innerH * ar);
  const frameW = innerW + chrome;
  const frameH = innerH + chrome;

  el.deviceFrame.style.width = `${frameW}px`;
  el.deviceFrame.style.height = `${frameH}px`;
  el.deviceFrame.style.setProperty('--frame-radius', `${Math.round(Math.min(52, frameW * 0.085))}px`);
  el.deviceFrame.style.setProperty('--screen-radius', `${Math.round(Math.min(44, frameW * 0.072))}px`);

  // A rotated view swaps the canvas box so the frame still fits exactly.
  el.canvas.style.width = `${viewRotated ? innerH : innerW}px`;
  el.canvas.style.height = `${viewRotated ? innerW : innerH}px`;
  el.deviceFrame.classList.toggle('rotated', viewRotated);
}

if (typeof ResizeObserver === 'function') {
  new ResizeObserver(() => layoutDevice()).observe(el.stage);
}
window.addEventListener('resize', layoutDevice);
window.addEventListener('orientationchange', () => setTimeout(layoutDevice, 250));
document.addEventListener('fullscreenchange', () => setTimeout(layoutDevice, 150));

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

/* --------------------------------------------------------- touch cursor --- */

// The simulator screen has no pointer of its own, so the page draws one: a glass
// ring that sits exactly where the next tap or drag will land, shrinks while
// pressed and pulses a ripple when the touch has been sent to the device.

function moveCursor(x, y) {
  if (!el.cursor) return;
  el.cursor.hidden = false;
  el.cursor.style.transform = `translate3d(${x}px, ${y}px, 0)`;
}

function hideCursor() {
  if (!el.cursor) return;
  el.cursor.hidden = true;
  el.cursor.classList.remove('pressed');
}

function rippleAt(x, y) {
  const ring = document.createElement('span');
  ring.className = 'ripple';
  ring.style.left = `${x}px`;
  ring.style.top = `${y}px`;
  document.body.append(ring);
  setTimeout(() => ring.remove(), 650);
}

function flashSent() {
  if (!el.cursor) return;
  el.cursor.classList.remove('sent');
  // Reflow so the animation can restart on rapid taps.
  void el.cursor.offsetWidth;
  el.cursor.classList.add('sent');
}

async function handleFrame(buf) {
  rxFrames += 1;
  lastFrameAt = Date.now();
  // The first real frame is what proves the stream works: dismiss the overlay
  // for every session, not just the demo one.
  el.overlay.hidden = true;
  setStatus('live', 'Live');
  if (mock.active) {
    mock.active = false;
    el.mockBadge.hidden = true;
  }
  if (pendingBitmap) return;
  pendingBitmap = true;
  try {
    const bitmap = await createImageBitmap(new Blob([buf], { type: 'image/jpeg' }));
    const resized = el.canvas.width !== bitmap.width || el.canvas.height !== bitmap.height;
    el.canvas.width = bitmap.width;
    el.canvas.height = bitmap.height;
    ctx.drawImage(bitmap, 0, 0);
    bitmap.close();
    // The simulator rotates: refit the frame to the new orientation.
    if (resized) layoutDevice();
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
    failedAttempts = 0;
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
    failedAttempts += 1;
    const expired = failedAttempts >= 3;
    setStatus('error', expired ? 'Session ended' : 'Disconnected');
    el.overlay.hidden = false;
    el.overlayTitle.textContent = expired ? 'This session has ended' : 'Stream disconnected';
    el.overlayBody.textContent = expired
      ? 'The runner or its temporary address is gone. Start a new workflow run and open the URL it publishes.'
      : 'The network dropped. Reconnecting…';
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
  if (el.macos) el.macos.textContent = s.host && s.host.macos ? s.host.macos : '—';
  if (el.xcode) el.xcode.textContent = s.host && s.host.xcode ? s.host.xcode : '—';
  if (el.ios) el.ios.textContent = s.device && s.device.iosVersion ? `iOS ${s.device.iosVersion}` : '—';
  if (el.device) el.device.textContent = s.device ? s.device.name : '—';
  if (el.expiry) el.expiry.textContent = fmtTime(s.session && s.session.expiresAt);

  const input = s.input || {};
  const label = input.touchVerified
    ? `Interactive · ${input.driver}`
    : input.touch
      ? `Interactive · ${input.driver} (unverified)`
      : 'View only';
  if (el.input) el.input.textContent = label;
  if (el.inputChip) el.inputChip.dataset.mode = input.touch ? 'interactive' : 'view';
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
    ['Device state', s.device && s.device.state ? s.device.state : 'fresh'],
    ['macOS runner', s.host ? s.host.macos : '—'],
    ['Xcode', s.host ? s.host.xcode : '—'],
    ['Stream', `${s.stream ? s.stream.achievedFps || 0 : 0} fps measured (${s.stream ? s.stream.fps : 0} target) · ${s.stream ? s.stream.frameSeq : 0} frames`],
    ['Frame', s.stream && s.stream.captureMs ? `${s.stream.captureMs} ms capture · ${Math.round((s.stream.lastFrameBytes || 0) / 1024)} KB` : '—'],
    ['Input driver', s.input ? s.input.driver : '—'],
    ['Touch verified', s.input ? (s.input.touchVerified ? 'yes' : 'not verified') : '—'],
    ['Session started', fmtTime(s.session && s.session.startedAt)],
    ['Session ends', s.session && s.session.expiresAt ? fmtTime(s.session.expiresAt) : 'when the run is cancelled'],
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

el.canvas.addEventListener('pointerenter', (event) => {
  moveCursor(event.clientX, event.clientY);
  el.cursor.classList.remove('pressed');
});

el.canvas.addEventListener('pointerleave', () => {
  if (!pointer) hideCursor();
});

el.canvas.addEventListener('pointerdown', (event) => {
  el.canvas.focus({ preventScroll: true });
  moveCursor(event.clientX, event.clientY);
  el.cursor.classList.add('pressed');
  if (mock.active) {
    mock.taps.push(canvasPoint(event));
    toast('Demo preview: run the workflow to interact with a real simulator.');
    return;
  }
  el.canvas.setPointerCapture(event.pointerId);
  pointer = { ...canvasPoint(event), at: Date.now(), moved: 0 };
});

el.canvas.addEventListener('pointermove', (event) => {
  moveCursor(event.clientX, event.clientY);
  if (!pointer) return;
  const p = canvasPoint(event);
  pointer.moved = Math.max(pointer.moved, Math.hypot(p.x - pointer.x, p.y - pointer.y));
  pointer.last = p;
});

el.canvas.addEventListener('pointerup', (event) => {
  el.cursor.classList.remove('pressed');
  if (mock.active) {
    // Touch is not available in the demo: show the ring without claiming a send.
    rippleAt(event.clientX, event.clientY);
    pointer = null;
    return;
  }
  if (!pointer) { pointer = null; return; }
  const p = canvasPoint(event);
  const duration = Date.now() - pointer.at;
  const distance = Math.hypot(p.x - pointer.x, p.y - pointer.y);
  const sent = distance < 0.012 && duration < 500
    ? send({ type: 'tap', x: p.x, y: p.y })
    : send({ type: 'swipe', x1: pointer.x, y1: pointer.y, x2: p.x, y2: p.y, durationMs: Math.min(1200, Math.max(80, duration)) });
  if (sent) {
    rippleAt(event.clientX, event.clientY);
    flashSent();
  }
  pointer = null;
});

el.canvas.addEventListener('pointercancel', () => {
  pointer = null;
  el.cursor.classList.remove('pressed');
  hideCursor();
});

// A mouse leaving the window mid-drag would otherwise leave the ring behind.
window.addEventListener('blur', () => { if (!pointer) hideCursor(); });

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
  layoutDevice();
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

// Measured frame rate, not the configured one: this is what the runner is
// actually delivering over the tunnel.
setInterval(() => {
  if (!el.streamStat) return;
  rxFps = rxFrames;
  rxFrames = 0;
  if (rxFps > 0) {
    const ms = status && status.stream && status.stream.captureMs ? ` · ${status.stream.captureMs} ms` : '';
    el.streamStat.textContent = `${rxFps} fps${ms}`;
    el.streamStat.hidden = false;
  } else if (el.streamStat.hidden === false) {
    el.streamStat.textContent = 'waiting for frames';
  }
}, 1000);

setInterval(() => {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ type: 'ping' }));
  if (Date.now() - lastFrameAt > 6000 && !mock.active) loadStatus();
}, 5000);

setInterval(loadStatus, 15000);

layoutDevice();
connect();
