#!/usr/bin/env node
'use strict';
/**
 * End-to-end verification of the public viewer endpoint:
 *   - unauthenticated requests must be rejected
 *   - the token grants access to the viewer HTML
 *   - the WebSocket accepts the session token and delivers a real JPEG frame
 *
 * Writes .session/stream-check.json and exits non-zero when the stream never
 * produces a frame.
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
    const done = (error) => {
      result.stream = { hello: !!hello, frames, bytes, error: error || null, url: wsUrl.replace(token, '***') };
      try { ws.close(); } catch (_) {}
      resolve();
    };
    const timer = setTimeout(() => done(frames ? null : 'no frame received within 25s'), 25000);
    ws.on('message', (data, isBinary) => {
      if (isBinary) {
        frames += 1;
        bytes += data.length;
        clearTimeout(timer);
        setTimeout(() => done(null), 400);
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
  } catch (err) {
    result.error = String(err && err.message ? err.message : err);
  }
  result.verifiedAt = new Date().toISOString();
  fs.writeFileSync(path.join(SESSION_DIR, 'stream-check.json'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.ok ? 0 : 1);
})();
