#!/usr/bin/env node
'use strict';
/**
 * Remote iOS Simulator streaming server.
 *
 * - Captures the real simulator framebuffer with `xcrun simctl io <udid> screenshot`
 *   in a tight loop and broadcasts JPEG frames over a WebSocket.
 * - Maps pointer/keyboard events from the browser onto the input driver
 *   (idb / AXe / AppleScript) so the session is interactive where the runner
 *   allows it.
 * - Everything except /api/health and the static assets requires the session
 *   token, delivered as ?token=... (sets an HttpOnly cookie) or a Bearer header.
 *
 * Env:
 *   PORT                 listen port (default 8080)
 *   SESSION_TOKEN        access credential; empty disables auth (local demo only)
 *   UDID                 simulator UDID (required unless SIM_MOCK=1)
 *   SIM_MOCK=1           render a demo screen in the browser, no simulator
 *   SESSION_DIR          directory holding detected environment + capability files
 *   FRAME_FPS            target frames per second (default 30; the capture loop
 *                        runs as fast as the device allows, this is only a cap)
 *   FRAME_WIDTH          frame width in px; 0 = native device resolution, which
 *                        skips the per-frame `sips` spawn entirely (default 0)
 *   FRAME_QUALITY        JPEG quality when a downscale happens (default 62)
 *   DEVICE_NAME / IOS_VERSION / XCODE_VERSION / MACOS_VERSION / PUBLIC_URL
 */

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');
const { WebSocketServer } = require('ws');
const { createDriver, run, simctlScreenshotPixels, scaleForDevice } = require('./drivers');

const PORT = Number(process.env.PORT || 8080);
const TOKEN = (process.env.SESSION_TOKEN || '').trim();
const MOCK = process.env.SIM_MOCK === '1';
const UDID = (process.env.UDID || '').trim();
const SESSION_DIR = process.env.SESSION_DIR || path.join(__dirname, '..', '.session');
const FPS = Math.min(90, Math.max(1, Number(process.env.FRAME_FPS || 30)));
// 0 means "send the device's own resolution". Downscaling costs an extra `sips`
// process per frame, which was a third of the per-frame time.
const FRAME_WIDTH = Math.min(1400, Math.max(0, Number(process.env.FRAME_WIDTH || 0)));
const FRAME_QUALITY = Math.min(95, Math.max(30, Number(process.env.FRAME_QUALITY || 62)));
const PUBLIC_DIR = path.join(__dirname, 'public');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'simview-'));
const STARTED_AT = new Date().toISOString();

const info = {
  device: process.env.DEVICE_NAME || 'unknown',
  ios: process.env.IOS_VERSION || 'unknown',
  xcode: process.env.XCODE_VERSION || 'unknown',
  macos: process.env.MACOS_VERSION || 'unknown',
  publicUrl: process.env.PUBLIC_URL || '',
  app: process.env.APP_NAME || '',
};

const state = {
  frameSeq: 0,
  lastFrameAt: null,
  lastFrameBytes: 0,
  captureErrors: 0,
  lastCaptureError: '',
  pointSize: null,
  driver: null,
  driverName: 'none',
  driverAttempts: [],
  inputEvents: 0,
  rejectedInputEvents: 0,
};

/* ------------------------------------------------------------- helpers --- */

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return fallback;
  }
}

function timingSafeEq(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length || ba.length === 0) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function cookies(req) {
  const raw = req.headers.cookie || '';
  const out = {};
  for (const part of raw.split(';')) {
    const idx = part.indexOf('=');
    if (idx < 0) continue;
    out[part.slice(0, idx).trim()] = decodeURIComponent(part.slice(idx + 1).trim());
  }
  return out;
}

function authorized(req, url) {
  if (!TOKEN) return true;
  const header = req.headers.authorization || '';
  if (header.toLowerCase().startsWith('bearer ') && timingSafeEq(header.slice(7).trim(), TOKEN)) return true;
  const q = url.searchParams.get('token');
  if (q && timingSafeEq(q, TOKEN)) return true;
  const c = cookies(req).sim_session;
  if (c && timingSafeEq(c, TOKEN)) return true;
  return false;
}

