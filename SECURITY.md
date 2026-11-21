# Security model

This project exposes a real macOS session on a public GitHub-hosted runner to a
browser somewhere on the internet. That is deliberate, and it is scoped.

## What is exposed

- **Only** the viewer's HTTPS endpoint (`/`, static assets, `/api/status`,
  `/api/snapshot.jpg`, `/ws`) through a tunnel.
- **Nothing else.** No VNC, no RFB, no screen-sharing port, no SSH, no raw
  WebSocket without an HTTP origin. The streaming server binds `0.0.0.0:8080`
  *inside the runner*, and the only path in from the internet is the tunnel. The
  tunnel is a Cloudflare quick tunnel (or your own named tunnel / ngrok) that
  proxies the single HTTP port; no other port is published.
- `/api/health` is unauthenticated on purpose: it returns `{ok, mock, uptime}`
  and nothing about the device, the app or the session.

## Authentication

- At session start `init-session.sh` generates a 48-hex-character random token
  from `openssl rand -hex 24`.
- Every request except `/api/health` and the health probe requires it, via
  `?token=`, an `Authorization: Bearer` header, or the `sim_session` cookie.
- Loading `/?token=...` sets an `HttpOnly; Secure; SameSite=Strict` cookie so
  asset and WebSocket requests authenticate without putting the token in
  history again.
- The WebSocket upgrade is authenticated *before* the handshake completes;
  unauthenticated upgrades get `401`.
- The workflow registers the token with `::add-mask::`, so it cannot appear in
  workflow logs. It is written to the job summary and to
  `artifacts/session-access.txt` (uploaded with the run's diagnostics artifact)
  because that is how you retrieve the URL; both are reachable only by people
  who can read the repository's Actions output. **On a public repository, Actions
  output is public**, so treat a session on a public repo as publicly viewable
  for the duration of the run.
- Unauthenticated requests are checked during verification: the run **fails**
  if `/` does not return `401` without a token.

Anyone who can read the workflow run's summary (repository collaborators, or
anyone you share it with) can access the session. Treat the URL as a credential.

## Credentials and secrets

- Repository secrets are optional. `CLOUDFLARED_TUNNEL_TOKEN`,
  `TUNNEL_HOSTNAME` and `NGROK_AUTHTOKEN` are passed only to the tunnel step as
  environment variables, are never echoed, and are never written to the
  workspace.
- No secret is committed to the repository. `.gitignore` excludes `.session/`,
  `artifacts/`, `build/` and `node_modules/`.
- The session token is deleted by `cleanup.sh` (`rm -f .session/state.env`), and
  only non-sensitive JSON is uploaded as an artifact.
- Do not paste tokens, tunnel credentials or access URLs into issues, chats or
  pull requests.

## Lifetime

- The session is bounded by `duration_minutes` (default 30, maximum 240) and by
  the job's 280-minute timeout.
- When the run ends, `cleanup.sh` runs with `if: always()`: the viewer and tunnel
  processes are terminated, the simulator is shut down, and the token file is
  removed. The tunnel URL stops resolving; the token is worthless afterwards.
- Cancelling the run performs the same cleanup.

## Hardening you may want

- Use a **named** Cloudflare tunnel plus Cloudflare Access (or your own reverse
  proxy with SSO) and pass `CLOUDFLARED_TUNNEL_TOKEN` + `TUNNEL_HOSTNAME`. The
  viewer token remains a second factor.
- Restrict who can run workflows (Actions → General → Workflow permissions) if
  runner minutes and simulator sessions are sensitive.
- Shorten `duration_minutes` to reduce the window in which a leaked URL works.
- Set `install_input_driver: false` when you only need to watch the screen — a
  view-only session cannot be operated remotely.

## Saved device state

- With `persist_state` enabled, the simulator device directory (app containers,
  preferences, OS state) is archived and stored in the repository's Actions
  cache under `ios-sim-state-`. It is restored by the next run.
- That archive can contain anything you put into the simulator: account tokens,
  test data, screenshots, saved passwords in Safari. Treat it as sensitive.
- Actions caches on a **public** repository are readable by anyone with
  repository read access. Do not keep credentials in the simulator on a public
  repository, or keep the repository private.
- Expired or deleted caches remove the saved state; the workflow never fails
  because state is missing — it starts a fresh device instead.

## What this is not

- Not a multi-tenant service: the runner is destroyed after the job, and nothing
  persists between sessions.
- Not a hardened remote-desktop product: it is a session-scoped viewer for
  testing an iOS app on Apple hardware you do not own locally.
- Not anonymous: Actions logs and summaries record who dispatched the run.

## Reporting

If you find a vulnerability in these scripts, open a private security advisory on
the repository rather than a public issue, and do not include live session URLs
or tokens.
