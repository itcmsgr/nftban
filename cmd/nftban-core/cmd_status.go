// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="cmd_status"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Status command showing system state and statistics"
// meta:input="Config from nftbanconf"
// meta:output="Status information to stdout"
// meta:depends="go"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/runtime"
	sharedstate "github.com/itcmsgr/nftban/internal/state"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getStatusConfigDir returns the config directory from passed config
func getStatusConfigDir(cfg *nftbanconf.Config) string {
	return cfg.ConfigDir
}

func cmdStatus(cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🛡️", "System Status"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Initialize RuntimeState
	state := runtime.NewRuntimeState(getStatusConfigDir(cfg))

	// Load whitelists
	fmt.Println("Loading whitelists...")
	if err := state.LoadWhitelists(); err != nil {
		return fmt.Errorf("failed to load whitelists: %w", err)
	}
	fmt.Printf("  ✅ Loaded %d IPv4 + %d IPv6 whitelist entries\n",
		len(state.WhitelistIPv4), len(state.WhitelistIPv6))

	// Load blacklists
	fmt.Println("Loading blacklists...")
	if err := state.LoadBlacklists(); err != nil {
		return fmt.Errorf("failed to load blacklists: %w", err)
	}
	fmt.Printf("  ✅ Loaded %d IPv4 + %d IPv6 blacklist entries\n",
		len(state.BlacklistIPv4), len(state.BlacklistIPv6))

	fmt.Println()

	// Display stats
	// V119 D3: upper-pane counts are file-loaded entries (line count, NOT
	// kernel-enforced element count). Lower "Shared State" pane reports
	// kernel-derived counts from watchdog netlink. Label disambiguation
	// added per V116 §3 D3 — runtime.Counters.TotalBlacklistIPv* field is
	// deliberately NOT renamed to preserve watchdog/metrics surface.
	stats := state.GetStats()
	fmt.Println("📊 Current Statistics:")
	fmt.Println(strings.Repeat("-", 70))
	fmt.Printf("Whitelist IPv4: %d        (configured file entries)\n", stats["whitelist_ipv4"])
	fmt.Printf("Whitelist IPv6: %d        (configured file entries)\n", stats["whitelist_ipv6"])
	fmt.Printf("Blacklist IPv4: %d        (configured file entries)\n", stats["blacklist_ipv4"])
	fmt.Printf("Blacklist IPv6: %d        (configured file entries)\n", stats["blacklist_ipv6"])
	fmt.Printf("Last Reload:    %s\n", stats["last_reload"])
	fmt.Println()

	counters := stats["counters"].(map[string]int64)
	fmt.Println("📈 Counters:")
	fmt.Println(strings.Repeat("-", 70))
	fmt.Printf("Total Bans:     %d\n", counters["bans_total"])
	fmt.Printf("Total Unbans:   %d\n", counters["unbans_total"])
	fmt.Printf("Total Reloads:  %d\n", counters["reloads_total"])
	fmt.Printf("Total Syncs:    %d\n", counters["syncs_total"])
	fmt.Printf("Sync Errors:    %d\n", counters["sync_errors_total"])
	fmt.Println()

	// Display source breakdown
	fmt.Println("📁 Sources:")
	fmt.Println(strings.Repeat("-", 70))
	for sourceName, sourceStats := range state.Sources {
		fmt.Printf("%s:\n", sourceName)
		fmt.Printf("  IPv4: %d | IPv6: %d | Last Update: %s\n",
			sourceStats.IPv4Count,
			sourceStats.IPv6Count,
			sourceStats.LastUpdate.Format("2006-01-02 15:04:05"))
	}
	fmt.Println()

	// Display metrics status from shared state (NO CLI - watchdog data)
	fmt.Println("📊 Metrics (Shared State):")
	fmt.Println(strings.Repeat("-", 70))
	if sharedstate.IsInitialized() {
		snap := sharedstate.Get()
		age := sharedstate.GetAge()
		staleStatus := "✅ fresh"
		if age > 30*time.Second {
			staleStatus = "⚠️ stale"
		}
		fmt.Printf("Banned IPv4:    %d\n", snap.BannedIPv4)
		fmt.Printf("Banned IPv6:    %d\n", snap.BannedIPv6)
		fmt.Printf("Whitelist IPv4: %d\n", snap.WhitelistIPv4)
		fmt.Printf("Whitelist IPv6: %d\n", snap.WhitelistIPv6)
		fmt.Printf("Rules Total:    %d\n", snap.RulesTotal)
		fmt.Printf("Feeds Active:   %d\n", snap.FeedsActive)
		fmt.Printf("Feeds IPs:      %d\n", snap.FeedsIPs)
		fmt.Printf("Data Age:       %s (%s)\n", age.Round(time.Second), staleStatus)
		fmt.Printf("Source:         watchdog (netlink - NO CLI)\n")
	} else {
		fmt.Printf("Status:         ⚠️ Not initialized (watchdog not started)\n")
		fmt.Printf("Source:         watchdog (netlink - NO CLI)\n")
	}
	fmt.Println()

	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("✅ Status check complete!")
	fmt.Println()

	return nil
}
