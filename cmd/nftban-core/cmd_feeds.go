// =============================================================================
// NFTBan - Threat Feeds Management Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="cmd_feeds"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Manage threat intelligence feeds for IP blocking"
// meta:input="Subcommand (list, load, stats, enable, disable, sync, update)"
// meta:output="Console output with feed status and operations"
// meta:depends="github.com/itcmsgr/nftban/internal/feeds,github.com/itcmsgr/nftban/pkg/ipc,github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/feeds.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network="http"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/version"
)

// feedFileOwner returns the owner of an enforced feed snapshot: root:nftban (v1.238,
// SEC-FEED-STAGING-SNAPSHOTS-OWNED-BY-NFTBAN-ACCOUNT, fhs-spec /var/lib/nftban/feeds *.txt).
// The nftban group keeps read access (unified exporter, operators); the service account no
// longer owns the content root enforces. ok=false: no nftban group, the file stays root:root.
// A variable so tests can run unprivileged.
var feedFileOwner = feeds.FileOwner

// writeFeedFile writes entries to outputFile as root:nftban 0640, correct AT CREATION, through
// the one feed-directory writer (feeds.WriteFeedDirFile: os.Root, exclusive 0600 temp file,
// owned through its descriptor, widened to 0640, synced, renamed over the snapshot).
func writeFeedFile(outputFile string, entries []string) error {
	dir, name := filepath.Split(outputFile)
	if dir == "" {
		dir = "."
	}
	var b strings.Builder
	for _, ip := range entries {
		b.WriteString(ip)
		b.WriteByte('\n')
	}
	return feeds.WriteFeedDirFile(dir, name, []byte(b.String()), feedFileOwner)
}

// selectFeedsForUpdate: no name = every enabled feed (timer path, unchanged); a name = only
// that feed (BUG-FEEDS-UPDATE-SINGLE-FEED-REFRESHES-ALL). Names match case-insensitively. An
// unknown or disabled feed is refused, never reported as updated.
func selectFeedsForUpdate(configs []FeedConfig, name string) ([]FeedConfig, error) {
	if name == "" {
		sel := []FeedConfig{}
		for _, fc := range configs {
			if fc.Enabled {
				sel = append(sel, fc)
			}
		}
		return sel, nil
	}
	for _, fc := range configs {
		if strings.EqualFold(fc.Name, name) {
			if !fc.Enabled {
				return nil, fmt.Errorf("feed %s is disabled; enable it first: nftban feeds enable %s", fc.Name, fc.Name)
			}
			return []FeedConfig{fc}, nil
		}
	}
	return nil, fmt.Errorf("unknown feed: %s (list: nftban feeds list)", name)
}

// extractConfigValue extracts a config value, handling trailing comments
// Input: "true"              # comment  -> Output: true
// Input: "false"             -> Output: false
// Input: "https://example.com" # URL -> Output: https://example.com
func extractConfigValue(rawValue string) string {
	// Strip trailing comment (anything after # outside quotes)
	// Config format is always: "value" [# comment]
	if idx := strings.Index(rawValue, "#"); idx != -1 {
		rawValue = rawValue[:idx]
	}
	// Trim quotes and whitespace
	return strings.Trim(rawValue, `"' `)
}

// replaceConfigValue replaces a config variable value using regex to handle spacing variations
// Pattern matches: VAR="value", VAR = "value", VAR= "value", etc.
func replaceConfigValue(content, varName, newValue string) string {
	// Regex pattern: varName + optional spaces + = + optional spaces + quoted value
	pattern := regexp.MustCompile(fmt.Sprintf(`(?m)^(\s*)%s\s*=\s*"[^"]*"(.*)$`, regexp.QuoteMeta(varName)))
	replacement := fmt.Sprintf(`${1}%s="%s"${2}`, varName, newValue)
	return pattern.ReplaceAllString(content, replacement)
}

// getFeedsPaths returns feeds directory and config paths from passed config
func getFeedsPaths(cfg *nftbanconf.Config) (feedsDir, feedsConfig, configDir string) {
	return cfg.DataDir + "/feeds", cfg.ConfigDir + "/conf.d/feeds.conf", cfg.ConfigDir
}

func cmdFeeds(action string, cfg *nftbanconf.Config) error {
	feedsDir, feedsConfig, _ := getFeedsPaths(cfg)

	switch action {
	case "list":
		return cmdFeedsList(feedsDir, cfg)
	case "load":
		return cmdFeedsLoad(feedsDir, cfg)
	case "stats":
		return cmdFeedsStats(feedsDir)
	case "enable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core feeds enable <FEED_NAME>")
		}
		feedName := os.Args[3]
		return cmdFeedsEnable(feedsConfig, feedName, true)
	case "disable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core feeds disable <FEED_NAME>")
		}
		feedName := os.Args[3]
		return cmdFeedsEnable(feedsConfig, feedName, false)
	case "effective":
		return cmdFeedsEffective(cfg)
	case "status":
		return cmdFeedsStatus(feedsConfig, cfg)
	case "abuseipdb-key":
		sub := ""
		if len(os.Args) >= 4 {
			sub = os.Args[3]
		}
		return cmdFeedsAbuseIPDBKey(cfg, sub)
	case "abuseipdb-test":
		return cmdFeedsAbuseIPDBTest(cfg)
	case "resolve":
		// v1.236 (design §7): records the operator's master decision. Called by
		// `nftban feeds enable|disable` without a feed name, after the switch is set.
		if len(os.Args) < 4 || (os.Args[3] != "enabled" && os.Args[3] != "disabled") {
			return fmt.Errorf("usage: nftban-core feeds resolve <enabled|disabled>")
		}
		state := feeds.StateResolvedEnabled
		if os.Args[3] == "disabled" {
			state = feeds.StateResolvedDisabled
		}
		return feeds.WriteState(cfg.DataDir, state, "", time.Now())
	case "sync":
		return cmdFeedsSync(feedsDir, feedsConfig, cfg)
	case "update":
		feedName := ""
		if len(os.Args) >= 4 {
			feedName = os.Args[3]
		}
		return cmdFeedsUpdate(feedsDir, feedsConfig, feedName, cfg)
	default:
		return fmt.Errorf("unknown feeds action: %s\nUsage: nftban-core feeds [list|load|stats|status [--json] [--all] [--feed NAME]|update [FEED_NAME]|enable|disable|sync|effective|abuseipdb-key <set|status|remove>|abuseipdb-test [--json]] [FEED_NAME]", action)
	}
}

