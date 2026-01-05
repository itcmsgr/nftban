# NFTBan GUI Authentication Migration Plan

**Date:** 2026-01-06
**Status:** PLANNING
**Priority:** HIGH (Security)

---

## Executive Summary

Migrate nftban-ui from stateless JWT tokens to server-side session tokens for improved security, revocation capability, and panel SSO support.

---

## Current State (INSECURE)

```
┌─────────────────────────────────────────────────────────────────┐
│ CURRENT: Stateless JWT                                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Browser ──login──► nftban-ui ──PAM──► auth.sock               │
│                         │                                       │
│                         ▼                                       │
│                    Generate JWT                                 │
│                    (HMAC-SHA256)                                │
│                         │                                       │
│                         ▼                                       │
│  Browser ◄──JWT Token───┘                                       │
│     │                                                           │
│     │ (stored in localStorage)                                  │
│     │                                                           │
│     ▼                                                           │
│  All requests include JWT in header                             │
│                                                                 │
│  PROBLEMS:                                                      │
│  ✗ Cannot revoke tokens (valid until expiry)                   │
│  ✗ Logout doesn't invalidate token                             │
│  ✗ Token theft = full access until expiry                      │
│  ✗ No session tracking (who is logged in?)                     │
│  ✗ No SSO support for panels                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Target State (SECURE)

```
┌─────────────────────────────────────────────────────────────────┐
│ TARGET: Server-Side Sessions + SSO                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ DIRECT LOGIN (Username/Password)                         │   │
│  │                                                          │   │
│  │ Browser ──login──► nftban-ui ──PAM──► auth.sock         │   │
│  │                        │                                 │   │
│  │                        ▼                                 │   │
│  │               Generate Session Token                     │   │
│  │               (32-byte random hex)                       │   │
│  │                        │                                 │   │
│  │                        ▼                                 │   │
│  │               Store in SessionStore                      │   │
│  │               (SQLite/Redis)                             │   │
│  │                        │                                 │   │
│  │ Browser ◄──Session Token──┘                              │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ SSO LOGIN (Panel Integration)                            │   │
│  │                                                          │   │
│  │ Panel ──HMAC token──► nftban-ui                         │   │
│  │                           │                              │   │
│  │                           ▼                              │   │
│  │                    Verify HMAC signature                 │   │
│  │                    Check expiry (≤60s)                   │   │
│  │                    Check single-use                      │   │
│  │                           │                              │   │
│  │                           ▼                              │   │
│  │               Generate Session Token                     │   │
│  │               Store in SessionStore                      │   │
│  │                           │                              │   │
│  │ Browser ◄──Session Token──┘                              │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  BENEFITS:                                                      │
│  ✓ Can revoke tokens instantly                                 │
│  ✓ Logout deletes session from server                          │
│  ✓ Token theft = revoke immediately                            │
│  ✓ Session tracking (list active sessions)                     │
│  ✓ SSO support for DirectAdmin/cPanel/Plesk                    │
│  ✓ Single-use SSO tokens prevent replay                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Migration Phases

### Phase 1: Session Store Backend (2-3 days)

**Files to Create:**
```
pkg/session/
├── store.go          # Interface definition
├── sqlite.go         # SQLite implementation (default)
├── redis.go          # Redis implementation (HA)
├── memory.go         # In-memory (testing only)
└── gc.go             # Garbage collection for expired sessions
```

**Session Schema (SQLite):**
```sql
CREATE TABLE sessions (
    token TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    groups TEXT NOT NULL,          -- JSON array
    client_ip TEXT,
    user_agent TEXT,
    created_at TIMESTAMP NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    last_seen_at TIMESTAMP
);

CREATE INDEX idx_sessions_expires ON sessions(expires_at);
CREATE INDEX idx_sessions_username ON sessions(username);
```

**Session Interface:**
```go
type Session struct {
    Token      string
    Username   string
    Groups     []string
    ClientIP   string
    UserAgent  string
    CreatedAt  time.Time
    ExpiresAt  time.Time
    LastSeenAt time.Time
}

type SessionStore interface {
    Create(session *Session) error
    Get(token string) (*Session, error)
    Delete(token string) error
    DeleteByUsername(username string) error  // Logout all sessions
    DeleteExpired() (int, error)             // GC
    List() ([]*Session, error)               // Admin: list active sessions
    Touch(token string) error                // Update last_seen_at
}
```

---

### Phase 2: Authentication Middleware (1-2 days)

