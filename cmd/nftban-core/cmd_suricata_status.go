// =============================================================================
// NFTBan - Suricata Integration - Status display, filters, and analytics
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Status display, filters, and analytics"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries="suricata"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/suricata/*.conf"
// meta:inventory.systemd_units="suricata.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/itcmsgr/nftban/internal/analytics"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/suricata"
	"github.com/itcmsgr/nftban/pkg/version"
)

// cmdSuricataStatus shows Suricata integration status
func cmdSuricataStatus(cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🛡️", "Suricata Integration Status"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Load config
	configDir, _, _, _ := getSuricataPaths(cfg)
	suricataCfg, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Global status
	fmt.Println("Global Configuration:")
	fmt.Printf("  Enabled:          %v\n", suricataCfg.GlobalEnabled)
	fmt.Printf("  Default Threshold: %d points\n", suricataCfg.DefaultThreshold)
	fmt.Printf("  Default Ban Time:  %s\n", suricataCfg.DefaultBanTime)
	fmt.Printf("  Default Action:    %s\n", suricataCfg.DefaultAction)
	fmt.Printf("  Score Decay:       %s\n", suricataCfg.ScoreDecay)
	fmt.Println()

	// Filter counts
	enabledFilters := suricataCfg.GetEnabledFilters()
	totalFilters := len(suricataCfg.Filters)
	enabledCount := len(enabledFilters)
	disabledCount := totalFilters - enabledCount

	fmt.Println("Filter Summary:")
	fmt.Printf("  Total Filters:    %d\n", totalFilters)
	fmt.Printf("  Enabled:          %d\n", enabledCount)
	fmt.Printf("  Disabled:         %d\n", disabledCount)
	fmt.Println()

	// Eve.json path
	_, evePath, _, _ := getSuricataPaths(cfg)
	if _, err := os.Stat(evePath); err == nil {
		fmt.Printf("✅ Eve log found: %s\n", evePath)
	} else {
		fmt.Printf("❌ Eve log not found: %s\n", evePath)
	}
	fmt.Println()

	return nil
}

// cmdSuricataFilters lists all configured filters
func cmdSuricataFilters(cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🛡️", "Suricata Filters"))
	fmt.Println(strings.Repeat("=", 100))
	fmt.Println()

	// Load config
	configDir, _, _, _ := getSuricataPaths(cfg)
	suricataCfg, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Create table writer
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "FILTER\tENABLED\tTHRESHOLD\tBAN TIME\tACTION\tBAN TYPE\tDESCRIPTION")
	fmt.Fprintln(w, "------\t-------\t---------\t--------\t------\t--------\t-----------")

	// Print each filter
	for name, filter := range suricataCfg.Filters {
		enabled := "✗"
		if filter.Enabled {
			enabled = "✓"
		}

		// Format ban type for display
		banTypeDisplay := filter.BanType
		if filter.BanType == "escalate" {
			banTypeDisplay = fmt.Sprintf("escalate:%d:%s", filter.MaxBans, filter.Period)
		}

		fmt.Fprintf(w, "%s\t%s\t%d\t%s\t%s\t%s\t%s\n",
			name,
			enabled,
			filter.Threshold,
			filter.BanTime,
			filter.Action,
			banTypeDisplay,
			filter.Description,
		)
	}

	_ = w.Flush()
	fmt.Println()
	fmt.Println("Legend:")
	fmt.Println("  Action modes:")
	fmt.Println("    log     - Log events only (testing, no bans)")
	fmt.Println("    observe - Log and track scores (tuning, no bans)")
	fmt.Println("    ban     - Ban IPs when threshold exceeded (production)")
	fmt.Println()
	fmt.Println("  Ban types:")
	fmt.Println("    temporary       - Always ban for ban_time duration")
	fmt.Println("    permanent       - Always ban permanently (forever)")
	fmt.Println("    escalate:N:T    - Ban temp initially, permanent after N bans in time T")
	fmt.Println()
	fmt.Println("Tip: Edit /etc/suricata/filters.conf.local to customize filters")
	fmt.Println()

	return nil
}

// appendFilterToLocal appends a filter configuration to the .local file
func appendFilterToLocal(localPath string, filter *suricata.FilterConfig) error {
	// Read existing .local file
	var existingLines []string
	if data, err := os.ReadFile(localPath); err == nil {
		existingLines = strings.Split(string(data), "\n")
	}

	// Remove existing entry for this filter
	newLines := []string{}
	inFiltersSection := false
	for _, line := range existingLines {
		trimmed := strings.TrimSpace(line)

		// Track if we're in [filters] section
		if trimmed == "[filters]" {
			inFiltersSection = true
			newLines = append(newLines, line)
			continue
		}
		if strings.HasPrefix(trimmed, "[") && trimmed != "[filters]" {
			inFiltersSection = false
		}

		// Skip line if it's this filter
		if inFiltersSection && strings.HasPrefix(trimmed, filter.Name+" =") {
			continue
		}

		newLines = append(newLines, line)
	}

	// Add [filters] section if not present
	hasFiltersSection := false
	for _, line := range newLines {
		if strings.TrimSpace(line) == "[filters]" {
			hasFiltersSection = true
			break
		}
	}

	if !hasFiltersSection {
		newLines = append(newLines, "", "[filters]")
	}

	// Format filter line
	keywords := strings.Join(filter.Keywords, ",")
	enabled := "false"
	if filter.Enabled {
		enabled = "true"
	}

	// Format ban type
	banTypeStr := filter.BanType
	if filter.BanType == "escalate" {
		banTypeStr = fmt.Sprintf("escalate:%d:%s", filter.MaxBans, filter.Period)
	}

	filterLine := fmt.Sprintf("%s = %s | %s | %d | %s | %s | %s | %s",
		filter.Name,
		enabled,
		keywords,
		filter.Threshold,
		filter.BanTime,
		filter.Action,
		banTypeStr,
		filter.Description,
	)

	// Append new filter line
	newLines = append(newLines, filterLine)

	// Write back to file
	content := strings.Join(newLines, "\n")
	if err := os.WriteFile(localPath, []byte(content), 0644); err != nil {
		return fmt.Errorf("failed to write file: %w", err)
	}

	return nil
}

// initAnalyticsIfNeeded initializes analytics if not already done
func initAnalyticsIfNeeded() error {
	if analytics.StateOrNil() != nil {
		return nil // Already initialized
	}
	cfg := nftbanconf.MustLoad()
	_, _, _, dataDir := getSuricataPaths(cfg)
	return analytics.Init(dataDir, dataDir+"/reports")
}

// saveAnalyticsIfNeeded saves analytics state if initialized
func saveAnalyticsIfNeeded() {
	if st := analytics.StateOrNil(); st != nil {
		if err := st.Save(); err != nil {
			log.Printf("Warning: Failed to save analytics: %v", err)
		}
	}
}
