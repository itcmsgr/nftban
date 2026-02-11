// =============================================================================
// NFTBan - Runtime Firewall State
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="state"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="In-memory firewall state with thread-safe whitelist/blacklist management"
// meta:input="Blacklist/whitelist configuration"
// meta:output="Runtime state for firewall operations"
// meta:depends="github.com/itcmsgr/nftban/pkg/blacklist,github.com/itcmsgr/nftban/pkg/whitelist"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package runtime

import (
	"fmt"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/blacklist"
	"github.com/itcmsgr/nftban/pkg/whitelist"
)

// RuntimeState holds the in-memory firewall state
// Thread-safe with RWMutex
type RuntimeState struct {
	mu sync.RWMutex

	// Whitelist sets (IPv4 and IPv6 separated)
	WhitelistIPv4 map[string]*IPEntry
	WhitelistIPv6 map[string]*IPEntry

	// Blacklist sets (IPv4 and IPv6 separated)
	BlacklistIPv4 map[string]*IPEntry
	BlacklistIPv6 map[string]*IPEntry

	// Note: EffectiveBlack* maps removed (CWE-400 mitigation)
	// They duplicated BlacklistIPv4/IPv6 and were unused.
	// Use IsBlacklisted() method instead.

	// Per-source tracking
	Sources map[string]*SourceStats

	// Counters
	Counters *Counters

	// Config directory
	ConfigDir string

	// Last reload time
	LastReload time.Time
}

// IPEntry represents a single IP in the runtime state
type IPEntry struct {
	IP         string
	Source     string    // "whitelist", "blacklist", "feeds", "geoban", "tempban" (v1.0: removed fail2ban)
	AddedAt    time.Time
	BanCount   int       // Number of times this IP was banned
	LastBanAt  time.Time // Last time this IP was banned
	ExpireAt   *time.Time // Optional: expiration time for temporary bans
	Reason     string    // Why this IP was added
}

// SourceStats tracks statistics per source
type SourceStats struct {
	Name         string
	IPv4Count    int
	IPv6Count    int
	LastUpdate   time.Time
	TotalAdded   int64 // Lifetime counter
	TotalRemoved int64 // Lifetime counter
}

// Counters holds atomic counters for metrics
type Counters struct {
	mu sync.RWMutex

	// Global counters
	TotalWhitelistIPv4 int64
	TotalWhitelistIPv6 int64
	TotalBlacklistIPv4 int64
	TotalBlacklistIPv6 int64

	// Per-source counters
	FeedsIPv4     int64
	FeedsIPv6     int64
	GeoBanIPv4    int64
	GeoBanIPv6    int64
	// Removed: Fail2BanIPv4, Fail2BanIPv6 (v1.0 migration to Suricata)
	ManualIPv4    int64
	ManualIPv6    int64

	// Operations counters
	BansTotal      int64
	UnbansTotal    int64
	ReloadsTotal   int64
	SyncsTotal     int64
	SyncErrorsTotal int64
}

// NewRuntimeState creates a new RuntimeState instance
func NewRuntimeState(configDir string) *RuntimeState {
	return &RuntimeState{
		WhitelistIPv4: make(map[string]*IPEntry),
		WhitelistIPv6: make(map[string]*IPEntry),
		BlacklistIPv4: make(map[string]*IPEntry),
		BlacklistIPv6: make(map[string]*IPEntry),
		Sources:       make(map[string]*SourceStats),
		Counters:      &Counters{},
		ConfigDir:     configDir,
		LastReload:    time.Now(),
	}
}

// LoadWhitelists loads all whitelist files into memory
func (rs *RuntimeState) LoadWhitelists() error {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	// Load from all whitelist sources
	ipv4Set, ipv6Set, err := whitelist.LoadAllWhitelists(rs.ConfigDir)
	if err != nil {
		return fmt.Errorf("failed to load whitelists: %w", err)
	}

	// Clear existing whitelists
	rs.WhitelistIPv4 = make(map[string]*IPEntry)
	rs.WhitelistIPv6 = make(map[string]*IPEntry)

	// Populate IPv4 whitelist
	for ip := range ipv4Set {
		rs.WhitelistIPv4[ip] = &IPEntry{
			IP:      ip,
			Source:  "whitelist",
			AddedAt: time.Now(),
		}
	}

	// Populate IPv6 whitelist
	for ip := range ipv6Set {
		rs.WhitelistIPv6[ip] = &IPEntry{
			IP:      ip,
			Source:  "whitelist",
			AddedAt: time.Now(),
		}
	}

	// Update counters
	rs.Counters.mu.Lock()
	rs.Counters.TotalWhitelistIPv4 = int64(len(rs.WhitelistIPv4))
	rs.Counters.TotalWhitelistIPv6 = int64(len(rs.WhitelistIPv6))
	rs.Counters.mu.Unlock()

	// Update source stats
	if _, ok := rs.Sources["whitelist"]; !ok {
		rs.Sources["whitelist"] = &SourceStats{Name: "whitelist"}
	}
	rs.Sources["whitelist"].IPv4Count = len(rs.WhitelistIPv4)
	rs.Sources["whitelist"].IPv6Count = len(rs.WhitelistIPv6)
	rs.Sources["whitelist"].LastUpdate = time.Now()

	return nil
}

