# nftban-api Internal Design

**Purpose:** `nftban-api` is an unprivileged HTTPS service that authenticates/authorizes users and translates web actions into IPC requests to nftband.

---

## Process Identity

- **User:** `nftban-www`
- **Group:** `nftban-web` (NOT full `nftban`)
- **IPC:** connects to `/run/nftban/nftband-web.sock`

**Rationale:** Separate group prevents escalation to full CLI capabilities if `nftban-api` is compromised.

---

## Internal Package Layout

```
nftban-api/
├── cmd/
│   └── main.go            # Entry point, service setup
├── internal/
│   ├── auth/             # PAM, login policies, session issuance, SSO
│   ├── session/          # Session store interface + backends
│   ├── rbac/             # Role checks, permissions, middleware
│   ├── ipc/              # Typed client to nftband IPC methods
│   ├── audit/            # Append-only JSON audit logs + helpers
│   ├── metrics/          # Aggregation, passthrough to daemon, SSE
│   ├── handlers/         # HTTP handlers by domain
│   ├── config/           # Server config loading/validation
│   ├── security/         # Rate limits, headers, origin policy
│   └── model/            # Data structures
└── go.mod
```

---

## Authentication

### Local Login (PAM)

**Endpoint:** `POST /api/v1/login`

**Request Body:**
```json
{
  "username": "admin",
  "password": "********"
}
```

**Policies (Enforced in Order):**

1. **Reject `username == "root"` BEFORE PAM authentication**
   ```go
   if req.Username == "root" {
       auditLog("SECURITY", "root", "login_attempt_blocked", r.RemoteAddr)
       http.Error(w, "Root login is not allowed via web interface", http.StatusForbidden)
       return
   }
   ```

2. **PAM authenticate** (local OS users)
   ```go
   user, err := PAMAuthenticate(req.Username, req.Password)
   if err != nil {
       http.Error(w, "Invalid credentials", http.StatusUnauthorized)
       return
   }
   ```

3. **Verify allowed groups**
   - `nftban-admin`
   - `nftban-operator`
   - `nftban-panel-admin`
   - `nftban-panel-user-*`

**Result:**
- Create session token (32 random bytes; hex/base64)
- Store server-side
- Return token + user metadata

**Response:**
```json
{
  "token": "a3f8d9c2e1b4567890abcdef12345678...",
  "username": "admin",
  "groups": ["nftban-admin"],
  "expires_at": "2026-01-02T21:00:00Z"
}
```

---

### Panel SSO Login (CRITICAL SECURITY TIGHTENINGS)

**Endpoint:** `GET /api/v1/panel/sso?panel_token=...`

**Token Format:** `payload + HMAC signature`

**Requirements:**
- Expiry ≤ 60 seconds
- Single-use token (consume immediately; store "used" marker with TTL)
- Panel-specific keys with rotation

### Defense-in-Depth Layering (UPDATED)

**CRITICAL:** Origin header validation alone is insufficient.

**Layered Checks (All Required):**

1. **CSP `frame-ancestors` allowlist** (PRIMARY browser enforcement)
   ```go
   w.Header().Set("Content-Security-Policy",
       "frame-ancestors https://directadmin.example.com https://cpanel.example.com")
   ```

2. **Validate `Host` header** / expected panel callback path
   ```go
   if r.Host != "nftban.example.com" {
       http.Error(w, "Invalid host", http.StatusForbidden)
       return
   }
   ```

3. **Validate `Origin` when present** (defense-in-depth)
   ```go
   origin := r.Header.Get("Origin")
   if origin != "" {
       var secret string
       switch origin {
       case "https://directadmin.example.com":
           secret = directAdminSecret
       case "https://cpanel.example.com":
           secret = cpanelSecret
       default:
           http.Error(w, "Invalid origin", http.StatusForbidden)
           return
       }
   }
   ```
   **Note:** Do NOT rely solely on `Origin` - many navigations won't include it, proxies can affect it.

4. **Optionally validate `Referer`** when present (do not require it)
   ```go
   referer := r.Header.Get("Referer")
   if referer != "" && !strings.HasPrefix(referer, "https://directadmin.example.com") {
       // Log suspicious request but don't fail (Referer can be missing/stripped)
       auditLog("WARN", "unknown", "suspicious_referer", r.RemoteAddr)
   }
   ```

