---
summary: "Gateway WebSocket protocol: handshake, frames, versioning"
read_when:
  - Implementing or updating gateway WS clients
  - Debugging protocol mismatches or connect failures
  - Regenerating protocol schema/models
title: "Gateway Protocol"
---

# Gateway protocol (WebSocket)

The Gateway WS protocol is the **single control plane + node transport** for
OpenClaw. All clients (CLI, web UI, macOS app, iOS/Android nodes, headless
nodes) connect over WebSocket and declare their **role** + **scope** at
handshake time.

## Transport

- WebSocket, text frames with JSON payloads.
- First frame **must** be a `connect` request.

## Handshake (connect)

Gateway → Client (pre-connect challenge):

```json
{
  "type": "event",
  "event": "connect.challenge",
  "payload": { "nonce": "…", "ts": 1737264000000 }
}
```

Client → Gateway:

```json
{
  "type": "req",
  "id": "…",
  "method": "connect",
  "params": {
    "minProtocol": 3,
    "maxProtocol": 3,
    "client": {
      "id": "cli",
      "version": "1.2.3",
      "platform": "macos",
      "mode": "operator"
    },
    "role": "operator",
    "scopes": ["operator.read", "operator.write"],
    "caps": [],
    "commands": [],
    "permissions": {},
    "auth": { "token": "…" },
    "locale": "en-US",
    "userAgent": "openclaw-cli/1.2.3",
    "device": {
      "id": "device_fingerprint",
      "publicKey": "…",
      "signature": "…",
      "signedAt": 1737264000000,
      "nonce": "…"
    }
  }
}
```

Gateway → Client:

```json
{
  "type": "res",
  "id": "…",
  "ok": true,
  "payload": { "type": "hello-ok", "protocol": 3, "policy": { "tickIntervalMs": 15000 } }
}
```

When a device token is issued, `hello-ok` also includes:

```json
{
  "auth": {
    "deviceToken": "…",
    "role": "operator",
    "scopes": ["operator.read", "operator.write"]
  }
}
```

### Node example

```json
{
  "type": "req",
  "id": "…",
  "method": "connect",
  "params": {
    "minProtocol": 3,
    "maxProtocol": 3,
    "client": {
      "id": "ios-node",
      "version": "1.2.3",
      "platform": "ios",
      "mode": "node"
    },
    "role": "node",
    "scopes": [],
    "caps": ["camera", "canvas", "screen", "location", "voice"],
    "commands": ["camera.snap", "canvas.navigate", "screen.record", "location.get"],
    "permissions": { "camera.capture": true, "screen.record": false },
    "auth": { "token": "…" },
    "locale": "en-US",
    "userAgent": "openclaw-ios/1.2.3",
    "device": {
      "id": "device_fingerprint",
      "publicKey": "…",
      "signature": "…",
      "signedAt": 1737264000000,
      "nonce": "…"
    }
  }
}
```

## Framing

- **Request**: `{type:"req", id, method, params}`
- **Response**: `{type:"res", id, ok, payload|error}`
- **Event**: `{type:"event", event, payload, seq?, stateVersion?}`

Side-effecting methods require **idempotency keys** (see schema).

## Roles + scopes

### Roles

- `operator` = control plane client (CLI/UI/automation).
- `node` = capability host (camera/screen/canvas/system.run).

### Scopes (operator)

Common scopes:

- `operator.read`
- `operator.write`
- `operator.admin`
- `operator.approvals`
- `operator.pairing`

Method scope is only the first gate. Some slash commands reached through
`chat.send` apply stricter command-level checks on top. For example, persistent
`/config set` and `/config unset` writes require `operator.admin`.

### Caps/commands/permissions (node)

Nodes declare capability claims at connect time:

- `caps`: high-level capability categories.
- `commands`: command allowlist for invoke.
- `permissions`: granular toggles (e.g. `screen.record`, `camera.capture`).

The Gateway treats these as **claims** and enforces server-side allowlists.

## Presence

- `system-presence` returns entries keyed by device identity.
- Presence entries include `deviceId`, `roles`, and `scopes` so UIs can show a single row per device
  even when it connects as both **operator** and **node**.

### Node helper methods

- Nodes may call `skills.bins` to fetch the current list of skill executables
  for auto-allow checks.

### Operator helper methods

