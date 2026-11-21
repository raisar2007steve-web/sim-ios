#!/usr/bin/env node
'use strict';
/**
 * Touch self-test: prove whether injected input actually reaches the simulator
 * framebuffer. Captures a screenshot, performs a gesture through the selected
 * input driver, captures again, and compares the pixel data.
 *
 * A screen change means the input path works. No change means the viewer must
 * be presented as view-only rather than claiming interaction works.
 */

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const drivers = require('../../remote-viewer/drivers');

const SESSION_DIR = process.env.SESSION_DIR || path.join(process.cwd(), '.session');

function run(cmd, args, timeout = 30000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) =>
      resolve({ ok: !err, stdout: String(stdout || ''), stderr: String(stderr || '') })
    );
  });
}

function stateGet(key, fallback = '') {
  try {
    const raw = fs.readFileSync(path.join(SESSION_DIR, 'state.env'), 'utf8');
    const line = raw.split('\n').filter((l) => l.startsWith(`${key}=`)).pop();
    return line ? line.slice(key.length + 1) : fallback;
  } catch (_) {
    return fallback;
  }
}

const udid = process.env.UDID || stateGet('UDID');
const deviceName = process.env.DEVICE_NAME || stateGet('DEVICE_NAME');
const bundleId = process.env.BUNDLE_ID || stateGet('BUNDLE_ID');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function shot(tag) {
  const file = path.join(SESSION_DIR, `selftest-${tag}.png`);
  const r = await run('xcrun', ['simctl', 'io', udid, 'screenshot', '--type=png', file]);
  if (!r.ok) return null;
  const h = await run('shasum', ['-a', '256', file]);
  return { file, hash: h.stdout.trim().split(/\s+/)[0] || null };
}

(async () => {
  const capability = {
    touch: false,
    touchVerified: false,
    keyboard: false,
    rotate: 'view',
    home: false,
    driver: 'none',
    driverAttempts: [],
    note: '',
  };

  if (!udid) {
    capability.note = 'No simulator UDID available; input self-test skipped.';
    fs.writeFileSync(path.join(SESSION_DIR, 'capability.json'), JSON.stringify(capability, null, 2));
    console.log(JSON.stringify(capability, null, 2));
    process.exit(0);
  }

  const { driver, attempts, reason } = await drivers.createDriver({
    udid,
    preferred: process.env.INPUT_DRIVER || '',
  });
  capability.driverAttempts = attempts;
  capability.driver = driver.name;

  if (driver.name === 'none') {
    capability.note = `No input driver available on this runner (${reason}). The viewer is live but view-only; taps and keys cannot be injected.`;
    fs.writeFileSync(path.join(SESSION_DIR, 'capability.json'), JSON.stringify(capability, null, 2));
    console.log(JSON.stringify(capability, null, 2));
    process.exit(0);
  }

  const pointSize = await (async () => {
    try {
      const pts = driver.pointSize ? await driver.pointSize() : null;
      if (pts) return pts;
    } catch (_) { /* ignore */ }
    const px = await drivers.simctlScreenshotPixels(udid, path.join(SESSION_DIR, 'selftest-probe.png'));
    const scale = drivers.scaleForDevice(deviceName || 'iPhone');
    return px ? { width: px.width / scale, height: px.height / scale } : { width: 393, height: 852 };
  })();

  capability.pointSize = pointSize;

  const before = await shot('before');
  const gesture = await driver.swipe(pointSize.width * 0.5, pointSize.height * 0.97,
    pointSize.width * 0.5, pointSize.height * 0.45, 320);
  await wait(1500);
  const afterSwipe = await shot('after-swipe');
  const swipeWorked = !!(before && afterSwipe && before.hash && afterSwipe.hash && before.hash !== afterSwipe.hash);

  let tapWorked = false;
  let tapResult = null;
  if (!swipeWorked) {
    tapResult = await driver.tap(pointSize.width * 0.5, pointSize.height * 0.45);
    await wait(1200);
    const afterTap = await shot('after-tap');
    tapWorked = !!(afterSwipe && afterTap && afterSwipe.hash && afterTap.hash && afterSwipe.hash !== afterTap.hash);
  }

  capability.touch = true;
  capability.touchVerified = swipeWorked || tapWorked;
  capability.keyboard = true;
  capability.home = true;
  capability.rotate = driver.name === 'applescript' ? 'device' : 'view';
  capability.method = swipeWorked ? 'swipe' : tapWorked ? 'tap' : 'none';
  capability.evidence = {
    swipeCommandOk: !!gesture.ok,
    swipeError: gesture.ok ? null : String(gesture.stderr || '').slice(0, 300),
    tapCommandOk: tapResult ? !!tapResult.ok : null,
    tapError: tapResult && !tapResult.ok ? String(tapResult.stderr || '').slice(0, 300) : null,
  };

  if (!capability.touchVerified) {
    capability.note = `Driver "${driver.name}" accepted the gesture but the simulator screen did not change, so interaction is not confirmed. The viewer is presented as unverified/limited.`;
  } else {
    capability.note = `Injected input confirmed via ${capability.method}; the simulator screen changed after the gesture.`;
  }

  // Restore the app to the foreground after the test gesture.
  if (bundleId) {
    await run('xcrun', ['simctl', 'launch', udid, bundleId]);
  }

  fs.writeFileSync(path.join(SESSION_DIR, 'capability.json'), JSON.stringify(capability, null, 2));
  console.log(JSON.stringify(capability, null, 2));
  process.exit(0);
})().catch((err) => {
  const capability = {
    touch: false,
    touchVerified: false,
    keyboard: false,
    rotate: 'view',
    home: false,
    driver: 'none',
    driverAttempts: [],
    note: `Input self-test crashed: ${String(err && err.message ? err.message : err)}`,
  };
  try {
    fs.writeFileSync(path.join(SESSION_DIR, 'capability.json'), JSON.stringify(capability, null, 2));
  } catch (_) { /* ignore */ }
  console.log(JSON.stringify(capability, null, 2));
  process.exit(0);
});