**Files to Modify:**
```
pkg/auth/
├── pam.go            # Keep PAM auth, remove JWT generation
├── session.go        # NEW: Session token generation/validation
└── middleware.go     # NEW: HTTP middleware for session auth
```

**Session Token Generation:**
```go
func GenerateSessionToken() (string, error) {
    b := make([]byte, 32)
    if _, err := rand.Read(b); err != nil {
        return "", err
    }
    return hex.EncodeToString(b), nil
}
```

**Middleware:**
```go
func SessionAuthMiddleware(store SessionStore) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            // 1. Extract token from header or cookie
            token := extractToken(r)
            if token == "" {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
            }

            // 2. Validate session
            session, err := store.Get(token)
            if err != nil || session == nil {
                http.Error(w, "invalid session", http.StatusUnauthorized)
                return
            }

            // 3. Check expiry
            if time.Now().After(session.ExpiresAt) {
                store.Delete(token)
                http.Error(w, "session expired", http.StatusUnauthorized)
                return
            }

            // 4. Update last seen
            store.Touch(token)

            // 5. Attach to context
            ctx := context.WithValue(r.Context(), "session", session)
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}
```

---

### Phase 3: SSO Token Support (2-3 days)

**Files to Create:**
```
pkg/sso/
├── token.go          # SSO token generation/validation
├── store.go          # Single-use token tracking
└── panels.go         # Panel-specific configurations
```

**SSO Token Format:**
```
username:role:expiry_unix:hmac_signature

Example:
admin:admin:1704499200:a1b2c3d4e5f6...
```

**Panel Configuration:**
```yaml
# /etc/nftban/panels.yaml
panels:
  directadmin:
    enabled: true
    secret: "shared-secret-with-da"
    allowed_origins:
      - "https://server.example.com:2222"
    max_token_age: 60s

  cpanel:
    enabled: true
    secret: "shared-secret-with-cpanel"
    allowed_origins:
      - "https://server.example.com:2083"
      - "https://server.example.com:2087"
    max_token_age: 60s
```

**SSO Validation:**
```go
func ValidateSSOToken(tokenStr, secret string, store SSOStore) (*SSOToken, error) {
    // 1. Parse token
    token, err := ParseSSOToken(tokenStr)
    if err != nil {
        return nil, err
    }

    // 2. Verify signature (constant-time)
    if !VerifyHMAC(token, secret) {
        return nil, ErrInvalidSignature
    }

    // 3. Check expiry
    if time.Now().Unix() > token.Expiry {
        return nil, ErrTokenExpired
    }

    // 4. Check single-use (atomic)
    if err := store.MarkUsed(tokenStr); err != nil {
        return nil, ErrTokenReplay
    }

    return token, nil
}
```

---

### Phase 4: API Handler Updates (1-2 days)

**Files to Modify:**
```
pkg/api/handlers.go   # Update all handlers to use sessions
cmd/nftban-ui/main.go # Update initialization
```

**New Endpoints:**
```
POST /api/v1/login           # Direct login (PAM)
POST /api/v1/logout          # Delete session
POST /api/v1/sso/login       # SSO login (panels)
GET  /api/v1/session         # Get current session info
GET  /api/v1/sessions        # Admin: list all sessions
DELETE /api/v1/sessions/:id  # Admin: revoke session
```

**Login Handler Update:**
```go
func LoginHandler(auth *PAMAuth, store SessionStore) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        var req LoginRequest
        json.NewDecoder(r.Body).Decode(&req)

        // 1. Authenticate via PAM
        user, err := auth.Authenticate(req.Username, req.Password)
        if err != nil {
            http.Error(w, "invalid credentials", http.StatusUnauthorized)
            return
        }

        // 2. Generate session token
        token, err := GenerateSessionToken()
        if err != nil {
            http.Error(w, "internal error", http.StatusInternalServerError)
            return
        }

        // 3. Create session
        session := &Session{
            Token:     token,
            Username:  user.Username,
            Groups:    user.Groups,
            ClientIP:  r.RemoteAddr,
            UserAgent: r.UserAgent(),
            CreatedAt: time.Now(),
            ExpiresAt: time.Now().Add(30 * time.Minute),
        }

        if err := store.Create(session); err != nil {
            http.Error(w, "internal error", http.StatusInternalServerError)
            return
        }

        // 4. Return token
        json.NewEncoder(w).Encode(map[string]string{
            "token": token,
            "expires_in": "1800",
        })
    }
}
```

---