5. **Single-use SSO token + 60s expiry** (ACTUAL anti-replay control)
   ```go
   session, err := validateSSOToken(token, secret)
   if err != nil {
       http.Error(w, "Invalid token: "+err.Error(), http.StatusUnauthorized)
       return
   }

   // CRITICAL: Mark token as used immediately (store with TTL = token expiry)
   if err := tokenStore.MarkUsed(token, 60*time.Second); err != nil {
       http.Error(w, "Token already used", http.StatusForbidden)
       return
   }
   ```

**Why This Matters:**
- `Origin` header is not present in all same-origin navigations
- Proxies can modify/strip headers
- Iframe `Origin` behavior varies by browser
- **Primary security is single-use token with short expiry**

---

## Session Management

### Interface

```go
type Store interface {
    Set(token string, session *Session) error
    Get(token string) (*Session, error)
    Delete(token string) error
    GC() error // Optional background garbage collection
}
```

### Backends (UPDATED - All 3 Supported)

1. **Memory** (dev only)
   - NOT scalable or persistent
   - Sessions lost on restart
   - Use only for development

2. **SQLite** (default for single-host)
   - Persists sessions across restarts
   - Acceptable for single-server deployments
   - Can become bottleneck under high load

3. **Redis** (recommended for HA/production)
   - Fast, reliable, scalable
   - Supports session clustering
   - Best choice for production environments

**Implementation Strategy:**
```go
// config.yaml
session:
  backend: "sqlite"  # or "redis" or "memory"
  sqlite:
    path: "/var/lib/nftban/sessions.db"
  redis:
    url: "redis://localhost:6379"
  ttl: 1800  # 30 minutes
```

### Expiry Strategy

**Combined Approach (Recommended):**

1. **Lazy Expiry** - Check on every request
   ```go
   session, err := sessionStore.Get(token)
   if err != nil || time.Now().After(session.ExpiresAt) {
       http.Error(w, "Session expired", http.StatusUnauthorized)
       sessionStore.Delete(token)  // Clean up
       return
   }
   ```

2. **Background GC** - Periodic cleanup
   ```go
   go func() {
       ticker := time.NewTicker(10 * time.Minute)
       for range ticker.C {
           sessionStore.GC()
       }
   }()
   ```

---

## Authorization (RBAC)

### Roles

| Role | Group | Permissions |
|------|-------|-------------|
| **Admin** | `nftban-admin` | Full access (ban/unban/config/services) |
| **Operator** | `nftban-operator` | Read-only (view/search/logs) |
| **Panel-Admin** | `nftban-panel-admin` | Server-wide management (DirectAdmin admin) |
| **Panel-User** | `nftban-panel-user-{username}` | Limited scope (cPanel user) |

### Middleware

**Auth Middleware:**
```go
func AuthMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        token := r.Header.Get("X-Session-Token")
        if token == "" {
            http.Error(w, "Missing X-Session-Token", http.StatusUnauthorized)
            return
        }

        session, err := sessionStore.Get(token)
        if err != nil {
            http.Error(w, "Invalid session token", http.StatusUnauthorized)
            return
        }

        // Check expiry (lazy expiry)
        if time.Now().After(session.ExpiresAt) {
            sessionStore.Delete(token)
            http.Error(w, "Session expired", http.StatusUnauthorized)
            return
        }

        // Attach session to request context
        ctx := context.WithValue(r.Context(), "session", session)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}
```

**RBAC Middleware:**
```go
func RequireRole(groups []string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            session := r.Context().Value("session").(*Session)

            // Check if user is in at least one required role
            authorized := false
            for _, requiredGroup := range groups {
                for _, userGroup := range session.Groups {
                    if requiredGroup == userGroup {
                        authorized = true
                        break
                    }
                }
                if authorized {
                    break
                }
            }

            if !authorized {
                http.Error(w, "Unauthorized", http.StatusForbidden)
                return
            }

            next.ServeHTTP(w, r)
        })
    }
}
```

**Usage:**
```go
http.Handle("/api/v1/ban",
    AuthMiddleware(
        RequireRole([]string{"nftban-admin", "nftban-panel-admin"})(
            http.HandlerFunc(banHandler))))
```

### Scope Enforcement (Panel Users)

**Problem:** Panel users should only see/act on their own resources.