// getFeedsEnabledStatus reads the feeds config and returns a map of feed name -> enabled status
// Config loading order (last wins): feeds.conf → feeds.conf.local → nftban.conf.local (central)
// cmdFeedsEffective prints the feed authority (design §7) as JSON, read-only: it never
// records state. An undecidable authority is an error (nonzero exit), never a guess.
func cmdFeedsEffective(cfg *nftbanconf.Config) error {
	d, err := feeds.Evaluate(cfg.ConfigDir, cfg.DataDir, cfg.FeedsEnabled)
	if err != nil {
		return fmt.Errorf("feed authority undecidable: %w", err)
	}
	out := map[string]interface{}{
		"master":      d.Master,
		"state":       d.State,
		"recorded":    d.Recorded,
		"enforced":    d.Enforced,
		"not_enabled": d.NotEnabled,
		"expired":     d.Expired,
		"reasons":     d.Reasons,
		"texts":       d.Texts,
	}
	data, err := json.Marshal(out)
	if err != nil {
		return err
	}
	fmt.Println(string(data))
	return nil
}

// v1.236: one reader, shared with the feed authority (internal/feeds.EnabledStatus).
func getFeedsEnabledStatus(configPath string) map[string]bool {
	return feeds.EnabledStatus(filepath.Dir(filepath.Dir(configPath))) // conf.d/feeds.conf → /etc/nftban
}