- Operators may call `tools.catalog` (`operator.read`) to fetch the runtime tool catalog for an
  agent. The response includes grouped tools and provenance metadata:
  - `source`: `core` or `plugin`
  - `pluginId`: plugin owner when `source="plugin"`
  - `optional`: whether a plugin tool is optional

## Exec approvals

- When an exec request needs approval, the gateway broadcasts `exec.approval.requested`.
- Operator clients resolve by calling `exec.approval.resolve` (requires `operator.approvals` scope).
- For `host=node`, `exec.approval.request` must include `systemRunPlan` (canonical `argv`/`cwd`/`rawCommand`/session metadata). Requests missing `systemRunPlan` are rejected.

## Versioning

- `PROTOCOL_VERSION` lives in `src/gateway/protocol/schema.ts`.
- Clients send `minProtocol` + `maxProtocol`; the server rejects mismatches.
- Schemas + models are generated from TypeBox definitions:
  - `pnpm protocol:gen`
  - `pnpm protocol:gen:swift`
  - `pnpm protocol:check`

## Auth

- If `OPENCLAW_GATEWAY_TOKEN` (or `--token`) is set, `connect.params.auth.token`
  must match or the socket is closed.
- After pairing, the Gateway issues a **device token** scoped to the connection
  role + scopes. It is returned in `hello-ok.auth.deviceToken` and should be
  persisted by the client for future connects.
- Device tokens can be rotated/revoked via `device.token.rotate` and
  `device.token.revoke` (requires `operator.pairing` scope).

## Device identity + pairing

- Nodes should include a stable device identity (`device.id`) derived from a
  keypair fingerprint.
- Gateways issue tokens per device + role.
- Pairing approvals are required for new device IDs unless local auto-approval
  is enabled.
- **Local** connects include loopback and the gateway host’s own tailnet address
  (so same‑host tailnet binds can still auto‑approve).
- All WS clients must include `device` identity during `connect` (operator + node).
  Control UI can omit it **only** when `gateway.controlUi.dangerouslyDisableDeviceAuth`
  is enabled for break-glass use.
- All connections must sign the server-provided `connect.challenge` nonce.

### Device auth migration diagnostics

For legacy clients that still use pre-challenge signing behavior, `connect` now returns
`DEVICE_AUTH_*` detail codes under `error.details.code` with a stable `error.details.reason`.

Common migration failures:

| Message                     | details.code                     | details.reason           | Meaning                                            |
| --------------------------- | -------------------------------- | ------------------------ | -------------------------------------------------- |
| `device nonce required`     | `DEVICE_AUTH_NONCE_REQUIRED`     | `device-nonce-missing`   | Client omitted `device.nonce` (or sent blank).     |
| `device nonce mismatch`     | `DEVICE_AUTH_NONCE_MISMATCH`     | `device-nonce-mismatch`  | Client signed with a stale/wrong nonce.            |
| `device signature invalid`  | `DEVICE_AUTH_SIGNATURE_INVALID`  | `device-signature`       | Signature payload does not match v2 payload.       |
| `device signature expired`  | `DEVICE_AUTH_SIGNATURE_EXPIRED`  | `device-signature-stale` | Signed timestamp is outside allowed skew.          |
| `device identity mismatch`  | `DEVICE_AUTH_DEVICE_ID_MISMATCH` | `device-id-mismatch`     | `device.id` does not match public key fingerprint. |
| `device public key invalid` | `DEVICE_AUTH_PUBLIC_KEY_INVALID` | `device-public-key`      | Public key format/canonicalization failed.         |

Migration target:

- Always wait for `connect.challenge`.
- Sign the v2 payload that includes the server nonce.
- Send the same nonce in `connect.params.device.nonce`.
- Preferred signature payload is `v3`, which binds `platform` and `deviceFamily`
  in addition to device/client/role/scopes/token/nonce fields.
- Legacy `v2` signatures remain accepted for compatibility, but paired-device
  metadata pinning still controls command policy on reconnect.

## TLS + pinning

- TLS is supported for WS connections.
- Clients may optionally pin the gateway cert fingerprint (see `gateway.tls`
  config plus `gateway.remote.tlsFingerprint` or CLI `--tls-fingerprint`).

## Scope

