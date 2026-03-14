// =============================================================================
// NFTBan v1.21.0 - HTTP Bot Guard: FCrDNS Verifier
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Forward-Confirmed Reverse DNS verification worker pool
//
// meta:name="botguard_verifier"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-14"
// meta:description="FCrDNS verification for bot IP classification"
//
// FCrDNS verification process:
//   1. Reverse DNS:  IP → hostname (net.LookupAddr)
//   2. Suffix check: hostname must match allowed domain suffix
//   3. Forward DNS:  hostname → IP list (net.LookupHost), original IP must be present
//
// Worker pool: bounded concurrency, rate-limited, with positive/negative caching.
//
// meta:inventory.files="verifier.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="dns"
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"context"
	"log"
	"net"
	"net/netip"
	"strings"
	"sync"
	"time"
)

// VerifyResult holds the outcome of an FCrDNS verification.
type VerifyResult struct {
	IP       netip.Addr   // The IP that was verified
	Status   VerifyStatus // Verification outcome
	BotName  string       // Matched bot name (empty if not matched)
	Hostname string       // Reverse DNS hostname (empty if lookup failed)
}

// cacheEntry stores a cached verification result.
type cacheEntry struct {
	result    VerifyResult
	expiresAt time.Time
}

// FCrDNSVerifier performs Forward-Confirmed Reverse DNS verification
// using a bounded worker pool with rate limiting and caching.
type FCrDNSVerifier struct {
	// Configuration
	allowedBots []BotConfig   // Known good crawler configs (domain suffixes)
	workers     int           // Max concurrent workers
	rateLimit   int           // Max new lookups per second
	timeout     time.Duration // Per-lookup DNS timeout
	posCacheTTL time.Duration // Positive result cache TTL
	negCacheTTL time.Duration // Negative result cache TTL

	// Channels
	requests chan netip.Addr    // Inbound verification requests
	results  chan VerifyResult  // Outbound verification results

	// Cache
	cache   map[netip.Addr]cacheEntry
	cacheMu sync.RWMutex

	// DNS resolver (allows test injection)
	resolver dnsResolver
}

// dnsResolver abstracts DNS lookups for testability.
type dnsResolver interface {
	LookupAddr(ctx context.Context, addr string) ([]string, error)
	LookupHost(ctx context.Context, host string) ([]string, error)
}

// netResolver wraps the standard net.Resolver.
type netResolver struct {
	r *net.Resolver
}

func (n *netResolver) LookupAddr(ctx context.Context, addr string) ([]string, error) {
	return n.r.LookupAddr(ctx, addr)
}

func (n *netResolver) LookupHost(ctx context.Context, host string) ([]string, error) {
	return n.r.LookupHost(ctx, host)
}

// NewFCrDNSVerifier creates a new verifier with the given config and bot list.
func NewFCrDNSVerifier(cfg *Config, allowedBots []BotConfig) *FCrDNSVerifier {
	return &FCrDNSVerifier{
		allowedBots: allowedBots,
		workers:     cfg.VerifyWorkers,
		rateLimit:   cfg.VerifyRateLimit,
		timeout:     cfg.VerifyTimeout,
		posCacheTTL: cfg.VerifyCacheTTL,
		negCacheTTL: cfg.VerifyNegTTL,
		requests:    make(chan netip.Addr, 256),
		results:     make(chan VerifyResult, 256),
		cache:       make(map[netip.Addr]cacheEntry),
		resolver:    &netResolver{r: net.DefaultResolver},
	}
}

// Start launches the worker pool and rate limiter. Blocks until ctx is cancelled.
func (v *FCrDNSVerifier) Start(ctx context.Context) {
	// Rate limiter: tokens refilled at rateLimit/s
	limiter := time.NewTicker(time.Second / time.Duration(v.rateLimit))
	defer limiter.Stop()

	// Semaphore for max concurrent workers
	sem := make(chan struct{}, v.workers)

	// Cache cleanup every 5 minutes
	cleanupTicker := time.NewTicker(5 * time.Minute)
	defer cleanupTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-cleanupTicker.C:
			v.pruneCache()
		case ip := <-v.requests:
			// Check cache first
			if result, ok := v.checkCache(ip); ok {
				select {
				case v.results <- result:
				case <-ctx.Done():
					return
				}
				continue
			}

			// Wait for rate limiter token
			select {
			case <-limiter.C:
			case <-ctx.Done():
				return
			}

			// Acquire worker slot
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				return
			}

			go func(addr netip.Addr) {
				defer func() { <-sem }()
				result := v.verify(ctx, addr)
				v.cacheResult(result)
				select {
				case v.results <- result:
				case <-ctx.Done():
				}
			}(ip)
		}
	}
}