function capability() {
  const cap = readJson(path.join(SESSION_DIR, 'capability.json'), null);
  if (cap) return cap;
  return {
    touch: state.driverName !== 'none',
    touchVerified: false,
    keyboard: state.driverName !== 'none',
    rotate: state.driverName === 'applescript' ? 'device' : 'view',
    home: state.driverName !== 'none',
    driver: state.driverName,
    driverAttempts: state.driverAttempts,
    note: state.driverName === 'none' ? 'No input driver available on this runner; the stream is view-only.' : '',
  };
}

function status() {
  return {
    ok: true,
    mock: MOCK,
    connected: !!state.lastFrameAt,
    device: {
      name: info.device,
      udid: UDID,
      iosVersion: info.ios,
      app: info.app,
      state: process.env.STATE_RESTORE || '',
      pointSize: state.pointSize,
    },
    host: { macos: info.macos, xcode: info.xcode },
    session: {
      startedAt: STARTED_AT,
      expiresAt: readJson(path.join(SESSION_DIR, 'session.json'), {}).expiresAt || null,
      durationMinutes: readJson(path.join(SESSION_DIR, 'session.json'), {}).durationMinutes || null,
      publicUrl: info.publicUrl,
    },
    stream: {
      fps: FPS,
      achievedFps: Math.round((state.achievedFps || 0) * 10) / 10,
      width: FRAME_WIDTH || (state.pointSize && state.pointSize.pixels ? state.pointSize.pixels.width : 0),
      mode: 'jpeg',
      capturePath: state.capturePath || 'stdout',
      quality: FRAME_WIDTH ? FRAME_QUALITY : null,
      frameSeq: state.frameSeq,
      lastFrameAt: state.lastFrameAt,
      lastFrameBytes: state.lastFrameBytes,
      captureMs: state.lastCaptureMs || null,
      captureErrors: state.captureErrors,
      lastCaptureError: state.lastCaptureError,
    },
    input: capability(),
    auth: { required: !!TOKEN },
  };
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.webmanifest': 'application/manifest+json',
};

function sendJson(res, code, body) {
  const payload = JSON.stringify(body);
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(payload),
    'x-content-type-options': 'nosniff',
  });
  res.end(payload);
}

function sendText(res, code, text, type = 'text/plain; charset=utf-8') {
  res.writeHead(code, {
    'content-type': type,
    'cache-control': 'no-store',
    'x-robots-tag': 'noindex, nofollow',
    'x-frame-options': 'SAMEORIGIN',
    'referrer-policy': 'no-referrer',
  });
  res.end(text);
}

/* ------------------------------------------------------------ capture --- */

let latestFrame = null;

function execSh(cmd, timeout = 30000) {
  return new Promise((resolve) => {
    execFile('/bin/sh', ['-c', cmd], { timeout, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) =>
      resolve({ ok: !err, stdout: String(stdout || ''), stderr: String(stderr || '') })
    );
  });
}

async function detectPointSize() {
  try {
    const shot = path.join(TMP, 'probe.png');
    const px = await simctlScreenshotPixels(UDID, shot);
    if (!px) return null;
    if (state.driver && typeof state.driver.pointSize === 'function') {
      const pts = await state.driver.pointSize();
      if (pts) return { ...pts, pixels: px, scale: px.width / pts.width };
    }
    const scale = scaleForDevice(info.device);
    return { width: Math.round(px.width / scale), height: Math.round(px.height / scale), pixels: px, scale };
  } catch (_) {
    return null;
  }
}

// Calling the resolved simctl binary skips an `xcrun` lookup on every frame,
// which is a measurable part of the per-frame cost.
let SIMCTL_BIN = 'simctl';
let SIMCTL_IO = 'xcrun simctl io';

async function resolveSimctl() {
  const r = await execSh('xcrun --find simctl');
  const found = r.ok ? r.stdout.trim().split('\n')[0] : '';
  if (found && found.startsWith('/')) {
    SIMCTL_BIN = found;
    SIMCTL_IO = `${JSON.stringify(found)} io`;
    console.log('[stream] simctl resolved to ' + found);
  }
}

// Fast path: the screenshot is written to stdout and read as a Buffer, so a
// frame never touches the disk. Encoding is forced to buffer: the default utf8
// encoding would mangle the JPEG bytes. The first failure is logged with the
// simulator's own message, because not every simctl build accepts `-` here.
let stdoutCaptureWorks = true;

