// =============================================================================
// NFTBan - Rate Limiter Middleware
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rate_limiter"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-06"
// meta:description="Rate limiting middleware for brute force protection on login endpoints"
// meta:input="HTTP requests"
// meta:output="Rate-limited HTTP requests (429 Too Many Requests when exceeded)"
// meta:depends="github.com/itcmsgr/nftban/internal/netutil"
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
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/logutil"
	"github.com/itcmsgr/nftban/internal/netutil"
)

// RateLimiter provides IP-based rate limiting for brute force protection
type RateLimiter struct {
	mu       sync.Mutex
	attempts map[string][]time.Time
	limit    int
	window   time.Duration
}

// NewRateLimiter creates a new rate limiter with the specified limit and time window
// limit: maximum number of requests allowed per IP within the window
// window: time duration for the sliding window
func NewRateLimiter(limit int, window time.Duration) *RateLimiter {
	rl := &RateLimiter{
		attempts: make(map[string][]time.Time),
		limit:    limit,
		window:   window,
	}
	// Start cleanup goroutine to prevent memory growth
	go rl.cleanup()
	return rl
}

// Allow checks if the given IP is allowed to make a request
// Returns true if the request is allowed, false if rate limit exceeded
func (rl *RateLimiter) Allow(ip string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-rl.window)

	// Filter old attempts outside the window
	var recent []time.Time
	for _, t := range rl.attempts[ip] {
		if t.After(cutoff) {
			recent = append(recent, t)
		}
	}

	// Check if limit exceeded
	if len(recent) >= rl.limit {
		rl.attempts[ip] = recent
		return false
	}

	// Record this attempt
	rl.attempts[ip] = append(recent, now)
	return true
}

// cleanup periodically removes stale entries to prevent memory growth
func (rl *RateLimiter) cleanup() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()

	for range ticker.C {
		rl.mu.Lock()
		cutoff := time.Now().Add(-rl.window)
		for ip, attempts := range rl.attempts {
			var recent []time.Time
			for _, t := range attempts {
				if t.After(cutoff) {
					recent = append(recent, t)
				}
			}
			if len(recent) == 0 {
				delete(rl.attempts, ip)
			} else {
				rl.attempts[ip] = recent
			}
		}
		rl.mu.Unlock()
	}
}

// Middleware returns HTTP middleware that rate limits requests by client IP
// When rate limit is exceeded, returns 429 Too Many Requests
func (rl *RateLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := netutil.GetClientIP(r)

		if !rl.Allow(ip) {
			log.Printf("[SECURITY] Rate limit exceeded for IP: %s on %s %s", logutil.Sanitize(ip), r.Method, logutil.Sanitize(r.URL.Path))
			http.Error(w, "Too many requests. Please try again later.", http.StatusTooManyRequests)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// MiddlewareFunc returns HTTP middleware function for use with gorilla/mux
// This is compatible with mux.MiddlewareFunc signature
func (rl *RateLimiter) MiddlewareFunc(next http.Handler) http.Handler {
	return rl.Middleware(next)
}

// WrapHandler wraps a single http.HandlerFunc with rate limiting
// Useful for applying rate limiting to specific routes without subrouters
func (rl *RateLimiter) WrapHandler(handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := netutil.GetClientIP(r)

		if !rl.Allow(ip) {
			log.Printf("[SECURITY] Rate limit exceeded for IP: %s on %s %s", logutil.Sanitize(ip), r.Method, logutil.Sanitize(r.URL.Path))
			http.Error(w, "Too many requests. Please try again later.", http.StatusTooManyRequests)
			return
		}

		handler(w, r)
	}
}

// GetAttemptCount returns the current number of attempts for an IP (for monitoring)
func (rl *RateLimiter) GetAttemptCount(ip string) int {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-rl.window)

	count := 0
	for _, t := range rl.attempts[ip] {
		if t.After(cutoff) {
			count++
		}
	}
	return count
}

// Reset clears all rate limit data for an IP (e.g., after successful login)
func (rl *RateLimiter) Reset(ip string) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	delete(rl.attempts, ip)
}