// LoadBlacklists loads all blacklist files into memory
func (rs *RuntimeState) LoadBlacklists() error {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	// Load from all blacklist sources
	ipv4Set, ipv6Set, err := blacklist.LoadAllBlacklists(rs.ConfigDir)
	if err != nil {
		return fmt.Errorf("failed to load blacklists: %w", err)
	}

	// Clear existing blacklists
	rs.BlacklistIPv4 = make(map[string]*IPEntry)
	rs.BlacklistIPv6 = make(map[string]*IPEntry)

	// Populate IPv4 blacklist
	for ip := range ipv4Set {
		rs.BlacklistIPv4[ip] = &IPEntry{
			IP:      ip,
			Source:  "blacklist",
			AddedAt: time.Now(),
		}
	}

	// Populate IPv6 blacklist
	for ip := range ipv6Set {
		rs.BlacklistIPv6[ip] = &IPEntry{
			IP:      ip,
			Source:  "blacklist",
			AddedAt: time.Now(),
		}
	}

	// Update counters
	rs.Counters.mu.Lock()
	rs.Counters.TotalBlacklistIPv4 = int64(len(rs.BlacklistIPv4))
	rs.Counters.TotalBlacklistIPv6 = int64(len(rs.BlacklistIPv6))
	rs.Counters.mu.Unlock()

	// Update source stats
	if _, ok := rs.Sources["blacklist"]; !ok {
		rs.Sources["blacklist"] = &SourceStats{Name: "blacklist"}
	}
	rs.Sources["blacklist"].IPv4Count = len(rs.BlacklistIPv4)
	rs.Sources["blacklist"].IPv6Count = len(rs.BlacklistIPv6)
	rs.Sources["blacklist"].LastUpdate = time.Now()

	return nil
}

// ReloadAll reloads both whitelists and blacklists
func (rs *RuntimeState) ReloadAll() error {
	if err := rs.LoadWhitelists(); err != nil {
		return fmt.Errorf("failed to reload whitelists: %w", err)
	}

	if err := rs.LoadBlacklists(); err != nil {
		return fmt.Errorf("failed to reload blacklists: %w", err)
	}

	rs.mu.Lock()
	rs.LastReload = time.Now()
	rs.mu.Unlock()

	rs.Counters.mu.Lock()
	rs.Counters.ReloadsTotal++
	rs.Counters.mu.Unlock()

	return nil
}

// IsWhitelisted checks if an IP is in the whitelist
func (rs *RuntimeState) IsWhitelisted(ip string, isIPv4 bool) bool {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	if isIPv4 {
		_, ok := rs.WhitelistIPv4[ip]
		return ok
	}

	_, ok := rs.WhitelistIPv6[ip]
	return ok
}

// IsBlacklisted checks if an IP is in the blacklist
func (rs *RuntimeState) IsBlacklisted(ip string, isIPv4 bool) bool {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	if isIPv4 {
		_, ok := rs.BlacklistIPv4[ip]
		return ok
	}

	_, ok := rs.BlacklistIPv6[ip]
	return ok
}