function simctlJpegStdout(timeout = 20000) {
  return new Promise((resolve) => {
    execFile(
      SIMCTL_BIN,
      ['io', UDID, 'screenshot', '--type=jpeg', '-'],
      { encoding: 'buffer', maxBuffer: 96 * 1024 * 1024, timeout },
      (err, stdout, stderr) => {
        if (!err && stdout && stdout.length > 512) return resolve(Buffer.from(stdout));
        const detail = err ? String(stderr || err.message || '').trim() : 'empty stdout';
        resolve({ error: detail.slice(0, 300) || 'empty stdout' });
      }
    );
  });
}

// Proven fallback: simctl writes its JPEG to a temp file and the file is read.
function simctlJpegFile() {
  const out = path.join(TMP, 'frame.jpg');
  return new Promise((resolve) => {
    execFile(
      SIMCTL_BIN,
      ['io', UDID, 'screenshot', '--type=jpeg', out],
      { timeout: 20000 },
      (err, _stdout, stderr) => {
        if (err) return resolve({ error: String(stderr || err.message || 'capture failed').trim().slice(0, 300) });
        try {
          const buf = fs.readFileSync(out);
          if (buf.length < 512) return resolve({ error: 'truncated frame' });
          return resolve(buf);
        } catch (e) {
          return resolve({ error: String(e.message) });
        }
      }
    );
  });
}

async function simctlJpeg() {
  if (stdoutCaptureWorks) {
    const r = await simctlJpegStdout();
    if (Buffer.isBuffer(r)) return r;
    stdoutCaptureWorks = false;
    state.capturePath = 'file';
    console.log('[stream] stdout capture unavailable (' + r.error + '); using a temp file instead');
  }
  const r = await simctlJpegFile();
  return Buffer.isBuffer(r) ? r : null;
}

async function captureOnce() {
  if (MOCK) return null;
  const raw = await simctlJpeg();
  if (!raw) {
    state.captureErrors += 1;
    state.lastCaptureError = 'simctl screenshot produced no frame';
    return null;
  }
  const nativeW = state.pointSize && state.pointSize.pixels ? state.pointSize.pixels.width : 0;
  // Only pay for a downscale when one is actually requested.
  if (!FRAME_WIDTH || !nativeW || FRAME_WIDTH >= nativeW - 2) return raw;
  const inFile = path.join(TMP, 'frame-raw.jpg');
  const out = path.join(TMP, 'frame.jpg');
  try {
    fs.writeFileSync(inFile, raw);
  } catch (err) {
    state.lastCaptureError = String(err.message);
    return raw;
  }
  const r = await execSh(
    `sips -s format jpeg -s formatOptions ${FRAME_QUALITY} --resampleWidth ${FRAME_WIDTH} ${JSON.stringify(inFile)} --out ${JSON.stringify(out)} >/dev/null`,
    15000
  );
  if (!r.ok) {
    // A failed downscale must not cost a frame: send the native one instead.
    return raw;
  }
  try {
    return fs.readFileSync(out);
  } catch (_) {
    return raw;
  }
}

async function captureLoop() {
  if (MOCK) return;
  const interval = 1000 / FPS;
  for (;;) {
    const started = Date.now();
    const buf = await captureOnce();
    if (buf) {
      const now = Date.now();
      // Achieved rate is measured from frame arrivals, never from the target.
      if (state.prevFrameAt) {
        const inst = 1000 / Math.max(1, now - state.prevFrameAt);
        state.achievedFps = state.achievedFps ? state.achievedFps * 0.85 + inst * 0.15 : inst;
      }
      state.prevFrameAt = now;
      latestFrame = buf;
      state.frameSeq += 1;
      state.lastFrameAt = new Date().toISOString();
      state.lastFrameBytes = buf.length;
      if (state.frameSeq === 1) console.log(`[stream] first frame ${buf.length} bytes`);
      for (const client of wss.clients) {
        if (client.readyState !== 1) continue;
        // A client that cannot keep up must not stall capture for everybody;
        // drop frames for it and let the stream stay at a steady rate.
        if ((client.bufferedAmount || 0) > 2 * 1024 * 1024) continue;
        client.send(buf, { binary: true });
      }
    }
    const elapsed = Date.now() - started;
    // Exposed so the achieved frame rate can be measured instead of guessed.
    state.lastCaptureMs = elapsed;
    // No idle floor: when capture is the bottleneck the loop goes straight into
    // the next frame, and the target only ever slows it down.
    const wait = interval - elapsed;
    await new Promise((r) => (wait > 0 ? setTimeout(r, wait) : setImmediate(r)));
  }
}

