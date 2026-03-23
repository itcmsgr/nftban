// =============================================================================
// NFTBan v1.5.0 - Report Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="report_types"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-25"
// meta:description="Report type definitions for daily summaries and top lists"
// meta:inventory.files="/var/lib/nftban/reports/"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package reports

import "time"

// DailySummary contains aggregated metrics for one day
type DailySummary struct {
	Date        string    `json:"date"`         // YYYY-MM-DD
	Host        string    `json:"host"`
	GeneratedAt time.Time `json:"generated_at"`

	Totals struct {
		BansAdded      int `json:"bans_added"`
		BansRemoved    int `json:"bans_removed"`
		BansActiveEnd  int `json:"bans_active_end"`
		WhitelistCount int `json:"whitelist_count"`
	} `json:"totals"`

	BansBySource  map[string]int `json:"bans_by_source"`  // loginmon, portscan, ddos, suricata, feeds, manual
	BansByCountry map[string]int `json:"bans_by_country"` // RU, CN, US, etc.

	Feeds map[string]FeedState `json:"feeds"`

	Watchdog struct {
		PressureMax map[string]float64 `json:"pressure_max"` // cpu, memory, io
		ModeChanges int                `json:"mode_changes"`
	} `json:"watchdog"`

	Health struct {
		UptimePercent float64 `json:"uptime_percent"`
		ErrorsCount   int     `json:"errors_count"`
	} `json:"health"`
}

// FeedState represents feed status at time of report
type FeedState struct {
	IPsLoaded int   `json:"ips_loaded"`
	LastSync  int64 `json:"last_sync"` // Unix timestamp
}

// DailyTop contains top lists for one day
type DailyTop struct {
	Date string `json:"date"` // YYYY-MM-DD

	TopBannedIPs  []TopIP        `json:"top_banned_ips"`
	TopCountries  []TopCountry   `json:"top_countries"`
	TopSources    []TopSource    `json:"top_sources"`
	RecidivistIPs []RecidivistIP `json:"recidivist_ips"`
}

// TopIP represents a frequently banned IP
type TopIP struct {
	IP      string   `json:"ip"`
	Count   int      `json:"count"`
	Country string   `json:"country"`
	Sources []string `json:"sources"`
}

// TopCountry represents country ban statistics
type TopCountry struct {
	Country    string  `json:"country"`
	Bans       int     `json:"bans"`
	Percentage float64 `json:"percentage"`
}

// TopSource represents ban source statistics
type TopSource struct {
	Source     string  `json:"source"`
	Bans       int     `json:"bans"`
	Percentage float64 `json:"percentage"`
}

// RecidivistIP represents an IP banned multiple times
type RecidivistIP struct {
	IP        string `json:"ip"`
	BanCount  int    `json:"ban_count"`
	FirstSeen string `json:"first_seen"` // YYYY-MM-DD
	LastSeen  string `json:"last_seen"`  // YYYY-MM-DD
}

// IndexEntry is one line in reports/index.jsonl for fast search
type IndexEntry struct {
	Date       string `json:"date"`
	Bans       int    `json:"bans"`
	Unbans     int    `json:"unbans"`
	Active     int    `json:"active"`
	TopCountry string `json:"top_country"`
	TopSource  string `json:"top_source"`
}
