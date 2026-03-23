// =============================================================================
// NFTBan - Rate Limiter Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rate_limiter_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-06"
// meta:description="Tests for rate limiter middleware"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
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
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// =============================================================================
// BASIC RATE LIMITING TESTS
// =============================================================================

// TestRateLimiter_BasicLimit tests that the rate limiter enforces the limit correctly
func TestRateLimiter_BasicLimit(t *testing.T) {
	rl := NewRateLimiter(5, time.Minute)
	ip := "192.168.1.1"

	// First 5 requests should be allowed
	for i := 0; i < 5; i++ {
		if !rl.Allow(ip) {
			t.Errorf("Request %d should be allowed, but was rejected", i+1)
		}
	}

	// 6th request should be rejected
	if rl.Allow(ip) {
		t.Error("6th request should be rejected, but was allowed")
	}
}

// TestRateLimiter_DifferentIPs tests that rate limits are per-IP
func TestRateLimiter_DifferentIPs(t *testing.T) {
	rl := NewRateLimiter(2, time.Minute)

	ip1 := "192.168.1.1"
	ip2 := "192.168.1.2"

	// Exhaust limit for IP1
	rl.Allow(ip1)
	rl.Allow(ip1)

	// IP1 should be rate limited
	if rl.Allow(ip1) {
		t.Error("IP1 should be rate limited")
	}

	// IP2 should still be allowed
	if !rl.Allow(ip2) {
		t.Error("IP2 should be allowed (different IP)")
	}
	if !rl.Allow(ip2) {
		t.Error("IP2 second request should be allowed")
	}

	// IP2 should now be rate limited
	if rl.Allow(ip2) {
		t.Error("IP2 should now be rate limited")
	}
}

// TestRateLimiter_WindowExpiry tests that the sliding window works correctly
func TestRateLimiter_WindowExpiry(t *testing.T) {
	// Use a very short window for testing
	rl := NewRateLimiter(2, 50*time.Millisecond)
	ip := "192.168.1.1"

	// Exhaust the limit
	rl.Allow(ip)
	rl.Allow(ip)

	// Should be rate limited
	if rl.Allow(ip) {
		t.Error("Should be rate limited immediately after exhausting limit")
	}

	// Wait for window to expire
	time.Sleep(60 * time.Millisecond)

	// Should be allowed again
	if !rl.Allow(ip) {
		t.Error("Should be allowed after window expires")
	}
}

// TestRateLimiter_SlidingWindow tests the sliding window behavior
func TestRateLimiter_SlidingWindow(t *testing.T) {
	rl := NewRateLimiter(3, 100*time.Millisecond)
	ip := "192.168.1.1"

	// Make 2 requests
	rl.Allow(ip)
	rl.Allow(ip)

	// Wait 50ms
	time.Sleep(50 * time.Millisecond)

	// Make 1 more request (total 3 within window)
	if !rl.Allow(ip) {
		t.Error("3rd request should be allowed")
	}

	// 4th request should be rejected
	if rl.Allow(ip) {
		t.Error("4th request should be rejected")
	}

	// Wait another 60ms (first 2 requests should expire)
	time.Sleep(60 * time.Millisecond)

	// Should allow 2 more requests now
	if !rl.Allow(ip) {
		t.Error("Should allow request after partial window expiry")
	}
}

// =============================================================================
// HELPER METHOD TESTS
// =============================================================================

// TestRateLimiter_GetAttemptCount tests the attempt count getter
func TestRateLimiter_GetAttemptCount(t *testing.T) {
	rl := NewRateLimiter(10, time.Minute)
	ip := "192.168.1.1"

	if count := rl.GetAttemptCount(ip); count != 0 {
		t.Errorf("Expected 0 attempts initially, got %d", count)
	}

	// Make 3 requests
	rl.Allow(ip)
	rl.Allow(ip)
	rl.Allow(ip)

	if count := rl.GetAttemptCount(ip); count != 3 {
		t.Errorf("Expected 3 attempts, got %d", count)
	}
}

// TestRateLimiter_Reset tests the reset functionality
func TestRateLimiter_Reset(t *testing.T) {
	rl := NewRateLimiter(2, time.Minute)
	ip := "192.168.1.1"

	// Exhaust the limit
	rl.Allow(ip)
	rl.Allow(ip)

	// Should be rate limited
	if rl.Allow(ip) {
		t.Error("Should be rate limited")
	}

	// Reset the IP
	rl.Reset(ip)

	// Should be allowed again
	if !rl.Allow(ip) {
		t.Error("Should be allowed after reset")
	}

	// Verify count is reset
	if count := rl.GetAttemptCount(ip); count != 1 {
		t.Errorf("Expected 1 attempt after reset and new request, got %d", count)
	}
}

// =============================================================================
// HTTP MIDDLEWARE TESTS
// =============================================================================

// TestRateLimiter_Middleware tests the HTTP middleware integration
func TestRateLimiter_Middleware(t *testing.T) {
	rl := NewRateLimiter(2, time.Minute)

	// Create a test handler
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	// Wrap with rate limiter middleware
	wrapped := rl.Middleware(handler)

	// Create test requests
	makeRequest := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "/test", nil)
		req.RemoteAddr = "192.168.1.1:12345"
		rr := httptest.NewRecorder()
		wrapped.ServeHTTP(rr, req)
		return rr
	}

	// First 2 requests should succeed
	rr1 := makeRequest()
	if rr1.Code != http.StatusOK {
		t.Errorf("First request: expected 200, got %d", rr1.Code)
	}

	rr2 := makeRequest()
	if rr2.Code != http.StatusOK {
		t.Errorf("Second request: expected 200, got %d", rr2.Code)
	}

	// Third request should be rate limited
	rr3 := makeRequest()
	if rr3.Code != http.StatusTooManyRequests {
		t.Errorf("Third request: expected 429, got %d", rr3.Code)
	}
}