/* --------------------------------------------------------------- http --- */

const server = http.createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch (_) {
    return sendText(res, 400, 'bad request');
  }
  const p = url.pathname;

  if (p === '/api/health') {
    return sendJson(res, 200, { ok: true, mock: MOCK, uptimeSeconds: Math.round(process.uptime()) });
  }

  if (p === '/api/status') {
    if (!authorized(req, url)) return sendJson(res, 401, { ok: false, error: 'authentication required' });
    return sendJson(res, 200, status());
  }

  if (p === '/api/snapshot.jpg') {
    if (!authorized(req, url)) return sendText(res, 401, 'authentication required');
    if (!latestFrame) return sendText(res, 503, 'no frame captured yet');
    res.writeHead(200, { 'content-type': 'image/jpeg', 'cache-control': 'no-store', 'content-length': latestFrame.length });
    return res.end(latestFrame);
  }

  // Static assets (viewer UI).
  if (p === '/' || p === '/index.html') {
    if (!authorized(req, url)) {
      return sendText(res, 401, 'Authentication required. Open the session URL that includes ?token=...');
    }
    const queryToken = url.searchParams.get('token');
    if (queryToken && TOKEN) {
      // The viewer is often embedded in another page, where SameSite=Strict/Lax
      // cookies are dropped; None works in frames and the token is short-lived.
      const cookie = `sim_session=${encodeURIComponent(TOKEN)}; Path=/; HttpOnly; Secure; SameSite=None; Max-Age=86400`;
      res.setHeader('set-cookie', cookie);
    }
    const file = path.join(PUBLIC_DIR, 'index.html');
    // Assets are fetched by the browser without the page's query string, so the
    // token is carried on every asset reference as well. Without this the shell
    // loads but app.js is refused and the UI sits on "Connecting…" forever.
    if (queryToken && TOKEN) {
      const html = fs
        .readFileSync(file, 'utf8')
        .replace(/(href|src)="(styles\.css|app\.js|favicon\.svg)"/g, `$1="$2?token=${encodeURIComponent(queryToken)}"`);
      res.writeHead(200, {
        'content-type': MIME['.html'],
        'cache-control': 'no-store',
        'content-length': Buffer.byteLength(html),
        'x-frame-options': 'SAMEORIGIN',
        'referrer-policy': 'no-referrer',
        'x-robots-tag': 'noindex, nofollow',
        'content-security-policy':
          "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'none'; frame-ancestors 'self'",
      });
      return res.end(html);
    }
    res.writeHead(200, {
      'content-type': MIME['.html'],
      'cache-control': 'no-store',
      'x-frame-options': 'SAMEORIGIN',
      'referrer-policy': 'no-referrer',
      'x-robots-tag': 'noindex, nofollow',
      'content-security-policy':
        "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'none'; frame-ancestors 'self'",
    });
    return fs.createReadStream(file).pipe(res);
  }

  if (p === '/app.js' || p === '/styles.css' || p === '/favicon.svg') {
    if (!authorized(req, url)) return sendText(res, 401, 'authentication required');
    const file = path.join(PUBLIC_DIR, path.basename(p));
    if (!fs.existsSync(file)) return sendText(res, 404, 'not found');
    res.writeHead(200, {
      'content-type': MIME[path.extname(file)] || 'application/octet-stream',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    });
    return fs.createReadStream(file).pipe(res);
  }

  return sendText(res, 404, 'not found');
});

/* ----------------------------------------------------------- websocket --- */

const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch (_) {
    socket.destroy();
    return;
  }
  if (url.pathname !== '/ws') {
    socket.destroy();
    return;
  }
  if (!authorized(req, url)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
});

function clamp01(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return null;
  return Math.min(1, Math.max(0, v));
}