**Solution:**
```go
func listBans(w http.ResponseWriter, r *http.Request) {
    session := r.Context().Value("session").(*Session)

    // Get all bans from IPC
    bans, err := ipcClient.List()
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    // Filter based on role
    if isPanelUser(session) {
        filtered := []Ban{}
        username := extractUsername(session)
        expectedSource := "panel-" + username

        for _, ban := range bans {
            if ban.Source == expectedSource {
                filtered = append(filtered, ban)
            }
        }
        bans = filtered
    }

    json.NewEncoder(w).Encode(bans)
}
```

**For write actions:**
```go
func banIP(w http.ResponseWriter, r *http.Request) {
    session := r.Context().Value("session").(*Session)
    var req BanRequest
    json.NewDecoder(r.Body).Decode(&req)

    // Determine source tag based on user role
    var source string
    if session.InGroup("nftban-admin") {
        source = "admin-" + session.Username
    } else if isPanelUser(session) {
        source = "panel-" + session.Username  // Server enforces tag
    }

    // Send IPC request with tagged source
    err := ipcClient.Ban(req.IP, req.Timeout, req.Reason, source)
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    json.NewEncoder(w).Encode(map[string]string{"status": "banned"})
}
```

---

## IPC Layer

### Goal

All firewall mutations occur in nftband. `nftban-api` **never** executes `nft`.

### Web IPC Socket Restriction (CRITICAL)

**Daemon exposes TWO sockets:**

1. **Full CLI Socket** (existing)
   - Path: `/run/nftban/nftband.sock`
   - Permissions: `0660 root:nftban`
   - Clients: CLI tools, admin scripts
   - Methods: ALL

2. **Web-Restricted Socket** (NEW)
   - Path: `/run/nftban/nftband-web.sock`
   - Permissions: `0660 root:nftban-web`
   - Clients: `nftban-api` only
   - Methods: **ALLOWLIST ONLY**

**Allowlist for Web Socket:**
- `ban`
- `unban`
- `list`
- `search`
- `metrics_read`
- `audit_read` (if daemon supports)
- `config/*` methods (only if explicitly permitted)

**Daemon Enforcement:**
```go
// In nftband daemon
func (d *Daemon) handleWebSocketConnection(conn net.Conn) {
    uid, gid, err := validatePeerCredentials(conn)
    if err != nil {
        return
    }

    // Verify connecting peer is nftban-web group
    if gid != nftbanWebGroupGID {
        log.Printf("Web socket: unauthorized group gid=%d", gid)
        return
    }

    var req IPCRequest
    json.NewDecoder(conn).Decode(&req)

    // Enforce web allowlist
    if !isWebAllowedMethod(req.Method) {
        log.Printf("Web socket: method %s not allowed", req.Method)
        d.writeSocketResponse(conn, SocketResponse{
            Success: false,
            Error:   "method not allowed via web socket",
        })
        return
    }

    // Process allowed request
    d.handleRequest(req, conn)
}
```

### Typed Client

```go
// internal/ipc/client.go
type Client struct {
    socketPath string
    timeout    time.Duration
}

func NewClient() *Client {
    return &Client{
        socketPath: "/run/nftban/nftband-web.sock",
        timeout:    30 * time.Second,
    }
}

func (c *Client) Ban(ip string, ttl int, reason, source string) error
func (c *Client) Unban(ip string) error
func (c *Client) List(offset, limit int, filters map[string]string) ([]Ban, error)
func (c *Client) Search(ip string) (*BanInfo, error)
func (c *Client) MetricsSummary() (*MetricsSummary, error)
func (c *Client) MetricsTimeline(period string) (*MetricsTimeline, error)
```

---

## Audit Logging (UPDATED - Attribution Handling)

### Requirements

Log **ALL** actions (success/failure), including auth events.

### Fields

```go
type AuditLogEntry struct {
    Timestamp  time.Time `json:"timestamp"`
    Actor      string    `json:"actor"`       // username
    ActorRoles []string  `json:"actor_roles"` // groups
    Action     string    `json:"action"`
    Target     string    `json:"target,omitempty"`     // ip/config key/service
    Params     string    `json:"params,omitempty"`     // redacted where needed
    Result     string    `json:"result"`               // success/failure + error
    ClientIP   string    `json:"client_ip"`
    RequestID  string    `json:"request_id,omitempty"` // correlation id
    Source     string    `json:"source"`               // web-gui/panel-da/panel-cpanel
}
```