### Phase 5: Frontend Updates (1 day)

**Files to Modify:**
```
cmd/nftban-ui/web/static/js/app.js
```

**Changes:**
1. Replace `Authorization: Bearer <jwt>` with `X-Session-Token: <token>`
2. Add logout API call (don't just clear localStorage)
3. Handle session expiry gracefully

```javascript
// Before (JWT)
headers: {
    'Authorization': 'Bearer ' + localStorage.getItem('jwt_token')
}

// After (Session)
headers: {
    'X-Session-Token': localStorage.getItem('session_token')
}

// Logout - call API to invalidate server-side
async function logout() {
    await fetch('/api/v1/logout', {
        method: 'POST',
        headers: { 'X-Session-Token': getToken() }
    });
    localStorage.removeItem('session_token');
    window.location.href = '/';
}
```

---

### Phase 6: Configuration Updates (0.5 days)

**Files to Modify:**
```
internal/config/config.go
install/config/ui.conf
```

**New Config Options:**
```ini
# /etc/nftban/ui.conf

# Session Settings
SESSION_STORE=sqlite              # sqlite, redis, memory
SESSION_TIMEOUT=30                # minutes
SESSION_GC_INTERVAL=5             # minutes

# SQLite Session Store
SESSION_DB=/var/lib/nftban/sessions.db

# Redis Session Store (for HA)
# SESSION_STORE=redis
# REDIS_URL=redis://localhost:6379/0
# REDIS_PASSWORD=

# SSO Settings
SSO_ENABLED=true
SSO_PANELS_CONFIG=/etc/nftban/panels.yaml

# Remove JWT settings (deprecated)
# JWT_SECRET=xxx  # No longer used
```

---

### Phase 7: Testing & Documentation (1-2 days)

**Test Cases:**
1. Direct login/logout flow
2. Session expiry
3. Session revocation (admin)
4. Multiple sessions per user
5. SSO token generation (panel side)
6. SSO token validation
7. SSO replay prevention
8. Concurrent session handling
9. Session GC

**Documentation:**
- Update README with new auth flow
- Panel integration guide
- API documentation updates

---

## Implementation Timeline

| Phase | Task | Duration | Dependencies |
|-------|------|----------|--------------|
| 1 | Session Store Backend | 2-3 days | None |
| 2 | Auth Middleware | 1-2 days | Phase 1 |
| 3 | SSO Token Support | 2-3 days | Phase 1 |
| 4 | API Handler Updates | 1-2 days | Phase 2, 3 |
| 5 | Frontend Updates | 1 day | Phase 4 |
| 6 | Configuration | 0.5 days | Phase 4 |
| 7 | Testing & Docs | 1-2 days | All |
| **Total** | | **9-14 days** | |

---

## Rollback Plan

If issues occur during migration:

1. Keep old JWT code in place (disabled by feature flag)
2. Config option: `AUTH_MODE=jwt|session`
3. Can switch back without code changes
4. Remove JWT code after 1 month stable

---

## Security Checklist

### Session Tokens
- [ ] Token is cryptographically random (crypto/rand)
- [ ] Token is 32 bytes (256 bits)
- [ ] Token stored server-side only
- [ ] Expiry checked on every request
- [ ] Expired sessions auto-deleted (GC)
- [ ] Logout deletes session
- [ ] Admin can revoke any session

### SSO Tokens
- [ ] HMAC-SHA256 signature
- [ ] Max lifetime 60 seconds
- [ ] Single-use enforcement
- [ ] Constant-time signature comparison
- [ ] Origin validation (defense-in-depth)
- [ ] Panel secrets in secure config

### General
- [ ] All API endpoints require valid session
- [ ] Session token never logged
- [ ] Rate limiting on login endpoint
- [ ] Audit logging for auth events

---

## Files Summary

### New Files
```
pkg/session/store.go
pkg/session/sqlite.go
pkg/session/redis.go
pkg/session/memory.go
pkg/session/gc.go
pkg/auth/session.go
pkg/auth/middleware.go
pkg/sso/token.go
pkg/sso/store.go
pkg/sso/panels.go
install/config/panels.yaml
```

### Modified Files
```
pkg/auth/pam.go
pkg/api/handlers.go
cmd/nftban-ui/main.go
cmd/nftban-ui/web/static/js/app.js
internal/config/config.go
install/config/ui.conf
```

### Deprecated (Remove after migration)
```
pkg/auth/pam.go (JWT methods only)
```

---

**Last Updated:** 2026-01-06
