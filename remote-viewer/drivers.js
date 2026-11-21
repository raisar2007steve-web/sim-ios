'use strict';
/**
 * Input drivers for a remote iOS Simulator.
 *
 * Every backend is best-effort: none of them can be assumed to exist on a
 * GitHub-hosted macOS runner, so each one exposes probe() and the session
 * self-test (scripts/ios-simulator/touch-selftest.js) decides whether injected
 * input actually reached the simulator.
 *
 * Backends, in order of preference:
 *   idb   - Facebook idb (`idb ui tap`) talking to idb_companion over gRPC.
 *           Uses CoreSimulator HID injection, no TCC/Accessibility needed.
 *   axe   - cameroncooke/AXe, HID injection through private frameworks.
 *   apple - AppleScript + optional cliclick against Simulator.app. Requires
 *           the Accessibility TCC grant, which hosted runners may not have.
 */

const { execFile } = require('child_process');

function run(cmd, args, timeout = 20000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({
        ok: !err,
        code: err ? (typeof err.code === 'number' ? err.code : 1) : 0,
        stdout: String(stdout || ''),
        stderr: String(stderr || ''),
        command: `${cmd} ${args.join(' ')}`.slice(0, 400),
      });
    });
  });
}

function which(cmd) {
  return run('/usr/bin/env', ['sh', '-c', `command -v ${cmd} >/dev/null 2>&1 && command -v ${cmd}`], 5000).then((r) =>
    r.ok ? r.stdout.trim().split('\n')[0] : null
  );
}

const APPLE_SCRIPT = '/usr/bin/osascript';

async function simctlScreenshotPixels(udid, file) {
  const r = await run('xcrun', ['simctl', 'io', udid, 'screenshot', '--type=png', file], 30000);
  if (!r.ok) return null;
  const s = await run('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', file]);
  const w = /pixelWidth:\s*(\d+)/.exec(s.stdout);
  const h = /pixelHeight:\s*(\d+)/.exec(s.stdout);
  if (!w || !h) return null;
  return { width: Number(w[1]), height: Number(h[1]) };
}

/** Fallback point-size table for devices whose accessibility tree is unavailable. */
function scaleForDevice(name) {
  if (/iPhone (SE|11|XR)/i.test(name)) return 2;
  return 3;
}

/* ------------------------------------------------------------------ idb --- */

class IdbDriver {
  constructor(udid) {
    this.udid = udid;
    this.name = 'idb';
  }
  base(args) {
    return ['--udid', this.udid, ...args];
  }
  async probe() {
    const exe = await which('idb');
    if (!exe) return { ok: false, reason: 'idb CLI not installed' };
    const r = await run('idb', this.base(['ui', 'describe-all']), 25000);
    if (!r.ok) return { ok: false, reason: `idb describe-all failed: ${(r.stderr || r.stdout).slice(0, 300)}` };
    return { ok: true, detail: 'idb companion reachable' };
  }
  tap(x, y) {
    return run('idb', this.base(['ui', 'tap', String(Math.round(x)), String(Math.round(y))]));
  }
  swipe(x1, y1, x2, y2, ms) {
    return run('idb', this.base(['ui', 'swipe', String(Math.round(x1)), String(Math.round(y1)),
      String(Math.round(x2)), String(Math.round(y2)), '--duration', String(Math.max(0.05, (ms || 250) / 1000))]));
  }
  text(txt) {
    return run('idb', this.base(['ui', 'text', txt]), 30000);
  }
  key(keys) {
    return run('idb', this.base(['ui', 'key', keys]));
  }
  home() {
    return run('idb', this.base(['ui', 'button', 'HOME']));
  }
  rotate() {
    // idb has no rotation command; the reader falls back to view rotation.
    return Promise.resolve({ ok: false, code: 1, stderr: 'rotation not supported by idb', command: 'idb ui rotate' });
  }
  async pointSize() {
    const r = await run('idb', this.base(['ui', 'describe-all', '--json']), 25000);
    if (r.ok) {
      try {
        const data = JSON.parse(r.stdout);
        let w = 0;
        let h = 0;
        const walk = (n) => {
          if (!n || typeof n !== 'object') return;
          const f = n.frame || n.AXFrame;
          if (f && typeof f.width === 'number') {
            w = Math.max(w, f.x + f.width);
            h = Math.max(h, f.y + f.height);
          }
          const kids = n.children || n.AXChildren || [];
          if (Array.isArray(kids)) kids.forEach(walk);
        };
        (Array.isArray(data) ? data : [data]).forEach(walk);
        if (w > 100 && h > 100) return { width: Math.round(w), height: Math.round(h) };
      } catch (_) { /* fall through */ }
    }
    return null;
  }
}

