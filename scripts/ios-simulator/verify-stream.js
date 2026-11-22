#!/usr/bin/env node
'use strict';
/**
 * End-to-end verification of the public viewer endpoint:
 *   - unauthenticated requests must be rejected
 *   - the token grants access to the viewer HTML
 *   - the WebSocket accepts the session token and delivers a real JPEG frame
 *
 * Writes .session/stream-check.json and exits non-zero when the stream never
 * produces a frame, or when the measured rate misses STREAM_MIN_FPS.
 *
 * The frame rate is timed over a real window instead of counting one frame, so a
 * session cannot be published as smooth on the strength of a single delivery.
 */

const fs = require('fs');
const path = require('path');
const WebSocket = require('../../remote-viewer/node_modules/ws');

const SESSION_DIR = process.env.SESSION_DIR || path.join(process.cwd(), '.session');

function stateGet(key, fallback = '') {
  try {
    const raw = fs.readFileSync(path.join(SESSION_DIR, 'state.env'), 'utf8');
    const line = raw.split('\n').filter((l) => l.startsWith(`${key}=`)).pop();
    return line ? line.slice(key.length + 1) : fallback;
  } catch (_) {
    return fallback;
  }
}

const base = (process.env.PUBLIC_URL || stateGet('PUBLIC_URL')).replace(/\/$/, '');
const token = process.env.SESSION_TOKEN || stateGet('SESSION_TOKEN');
const MEASURE_MS = Math.max(2000, Number(process.env.STREAM_MEASURE_MS || 8000));
// The first seconds after a tunnel comes up are not representative: the capture
// loop is still warming and the tunnel is still settling, which produced a 1.8
// fps reading for a stream that then ran at 5. Discard that burst.
const WARMUP_MS = Math.max(0, Number(process.env.STREAM_WARMUP_MS || 5000));
const MIN_FPS = Math.max(0, Number(process.env.STREAM_MIN_FPS || 0));
const result = { checkedAt: new Date().toISOString(), base, auth: {}, stream: {}, ok: false };

async function http(pathname, headers = {}) {
  const res = await fetch(base + pathname, { headers, redirect: 'follow' });
  const body = await res.text();
  return { status: res.status, body };
}

function checkStream() {
  return new Promise((resolve) => {
    const wsUrl = `${base.replace(/^http/, 'ws')}/ws?token=${encodeURIComponent(token)}`;
    const ws = new WebSocket(wsUrl, { handshakeTimeout: 20000 });
    let hello = null;
    let frames = 0;
    let bytes = 0;
    let windowStart = 0;
    let finished = false;
    const openedAt = Date.now();
    const done = (error) => {
      if (finished) return;
      finished = true;
      const seconds = windowStart ? (Date.now() - windowStart) / 1000 : 0;
      const fps = seconds ? Math.round((frames / seconds) * 10) / 10 : 0;
      result.stream = {
        hello: !!hello,
        frames,
        bytes,
        seconds: Math.round(seconds * 10) / 10,
        fps,
        minFps: MIN_FPS,
        error: error || null,
        url: wsUrl.replace(token, '***'),
      };
      try { ws.close(); } catch (_) {}
      resolve();
    };
    const timer = setTimeout(() => done(frames ? null : 'no frame received within 25s'), 25000);
    ws.on('message', (data, isBinary) => {
      if (isBinary) {
        bytes += data.length;
        clearTimeout(timer);
        if (!windowStart) {
          if (Date.now() - openedAt < WARMUP_MS) {
            // Still warming up: count nothing yet, keep the connection.
            return;
          }
          // Time a real window: one fast frame followed by a stall must not read
          // as a usable frame rate.
          windowStart = Date.now();
          setTimeout(() => done(null), MEASURE_MS);
        }
        frames += 1;
        return;
      }
      try {
        const msg = JSON.parse(String(data));
        if (msg.type === 'hello') hello = msg.status;
      } catch (_) { /* ignore */ }
    });
    ws.on('error', (err) => { clearTimeout(timer); done(String(err.message || err)); });
    ws.on('close', () => { /* handled by done() */ });
  });
}

(async () => {
  try {
    const unauth = await http('/');
    result.auth.withoutToken = unauth.status;
    const authed = await http(`/?token=${encodeURIComponent(token)}`);
    result.auth.withToken = authed.status;
    result.auth.titlePresent = /Remote iOS Simulator/i.test(authed.body);
    const status = await http('/api/status', { Authorization: `Bearer ${token}` });
    result.auth.statusEndpoint = status.status;
    await checkStream();
    result.ok = result.auth.withoutToken === 401 && result.auth.withToken === 200 && result.stream.frames > 0;
    // One slow window is not a verdict: re-measure once before failing a session.
    if (result.ok && MIN_FPS > 0 && result.stream.fps < MIN_FPS) {
      const first = result.stream.fps;
      await checkStream();
      result.stream.firstFps = first;
      result.ok = result.stream.frames > 0;
    }
    if (result.ok && MIN_FPS > 0 && result.stream.fps < MIN_FPS) {
      result.error = `measured ${result.stream.fps} fps, below the required ${MIN_FPS} fps`;
      result.ok = false;
    }
  } catch (err) {
    result.error = String(err && err.message ? err.message : err);
  }
  result.verifiedAt = new Date().toISOString();
  fs.writeFileSync(path.join(SESSION_DIR, 'stream-check.json'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.ok ? 0 : 1);
})();
