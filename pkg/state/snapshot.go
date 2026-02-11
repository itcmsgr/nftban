// =============================================================================
// NFTBan v1.0 - Shared State Snapshot
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="snapshot"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-24"
// meta:description="Shared state for BASIC tier metrics - single source of truth"
// meta:input="Watchdog snapshot, feeds loader state"
// meta:output="BasicSnapshot for sampler, stats CLI, status CLI, UI"
// meta:depends="sync,time"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package state

import (
	"sync"
	"time"
)

// BasicSnapshot holds data needed by BASIC tier consumers.
// This is the single source of truth for:
//   - nftban stats command
//   - nftban status command
//   - Web UI dashboard
//   - Sampler (when metrics disabled)
//
// Data is populated by watchdog (netlink) and feeds loader (in-memory).
// NO CLI CALLS - all consumers read from this shared state.
type BasicSnapshot struct {
	// nftables data (from watchdog netlink - NO CLI)
	BannedIPv4    int64 `json:"banned_ipv4"`
	BannedIPv6    int64 `json:"banned_ipv6"`
	WhitelistIPv4 int64 `json:"whitelist_ipv4"`
	WhitelistIPv6 int64 `json:"whitelist_ipv6"`
	RulesTotal    int64 `json:"rules_total"`

	// Feeds data (from loader in-memory - NO CLI)
	FeedsActive int   `json:"feeds_active"`
	FeedsIPs    int64 `json:"feeds_ips"`

	// Timestamp
	UpdatedAt time.Time `json:"updated_at"`
}

var (
	current BasicSnapshot
	mu      sync.RWMutex
)

// Update is called by watchdog after each collection cycle.
// This populates the shared state that all BASIC tier consumers read from.
func Update(snap BasicSnapshot) {
	mu.Lock()
	defer mu.Unlock()
	snap.UpdatedAt = time.Now()
	current = snap
}

// Get returns current snapshot for BASIC tier consumers
// (sampler, stats CLI, status CLI, UI handlers).
func Get() BasicSnapshot {
	mu.RLock()
	defer mu.RUnlock()
	return current
}

// GetBannedTotal returns total banned IPs (IPv4 + IPv6).
func GetBannedTotal() int64 {
	mu.RLock()
	defer mu.RUnlock()
	return current.BannedIPv4 + current.BannedIPv6
}

// GetWhitelistTotal returns total whitelist IPs (IPv4 + IPv6).
func GetWhitelistTotal() int64 {
	mu.RLock()
	defer mu.RUnlock()
	return current.WhitelistIPv4 + current.WhitelistIPv6
}

// GetFeedsActive returns number of active feeds.
func GetFeedsActive() int {
	mu.RLock()
	defer mu.RUnlock()
	return current.FeedsActive
}

// GetFeedsIPs returns total IPs from all feeds.
func GetFeedsIPs() int64 {
	mu.RLock()
	defer mu.RUnlock()
	return current.FeedsIPs
}

// GetAge returns how old the current snapshot is.
func GetAge() time.Duration {
	mu.RLock()
	defer mu.RUnlock()
	if current.UpdatedAt.IsZero() {
		return 0
	}
	return time.Since(current.UpdatedAt)
}

// IsStale returns true if snapshot is older than given duration.
func IsStale(maxAge time.Duration) bool {
	return GetAge() > maxAge
}

// IsInitialized returns true if snapshot has been populated at least once.
func IsInitialized() bool {
	mu.RLock()
	defer mu.RUnlock()
	return !current.UpdatedAt.IsZero()
}

// UpdateFeeds updates just the feeds-related fields in the snapshot.
// Called by feeds loader/sync after feed operations complete.
// This allows feeds data to be updated independently of watchdog nftables collection.
func UpdateFeeds(active int, totalIPs int64) {
	mu.Lock()
	defer mu.Unlock()
	current.FeedsActive = active
	current.FeedsIPs = totalIPs
	// Don't update UpdatedAt - that's for full snapshots from watchdog
}
