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
  constructor(udid = '') {
    this.name = 'applescript';
    this.udid = udid;
    this.bounds = null;
    this.boundsAt = 0;
    // Device point size, used to map device coordinates onto the on-screen
    // Simulator window (which is scaled to whatever the runner's display is).
    this.deviceSize = null;
  }
  setDeviceSize(size) {
    if (size && size.width > 0 && size.height > 0) {
      this.deviceSize = { width: size.width, height: size.height };
    }
  }
  toScreen(bounds, x, y) {
    const dw = this.deviceSize ? this.deviceSize.width : 440;
    const dh = this.deviceSize ? this.deviceSize.height : 956;
    return {
      x: Math.round(bounds.x + (x / dw) * bounds.width),
      y: Math.round(bounds.y + (y / dh) * bounds.height),
    };
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
  /** Read the Simulator window rectangle straight from the accessibility API. */
  async readBounds() {
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
    // Derive the title-bar height from the window/device aspect ratio instead of
    // assuming a fixed chrome size: the window is wider than the screen is tall
    // only by whatever chrome it has.
    const dw = this.deviceSize ? this.deviceSize.width : 440;
    const dh = this.deviceSize ? this.deviceSize.height : 956;
    const winH = parts[3];
    const contentH = Math.min(winH, Math.round(parts[2] * (dh / dw)));
    const chrome = Math.max(0, winH - contentH);
    return { x: parts[0], y: parts[1] + chrome, width: parts[2], height: Math.max(1, contentH) };
  }
  /**
   * Bounds with recovery: a long session can lose the Simulator window (app
   * closed, device switch, display change), so reopen the app and retry rather
   * than failing every tap with "window unavailable".
   */
  async windowBounds(force = false) {
    if (!force && this.bounds && Date.now() - this.boundsAt < 2000) return this.bounds;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const b = await this.readBounds();
      if (b && b.width > 10 && b.height > 10) {
        this.bounds = b;
        this.boundsAt = Date.now();
        return b;
      }
      const args = ['-a', 'Simulator'];
      if (this.udid) args.push('--args', '-CurrentDeviceUDID', this.udid);
      await run('open', args, 10000);
      await run(APPLE_SCRIPT, ['-e', 'tell application "Simulator" to activate'], 8000);
      await new Promise((r) => setTimeout(r, 1500));
    }
    this.bounds = null;
    return null;
  }
  async click(deviceX, deviceY) {
    const b = await this.windowBounds(true);
    if (!b) {
      return {
        ok: false,
        code: 1,
        stderr: 'Simulator window unavailable: the app could not be opened on this runner (no GUI session or Accessibility permission missing)',
      };
    }
    const pt = this.toScreen(b, deviceX, deviceY);
    const cliclick = await which('cliclick');
    if (cliclick) {
      const r = await run(cliclick, ['c:' + pt.x, ',' + pt.y]);
      if (r.ok) return r;
    }
    return this.osa([
      'tell application "Simulator" to activate',
      'tell application "System Events"',
      `  click at {${pt.x}, ${pt.y}}`,
      'end tell',
    ]);
  }
  tap(x, y) {
    return this.click(x, y);
  }
  async swipe(x1, y1, x2, y2) {
    const b = await this.windowBounds(true);
    if (!b) {
      return {
        ok: false,
        code: 1,
        stderr: 'Simulator window unavailable: the app could not be opened on this runner (no GUI session or Accessibility permission missing)',
      };
    }
    const cliclick = await which('cliclick');
    if (!cliclick) return { ok: false, code: 1, stderr: 'cliclick not installed; swipe needs cliclick' };
    const from = this.toScreen(b, x1, y1);
    const to = this.toScreen(b, x2, y2);
    const steps = 14;
    const lines = [`dd:${from.x},${from.y}`];
    for (let i = 1; i <= steps; i += 1) {
      const t = i / steps;
      lines.push(`dm:${Math.round(from.x + (to.x - from.x) * t)},${Math.round(from.y + (to.y - from.y) * t)}`);
      lines.push('w:10');
    }
    lines.push(`du:${to.x},${to.y}`);
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
  if (!preferred || preferred === 'applescript') candidates.push(() => new AppleDriver(udid));

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