// Enqueue submits an IP for FCrDNS verification.
// Non-blocking: drops the request if the queue is full.
func (v *FCrDNSVerifier) Enqueue(ip netip.Addr) {
	select {
	case v.requests <- ip:
	default:
		log.Printf("[botguard] verifier queue full, dropping %s", ip)
	}
}

// Results returns the channel of completed verifications.
func (v *FCrDNSVerifier) Results() <-chan VerifyResult {
	return v.results
}

// verify performs a single FCrDNS verification.
func (v *FCrDNSVerifier) verify(ctx context.Context, ip netip.Addr) VerifyResult {
	result := VerifyResult{IP: ip, Status: VerifyFailed}

	lookupCtx, cancel := context.WithTimeout(ctx, v.timeout)
	defer cancel()

	// Step 1: Reverse DNS lookup
	names, err := v.resolver.LookupAddr(lookupCtx, ip.String())
	if err != nil {
		if lookupCtx.Err() != nil {
			result.Status = VerifyTimeout
			return result
		}
		result.Status = VerifyNoRDNS
		return result
	}
	if len(names) == 0 {
		result.Status = VerifyNoRDNS
		return result
	}

	// Use first hostname, strip trailing dot
	hostname := strings.TrimSuffix(names[0], ".")
	result.Hostname = hostname

	// Step 2: Check if hostname matches any allowed bot domain suffix
	var matchedBot *BotConfig
	hostLower := strings.ToLower(hostname)
	for i := range v.allowedBots {
		for _, domain := range v.allowedBots[i].Domains {
			if strings.HasSuffix(hostLower, "."+strings.ToLower(domain)) ||
				strings.EqualFold(hostLower, domain) {
				matchedBot = &v.allowedBots[i]
				break
			}
		}
		if matchedBot != nil {
			break
		}
	}

	if matchedBot == nil {
		// Hostname doesn't match any allowed crawler domain
		result.Status = VerifyFailed
		return result
	}

	result.BotName = matchedBot.Name

	// Step 3: Forward DNS confirmation — hostname must resolve back to the original IP
	fwdCtx, fwdCancel := context.WithTimeout(ctx, v.timeout)
	defer fwdCancel()

	addrs, err := v.resolver.LookupHost(fwdCtx, hostname)
	if err != nil {
		if fwdCtx.Err() != nil {
			result.Status = VerifyTimeout
		} else {
			result.Status = VerifyFailed
		}
		return result
	}

	ipStr := ip.String()
	for _, addr := range addrs {
		if addr == ipStr {
			result.Status = VerifyVerified
			return result
		}
		// Handle IPv6 normalization
		parsed, err := netip.ParseAddr(addr)
		if err == nil && parsed == ip {
			result.Status = VerifyVerified
			return result
		}
	}

	// Forward lookup didn't confirm the IP
	result.Status = VerifyFailed
	return result
}

// checkCache returns a cached result if present and not expired.
func (v *FCrDNSVerifier) checkCache(ip netip.Addr) (VerifyResult, bool) {
	v.cacheMu.RLock()
	defer v.cacheMu.RUnlock()

	entry, ok := v.cache[ip]
	if !ok || time.Now().After(entry.expiresAt) {
		return VerifyResult{}, false
	}
	return entry.result, true
}

// cacheResult stores a verification result in the cache.
func (v *FCrDNSVerifier) cacheResult(result VerifyResult) {
	v.cacheMu.Lock()
	defer v.cacheMu.Unlock()

	ttl := v.negCacheTTL
	if result.Status == VerifyVerified {
		ttl = v.posCacheTTL
	}

	v.cache[result.IP] = cacheEntry{
		result:    result,
		expiresAt: time.Now().Add(ttl),
	}
}

// pruneCache removes expired entries from the cache.
func (v *FCrDNSVerifier) pruneCache() {
	v.cacheMu.Lock()
	defer v.cacheMu.Unlock()

	now := time.Now()
	for ip, entry := range v.cache {
		if now.After(entry.expiresAt) {
			delete(v.cache, ip)
		}
	}
}