// TestRateLimiter_WrapHandler tests the single handler wrapper
func TestRateLimiter_WrapHandler(t *testing.T) {
	rl := NewRateLimiter(1, time.Minute)

	handler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}

	wrapped := rl.WrapHandler(handler)

	req := httptest.NewRequest("GET", "/test", nil)
	req.RemoteAddr = "10.0.0.1:9999"

	// First request should succeed
	rr1 := httptest.NewRecorder()
	wrapped(rr1, req)
	if rr1.Code != http.StatusOK {
		t.Errorf("First request: expected 200, got %d", rr1.Code)
	}

	// Second request should be rate limited
	rr2 := httptest.NewRecorder()
	wrapped(rr2, req)
	if rr2.Code != http.StatusTooManyRequests {
		t.Errorf("Second request: expected 429, got %d", rr2.Code)
	}
}

// =============================================================================
// CONCURRENCY TESTS
// =============================================================================

// TestRateLimiter_ConcurrentAccess tests thread safety
func TestRateLimiter_ConcurrentAccess(t *testing.T) {
	rl := NewRateLimiter(100, time.Minute)

	var wg sync.WaitGroup
	numGoroutines := 50
	requestsPerGoroutine := 10

	// Run concurrent requests from multiple IPs
	for i := 0; i < numGoroutines; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			ip := "192.168.1." + string(rune(id%256))
			for j := 0; j < requestsPerGoroutine; j++ {
				rl.Allow(ip)
				rl.GetAttemptCount(ip)
			}
		}(i)
	}

	wg.Wait()
	// Test passes if no race conditions or panics occur
}

// TestRateLimiter_ConcurrentSameIP tests concurrent access from the same IP
func TestRateLimiter_ConcurrentSameIP(t *testing.T) {
	rl := NewRateLimiter(1000, time.Minute)
	ip := "192.168.1.1"

	var wg sync.WaitGroup
	var allowedCount int64
	var mu sync.Mutex

	// Run 100 concurrent requests from the same IP
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if rl.Allow(ip) {
				mu.Lock()
				allowedCount++
				mu.Unlock()
			}
		}()
	}

	wg.Wait()

	// All 100 should be allowed since limit is 1000
	if allowedCount != 100 {
		t.Errorf("Expected 100 allowed requests, got %d", allowedCount)
	}
}

// =============================================================================
// EDGE CASE TESTS
// =============================================================================

// TestRateLimiter_ZeroLimit tests behavior with zero limit
func TestRateLimiter_ZeroLimit(t *testing.T) {
	rl := NewRateLimiter(0, time.Minute)
	ip := "192.168.1.1"

	// With zero limit, all requests should be denied
	if rl.Allow(ip) {
		t.Error("Request should be denied with zero limit")
	}
}

// TestRateLimiter_VeryShortWindow tests behavior with very short window
func TestRateLimiter_VeryShortWindow(t *testing.T) {
	rl := NewRateLimiter(1, time.Millisecond)
	ip := "192.168.1.1"

	// First request should be allowed
	if !rl.Allow(ip) {
		t.Error("First request should be allowed")
	}

	// Second immediate request should be denied
	if rl.Allow(ip) {
		t.Error("Second immediate request should be denied")
	}

	// Wait for window to expire
	time.Sleep(2 * time.Millisecond)

	// Should be allowed again
	if !rl.Allow(ip) {
		t.Error("Request after window expiry should be allowed")
	}
}

// TestRateLimiter_EmptyIP tests behavior with empty IP
func TestRateLimiter_EmptyIP(t *testing.T) {
	rl := NewRateLimiter(2, time.Minute)
	ip := ""

	// Should work with empty IP (tracks as a single "client")
	if !rl.Allow(ip) {
		t.Error("First request with empty IP should be allowed")
	}
	if !rl.Allow(ip) {
		t.Error("Second request with empty IP should be allowed")
	}
	if rl.Allow(ip) {
		t.Error("Third request with empty IP should be denied")
	}
}

// TestRateLimiter_IPv6 tests behavior with IPv6 addresses
func TestRateLimiter_IPv6(t *testing.T) {
	rl := NewRateLimiter(2, time.Minute)
	ipv6 := "2001:db8::1"

	if !rl.Allow(ipv6) {
		t.Error("First IPv6 request should be allowed")
	}
	if !rl.Allow(ipv6) {
		t.Error("Second IPv6 request should be allowed")
	}
	if rl.Allow(ipv6) {
		t.Error("Third IPv6 request should be denied")
	}
}

// =============================================================================
// BENCHMARKS
// =============================================================================

func BenchmarkRateLimiter_Allow(b *testing.B) {
	rl := NewRateLimiter(1000000, time.Minute)
	ip := "192.168.1.1"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rl.Allow(ip)
	}
}

func BenchmarkRateLimiter_AllowConcurrent(b *testing.B) {
	rl := NewRateLimiter(1000000, time.Minute)
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		ip := "192.168.1.1"
		for pb.Next() {
			rl.Allow(ip)
		}
	})
}

func BenchmarkRateLimiter_GetAttemptCount(b *testing.B) {
	rl := NewRateLimiter(1000000, time.Minute)
	ip := "192.168.1.1"
	// Pre-populate some attempts
	for i := 0; i < 100; i++ {
		rl.Allow(ip)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rl.GetAttemptCount(ip)
	}
}
