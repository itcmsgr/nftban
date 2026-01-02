# NFTBan Web GUI v2.0 Implementation Plan

**Date:** 2026-01-02
**Scope:** Replace outdated GUI with a secure Web GUI integrated with nftband IPC.

---

## Guiding Constraints (Non-Negotiable)

- Web GUI must never run as root.
- Web GUI must never allow root login.
- Web GUI must use IPC to nftband (no direct nft commands).
- HTTP sessions use temporary server-side tokens (NOT JWT).
- CLI architecture and security model remain unchanged.

---

## High-Level Architecture

```
Browser (HTTPS) → nftban-api (unprivileged) → IPC (Unix socket) → nftband (root) → nftables
```

---

## Daemon Boundary Hardening (Required)

To preserve "authorization at daemon boundary" for the web channel:

- **Add a dedicated "web IPC" socket** with restricted method allowlist:
  - `/run/nftban/nftband-web.sock` owned `root:nftban-web` mode `0660`
  - `nftban-api` runs as `nftban-www:nftban-web`
  - nftband enforces `web-allowlist` methods for peers connecting via that socket.
- **Keep existing `/run/nftban/nftband.sock`** unchanged for CLI/admin.

**Rationale:** This ensures that even if `nftban-api` is compromised, the attacker can only invoke web-safe IPC methods, not full CLI capabilities.

---

## Phase 1: Core Backend (nftban-api) MVP

**Goal:** Backend works end-to-end without frontend.

### Deliverables

- `nftban-api` Go service (systemd unit) running as `nftban-www`.
- PAM login (root blocked **before** PAM).
- Session tokens (32-byte random), server-side store (SQLite default; Redis optional).
- RBAC middleware (Admin / Operator / Panel-Admin / Panel-User).
- IPC client to `nftband-web` socket.
- Minimal endpoints:
  - `POST /api/v1/login`
  - `POST /api/v1/logout`
  - `GET  /api/v1/me`
  - `POST /api/v1/ban`
  - `POST /api/v1/unban`
  - `GET  /api/v1/list` (pagination)
  - `GET  /api/v1/search`

### Acceptance Tests

- Root login forbidden (rejected before PAM authentication).
- Non-member of allowed groups forbidden.
- Admin can ban/unban.
- Operator cannot ban/unban.
- Pagination behaves correctly on large lists.

---

## Phase 2: Frontend MVP

**Goal:** Usable GUI for ban/unban and list/search.

### Deliverables

- **Vue.js** (or React if you choose) SPA.
- Pages:
  - Login
  - Dashboard (basic counts)
  - Ban List (paginated + virtual scroll)
  - Ban Action (single + bulk)
- API integration with session token header (`X-Session-Token`).
- Basic UI error handling and notifications.

### Acceptance Tests

- Works behind nginx reverse proxy.
- No sensitive info in browser storage beyond session token.
- UI respects RBAC (buttons hidden/disabled + server-side enforcement).

---

## Phase 3: Panel Integration (DirectAdmin + cPanel)

**Goal:** SSO-based iframe embedding with strict anti-replay and origin policy.

### Deliverables

- **SSO endpoint:**
  - `GET /api/v1/panel/sso?panel_token=...`
- **Token requirements:**
  - HMAC signed
  - Expiry ≤ 60 seconds
  - Single-use (consume token immediately; store "used" marker)
  - Per-panel keys (DirectAdmin key, cPanel key) with rotation support
- **Embedding security (CRITICAL TIGHTENINGS):**
  - **CSP header** with `frame-ancestors` allowlist of panel origins (PRIMARY enforcement)
  - **Validate Host** / expected panel callback path
  - **Validate Origin when present** (defense-in-depth; do NOT rely solely on it)
  - **Optionally validate Referer** when present (do not require it)
  - **Single-use SSO token + 60s expiry** as the actual anti-replay control
  - **DO NOT use `X-Frame-Options: SAMEORIGIN`** - will block cross-origin iframe embedding
- **Role mapping:**
  - DirectAdmin admin → Panel-Admin
  - cPanel user → Panel-User (scoped view)

### Security Tightenings

**Origin header validation alone is insufficient:**
- Many same-origin navigations won't include an `Origin` header
- Proxies can affect it
- For iframe loads, `Origin` behavior varies

**Fix (Layered Checks):**
1. CSP `frame-ancestors` (primary browser enforcement)
2. Validate `Host` / expected panel callback path
3. Validate `Origin` when present (do not rely solely on it)
4. Optionally validate `Referer` when present (do not require it)
5. Require single-use SSO token + 60s expiry as the actual anti-replay control

### Acceptance Tests

- Token replay rejected.
- Wrong panel origin rejected (by CSP + server-side checks).
- Panel-user only sees/acts within scope.

---

## Phase 4: Advanced Features

**Goal:** Parity with CLI + operational maturity.

### Deliverables

- **Config endpoints:**
  - `GET  /api/v1/config`
  - `POST /api/v1/config/set`
  - `POST /api/v1/config/reload`
- **Services endpoints** (if required by product scope):
  - `GET  /api/v1/services`
  - `POST /api/v1/service/control` (restricted to Admin)
- **Metrics:**
  - `GET /api/v1/metrics/summary`
  - `GET /api/v1/metrics/timeline`
  - Optional: SSE `/api/v1/events` (server→client updates)
- **Audit:**
  - `GET  /api/v1/audit` (filters + pagination)
  - `POST /api/v1/audit/export`

### Hardening

- Per-endpoint rate limits (login strictest).
- Security headers baseline:
  - `Strict-Transport-Security`
  - `Content-Security-Policy` (include `frame-ancestors` allowlist)
  - `X-Content-Type-Options: nosniff`
  - `Referrer-Policy: no-referrer`
  - `Permissions-Policy`
  - **DO NOT include `X-Frame-Options`** (conflicts with iframe embedding; CSP is preferred)
- Logrotate for audit logs.

---

## Phase 5: Deprecation and Removal of Old GUI

**Goal:** Safe rollout without breaking existing installs.

### Deliverables

- Old GUI displays deprecation banner + link to new GUI.
- Installer supports:
  - `--with-gui` install
  - `nftban gui install|uninstall|enable|disable`
- Remove old GUI in next major release after a communicated window.

---

## Attribution Handling (CRITICAL)

### Problem

With a mediator API, the daemon will log `uid=nftban-www` for all web actions unless you add an "actor" field.

### Fix

**Treat `nftban-api` as the system of record for web audit attribution:**
- User
- Role
- Source IP
- Token/session ID

**Keep daemon logs for infrastructure-level tracing.**

If you want daemon-level attribution, add an optional `actor` object in IPC params that is:
- **Only trusted for logging** (not for auth)
- OR sign actor claims with a daemon-shared key (more complexity; usually unnecessary if API audit is immutable and protected)

---

## Session Storage Strategy (UPDATED)

### Interface

Implement a session store interface with **3 backends**:

1. **Memory** (dev only) - NOT scalable or persistent
2. **SQLite** (default) - single-host, persists across restarts
3. **Redis** (recommended for HA) - scalable, clustering support

**Rationale:** SQLite is acceptable for single-server deployments. Redis is best for production/HA environments.

---

## Definition of Done

- Full CLI function coverage exposed via GUI (within RBAC constraints).
- No direct nft execution outside nftband.
- **Web channel restricted at daemon boundary via web IPC allowlist.**
- Audit trail complete and queryable.
- Panel embedding works with SSO + anti-replay + layered origin security.
- Documentation complete and shipped with packages.

---

**Last Updated:** 2026-01-02