function rateLimited(ws) {
  const now = Date.now();
  ws._bucket = ws._bucket || [];
  ws._bucket = ws._bucket.filter((t) => now - t < 2000);
  if (ws._bucket.length >= 25) {
    state.rejectedInputEvents += 1;
    return true;
  }
  ws._bucket.push(now);
  return false;
}

async function handleInput(ws, msg) {
  if (rateLimited(ws)) return ws.send(JSON.stringify({ type: 'error', error: 'input rate limit' }));
  if (MOCK || !state.driver || state.driverName === 'none') {
    return ws.send(JSON.stringify({ type: 'input-unavailable', driver: state.driverName }));
  }
  const pts = state.pointSize && state.pointSize.width ? state.pointSize : null;
  const toX = (v) => (pts ? v * pts.width : v * 400);
  const toY = (v) => (pts ? v * pts.height : v * 800);
  let result = { ok: false, stderr: 'unsupported message' };

  switch (msg.type) {
    case 'tap': {
      const x = clamp01(msg.x);
      const y = clamp01(msg.y);
      if (x === null || y === null) break;
      result = await state.driver.tap(toX(x), toY(y));
      break;
    }
    case 'swipe': {
      const x1 = clamp01(msg.x1);
      const y1 = clamp01(msg.y1);
      const x2 = clamp01(msg.x2);
      const y2 = clamp01(msg.y2);
      if ([x1, y1, x2, y2].some((v) => v === null)) break;
      result = await state.driver.swipe(toX(x1), toY(y1), toX(x2), toY(y2), msg.durationMs || 250);
      break;
    }
    case 'text':
      if (typeof msg.text !== 'string' || !msg.text) break;
      result = await state.driver.text(msg.text.slice(0, 500));
      break;
    case 'key':
      if (!msg.key) break;
      result = await state.driver.key(String(msg.key));
      break;
    case 'home':
      result = await state.driver.home();
      break;
    case 'rotate':
      result = await state.driver.rotate(msg.direction === 'left' ? 'left' : 'right');
      break;
    default:
      break;
  }
  state.inputEvents += 1;
  ws.send(JSON.stringify({
    type: 'input-result',
    action: msg.type,
    ok: !!result.ok,
    error: result.ok ? null : String(result.stderr || result.error || 'failed').slice(0, 300),
    capability: capability(),
  }));
}

wss.on('connection', (ws) => {
  ws._bucket = [];
  ws.send(JSON.stringify({ type: 'hello', status: status() }));
  if (latestFrame) ws.send(latestFrame, { binary: true });
  ws.on('message', async (data, isBinary) => {
    if (isBinary) return;
    let msg;
    try {
      msg = JSON.parse(String(data));
    } catch (_) {
      return;
    }
    if (!msg || typeof msg.type !== 'string') return;
    if (msg.type === 'ping') return ws.send(JSON.stringify({ type: 'pong', t: Date.now() }));
    if (msg.type === 'status') return ws.send(JSON.stringify({ type: 'hello', status: status() }));
    return handleInput(ws, msg);
  });
});

/* -------------------------------------------------------------- start --- */

async function main() {
  if (!MOCK) {
    if (!UDID) {
      console.error('UDID is required unless SIM_MOCK=1');
      process.exit(2);
    }
    const { driver, attempts, reason } = await createDriver({ udid: UDID, preferred: process.env.INPUT_DRIVER || '' });
    state.driver = driver;
    state.driverName = driver.name;
    state.driverAttempts = attempts;
    console.log('[input] driver=' + driver.name + (reason ? ` (${reason})` : ''));
    console.log('[input] attempts=' + JSON.stringify(attempts));
    state.pointSize = await detectPointSize();
    if (state.pointSize && typeof driver.setDeviceSize === 'function') {
      driver.setDeviceSize(state.pointSize);
    }
    console.log('[device] point size=' + JSON.stringify(state.pointSize));
  } else {
    console.log('[stream] SIM_MOCK=1 - demo screen only, no simulator attached');
  }

  await resolveSimctl();

  server.listen(PORT, '0.0.0.0', () => {
    console.log(`[http] listening on 0.0.0.0:${PORT} (auth ${TOKEN ? 'required' : 'DISABLED'}, mock=${MOCK})`);
  });
  captureLoop().catch((err) => console.error('[stream] capture loop crashed', err));
}

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));

main().catch((err) => {
  console.error('fatal', err);
  process.exit(1);
});