func cmdFeedsList(feedsDir string, cfg *nftbanconf.Config) error {
	// Check for --json flag
	jsonOutput := hasFlag("--json")

	// Read config to get enabled/disabled status
	_, configPath, _ := getFeedsPaths(cfg)
	enabledMap := getFeedsEnabledStatus(configPath)

	feedsList, err := feeds.ListAvailableFeeds(feedsDir)
	if err != nil {
		if jsonOutput {
			output := map[string]interface{}{
				"success": false,
				"error":   err.Error(),
			}
			data, _ := json.MarshalIndent(output, "", "  ")
			fmt.Println(string(data))
			return err
		}
		return fmt.Errorf("failed to list feeds: %w", err)
	}

	if jsonOutput {
		// Get feed stats for counts
		feedsInfo, _ := feeds.GetFeedStats(feedsDir)

		// Build hash map for O(1) lookup instead of O(n²) nested loops
		feedsInfoMap := make(map[string]*feeds.FeedInfo, len(feedsInfo))
		for i := range feedsInfo {
			feedsInfoMap[feedsInfo[i].Name] = &feedsInfo[i]
		}

		// Build feeds array with details - now O(n) instead of O(n²)
		feedsData := []map[string]interface{}{}
		for _, feedName := range feedsList {
			// Check if enabled in config
			enabled := enabledMap[strings.ToUpper(feedName)]

			feedData := map[string]interface{}{
				"name":    feedName,
				"enabled": enabled,
				"count":   0,
			}

			// O(1) lookup instead of O(n) linear search
			if info, ok := feedsInfoMap[feedName]; ok {
				feedData["count"] = info.IPv4Count + info.IPv6Count
				feedData["ipv4_count"] = info.IPv4Count
				feedData["ipv6_count"] = info.IPv6Count
				feedData["last_updated"] = info.LastUpdated
			}

			feedsData = append(feedsData, feedData)
		}

		output := map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"feeds": feedsData,
				"total": len(feedsList),
			},
		}
		data, _ := json.MarshalIndent(output, "", "  ")
		fmt.Println(string(data))
		return nil
	}

	// Human-readable output
	fmt.Println(version.BannerWithEmoji("🗂️", "Available Feeds"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	if len(feedsList) == 0 {
		fmt.Println("No feeds found.")
		fmt.Printf("Feed directory: %s\n", feedsDir)
		return nil
	}

	fmt.Printf("Found %d feeds:\n\n", len(feedsList))
	for i, feedName := range feedsList {
		// Check if enabled in config
		isEnabled := enabledMap[strings.ToUpper(feedName)]
		status := "disabled"
		marker := "[✗]"
		if isEnabled {
			status = "enabled"
			marker = "[✓]"
		}

		fmt.Printf("  %d. %s %s %s\n", i+1, marker, feedName, status)
	}
	fmt.Println()

	return nil
}

func cmdFeedsStats(feedsDir string) error {
	// Check for --json flag
	jsonOutput := hasFlag("--json")

	feedsInfo, err := feeds.GetFeedStats(feedsDir)
	if err != nil {
		if jsonOutput {
			output := map[string]interface{}{
				"success": false,
				"error":   err.Error(),
			}
			data, _ := json.MarshalIndent(output, "", "  ")
			fmt.Println(string(data))
			return err
		}
		return fmt.Errorf("failed to get feed stats: %w", err)
	}

	totalIPv4 := 0
	totalIPv6 := 0

	for _, feed := range feedsInfo {
		totalIPv4 += feed.IPv4Count
		totalIPv6 += feed.IPv6Count
	}

	if jsonOutput {
		// Build feeds array
		feedsData := []map[string]interface{}{}
		for _, feed := range feedsInfo {
			feedsData = append(feedsData, map[string]interface{}{
				"name":         feed.Name,
				"ipv4_count":   feed.IPv4Count,
				"ipv6_count":   feed.IPv6Count,
				"total":        feed.IPv4Count + feed.IPv6Count,
				"last_updated": feed.LastUpdated,
			})
		}

		output := map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"feeds":       feedsData,
				"total_feeds": len(feedsInfo),
				"total_ipv4":  totalIPv4,
				"total_ipv6":  totalIPv6,
				"grand_total": totalIPv4 + totalIPv6,
			},
		}
		data, _ := json.MarshalIndent(output, "", "  ")
		fmt.Println(string(data))
		return nil
	}

	// Human-readable output
	fmt.Println(version.BannerWithEmoji("📊", "Feeds Statistics"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	if len(feedsInfo) == 0 {
		fmt.Println("No feeds found.")
		return nil
	}

	fmt.Println("Feed Details:")
	fmt.Println(strings.Repeat("-", 70))
	for _, feed := range feedsInfo {
		fmt.Printf("\n%s:\n", feed.Name)
		fmt.Printf("  IPv4: %d IPs\n", feed.IPv4Count)
		fmt.Printf("  IPv6: %d IPs\n", feed.IPv6Count)
		fmt.Printf("  Total: %d IPs\n", feed.IPv4Count+feed.IPv6Count)
		fmt.Printf("  Last Updated: %s\n", feed.LastUpdated)
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("Summary:")
	fmt.Printf("  Total Feeds: %d\n", len(feedsInfo))
	fmt.Printf("  Total IPv4: %d\n", totalIPv4)
	fmt.Printf("  Total IPv6: %d\n", totalIPv6)
	fmt.Printf("  Grand Total: %d IPs\n", totalIPv4+totalIPv6)
	fmt.Println()

	return nil
}

func cmdFeedsLoad(feedsDir string, cfg *nftbanconf.Config) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Println(version.BannerWithEmoji("🔄", "Load Feeds"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Step 1: load the feeds the ONE feed authority enforces (v1.238 D5-2): never a disabled,
	// not-enabled or expired feed. The load stays additive (its callers' semantics); the daemon
	// full sync is what removes entries.
	fmt.Println("Step 1: Loading enforced feeds from disk...")
	fd, err := feeds.Evaluate(cfg.ConfigDir, cfg.DataDir, cfg.FeedsEnabled)
	if err != nil {
		return fmt.Errorf("feed authority undecidable, nothing loaded: %w", err)
	}
	for _, t := range fd.Texts {
		fmt.Printf("  ℹ️  %s\n", t)
	}
	if len(fd.Enforced) == 0 {
		fmt.Println("  ⚠️  No enforced feeds: nothing to load")
		return nil
	}
	ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, err := feeds.LoadEnforcedFeeds(feedsDir, fd.Enforced)
	if err != nil {
		return fmt.Errorf("failed to load feeds: %w", err)
	}

	totalEntries := len(ipv4Set) + len(ipv4CIDRSet) + len(ipv6Set) + len(ipv6CIDRSet)
	if totalEntries == 0 {
		fmt.Println("  ⚠️  Enforced feeds hold no entries: nothing to load")
		return nil
	}

	fmt.Printf("  ✅ Loaded %d enforced feeds: %s\n", len(fd.Enforced), strings.Join(fd.Enforced, ", "))
	fmt.Printf("  ✅ Total IPv4: %d IPs + %d CIDRs\n", len(ipv4Set), len(ipv4CIDRSet))
	fmt.Printf("  ✅ Total IPv6: %d IPs + %d CIDRs\n", len(ipv6Set), len(ipv6CIDRSet))
	fmt.Println()

	// Warn about large feed sets
	if totalEntries > 100000 {
		fmt.Println("  ⚠️  WARNING: Large feed set detected!")
		fmt.Printf("     Loading %d entries will take 30-60 seconds.\n", totalEntries)
		fmt.Println("     After loading, 'nft list ruleset' will be VERY SLOW (60-90 sec).")
		fmt.Println("     USE 'nft -t list ruleset' instead (terse mode - fast).")
		fmt.Println()
		fmt.Println("     See docs/FEEDS_PERFORMANCE.md for details.")
		fmt.Println()
	}

	// Step 2: Connect to daemon
	fmt.Println("Step 2: Connecting to nftband daemon...")
	client := ipc.NewClient()
	if err := client.Ping(); err != nil {
		return fmt.Errorf("daemon not running: %w\nStart with: sudo systemctl start nftband", err)
	}
	fmt.Println("  ✅ Connected to nftband daemon")
	fmt.Println()

	// Step 3: Load feeds via IPC
	fmt.Println("Step 3: Loading feeds into blacklist via daemon...")

	// Increase timeout for large feed sets (CIDR merging + nftables loading takes time)
	// ~5k CIDRs typically needs 2-4 minutes for merge + load on slower systems
	// Formula: base 90s + 1 second per 30 entries, cap at 10 minutes
	if totalEntries > 500 {
		loadTimeout := time.Duration(90+totalEntries/30) * time.Second
		if loadTimeout > 10*time.Minute {
			loadTimeout = 10 * time.Minute // Cap at 10 minutes
		}
		client.SetTimeout(loadTimeout)
		fmt.Printf("  ⏱️  Timeout set to %v for %d entries\n", loadTimeout, totalEntries)
	}

	// Combine IPv4 IPs (as /32) and CIDRs into single list
	var ipv4Combined []string
	for ip := range ipv4Set {
		ipv4Combined = append(ipv4Combined, ip+"/32")
	}
	for cidr := range ipv4CIDRSet {
		ipv4Combined = append(ipv4Combined, cidr)
	}

	// Combine IPv6 IPs (as /128) and CIDRs into single list
	var ipv6Combined []string
	for ip := range ipv6Set {
		ipv6Combined = append(ipv6Combined, ip+"/128")
	}
	for cidr := range ipv6CIDRSet {
		ipv6Combined = append(ipv6Combined, cidr)
	}

	// Combine all CIDRs
	allCIDRs := append(ipv4Combined, ipv6Combined...)

	resp, err := client.LoadCIDRs("blacklist", allCIDRs)
	if err != nil {
		return fmt.Errorf("failed to load feeds: %w", err)
	}

	if !resp.Success {
		return fmt.Errorf("failed to load feeds: %s", resp.Error)
	}

	// Extract results
	data, ok := resp.Data.(map[string]any)
	if !ok {
		return fmt.Errorf("unexpected response format")
	}

	// v1.235 (owner 2026-10-08): prefixes dropped WHOLE at the never-ban split limit are
	// a protection gap; the load is reported DEGRADED and the command fails, never "✅".
	if degraded, _ := data["degraded"].(bool); degraded {
		fmt.Println()
		fmt.Printf("⚠️  Feeds loaded PARTIALLY (DEGRADED: %v)\n", data["degraded_reason"])
		if pfx, ok := data["exempt_split_limit_prefixes"].([]any); ok {
			fmt.Printf("   %d prefix(es) NOT loaded: splitting them around never-ban addresses would exceed the split limit;\n", len(pfx))
			fmt.Printf("   their non-exempt addresses are NOT blocked:\n")
			for _, p := range pfx {
				fmt.Printf("     - %v\n", p)
			}
		}
		return fmt.Errorf("feeds loaded partially: %v (see above and the daemon log)", data["degraded_reason"])
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	fmt.Printf("✅ Feeds loaded into blacklist successfully!\n")
	fmt.Println()
	fmt.Printf("Architecture: v1.0 Consolidated Blacklist\n")
	fmt.Printf("  - All threat feeds merged into blacklist_ipv4/ipv6 sets\n")
	fmt.Printf("  - Firewall rules check @blacklist (no separate @feeds check needed)\n")
	fmt.Println()
	fmt.Printf("Feed entries: %d IPv4 IPs + %d IPv4 CIDRs\n", len(ipv4Set), len(ipv4CIDRSet))
	fmt.Printf("              %d IPv6 IPs + %d IPv6 CIDRs\n", len(ipv6Set), len(ipv6CIDRSet))

	// Show results from daemon
	if ipv4Input, ok := data["ipv4_input"].(float64); ok && ipv4Input > 0 {
		if ipv4Ranges, ok := data["ipv4_output_ranges"].(float64); ok {
			if reduction, ok := data["ipv4_reduction_pct"].(float64); ok {
				fmt.Printf("Optimized to:  %.0f IPv4 ranges (%.1f%% reduction)\n", ipv4Ranges, reduction)
			}
		}
	}
	if ipv6Input, ok := data["ipv6_input"].(float64); ok && ipv6Input > 0 {
		if ipv6Ranges, ok := data["ipv6_output_ranges"].(float64); ok {
			if reduction, ok := data["ipv6_reduction_pct"].(float64); ok {
				fmt.Printf("              %.0f IPv6 ranges (%.1f%% reduction)\n", ipv6Ranges, reduction)
			}
		}
	}
	fmt.Println()
	fmt.Println("⚠️  NOTE: Existing blacklist entries (manual bans, etc.) preserved.")
	fmt.Println("Feeds are now ACTIVE and blocking traffic.")
	fmt.Println()

	// Performance warning for large sets
	totalInput := 0
	if v, ok := data["total_input"].(float64); ok {
		totalInput = int(v)
	}
	if totalInput > 100000 {
		fmt.Println(strings.Repeat("=", 70))
		fmt.Println("⚠️  PERFORMANCE WARNING:")
		fmt.Printf("   You have %d entries loaded in nftables.\n", totalInput)
		fmt.Println()
		fmt.Println("   IMPORTANT: Use terse mode when listing rules:")
		fmt.Println("   ✅ nft -t list ruleset      (fast - < 1 second)")
		fmt.Println("   ❌ nft list ruleset          (VERY slow - 60-90 seconds!)")
		fmt.Println()
		fmt.Println("   To check specific IPs:")
		fmt.Println("   nft get element ip nftban blacklist_ipv4 { 1.2.3.4 }")
		fmt.Println()
		fmt.Println("   Documentation: docs/FEEDS_PERFORMANCE.md")
		fmt.Println(strings.Repeat("=", 70))
		fmt.Println()
	}

	return nil
}

func cmdFeedsEnable(configPath, feedName string, enable bool) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	action := "disable"
	if enable {
		action = "enable"
	}

	// Verify feed exists in module config (feeds.conf defines available feeds)
	content, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("failed to read feeds config: %w", err)
	}

	// Convert feed name to uppercase for config variable
	feedNameUpper := strings.ToUpper(feedName)
	enabledVar := fmt.Sprintf("FEED_%s_ENABLED", feedNameUpper)

	// Check if feed exists in config (URL must be defined in feeds.conf)
	urlVar := fmt.Sprintf("FEED_%s_URL", feedNameUpper)
	if !strings.Contains(string(content), urlVar) {
		return fmt.Errorf("feed '%s' not found in config\nAvailable feeds: run 'nftban feeds list'", feedName)
	}

	// Central config architecture: write to nftban.conf.local (never modify package defaults)
	configDir := filepath.Dir(filepath.Dir(configPath)) // conf.d/feeds.conf → /etc/nftban
	localConf := configDir + "/nftban.conf.local"

	newValue := "false"
	if enable {
		newValue = "true"
	}

	// Read or create nftban.conf.local
	localContent := ""
	if data, err := os.ReadFile(localConf); err == nil {
		localContent = string(data)
	}

	// Check if variable already exists in .local with same value
	if strings.Contains(localContent, fmt.Sprintf(`%s="%s"`, enabledVar, newValue)) {
		if enable {
			fmt.Printf("Feed '%s' is already enabled\n", feedName)
		} else {
			fmt.Printf("Feed '%s' is already disabled\n", feedName)
		}
		return nil
	}

	// Update or append the variable in nftban.conf.local
	newLine := fmt.Sprintf(`%s="%s"`, enabledVar, newValue)
	sectionMarker := "# --- FEEDS Configuration ---"

	if strings.Contains(localContent, enabledVar+"=") {
		// Replace existing value
		localContent = replaceConfigValue(localContent, enabledVar, newValue)
	} else if strings.Contains(localContent, sectionMarker) {
		// Append under existing FEEDS section
		localContent = strings.Replace(localContent, sectionMarker, sectionMarker+"\n"+newLine, 1)
	} else {
		// Create FEEDS section
		if localContent != "" && !strings.HasSuffix(localContent, "\n") {
			localContent += "\n"
		}
		if localContent == "" {
			localContent = "# NFTBan Local Configuration Overrides\n# Auto-generated by nftban config command\n"
		}
		localContent += "\n" + sectionMarker + "\n" + newLine + "\n"
	}

	// Write to nftban.conf.local (central override — survives package upgrades)
	if err := os.WriteFile(localConf, []byte(localContent), 0640); err != nil {
		return fmt.Errorf("failed to write %s: %w", localConf, err)
	}

	fmt.Printf("✅ Feed '%s' %sd successfully\n", feedName, action)

	if enable {
		fmt.Println()
		fmt.Println("Next steps:")
		fmt.Println("  1. Update feeds: nftban feeds update  (downloads the feed)")
		fmt.Println("  2. Load feeds:   sudo nftban-core feeds load  (loads into nftables)")
	} else {
		fmt.Println()
		fmt.Println("Feed disabled. To remove from nftables:")
		fmt.Printf("  sudo rm /var/lib/nftban/feeds/%s.txt\n", strings.ToLower(feedName))
		fmt.Println("  sudo nftban-core feeds load  (reload without this feed)")
	}

	return nil
}

func cmdFeedsSync(feedsDir, configPath string, cfg *nftbanconf.Config) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	// Path to store last config hash - use data dir from passed config
	stateFile := cfg.DataDir + "/feeds.state"

	// Check module config + central override (nftban.conf.local)
	configFiles := []string{
		configPath,
		configPath + ".local",
		cfg.ConfigDir + "/nftban.conf.local",
	}

	// Get latest modification time from all config files
	var latestModTime int64
	var changedFile string
	for _, cf := range configFiles {
		if info, err := os.Stat(cf); err == nil {
			modTime := info.ModTime().Unix()
			if modTime > latestModTime {
				latestModTime = modTime
				changedFile = cf
			}
		}
	}

	if latestModTime == 0 {
		return fmt.Errorf("no config files found")
	}

	// Read previous mod time from state file
	var lastModTime int64
	if data, err := os.ReadFile(stateFile); err == nil {
		fmt.Sscanf(string(data), "%d", &lastModTime)
	}

	// Check if config changed
	if latestModTime <= lastModTime {
		fmt.Println("✅ Feeds config unchanged, no sync needed")
		return nil
	}

	fmt.Println("🔄 Config change detected, syncing feeds...")
	if lastModTime > 0 {
		fmt.Printf("   Last sync: %s\n", time.Unix(lastModTime, 0).Format("2006-01-02 15:04:05"))
	} else {
		fmt.Println("   Last sync: Never")
	}
	fmt.Printf("   Changed file: %s\n", changedFile)
	fmt.Printf("   Modified: %s\n", time.Unix(latestModTime, 0).Format("2006-01-02 15:04:05"))
	fmt.Println()

	// Reload feeds
	err := cmdFeedsLoad(feedsDir, cfg)
	if err != nil {
		return fmt.Errorf("failed to reload feeds: %w", err)
	}

	// Save new mod time
	err = os.WriteFile(stateFile, []byte(fmt.Sprintf("%d", latestModTime)), 0644)
	if err != nil {
		// Non-fatal, just warn
		fmt.Printf("⚠️  Warning: failed to update state file: %v\n", err)
	}

	fmt.Println()
	fmt.Println("✅ Feeds synced successfully")

	return nil
}

// FeedConfig represents a single feed configuration
type FeedConfig struct {
	Name        string
	URL         string
	Enabled     bool
	Category    string
	Description string
	// v1.238 part B
	Format            string        // "" = plain IP/CIDR list; "abuseipdb" = AbuseIPDB blacklist API
	MinInterval       time.Duration // no new request sooner than this after the last success (0 = none)
	ConfidenceMinimum int           // abuseipdb: 0 = provider default
	Limit             int           // abuseipdb: 0 = provider default
}

// FeedFormatAbuseIPDB selects the AbuseIPDB blacklist provider (key from abuseIPDBKeyFile).
const FeedFormatAbuseIPDB = "abuseipdb"

// abuseIPDBKeyName is the credential file in the config dir (fhs-spec: root:root 0600). Fixed, not
// configurable: the key is read from one declared, root-only place.
const abuseIPDBKeyName = "abuseipdb.key"

// cmdFeedsUpdate downloads every enabled feed, or only feedName when given, using native Go HTTP
func cmdFeedsUpdate(feedsDir, configPath, feedName string, cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🔄", "Update Feeds"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Step 1: Parse config to get enabled feeds
	fmt.Println("Step 1: Reading feeds configuration...")
	feedConfigs, err := parseFeedsConfig(configPath)
	if err != nil {
		return fmt.Errorf("failed to parse feeds config: %w", err)
	}

	enabledFeeds, err := selectFeedsForUpdate(feedConfigs, feedName)
	if err != nil {
		return err
	}

	if feedName != "" {
		fmt.Printf("  ✅ Updating one feed: %s\n", enabledFeeds[0].Name)
	} else {
		fmt.Printf("  ✅ Found %d feeds (%d enabled)\n", len(feedConfigs), len(enabledFeeds))
	}
	fmt.Println()

	if len(enabledFeeds) == 0 {
		fmt.Println("⚠️  No feeds enabled. Use 'nftban feeds enable <name>' to enable feeds.")
		fmt.Println("   Available feeds: nftban feeds list")
		return nil
	}

	// Step 2: Ensure feeds directory exists
	fmt.Println("Step 2: Preparing feeds directory...")
	if err := os.MkdirAll(feedsDir, 0755); err != nil {
		return fmt.Errorf("failed to create feeds directory: %w", err)
	}
	fmt.Printf("  ✅ Directory ready: %s\n", feedsDir)
	fmt.Println()

	// Step 3: Download each enabled feed
	fmt.Println("Step 3: Downloading feeds...")
	fmt.Println(strings.Repeat("-", 70))

	successCount, failCount, deferredCount, totalIPs := 0, 0, 0, 0
	var failed, deferred []string
	now := time.Now()

	for i, feed := range enabledFeeds {
		fmt.Printf("\n[%d/%d] %s\n", i+1, len(enabledFeeds), feed.Name)
		fmt.Printf("  Category: %s\n", feed.Category)
		if feed.Format == FeedFormatAbuseIPDB {
			fmt.Printf("  Provider: AbuseIPDB blacklist API (key: %s)\n", filepath.Join(cfg.ConfigDir, abuseIPDBKeyName))
		} else {
			fmt.Printf("  URL: %s\n", feed.URL)
		}

		switch r := refreshOne(feed, feedsDir, cfg.ConfigDir, now); r.outcome {
		case refreshDeferred:
			deferredCount++
			deferred = append(deferred, feed.Name)
		case refreshFailed:
			failCount++
			failed = append(failed, feed.Name)
		default:
			successCount++
			totalIPs += r.entries
		}
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("Download Summary:")
	fmt.Printf("  ✅ Success: %d feeds\n", successCount)
	if failCount > 0 {
		fmt.Printf("  ❌ Failed: %d feeds (%s)\n", failCount, strings.Join(failed, ", "))
	}
	if deferredCount > 0 {
		fmt.Printf("  ⏸️  Deferred: %d feeds (%s)\n", deferredCount, strings.Join(deferred, ", "))
	}
	fmt.Printf("  📊 Total IPs/CIDRs: %d\n", totalIPs)
	fmt.Println()

	// Step 4 (v1.238 D5-2, owner GO 2026-11-20): the daemon's own full sync, not the additive
	// load. It applies the ONE feed authority (enforced feeds only: disabled, not-enabled and
	// expired feeds are dropped) in the daemon's single-writer atomic transaction with the
	// never-ban split and protection rules. It runs whatever the download outcome, so an expiry
	// or a disable takes effect even when every refresh failed. The daemon records the sync
	// outcome (feeds/full-sync.status) itself.
	fmt.Println("Step 4: Applying feeds through the daemon full sync...")
	syncErr := runDaemonSync(false, "", 5*time.Minute)

	// v1.238 part B: download and sync outcomes are separate and both decide the exit status. A
	// failed download is non-zero even when the sync succeeded; a failed sync is non-zero even
	// when every download succeeded.
	return updateOutcome(feedName, failed, deferred, syncErr)
}

// Refresh outcomes of one feed.
const (
	refreshOK       = "ok"
	refreshFailed   = "failed"
	refreshDeferred = "deferred"
)

type refreshResult struct {
	outcome string
	entries int
}

// Fetchers (variables so tests use a mock).
var (
	fetchPlainFn     = fetchPlain
	fetchAbuseIPDBFn = fetchAbuseIPDB
)

// refreshOne refreshes one feed (v1.238 part B). No request is sent before the provider's
// back-off or the feed's minimum interval (deferred: the record is not touched, nothing was
// attempted). A failed request leaves the snapshot and its last successful refresh time as they
// were and records the failure; a success replaces the snapshot first, then records it.
func refreshOne(feed FeedConfig, feedsDir, configDir string, now time.Time) refreshResult {
	rec, _, rerr := feeds.ReadRefresh(feedsDir, feed.Name)
	if rerr != nil {
		fmt.Printf("  ⚠️  %v (replaced by the next outcome)\n", rerr)
	}
	if next := feeds.NextPermitted(rec, feed.MinInterval, now); !next.IsZero() {
		fmt.Printf("  ⏸️  Deferred: next permitted request %s (in %s)\n", next.UTC().Format("2006-01-02 15:04 UTC"), next.Sub(now).Round(time.Minute))
		return refreshResult{outcome: refreshDeferred}
	}

	var res *fetchResult
	var err error
	if feed.Format == FeedFormatAbuseIPDB {
		res, err = fetchAbuseIPDBFn(feed, configDir)
	} else {
		res, err = fetchPlainFn(feed.URL)
	}
	feedFile := filepath.Join(feedsDir, strings.ToLower(feed.Name)+".txt")
	if err == nil {
		// v1.238: root:nftban 0640 at creation, then atomic rename (writeFeedFile)
		err = writeFeedFile(feedFile, res.entries)
	}
	if err != nil {
		var notBefore time.Time
		var rl feeds.RateLimitInfo
		var pe *feeds.ProviderError
		if errors.As(err, &pe) {
			notBefore, rl = pe.NotBefore, pe.RateLimit
		}
		fmt.Printf("  ❌ Error: %v\n", err)
		fmt.Println("     Snapshot not replaced; its last successful refresh time is unchanged.")
		tr, werr := feeds.RecordFailure(feedsDir, feed.Name, err.Error(), notBefore, rl, time.Now())
		reportRecord(feed.Name, tr, err.Error(), werr)
		return refreshResult{outcome: refreshFailed}
	}
	tr, werr := feeds.RecordSuccess(feedsDir, feed.Name, len(res.entries), res.generatedAt, res.prov, time.Now())
	reportRecord(feed.Name, tr, "", werr)
	fmt.Printf("  ✅ Downloaded: %d IPs/CIDRs\n", len(res.entries))
	if res.detail != "" {
		fmt.Printf("     %s\n", res.detail)
	}
	if res.generatedAt != "" {
		fmt.Printf("     Provider generated at: %s (provider time; the local refresh time is now)\n", res.generatedAt)
	}
	return refreshResult{outcome: refreshOK, entries: len(res.entries)}
}

// reportRecord prints a refresh-record write problem and the once-only transition line (the
// journal of the feeds timer keeps it: transitions only, never one line per attempt).
func reportRecord(feed, transition, reason string, werr error) {
	if werr != nil {
		fmt.Printf("  ⚠️  Could not write the refresh record for %s: %v\n", feed, werr)
	}
	switch transition {
	case feeds.TransitionFailure:
		fmt.Printf("  FEED-TRANSITION feed=%s state=failing reason=%q\n", strings.ToLower(feed), reason)
	case feeds.TransitionRecovery:
		fmt.Printf("  FEED-TRANSITION feed=%s state=recovered\n", strings.ToLower(feed))
	}
}

// updateOutcome is the exit status of `feeds update`. A named feed that was deferred is not
// refreshed, so it is non-zero too; deferral in a scheduled run (all feeds) is reported, not a
// failure.
func updateOutcome(feedName string, failed, deferred []string, syncErr error) error {
	var parts []string
	if len(failed) > 0 {
		parts = append(parts, fmt.Sprintf("download failed for %s (snapshot kept, last successful refresh unchanged)", strings.Join(failed, ", ")))
	}
	if feedName != "" && len(deferred) > 0 {
		parts = append(parts, fmt.Sprintf("%s not refreshed: request deferred (see: nftban-core feeds status)", strings.Join(deferred, ", ")))
	}
	if syncErr != nil {
		parts = append(parts, "full sync did not complete: "+syncErr.Error())
	}
	if len(parts) == 0 {
		return nil
	}
	return errors.New(strings.Join(parts, "; "))
}

// parseFeedsConfig reads feeds.conf and extracts feed definitions
// Config loading order (last wins): feeds.conf → feeds.conf.local → nftban.conf.local (central)
func parseFeedsConfig(configPath string) ([]FeedConfig, error) {
	feedConfigs := []FeedConfig{}

	// Central config architecture: module config first, then central override last (highest priority)
	configDir := filepath.Dir(filepath.Dir(configPath)) // conf.d/feeds.conf → /etc/nftban
	configFiles := []string{configPath, configPath + ".local", configDir + "/nftban.conf.local"}

	// Maps to track feed properties
	feedURLs := make(map[string]string)
	feedEnabled := make(map[string]bool)
	feedCategories := make(map[string]string)
	feedDescriptions := make(map[string]string)
	feedExtra := make(map[string]string) // NAME_SUFFIX -> value (v1.238 part B properties)

	for _, cf := range configFiles {
		content, err := os.ReadFile(cf)
		if err != nil {
			if cf == configPath {
				return nil, fmt.Errorf("cannot read config file %s: %w", cf, err)
			}
			continue // .local file is optional
		}

		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}

			// Parse FEED_<NAME>_<PROPERTY>="value"
			if strings.HasPrefix(line, "FEED_") {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}

				varName := parts[0]
				value := extractConfigValue(parts[1])

				// Extract feed name and property
				// FEED_SPAMHAUS_DROP_URL -> name=SPAMHAUS_DROP, property=URL
				varName = strings.TrimPrefix(varName, "FEED_")

				if strings.HasSuffix(varName, "_URL") {
					feedName := strings.TrimSuffix(varName, "_URL")
					feedURLs[feedName] = value
				} else if strings.HasSuffix(varName, "_ENABLED") {
					feedName := strings.TrimSuffix(varName, "_ENABLED")
					feedEnabled[feedName] = (value == "true")
				} else if strings.HasSuffix(varName, "_CATEGORY") {
					feedName := strings.TrimSuffix(varName, "_CATEGORY")
					feedCategories[feedName] = value
				} else if strings.HasSuffix(varName, "_DESCRIPTION") {
					feedName := strings.TrimSuffix(varName, "_DESCRIPTION")
					feedDescriptions[feedName] = value
				} else {
					for _, suf := range []string{"_FORMAT", "_MIN_INTERVAL", "_CONFIDENCE_MINIMUM", "_LIMIT"} {
						if strings.HasSuffix(varName, suf) {
							feedExtra[strings.TrimSuffix(varName, suf)+suf] = value
							break
						}
					}
				}
			}
		}
	}

	// Build feed configs from collected data
	for name, url := range feedURLs {
		fc := FeedConfig{
			Name:        name,
			URL:         url,
			Enabled:     feedEnabled[name],
			Category:    feedCategories[name],
			Description: feedDescriptions[name],
		}
		if fc.Category == "" {
			fc.Category = "other"
		}
		if fc.Description == "" {
			fc.Description = "No description"
		}
		if err := applyFeedExtras(&fc, feedExtra); err != nil {
			return nil, err
		}
		feedConfigs = append(feedConfigs, fc)
	}

	return feedConfigs, nil
}