/* ------------------------------------------------------------------ axe --- */

class AxeDriver {
  constructor(udid) {
    this.udid = udid;
    this.name = 'axe';
  }
  base(args) {
    return ['--udid', this.udid, ...args];
  }
  async probe() {
    const exe = await which('axe');
    if (!exe) return { ok: false, reason: 'axe CLI not installed' };
    const r = await run('axe', this.base(['describe-ui']), 25000);
    if (!r.ok) return { ok: false, reason: `axe describe-ui failed: ${(r.stderr || r.stdout).slice(0, 300)}` };
    return { ok: true, detail: 'axe reachable' };
  }
  tap(x, y) {
    return run('axe', this.base(['tap', '-x', String(Math.round(x)), '-y', String(Math.round(y))]));
  }
  swipe(x1, y1, x2, y2, ms) {
    return run('axe', this.base(['swipe', '--start-x', String(Math.round(x1)), '--start-y', String(Math.round(y1)),
      '--end-x', String(Math.round(x2)), '--end-y', String(Math.round(y2)),
      '--duration', String((ms || 250) / 1000)]));
  }
  text(txt) {
    return run('axe', this.base(['type', txt]), 30000);
  }
  key(keys) {
    return run('axe', this.base(['key', keys]));
  }
  home() {
    return run('axe', this.base(['button', 'home']));
  }
  rotate() {
    return Promise.resolve({ ok: false, code: 1, stderr: 'rotation not supported by axe', command: 'axe rotate' });
  }
}

/* --------------------------------------------------------- AppleScript --- */