### Storage

- **Default:** `/var/log/nftban/audit.log` (JSON lines, append-only)
- **Logrotate config** shipped with package
- **Optional:** syslog or database (PostgreSQL) for high-volume installs

### Attribution Strategy (CRITICAL)

**Problem:** Daemon sees `uid=nftban-www` for all web actions.

**Solution:**

1. **`nftban-api` is system of record** for web audit attribution
   - All audit fields above are logged by `nftban-api`
   - Append-only log with proper permissions (`0640 nftban-www:nftban-audit`)

2. **Daemon logs infrastructure-level tracing**
   - IPC connection from `uid=nftban-www`
   - Method invoked
   - Success/failure

3. **(Optional) Pass actor to daemon for logging**
   - Add optional `actor` object in IPC params:
     ```json
     {
       "method": "ban",
       "params": {
         "ip": "1.2.3.4",
         "actor": {
           "username": "admin",
           "roles": ["nftban-admin"],
           "source": "web-gui"
         }
       }
     }
     ```
   - Daemon logs actor **for tracing only** (NOT for authorization)
   - OR sign actor claims with daemon-shared key (more complexity; usually unnecessary)

**Recommendation:** Keep it simple - `nftban-api` audit log is authoritative for web actions. Daemon logs are for infrastructure debugging.

---

## Security Controls

### Headers (Baseline)

```go
func securityHeaders(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // HSTS
        w.Header().Set("Strict-Transport-Security",
            "max-age=31536000; includeSubDomains")

        // CSP with frame-ancestors allowlist
        w.Header().Set("Content-Security-Policy",
            "frame-ancestors https://directadmin.example.com https://cpanel.example.com; "+
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'")

        // Other headers
        w.Header().Set("X-Content-Type-Options", "nosniff")
        w.Header().Set("Referrer-Policy", "no-referrer")
        w.Header().Set("Permissions-Policy", "geolocation=(), microphone=(), camera=()")

        // DO NOT set X-Frame-Options (conflicts with iframe embedding)

        next.ServeHTTP(w, r)
    })
}
```

### Rate Limiting

```go
import "golang.org/x/time/rate"

var (
    loginLimiter  = rate.NewLimiter(rate.Every(5*time.Second), 5)  // 5 attempts/5s
    writeLimiter  = rate.NewLimiter(rate.Every(1*time.Second), 10) // 10 ops/s
    readLimiter   = rate.NewLimiter(rate.Every(1*time.Second), 50) // 50 ops/s
)

func rateLimitMiddleware(limiter *rate.Limiter) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            if !limiter.Allow() {
                http.Error(w, "Rate limit exceeded", http.StatusTooManyRequests)
                return
            }
            next.ServeHTTP(w, r)
        })
    }
}
```

### CSRF Protection

**With header-based auth (X-Session-Token):**
- CSRF risk is reduced (not cookie-based)
- Still enforce:
  - SameSite cookies if you choose cookie mode
  - Origin/Referer validation for sensitive endpoints (defense-in-depth)

---

## Real-Time Updates (Optional)

### SSE Endpoint

```
GET /api/v1/events
```

**Auth:** Required (X-Session-Token)

**Emits:**
- Ban/unban events
- Daemon health changes

**Implementation:**
```go
func eventsHandler(w http.ResponseWriter, r *http.Request) {
    // Set SSE headers
    w.Header().Set("Content-Type", "text/event-stream")
    w.Header().Set("Cache-Control", "no-cache")
    w.Header().Set("Connection", "keep-alive")

    // Subscribe to event bus
    events := eventBus.Subscribe()
    defer eventBus.Unsubscribe(events)

    for {
        select {
        case event := <-events:
            fmt.Fprintf(w, "data: %s\n\n", event.ToJSON())
            w.(http.Flusher).Flush()
        case <-r.Context().Done():
            return
        }
    }
}
```

---

## Deployment Notes

### Recommended Setup

- **Reverse proxy:** nginx terminates TLS
- **nftban-api:** listens on localhost only
- **TLS:** Let's Encrypt + certbot auto-renewal

### Systemd Hardening

```ini
[Service]
User=nftban-www
Group=nftban-web
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/nftban /var/lib/nftban
CapabilityBoundingSet=
```

---

**Last Updated:** 2026-01-02
