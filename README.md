# Remote iOS Simulator on GitHub Actions

A GitHub-hosted macOS runner boots a real iPhone Simulator, builds your app into
it, captures its framebuffer through Apple's native tools, and serves that screen
to a browser over an authenticated temporary HTTPS URL. Nothing runs on your own
machine, and nothing is simulated in the browser: the pixels come from
`xcrun simctl io <udid> screenshot` on the runner.

![architecture](#architecture)

## What it does

1. **Detects the environment** — macOS build, CPU architecture, every installed
   Xcode, the active developer directory, the newest *stable* Xcode, all iOS
   Simulator runtimes and all available devices. Nothing is hard-coded.
2. **Selects and boots a simulator** — newest stable iOS runtime, newest
   available iPhone (or the device name you pass in), `simctl boot` +
   `bootstatus`, then `open -a Simulator`. The framebuffer is screenshotted to
   prove the device is responsive.
3. **Builds your app** — finds `.xcworkspace`, `.xcodeproj` or a Swift package,
   resolves dependencies, picks a runnable scheme, builds for the booted
   simulator, installs and launches it, and records the PID. If the repository
   contains no iOS application source, a small built-in SwiftUI demo app is
   compiled with `swiftc` instead (see [No app in the repo](#no-app-in-the-repo)).
4. **Streams the screen** — a dependency-free Node server polls the simulator
   framebuffer, downscales with `sips`, and pushes JPEG frames over a WebSocket.
5. **Injects input** — taps, swipes, text, Return and Home are mapped onto the
   best input driver available on the runner (`idb`, `AXe`, or AppleScript).
6. **Publishes an HTTPS URL** — Cloudflare Tunnel (quick tunnel by default, named
   tunnel or ngrok if you provide secrets). Only the authenticated HTTP endpoint
   is exposed; no VNC or control port is ever opened.
7. **Verifies itself** — 401 without a token, 200 with one, a real JPEG frame over
   `wss://`, and a screenshot diff that proves whether injected touch reached the
   simulator.
8. **Cleans up** — services stopped, simulator shut down, credential deleted, logs
   preserved as an artifact.

## Architecture

```
GitHub Actions (macos-latest)
┌──────────────────────────────────────────────────────────────┐
│  Xcode + iOS Simulator                                       │
│    xcrun simctl boot / install / launch                      │
│    xcrun simctl io <udid> screenshot  ──► JPEG frames        │
│                                   │                          │
│  input driver (idb | AXe | AppleScript)  ◄── tap / swipe / key│
│                                   │                          │
│  remote-viewer/server.js  (HTTP + WebSocket, token auth)     │
│         │                                                    │
│  cloudflared quick tunnel  ──► https://xxxx.trycloudflare.com│
└──────────────────────────────────────────────────────────────┘
                 │  HTTPS + WSS
        Browser (Windows / macOS / Linux)
```

## Quick start

1. Make sure this workflow is on the default branch of your repository and that
   Actions is enabled.
2. *(Optional)* add repository secrets — the workflow works without them:
   | Secret | Purpose |
   | --- | --- |
   | `CLOUDFLARED_TUNNEL_TOKEN` | Run behind a named Cloudflare tunnel instead of a random quick-tunnel URL |
   | `TUNNEL_HOSTNAME` | Public hostname of that named tunnel, e.g. `sim.example.com` (this becomes the permanent address) |
   | `NGROK_AUTHTOKEN` | Fall back to ngrok if Cloudflare is unavailable |
3. Actions → **iOS Simulator Live** → *Run workflow*.
4. Wait for the *Publish connection info and keep session alive* step; the URL is
   in the run's **Summary** tab (it includes the session token) and in the
   `ios-simulator-diagnostics` artifact as `session-access.txt`.
5. Open it on any device. The session ends automatically when the run ends.

### Workflow inputs

| Input | Default | Notes |
| --- | --- | --- |
| `device` | *(blank)* | Case-insensitive device name, e.g. `iPhone 16 Pro`. Blank picks the newest available iPhone in the newest stable runtime. |
| `duration_minutes` | `30` | Clamped to 1–240. The job timeout is 280 minutes. |
| `frame_rate` | `6` | 1–15 fps. Higher is smoother and uses more bandwidth. |
| `run_tests` | `false` | Runs `xcodebuild test` for the scheme (15 minute cap). |
| `install_input_driver` | `true` | Installs `idb`/`AXe`/`cliclick`. Adds a few minutes; set `false` for a view-only session. |

## Interaction: what is real and what is not

The simulator *screen* is always genuinely live. Input depends on what the runner
lets a process inject:

| Driver | Mechanism | Needs |
| --- | --- | --- |
| `idb` | CoreSimulator HID injection (`idb ui tap/swipe/text`) | `idb-companion` + `fb-idb` |
| `AXe` | HID injection through private frameworks | `axe` CLI |
| AppleScript | GUI events on `Simulator.app`, optional `cliclick` | Accessibility (TCC) grant |

The workflow never claims interaction works — it *tests* it. `touch-selftest.js`
screenshots the simulator, injects a swipe (falling back to a tap), screenshots
again and compares hashes. Only a screen change marks touch as **verified**; the
viewer shows *View only*, *unverified* or *Interactive · verified* accordingly,
and the job summary says which it was.

Known limits:

- **Rotation** is device rotation only with the AppleScript driver. With `idb`/
  `AXe` the viewer rotates the canvas locally and says so.
- **Text input** is injected as text (not per-keystroke), so the on-screen
  keyboard never animates.
- Stream latency is bounded by the capture loop (`simctl io screenshot` per
  frame), typically 6–10 fps at 750 px wide. This is a framebuffer stream, not a
  hardware video encoder.

## Files

```
.github/workflows/ios-simulator-live.yml   manual workflow (macos-latest)
scripts/ios-simulator/
  lib.sh                 shared state/summary helpers
  init-session.sh        input validation, session token, expiry
  detect-environment.sh  macOS/Xcode/runtime detection, stable selection
  boot-simulator.sh      device selection, boot, Simulator.app, liveness check
  build-and-launch.sh    project detection, build, install, launch, optional tests
  demo-app/              built-in SwiftUI fallback app (swiftc, no .xcodeproj)
  setup-input-driver.sh  installs idb/AXe/cliclick
  start-viewer.sh        starts the streaming server
  start-tunnel.sh        Cloudflare quick/named tunnel, ngrok fallback
  verify-session.sh      auth + stream + input verification
  verify-stream.js       WSS frame check against the public URL
  touch-selftest.js      screenshot-diff proof of injected input
  keepalive.sh           publishes the URL, holds the session open
  write-summary.sh       final job summary
  cleanup.sh             stops everything, deletes the credential
remote-viewer/           streaming server + browser viewer
README.md                this file
SECURITY.md              access model and credential handling
```

## A permanent address with a named Cloudflare tunnel

A quick tunnel (`*.trycloudflare.com`) is random and dies with the job. For a
single address that stays the same across every session, create a named tunnel
once in the Cloudflare dashboard:

1. Cloudflare Zero Trust → **Networks → Tunnels → Create a tunnel** (type
   *Cloudflared*), copy the **tunnel token**.
2. In that tunnel add a **Public Hostname** for a domain you control, service
   `http://localhost:8080` (the viewer port).
3. Add repository secrets: `CLOUDFLARED_TUNNEL_TOKEN` (the token) and
   `TUNNEL_HOSTNAME` (e.g. `sim.example.com`).

From then on `start-tunnel.sh` tries the named tunnel **first**, so every run is
published at `https://$TUNNEL_HOSTNAME` — the same URL every time, with the
session token still required on top of it. The random quick tunnel remains the
fallback when those secrets are absent, and localhost.run/ngrok back it up.

What "always available" can and cannot mean here: the address is permanent, but
the thing behind it exists only while a workflow run is alive, because GitHub
hosts macOS runners per job and bills per minute. So the URL is stable and
reused; the stream is live whenever a session is running. For a genuinely 24/7
stream you need a machine that stays up (a self-hosted macOS runner registered
to this repository and kept online, reached through the same named tunnel) — the
viewer, scripts and tunnel are unchanged, only the runner's lifetime differs.

## Persistent device state (save and resume)

A GitHub-hosted runner is destroyed after the job, so the simulator is saved off
the runner and restored into the **same device** on the next session:

- `scripts/ios-simulator/save-state.sh` shuts the device down and archives
  `~/Library/Developer/CoreSimulator/Devices/<UDID>` (OS state, every app
  container, preferences) into `$RUNNER_TEMP/sim-state/device-state.tar.gz`,
  with disposable caches, logs and tmp excluded. It also writes
  `state-marker.txt` into the app's data container.
- The workflow persists that directory with `actions/cache/save` under the fixed
  prefix `ios-sim-state-`, and restores the newest matching entry with
  `actions/cache/restore` (`restore-keys: ios-sim-state-`) before booting.
- `scripts/ios-simulator/restore-state.sh` unpacks the archive back into the
  simulator directory and hands the saved UDID to `boot-simulator.sh`, which
  boots that device instead of creating a new one.
- `build-and-launch.sh` looks for `state-marker.txt` in the app container and
  reports `Restored app data: yes (saved-by-run …)` in the job summary, so the
  restore is proven rather than assumed.

All state lives in one fixed place (the repository's Actions cache under
`ios-sim-state-`), so every run resumes the most recent device. Set
`persist_state: false` to start clean. Notes:

- Caches are keyed by runner OS and the archive is skipped above 4.5 GB; a saved
  device that this Xcode/runtime set cannot see is ignored with a warning and a
  fresh device is used instead, so a stale state never breaks a session.
- Simulator app data can contain personal or secret material. On a **public**
  repository, Actions caches are readable by anyone with repository read access —
  keep credentials out of the simulator, or use a private repository.
- Cache entries are immutable: each run writes a new key and restoration picks the
  newest prefixed entry, which is what makes "resume where you left off" work.

## Local preview of the viewer UI

The viewer runs without a simulator, rendering a clearly-labelled demo screen:

```bash
cd remote-viewer
npm install
SIM_MOCK=1 PORT=3000 node server.js
# open http://localhost:3000
```

In mock mode the UI shows `DEMO PREVIEW · NO SIMULATOR ATTACHED`; nothing is
streamed or injected. This is only for working on the interface.

## No app in the repo

If no `.xcworkspace`, `.xcodeproj` or `Package.swift` is found, the workflow
compiles `scripts/ios-simulator/demo-app/SimulatorDemo.swift` with `swiftc` for
the simulator SDK, assembles a `.app` bundle around it, installs and launches it.
The summary reports `Source: built-in demo app — the repository contains no iOS
application source`, so the real build status is never overstated. Add your own
project (or a scheme) and it is detected first.

## Troubleshooting

| Symptom | Where to look |
| --- | --- |
| `No available iOS Simulator runtime` | Runner image has no iOS runtime installed; pick another `runs-on` image. |
| `No Xcode scheme could be resolved` | `artifacts/xcodebuild-list.json`. Schemes must be shared. |
| `xcodebuild build failed` | `artifacts/xcodebuild-build.log`. |
| App launches then disappears | `artifacts/launch.log`; the app may crash on startup. |
| `does not answer framebuffer capture` | Simulator boot failure; `artifacts/bootstatus.log`. |
| `Could not start an HTTPS tunnel` | `artifacts/tunnel.log`; outbound network blocked or tunnel quota. |
| `No live frames were delivered` | `artifacts/stream-check.log` and `artifacts/viewer.log`. |
| Viewer connects but shows *View only* | No input driver was usable; see `artifacts/capability.json` (`driverAttempts`). |
| `Touch injection unverified` | The driver accepted gestures but the screen did not change; the runner blocks synthetic input. |

Every failure is fatal for the *session* (not silently ignored): the summary and
the artifact carry the reason.

## Cost

A 30-minute session uses roughly 30 runner minutes on a macOS runner, plus
2–6 minutes for Xcode/simulator/tooling setup. Long sessions are billed for the
whole run because the runner must stay alive to serve the stream.