// applyFeedExtras reads the v1.238 per-feed properties. An invalid value is a config error
// (reported, never guessed).
func applyFeedExtras(fc *FeedConfig, extra map[string]string) error {
	fc.Format = strings.ToLower(extra[fc.Name+"_FORMAT"])
	if fc.Format != "" && fc.Format != FeedFormatAbuseIPDB {
		return fmt.Errorf("FEED_%s_FORMAT=%q is not supported (supported: %s)", fc.Name, fc.Format, FeedFormatAbuseIPDB)
	}
	if v := extra[fc.Name+"_MIN_INTERVAL"]; v != "" && v != "0" {
		d, err := time.ParseDuration(v)
		if err != nil || d < 0 {
			return fmt.Errorf("FEED_%s_MIN_INTERVAL=%q is not a valid duration (e.g. 6h)", fc.Name, v)
		}
		fc.MinInterval = d
	}
	for suf, dst := range map[string]*int{"_CONFIDENCE_MINIMUM": &fc.ConfidenceMinimum, "_LIMIT": &fc.Limit} {
		if v := extra[fc.Name+suf]; v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 0 {
				return fmt.Errorf("FEED_%s%s=%q is not a valid number", fc.Name, suf, v)
			}
			*dst = n
		}
	}
	return nil
}