// AddToBlacklist adds an IP to the blacklist
func (rs *RuntimeState) AddToBlacklist(ip string, isIPv4 bool, source string, reason string) error {
	// Check if whitelisted first
	if rs.IsWhitelisted(ip, isIPv4) {
		return fmt.Errorf("cannot blacklist %s: IP is whitelisted", ip)
	}

	rs.mu.Lock()
	defer rs.mu.Unlock()

	entry := &IPEntry{
		IP:        ip,
		Source:    source,
		AddedAt:   time.Now(),
		BanCount:  1,
		LastBanAt: time.Now(),
		Reason:    reason,
	}

	if isIPv4 {
		if existing, ok := rs.BlacklistIPv4[ip]; ok {
			// IP already blacklisted, increment ban count
			existing.BanCount++
			existing.LastBanAt = time.Now()
			return nil
		}
		rs.BlacklistIPv4[ip] = entry
		rs.Counters.mu.Lock()
		rs.Counters.TotalBlacklistIPv4++
		rs.Counters.BansTotal++
		rs.Counters.mu.Unlock()
	} else {
		if existing, ok := rs.BlacklistIPv6[ip]; ok {
			existing.BanCount++
			existing.LastBanAt = time.Now()
			return nil
		}
		rs.BlacklistIPv6[ip] = entry
		rs.Counters.mu.Lock()
		rs.Counters.TotalBlacklistIPv6++
		rs.Counters.BansTotal++
		rs.Counters.mu.Unlock()
	}

	return nil
}

// RemoveFromBlacklist removes an IP from the blacklist
func (rs *RuntimeState) RemoveFromBlacklist(ip string, isIPv4 bool) error {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	if isIPv4 {
		if _, ok := rs.BlacklistIPv4[ip]; !ok {
			return fmt.Errorf("IP %s not found in blacklist", ip)
		}
		delete(rs.BlacklistIPv4, ip)
		rs.Counters.mu.Lock()
		rs.Counters.TotalBlacklistIPv4--
		rs.Counters.UnbansTotal++
		rs.Counters.mu.Unlock()
	} else {
		if _, ok := rs.BlacklistIPv6[ip]; !ok {
			return fmt.Errorf("IP %s not found in blacklist", ip)
		}
		delete(rs.BlacklistIPv6, ip)
		rs.Counters.mu.Lock()
		rs.Counters.TotalBlacklistIPv6--
		rs.Counters.UnbansTotal++
		rs.Counters.mu.Unlock()
	}

	return nil
}

// GetStats returns a snapshot of current stats
func (rs *RuntimeState) GetStats() map[string]interface{} {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	rs.Counters.mu.RLock()
	defer rs.Counters.mu.RUnlock()

	return map[string]interface{}{
		"whitelist_ipv4": len(rs.WhitelistIPv4),
		"whitelist_ipv6": len(rs.WhitelistIPv6),
		"blacklist_ipv4": len(rs.BlacklistIPv4),
		"blacklist_ipv6": len(rs.BlacklistIPv6),
		"last_reload":    rs.LastReload.Format(time.RFC3339),
		"counters": map[string]int64{
			"bans_total":        rs.Counters.BansTotal,
			"unbans_total":      rs.Counters.UnbansTotal,
			"reloads_total":     rs.Counters.ReloadsTotal,
			"syncs_total":       rs.Counters.SyncsTotal,
			"sync_errors_total": rs.Counters.SyncErrorsTotal,
		},
	}
}

// GetWhitelistSnapshot returns a copy of current whitelist
func (rs *RuntimeState) GetWhitelistSnapshot() ([]string, []string) {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	ipv4List := make([]string, 0, len(rs.WhitelistIPv4))
	for ip := range rs.WhitelistIPv4 {
		ipv4List = append(ipv4List, ip)
	}

	ipv6List := make([]string, 0, len(rs.WhitelistIPv6))
	for ip := range rs.WhitelistIPv6 {
		ipv6List = append(ipv6List, ip)
	}

	return ipv4List, ipv6List
}

// GetBlacklistSnapshot returns a copy of current blacklist
func (rs *RuntimeState) GetBlacklistSnapshot() ([]string, []string) {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	ipv4List := make([]string, 0, len(rs.BlacklistIPv4))
	for ip := range rs.BlacklistIPv4 {
		ipv4List = append(ipv4List, ip)
	}

	ipv6List := make([]string, 0, len(rs.BlacklistIPv6))
	for ip := range rs.BlacklistIPv6 {
		ipv6List = append(ipv6List, ip)
	}

	return ipv4List, ipv6List
}

// IncrementSyncCounter increments the sync counter
func (rs *RuntimeState) IncrementSyncCounter(success bool) {
	rs.Counters.mu.Lock()
	defer rs.Counters.mu.Unlock()

	rs.Counters.SyncsTotal++
	if !success {
		rs.Counters.SyncErrorsTotal++
	}
}
