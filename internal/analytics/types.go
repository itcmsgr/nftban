// =============================================================================
// NFTBan v1.0 - Analytics Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="types"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Type definitions for analytics data structures"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package analytics

import (
	"container/list"
	"time"
)

// CountryStats keeps aggregate info for a country.
type CountryStats struct {
	Country     string              `json:"country"`
	IPCount     int                 `json:"ip_count"`
	IPs         []string            `json:"ips,omitempty"`     // Used for JSON serialization
	IPSet       map[string]struct{} `json:"-"`                 // O(1) lookup set (not serialized)
	LastUpdated time.Time           `json:"last_updated"`
}

// IPOrigin describes origin info for a specific IP.
type IPOrigin struct {
	IP       string    `json:"ip"`
	Country  string    `json:"country"`
	City     string    `json:"city,omitempty"`
	BannedAt time.Time `json:"banned_at"`
	Source   string    `json:"source,omitempty"`  // suricata, login-monitor, manual, feeds
	Service  string    `json:"service,omitempty"` // ssh, http, wordpress, malware, etc.
	Reason   string    `json:"reason,omitempty"`
	Duration int       `json:"duration,omitempty"` // Ban duration in seconds (0 = permanent)

	// LRU bookkeeping (not serialized)
	lruElement *list.Element `json:"-"`
}

// DailySummary represents a daily analytics snapshot.
type DailySummary struct {
	Date           string                  `json:"date"`
	TotalBans      int                     `json:"total_bans"`
	UniqueIPs      int                     `json:"unique_ips"`
	TopCountries   []CountryStats          `json:"top_countries"`
	BySource       map[string]int          `json:"by_source"`   // suricata, login-monitor, manual, feeds
	ByService      map[string]int          `json:"by_service"`  // Dynamic from filters.conf
	GeneratedAt    time.Time               `json:"generated_at"`
}

// AnalyticsSummary is returned by CLI for JSON output.
type AnalyticsSummary struct {
	Success      bool                    `json:"success"`
	TotalIPs     int                     `json:"total_ips"`
	TotalCountries int                   `json:"total_countries"`
	Countries    map[string]*CountryStats `json:"countries"`
	LastUpdated  time.Time               `json:"last_updated"`
}

// IPLookupResult is returned by IP lookup command.
type IPLookupResult struct {
	Success bool      `json:"success"`
	IP      string    `json:"ip"`
	Found   bool      `json:"found"`
	Origin  *IPOrigin `json:"origin,omitempty"`
	Message string    `json:"message,omitempty"`
}