// fetchResult is one successful download (before the snapshot is replaced).
type fetchResult struct {
	entries     []string
	generatedAt string               // provider's own time (abuseipdb meta.generatedAt), "" when none
	detail      string               // one line for the operator
	prov        *feeds.ProviderStats // provider feeds only
}

// fetchAbuseIPDB fetches the AbuseIPDB blacklist with the key from the root-only key file. Errors
// never contain the key (provider errors are sanitized; the credential reader never echoes it).
func fetchAbuseIPDB(feed FeedConfig, configDir string) (*fetchResult, error) {
	key, err := feeds.ReadCredentialFile(filepath.Join(configDir, abuseIPDBKeyName))
	if err != nil {
		return nil, err
	}
	p := feeds.AbuseIPDBParams{ConfidenceMinimum: feed.ConfidenceMinimum, Limit: feed.Limit}
	if p.ConfidenceMinimum == 0 {
		p.ConfidenceMinimum = feeds.AbuseIPDBDefaultConfidence
	}
	if p.Limit == 0 {
		p.Limit = feeds.AbuseIPDBDefaultLimit
	}
	base := feed.URL
	if base == "" {
		base = feeds.AbuseIPDBDefaultURL
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	res, err := feeds.FetchAbuseIPDB(ctx, &http.Client{Timeout: 2 * time.Minute}, base, key, p, 0)
	if err != nil {
		return nil, err
	}
	if len(res.Entries) == 0 {
		return nil, fmt.Errorf("abuseipdb: response held no usable address (received %d, rejected %d); snapshot not replaced", res.Received, res.Rejected)
	}
	d := fmt.Sprintf("received %d, accepted %d, rejected %d (confidence >= %d, limit %d)", res.Received, res.Accepted, res.Rejected, p.ConfidenceMinimum, p.Limit)
	if res.RateLimit.Known {
		d += fmt.Sprintf("; quota %d/%d left", res.RateLimit.Remaining, res.RateLimit.Limit)
	}
	prov := &feeds.ProviderStats{RequestedConfidence: p.ConfidenceMinimum, RequestedLimit: p.Limit,
		Received: res.Received, Accepted: res.Accepted, Rejected: res.Rejected, MinScore: res.MinScore, MaxScore: res.MaxScore}
	prov.SetQuota(res.RateLimit, time.Now())
	return &fetchResult{entries: res.Entries, generatedAt: res.GeneratedAt, detail: d, prov: prov}, nil
}

// fetchPlain downloads a plain IP/CIDR list. Nothing is written here: the caller replaces the
// snapshot and records the outcome in one place.
func fetchPlain(url string) (*fetchResult, error) {
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("bad HTTP status: %s", resp.Status)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	validIPs := parseIPsFromFeed(string(body))
	if len(validIPs) == 0 {
		return nil, fmt.Errorf("no valid IPs found in feed")
	}
	return &fetchResult{entries: validIPs}, nil
}

// parseIPsFromFeed extracts valid IPv4/IPv6 addresses and CIDRs from feed content
func parseIPsFromFeed(content string) []string {
	validIPs := []string{}

	// Regex patterns for IP addresses and CIDRs
	ipv4Pattern := regexp.MustCompile(`^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(/\d{1,2})?$`)
	ipv6Pattern := regexp.MustCompile(`^([0-9a-fA-F:]+)(/\d{1,3})?$`)

	scanner := bufio.NewScanner(strings.NewReader(content))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}

		// Some feeds have IP;comment or IP,comment format
		if idx := strings.IndexAny(line, ";,"); idx != -1 {
			line = strings.TrimSpace(line[:idx])
		}

		// Check if it's a valid IPv4 or IPv6 address/CIDR
		if ipv4Pattern.MatchString(line) || ipv6Pattern.MatchString(line) {
			validIPs = append(validIPs, line)
		}
	}

	return validIPs
}