This protocol exposes the **full gateway API** (status, channels, models, chat,
agent, sessions, nodes, approvals, etc.). The exact surface is defined by the
TypeBox schemas in `src/gateway/protocol/schema.ts`.
===WEBCHAT===
---
summary: "Loopback WebChat static host and Gateway WS usage for chat UI"
read_when:
  - Debugging or configuring WebChat access
title: "WebChat"
---

# WebChat (Gateway WebSocket UI)

Status: the macOS/iOS SwiftUI chat UI talks directly to the Gateway WebSocket.

## What it is

- A native chat UI for the gateway (no embedded browser and no local static server).
- Uses the same sessions and routing rules as other channels.
- Deterministic routing: replies always go back to WebChat.

## Quick start

1. Start the gateway.
2. Open the WebChat UI (macOS/iOS app) or the Control UI chat tab.
3. Ensure gateway auth is configured (required by default, even on loopback).

## How it works (behavior)

- The UI connects to the Gateway WebSocket and uses `chat.history`, `chat.send`, and `chat.inject`.
- `chat.history` is bounded for stability: Gateway may truncate long text fields, omit heavy metadata, and replace oversized entries with `[chat.history omitted: message too large]`.
- `chat.inject` appends an assistant note directly to the transcript and broadcasts it to the UI (no agent run).
- Aborted runs can keep partial assistant output visible in the UI.
- Gateway persists aborted partial assistant text into transcript history when buffered output exists, and marks those entries with abort metadata.
- History is always fetched from the gateway (no local file watching).
- If the gateway is unreachable, WebChat is read-only.

## Control UI agents tools panel

- The Control UI `/agents` Tools panel fetches a runtime catalog via `tools.catalog` and labels each
  tool as `core` or `plugin:<id>` (plus `optional` for optional plugin tools).
- If `tools.catalog` is unavailable, the panel falls back to a built-in static list.
- The panel edits profile and override config, but effective runtime access still follows policy
  precedence (`allow`/`deny`, per-agent and provider/channel overrides).

## Remote use

- Remote mode tunnels the gateway WebSocket over SSH/Tailscale.
- You do not need to run a separate WebChat server.

## Configuration reference (WebChat)

Full configuration: [Configuration](/gateway/configuration)

Channel options:

- No dedicated `webchat.*` block. WebChat uses the gateway endpoint + auth settings below.

Related global options:

- `gateway.port`, `gateway.bind`: WebSocket host/port.
- `gateway.auth.mode`, `gateway.auth.token`, `gateway.auth.password`: WebSocket auth (token/password).
- `gateway.auth.mode: "trusted-proxy"`: reverse-proxy auth for browser clients (see [Trusted Proxy Auth](/gateway/trusted-proxy-auth)).
- `gateway.remote.url`, `gateway.remote.token`, `gateway.remote.password`: remote gateway target.
- `session.*`: session storage and main key defaults.
===CONTROL-UI===
---
summary: "Browser-based control UI for the Gateway (chat, nodes, config)"
read_when:
  - You want to operate the Gateway from a browser
  - You want Tailnet access without SSH tunnels
title: "Control UI"
---

# Control UI (browser)

The Control UI is a small **Vite + Lit** single-page app served by the Gateway:

- default: `http://<host>:18789/`
- optional prefix: set `gateway.controlUi.basePath` (e.g. `/openclaw`)

It speaks **directly to the Gateway WebSocket** on the same port.

## Quick open (local)

If the Gateway is running on the same computer, open:

- [http://127.0.0.1:18789/](http://127.0.0.1:18789/) (or [http://localhost:18789/](http://localhost:18789/))

If the page fails to load, start the Gateway first: `openclaw gateway`.

Auth is supplied during the WebSocket handshake via:

- `connect.params.auth.token`
- `connect.params.auth.password`
  The dashboard settings panel lets you store a token; passwords are not persisted.
  The onboarding wizard generates a gateway token by default, so paste it here on first connect.

## Device pairing (first connection)

When you connect to the Control UI from a new browser or device, the Gateway
requires a **one-time pairing approval** — even if you're on the same Tailnet
with `gateway.auth.allowTailscale: true`. This is a security measure to prevent
unauthorized access.

**What you'll see:** "disconnected (1008): pairing required"

**To approve the device:**

```bash
# List pending requests
openclaw devices list

# Approve by request ID
openclaw devices approve <requestId>
```

Once approved, the device is remembered and won't require re-approval unless
you revoke it with `openclaw devices revoke --device <id> --role <role>`. See
[Devices CLI](/cli/devices) for token rotation and revocation.

**Notes:**

- Local connections (`127.0.0.1`) are auto-approved.
- Remote connections (LAN, Tailnet, etc.) require explicit approval.
- Each browser profile generates a unique device ID, so switching browsers or
  clearing browser data will require re-pairing.

## Language support

The Control UI can localize itself on first load based on your browser locale, and you can override it later from the language picker in the Access card.

- Supported locales: `en`, `zh-CN`, `zh-TW`, `pt-BR`, `de`, `es`
- Non-English translations are lazy-loaded in the browser.
- The selected locale is saved in browser storage and reused on future visits.
- Missing translation keys fall back to English.

## What it can do (today)

- Chat with the model via Gateway WS (`chat.history`, `chat.send`, `chat.abort`, `chat.inject`)
- Stream tool calls + live tool output cards in Chat (agent events)
- Channels: WhatsApp/Telegram/Discord/Slack + plugin channels (Mattermost, etc.) status + QR login + per-channel config (`channels.status`, `web.login.*`, `config.patch`)
- Instances: presence list + refresh (`system-presence`)
- Sessions: list + per-session thinking/verbose overrides (`sessions.list`, `sessions.patch`)
- Cron jobs: list/add/edit/run/enable/disable + run history (`cron.*`)
- Skills: status, enable/disable, install, API key updates (`skills.*`)
- Nodes: list + caps (`node.list`)
- Exec approvals: edit gateway or node allowlists + ask policy for `exec host=gateway/node` (`exec.approvals.*`)
- Config: view/edit `~/.openclaw/openclaw.json` (`config.get`, `config.set`)
- Config: apply + restart with validation (`config.apply`) and wake the last active session
- Config writes include a base-hash guard to prevent clobbering concurrent edits
- Config schema + form rendering (`config.schema`, including plugin + channel schemas); Raw JSON editor remains available
- Debug: status/health/models snapshots + event log + manual RPC calls (`status`, `health`, `models.list`)
- Logs: live tail of gateway file logs with filter/export (`logs.tail`)
- Update: run a package/git update + restart (`update.run`) with a restart report

Cron jobs panel notes:

- For isolated jobs, delivery defaults to announce summary. You can switch to none if you want internal-only runs.
- Channel/target fields appear when announce is selected.
- Webhook mode uses `delivery.mode = "webhook"` with `delivery.to` set to a valid HTTP(S) webhook URL.
- For main-session jobs, webhook and none delivery modes are available.
- Advanced edit controls include delete-after-run, clear agent override, cron exact/stagger options,
  agent model/thinking overrides, and best-effort delivery toggles.
- Form validation is inline with field-level errors; invalid values disable the save button until fixed.
- Set `cron.webhookToken` to send a dedicated bearer token, if omitted the webhook is sent without an auth header.
- Deprecated fallback: stored legacy jobs with `notify: true` can still use `cron.webhook` until migrated.

## Chat behavior

- `chat.send` is **non-blocking**: it acks immediately with `{ runId, status: "started" }` and the response streams via `chat` events.
- Re-sending with the same `idempotencyKey` returns `{ status: "in_flight" }` while running, and `{ status: "ok" }` after completion.
- `chat.history` responses are size-bounded for UI safety. When transcript entries are too large, Gateway may truncate long text fields, omit heavy metadata blocks, and replace oversized messages with a placeholder (`[chat.history omitted: message too large]`).
- `chat.inject` appends an assistant note to the session transcript and broadcasts a `chat` event for UI-only updates (no agent run, no channel delivery).
- Stop:
  - Click **Stop** (calls `chat.abort`)
  - Type `/stop` (or standalone abort phrases like `stop`, `stop action`, `stop run`, `stop openclaw`, `please stop`) to abort out-of-band
  - `chat.abort` supports `{ sessionKey }` (no `runId`) to abort all active runs for that session
- Abort partial retention:
  - When a run is aborted, partial assistant text can still be shown in the UI
  - Gateway persists aborted partial assistant text into transcript history when buffered output exists
  - Persisted entries include abort metadata so transcript consumers can tell abort partials from normal completion output

## Tailnet access (recommended)

### Integrated Tailscale Serve (preferred)

Keep the Gateway on loopback and let Tailscale Serve proxy it with HTTPS:

```bash
openclaw gateway --tailscale serve
```

Open:

- `https://<magicdns>/` (or your configured `gateway.controlUi.basePath`)

By default, Control UI/WebSocket Serve requests can authenticate via Tailscale identity headers
(`tailscale-user-login`) when `gateway.auth.allowTailscale` is `true`. OpenClaw
verifies the identity by resolving the `x-forwarded-for` address with
`tailscale whois` and matching it to the header, and only accepts these when the
request hits loopback with Tailscale’s `x-forwarded-*` headers. Set
`gateway.auth.allowTailscale: false` (or force `gateway.auth.mode: "password"`)
if you want to require a token/password even for Serve traffic.
Tokenless Serve auth assumes the gateway host is trusted. If untrusted local
code may run on that host, require token/password auth.

### Bind to tailnet + token

```bash
openclaw gateway --bind tailnet --token "$(openssl rand -hex 32)"
```

Then open:

- `http://<tailscale-ip>:18789/` (or your configured `gateway.controlUi.basePath`)

Paste the token into the UI settings (sent as `connect.params.auth.token`).

## Insecure HTTP

If you open the dashboard over plain HTTP (`http://<lan-ip>` or `http://<tailscale-ip>`),
the browser runs in a **non-secure context** and blocks WebCrypto. By default,
OpenClaw **blocks** Control UI connections without device identity.

**Recommended fix:** use HTTPS (Tailscale Serve) or open the UI locally:

- `https://<magicdns>/` (Serve)
- `http://127.0.0.1:18789/` (on the gateway host)

**Insecure-auth toggle behavior:**

```json5
{
  gateway: {
    controlUi: { allowInsecureAuth: true },
    bind: "tailnet",
    auth: { mode: "token", token: "replace-me" },
  },
}
```

`allowInsecureAuth` does not bypass Control UI device identity or pairing checks.

**Break-glass only:**

```json5
{
  gateway: {
    controlUi: { dangerouslyDisableDeviceAuth: true },
    bind: "tailnet",
    auth: { mode: "token", token: "replace-me" },
  },
}
```

`dangerouslyDisableDeviceAuth` disables Control UI device identity checks and is a
severe security downgrade. Revert quickly after emergency use.

See [Tailscale](/gateway/tailscale) for HTTPS setup guidance.

## Building the UI

The Gateway serves static files from `dist/control-ui`. Build them with:

```bash
pnpm ui:build # auto-installs UI deps on first run
```

Optional absolute base (when you want fixed asset URLs):

```bash
OPENCLAW_CONTROL_UI_BASE_PATH=/openclaw/ pnpm ui:build
```

For local development (separate dev server):

```bash
pnpm ui:dev # auto-installs UI deps on first run
```

Then point the UI at your Gateway WS URL (e.g. `ws://127.0.0.1:18789`).

## Debugging/testing: dev server + remote Gateway

The Control UI is static files; the WebSocket target is configurable and can be
different from the HTTP origin. This is handy when you want the Vite dev server
locally but the Gateway runs elsewhere.

1. Start the UI dev server: `pnpm ui:dev`
2. Open a URL like:

```text
http://localhost:5173/?gatewayUrl=ws://<gateway-host>:18789
```

Optional one-time auth (if needed):

```text
http://localhost:5173/?gatewayUrl=wss://<gateway-host>:18789#token=<gateway-token>
```

Notes:

- `gatewayUrl` is stored in localStorage after load and removed from the URL.
- `token` is imported into memory for the current tab and stripped from the URL; it is not stored in localStorage.
- `password` is kept in memory only.
- When `gatewayUrl` is set, the UI does not fall back to config or environment credentials.
  Provide `token` (or `password`) explicitly. Missing explicit credentials is an error.
- Use `wss://` when the Gateway is behind TLS (Tailscale Serve, HTTPS proxy, etc.).
- `gatewayUrl` is only accepted in a top-level window (not embedded) to prevent clickjacking.
- Non-loopback Control UI deployments must set `gateway.controlUi.allowedOrigins`
  explicitly (full origins). This includes remote dev setups.
- `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback=true` enables
  Host-header origin fallback mode, but it is a dangerous security mode.

Example:

```json5
{
  gateway: {
    controlUi: {
      allowedOrigins: ["http://localhost:5173"],
    },
  },
}
```

Remote access setup details: [Remote access](/gateway/remote).
