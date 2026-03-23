// =============================================================================
// NFTBan - HTTP Middleware
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="middleware"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP middleware for logging, auth, IP whitelist, and security headers"
// meta:input="HTTP requests"
// meta:output="Processed HTTP requests"
// meta:depends="github.com/itcmsgr/nftban/internal/auth,github.com/itcmsgr/nftban/internal/netutil"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package middleware

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/config"
	"github.com/itcmsgr/nftban/internal/auth"
	"github.com/itcmsgr/nftban/internal/logutil"
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/session"
)

type contextKey string

const (
	UserContextKey contextKey = "user"
)

// LoggingMiddleware logs all HTTP requests
func LoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		clientIP := netutil.GetClientIP(r)

		// Create response writer wrapper to capture status code
		lrw := &loggingResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		// Call next handler
		next.ServeHTTP(lrw, r)

		// Log request
		duration := time.Since(start)
		log.Printf("[HTTP] %s %s %s - %d - %v", logutil.Sanitize(clientIP), r.Method, logutil.Sanitize(r.RequestURI), lrw.statusCode, duration)
	})
}

// loggingResponseWriter wraps http.ResponseWriter to capture status code
type loggingResponseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (lrw *loggingResponseWriter) WriteHeader(code int) {
	lrw.statusCode = code
	lrw.ResponseWriter.WriteHeader(code)
}

// IPWhitelistMiddleware enforces IP-based access control
// SECURITY: Logs warning at startup if whitelist file is missing (all IPs will be denied)
func IPWhitelistMiddleware(cfg *config.Config) func(http.Handler) http.Handler {
	// Check whitelist file at startup and warn if missing
	if _, err := os.Stat(cfg.IPWhitelistFile); os.IsNotExist(err) {
		log.Printf("[SECURITY] WARNING: IP whitelist file %s does not exist - ALL IPs will be DENIED access", cfg.IPWhitelistFile)
	} else if err != nil {
		log.Printf("[SECURITY] WARNING: Cannot access IP whitelist file %s: %v", cfg.IPWhitelistFile, err)
	} else {
		log.Printf("[SECURITY] IP whitelist enabled using: %s", cfg.IPWhitelistFile)
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			clientIP := netutil.GetClientIP(r)

			// Check if IP is whitelisted
			allowed, err := netutil.IsIPWhitelisted(clientIP, cfg.IPWhitelistFile)
			if err != nil {
				log.Printf("[SECURITY] IP whitelist check error for %s: %v", logutil.Sanitize(clientIP), err)
				http.Error(w, "Internal server error", http.StatusInternalServerError)
				return
			}

			if !allowed {
				log.Printf("[SECURITY] Blocked access from non-whitelisted IP: %s", logutil.Sanitize(clientIP))
				http.Error(w, "Access denied - IP not whitelisted", http.StatusForbidden)
				return
			}

			// IP is whitelisted, proceed
			next.ServeHTTP(w, r)
		})
	}
}

