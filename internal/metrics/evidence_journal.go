// =============================================================================
// NFTBan v1.88 - Journal Evidence Collector (M88-2)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_journal"
// meta:type="package"
// meta:version="1.88.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Collects journal-based evidence for metrics"
// meta:inventory.files="internal/metrics/evidence_journal.go"
// meta:inventory.binaries="journalctl"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// Collects bounded journal evidence for LoginMon activity.
// Uses the same journalctl strategy as the validator (A1-1 pattern):
// global query, bounded window, filter in code.
// =============================================================================
package metrics

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// JournalEvidenceResult holds journal-based evidence for metrics.
type JournalEvidenceResult struct {
	LoginMonActive bool   `json:"loginmon_active"`         // recent ban/login_failed events found
	LoginMonBans   int    `json:"loginmon_bans"`            // ban event count in window
	LoginMonEvents int    `json:"loginmon_events"`          // login_failed event count in window
	Unknown        bool   `json:"unknown,omitempty"`        // collection failed
}

// DataFreshnessResult holds freshness checks for data pipeline artifacts.
type DataFreshnessResult struct {
	FeedFresh    bool   `json:"feed_fresh"`              // feed data files < 7 days old
	FeedAge      string `json:"feed_age,omitempty"`      // human-readable age of newest feed
	GeoIPFresh   bool   `json:"geoip_fresh"`             // GeoIP DB < 45 days old
	GeoIPAge     string `json:"geoip_age,omitempty"`     // human-readable age
	Unknown      bool   `json:"unknown,omitempty"`        // collection failed
}

// CollectJournalEvidence queries nftband journal for LoginMon activity.
// Bounded: 15m window, 500 line cap, 3s timeout.
func CollectJournalEvidence(ctx context.Context) *JournalEvidenceResult {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	output, err := exec.CommandContext(ctx,
		"journalctl", "-u", "nftband", "--since", "-15m",
		"--no-pager", "-o", "cat", "-n", "500",
	).Output() // #nosec G204
	if err != nil {
		// Exec failure (binary missing, permission denied, timeout).
		// Distinct from "no entries" which returns empty output with exit 0.
		return &JournalEvidenceResult{Unknown: true}
	}

	// Empty output with exit 0 = no journal entries in window (not an error)
	if len(strings.TrimSpace(string(output))) == 0 {
		return &JournalEvidenceResult{} // Active=false, Unknown=false
	}

	result := &JournalEvidenceResult{}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.Contains(line, "[EVENT] ban: loginmon") {
			result.LoginMonBans++
		}
		if strings.Contains(line, "[EVENT] login_failed: loginmon") {
			result.LoginMonEvents++
		}
	}

	result.LoginMonActive = result.LoginMonBans > 0 || result.LoginMonEvents > 0
	return result
}

// CollectDataFreshness checks feed and GeoIP data pipeline freshness.
// M88-3: Feed data files in /var/lib/nftban/feeds/ — fresh if any file < 7 days
// M88-4: GeoIP DB at /var/lib/nftban/geoip/dbip-country-lite.mmdb — fresh if < 45 days
func CollectDataFreshness() *DataFreshnessResult {
	result := &DataFreshnessResult{}

	// M88-3: Feed freshness
	feedDir := "/var/lib/nftban/feeds"
	var newestFeed time.Time
	entries, err := os.ReadDir(feedDir)
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			if info.ModTime().After(newestFeed) {
				newestFeed = info.ModTime()
			}
		}
		if !newestFeed.IsZero() {
			age := time.Since(newestFeed)
			result.FeedFresh = age < 7*24*time.Hour
			result.FeedAge = formatAge(age)
		}
	}

	// M88-4: GeoIP freshness
	geoDBPath := "/var/lib/nftban/geoip/dbip-country-lite.mmdb"
	info, err := os.Stat(geoDBPath)
	if err == nil && info.Size() > 0 {
		age := time.Since(info.ModTime())
		result.GeoIPFresh = age < 45*24*time.Hour
		result.GeoIPAge = formatAge(age)
	}

	return result
}

func formatAge(d time.Duration) string {
	days := int(d.Hours() / 24)
	if days == 0 {
		hours := int(d.Hours())
		return fmt.Sprintf("%dh", hours)
	}
	return fmt.Sprintf("%dd", days)
}

// feedDataDir and geoDBPath could be made configurable via env vars if needed.
// For now, using canonical FHS paths proven by fleet audit.
var _ = filepath.Join // suppress unused import