class AppleDriver {
  constructor() {
    this.name = 'applescript';
    this.bounds = null;
  }
  async osa(lines) {
    const args = [];
    for (const l of lines) args.push('-e', l);
    return run(APPLE_SCRIPT, args, 20000);
  }
  async probe() {
    if (process.platform !== 'darwin') return { ok: false, reason: 'not macOS' };
    const r = await this.windowBounds();
    if (!r) {
      return { ok: false, reason: 'Simulator window not reachable (Accessibility permission missing or no GUI session)' };
    }
    return { ok: true, detail: `Simulator window at ${r.x},${r.y} ${r.width}x${r.height}` };
  }
  async windowBounds() {
    const r = await this.osa([
      'tell application "System Events"',
      '  tell process "Simulator"',
      '    set p to position of window 1',
      '    set s to size of window 1',
      '    return (item 1 of p as string) & "," & (item 2 of p as string) & "," & (item 1 of s as string) & "," & (item 2 of s as string)',
      '  end tell',
      'end tell',
    ]);
    if (!r.ok) return null;
    const parts = r.stdout.trim().split(',').map(Number);
    if (parts.length !== 4 || parts.some((n) => Number.isNaN(n))) return null;
    // The device screen sits below the window title bar.
    const TITLE = 28;
    return { x: parts[0], y: parts[1] + TITLE, width: parts[2], height: Math.max(1, parts[3] - TITLE) };
  }
  async click(px, py) {
    const b = await this.windowBounds();
    if (!b) return { ok: false, code: 1, stderr: 'Simulator window unavailable' };
    const cliclick = await which('cliclick');
    if (cliclick) {
      const r = await run(cliclick, ['c:' + Math.round(b.x + px), ',' + Math.round(b.y + py)]);
      if (r.ok) return r;
    }
    return this.osa([
      'tell application "Simulator" to activate',
      'tell application "System Events"',
      `  click at {${Math.round(b.x + px)}, ${Math.round(b.y + py)}}`,
      'end tell',
    ]);
  }
  tap(x, y) {
    return this.click(x, y);
  }
  async swipe(x1, y1, x2, y2) {
    const b = await this.windowBounds();
    if (!b) return { ok: false, code: 1, stderr: 'Simulator window unavailable' };
    const cliclick = await which('cliclick');
    if (!cliclick) return { ok: false, code: 1, stderr: 'cliclick not installed; swipe needs cliclick' };
    const steps = 12;
    const lines = [`${Math.round(b.x + x1)},${Math.round(b.y + y1)}`];
    for (let i = 1; i <= steps; i += 1) {
      const t = i / steps;
      lines.push(`dd:${Math.round(b.x + x1 + (x2 - x1) * t)},${Math.round(b.y + y1 + (y2 - y1) * t)}`);
      lines.push('w:12');
    }
    lines.push('du:' + `${Math.round(b.x + x2)},${Math.round(b.y + y2)}`);
    return run(cliclick, lines);
  }
  text(txt) {
    return this.osa([
      'tell application "Simulator" to activate',
      'tell application "System Events"',
      `  keystroke ${JSON.stringify(txt)}`,
      'end tell',
    ]);
  }
  key(keys) {
    return this.osa([
      'tell application "Simulator" to activate',
      'tell application "System Events"',
      `  key code ${Number(keys) || 0}`,
      'end tell',
    ]);
  }
  home() {
    return this.osa([
      'tell application "Simulator" to activate',
      'tell application "System Events"',
      '  keystroke "h" using {command down, shift down}',
      'end tell',
    ]);
  }
  rotate(dir) {
    const item = dir === 'left' ? 'Rotate Left' : 'Rotate Right';
    return this.osa([
      'tell application "Simulator" to activate',
      'tell application "System Events"',
      '  tell process "Simulator"',
      `    click menu item "${item}" of menu "Device" of menu bar 1`,
      '  end tell',
      'end tell',
    ]);
  }
}

/**
 * Build the best available driver for a booted simulator.
 * `preferred` (env INPUT_DRIVER) pins one backend when set.
 */
async function createDriver({ udid, preferred } = {}) {
  const candidates = [];
  if (!preferred || preferred === 'idb') candidates.push(() => new IdbDriver(udid));
  if (!preferred || preferred === 'axe') candidates.push(() => new AxeDriver(udid));
  if (!preferred || preferred === 'applescript') candidates.push(() => new AppleDriver());

  const attempts = [];
  for (const make of candidates) {
    const driver = make();
    let probe;
    try {
      probe = await driver.probe();
    } catch (err) {
      probe = { ok: false, reason: String(err && err.message) };
    }
    attempts.push({ driver: driver.name, ...probe });
    if (probe.ok) return { driver, attempts, reason: null };
  }
  const nullDriver = {
    name: 'none',
    tap: () => Promise.resolve({ ok: false, code: 1, stderr: 'no input driver available' }),
    swipe: () => Promise.resolve({ ok: false, code: 1, stderr: 'no input driver available' }),
    text: () => Promise.resolve({ ok: false, code: 1, stderr: 'no input driver available' }),
    key: () => Promise.resolve({ ok: false, code: 1, stderr: 'no input driver available' }),
    home: () => Promise.resolve({ ok: false, code: 1, stderr: 'no input driver available' }),
    rotate: () => Promise.resolve({ ok: false, code: 1, stderr: 'no input driver available' }),
  };
  return { driver: nullDriver, attempts, reason: 'no usable input driver' };
}

module.exports = {
  createDriver,
  run,
  which,
  simctlScreenshotPixels,
  scaleForDevice,
  IdbDriver,
  AxeDriver,
  AppleDriver,
};