// JWTAuthMiddleware validates JWT tokens
// The authService is created once and reused for all requests (performance optimization)
func JWTAuthMiddleware(cfg *config.Config) func(http.Handler) http.Handler {
	// Create auth service ONCE at middleware initialization, not per-request
	authService, err := auth.NewPAMAuth(cfg)
	if err != nil {
		log.Printf("[AUTH] FATAL: Failed to initialize auth service for middleware: %v", err)
		// Return middleware that always fails if auth service couldn't be created
		return func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				http.Error(w, "Authentication service unavailable", http.StatusInternalServerError)
			})
		}
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Extract token from Authorization header
			authHeader := r.Header.Get("Authorization")
			if authHeader == "" {
				http.Error(w, "Missing authorization header", http.StatusUnauthorized)
				return
			}

			// Parse Bearer token
			parts := strings.SplitN(authHeader, " ", 2)
			if len(parts) != 2 || parts[0] != "Bearer" {
				http.Error(w, "Invalid authorization header format", http.StatusUnauthorized)
				return
			}

			tokenString := parts[1]

			// Validate token using pre-initialized auth service
			claims, err := authService.ValidateToken(tokenString)
			if err != nil {
				log.Printf("[AUTH] Invalid token from %s: %v", logutil.Sanitize(netutil.GetClientIP(r)), err)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusUnauthorized)
				json.NewEncoder(w).Encode(map[string]interface{}{
					"success": false,
					"error":   "Invalid or expired token",
				})
				return
			}

			// Add user to context
			ctx := context.WithValue(r.Context(), UserContextKey, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// SessionAuthMiddleware validates session tokens (replacement for JWT)
// Uses in-memory session store for token validation
// Maintains backward compatibility by putting *auth.Claims in context
func SessionAuthMiddleware(store *session.Store) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Extract token from X-Session-Token header or Authorization header
			token := r.Header.Get("X-Session-Token")
			if token == "" {
				// Fallback: check Authorization header for backward compatibility
				authHeader := r.Header.Get("Authorization")
				if authHeader != "" {
					parts := strings.SplitN(authHeader, " ", 2)
					if len(parts) == 2 && parts[0] == "Bearer" {
						token = parts[1]
					}
				}
			}

			if token == "" {
				http.Error(w, "Missing session token", http.StatusUnauthorized)
				return
			}

			// Validate session token
			sess, err := store.Get(token)
			if err != nil {
				log.Printf("[AUTH] Invalid session from %s: %v", logutil.Sanitize(netutil.GetClientIP(r)), err)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusUnauthorized)
				json.NewEncoder(w).Encode(map[string]interface{}{
					"success": false,
					"error":   "Invalid or expired session",
				})
				return
			}

			// Create auth.Claims for backward compatibility with handlers
			// This allows existing handlers to work unchanged
			claims := &auth.Claims{
				Username: sess.Username,
				Groups:   sess.Groups,
			}

			// Add claims to context (same key as JWT middleware)
			ctx := context.WithValue(r.Context(), UserContextKey, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// CSRFMiddleware validates CSRF tokens on state-changing requests (POST, PUT, DELETE)
// Protects GOTH GUI forms from cross-site request forgery attacks
// CSRF token is read from X-CSRF-Token header or csrf_token form field
func CSRFMiddleware(store *session.Store) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Only validate state-changing methods
			if r.Method == "GET" || r.Method == "HEAD" || r.Method == "OPTIONS" {
				next.ServeHTTP(w, r)
				return
			}

			// Skip CSRF for REST API endpoints using Bearer token auth
			// (Bearer tokens are naturally CSRF-safe as they come from headers)
			authHeader := r.Header.Get("Authorization")
			if strings.HasPrefix(authHeader, "Bearer ") {
				next.ServeHTTP(w, r)
				return
			}

			// Skip CSRF for login endpoint (no session yet)
			if r.URL.Path == "/ui/action/login" || r.URL.Path == "/api/v1/login" {
				next.ServeHTTP(w, r)
				return
			}

			// Get session token from cookie or header
			sessionToken := ""
			if cookie, err := r.Cookie("session_id"); err == nil {
				sessionToken = cookie.Value
			}
			if sessionToken == "" {
				sessionToken = r.Header.Get("X-Session-Token")
			}

			if sessionToken == "" {
				log.Printf("[CSRF] Missing session token from %s", logutil.Sanitize(netutil.GetClientIP(r)))
				http.Error(w, "CSRF validation failed: no session", http.StatusForbidden)
				return
			}

			// Get session
			sess, err := store.Get(sessionToken)
			if err != nil {
				log.Printf("[CSRF] Invalid session from %s: %v", logutil.Sanitize(netutil.GetClientIP(r)), err)
				http.Error(w, "CSRF validation failed: invalid session", http.StatusForbidden)
				return
			}

			// Get CSRF token from header or form
			csrfToken := r.Header.Get("X-CSRF-Token")
			if csrfToken == "" {
				// Parse form to get csrf_token field
				if err := r.ParseForm(); err == nil {
					csrfToken = r.FormValue("csrf_token")
				}
			}

			// Validate CSRF token
			if !sess.ValidateCSRF(csrfToken) {
				log.Printf("[CSRF] Invalid CSRF token from %s (user: %s)", logutil.Sanitize(netutil.GetClientIP(r)), logutil.Sanitize(sess.Username))
				http.Error(w, "CSRF validation failed: invalid token", http.StatusForbidden)
				return
			}

			// CSRF valid, proceed
			next.ServeHTTP(w, r)
		})
	}
}

// MaxBodySizeMiddleware limits request body size to prevent memory exhaustion attacks
// Default limit is 1MB (1048576 bytes)
func MaxBodySizeMiddleware(maxBytes int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
			next.ServeHTTP(w, r)
		})
	}
}

// SecurityHeadersMiddleware adds security headers to responses
func SecurityHeadersMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Prevent clickjacking
		w.Header().Set("X-Frame-Options", "DENY")

		// Prevent MIME type sniffing
		w.Header().Set("X-Content-Type-Options", "nosniff")

		// Enable XSS protection
		w.Header().Set("X-XSS-Protection", "1; mode=block")

		// HSTS (HTTP Strict Transport Security)
		w.Header().Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")

		// Content Security Policy - Allow Chart.js CDN only (no external iframes)
		// NOTE: Tailwind removed in v0.7 - using pure CSS now
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self';")

		// Referrer Policy
		w.Header().Set("Referrer-Policy", "no-referrer")

		// Permissions Policy
		w.Header().Set("Permissions-Policy", "geolocation=(), microphone=(), camera=()")

		next.ServeHTTP(w, r)
	})
}

// GetClientIP extracts the real client IP address
// Exported for backward compatibility - delegates to netutil.GetClientIP
// Deprecated: Use netutil.GetClientIP directly for new code
func GetClientIP(r *http.Request) string {
	return netutil.GetClientIP(r)
}

//nolint:U1000 // Kept for backward compatibility
// Deprecated: Use netutil.IsIPWhitelisted directly for new code
