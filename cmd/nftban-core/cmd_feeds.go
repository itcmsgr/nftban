// =============================================================================
// NFTBan - Threat Feeds Management Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_feeds"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Manage threat intelligence feeds for IP blocking"
// meta:input="Subcommand (list, load, stats, enable, disable, sync, update)"
// meta:output="Console output with feed status and operations"
// meta:depends="github.com/itcmsgr/nftban/pkg/feeds,github.com/itcmsgr/nftban/pkg/ipc,github.com/itcmsgr/nftban/pkg/nftbanconf"
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
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/feeds"
	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/version"
)

// setFeedFileOwnership sets nftban:nftban ownership and 0640 permissions on feed files
// This allows the unified exporter (running as nftban user) to read feed files
func setFeedFileOwnership(path string) error {
	// Set permissions to 0640 (rw-r-----)
	if err := os.Chmod(path, 0640); err != nil {
		return fmt.Errorf("chmod failed: %w", err)
	}

	// Look up nftban user and group
	nftbanUser, err := user.Lookup("nftban")
	if err != nil {
		// Fallback: just set group-readable (root:nftban)
		if grp, err := user.LookupGroup("nftban"); err == nil {
			if gid, err := strconv.Atoi(grp.Gid); err == nil {
				_ = os.Chown(path, 0, gid)
			}
		}
		return nil
	}

	uid, _ := strconv.Atoi(nftbanUser.Uid)
	gid, _ := strconv.Atoi(nftbanUser.Gid)

	if err := os.Chown(path, uid, gid); err != nil {
		return fmt.Errorf("chown failed: %w", err)
	}

	return nil
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
	case "sync":
		return cmdFeedsSync(feedsDir, feedsConfig, cfg)
	case "update":
		return cmdFeedsUpdate(feedsDir, feedsConfig, cfg)
	default:
		return fmt.Errorf("unknown feeds action: %s\nUsage: nftban-core feeds [list|load|stats|update|enable|disable|sync] [FEED_NAME]", action)
	}
}

// getFeedsEnabledStatus reads the feeds config and returns a map of feed name -> enabled status
// Config loading order (last wins): feeds.conf → feeds.conf.local → nftban.conf.local (central)
func getFeedsEnabledStatus(configPath string) map[string]bool {
	enabledMap := make(map[string]bool)

	// Central config architecture: module config first, then central override last (highest priority)
	configDir := filepath.Dir(filepath.Dir(configPath)) // conf.d/feeds.conf → /etc/nftban
	configFiles := []string{configPath, configPath + ".local", configDir + "/nftban.conf.local"}

	for _, cf := range configFiles {
		content, err := os.ReadFile(cf)
		if err != nil {
			continue // Skip if file doesn't exist
		}

		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)

			// Look for FEED_*_ENABLED="true" or "false"
			if strings.HasPrefix(line, "FEED_") && strings.Contains(line, "_ENABLED=") {
				// Extract feed name and enabled status
				// Format: FEED_BLOCKLISTDE_SSH_ENABLED="true"
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}

				// Extract feed name from FEED_<NAME>_ENABLED
				varName := parts[0]
				if !strings.HasSuffix(varName, "_ENABLED") {
					continue
				}
				feedName := strings.TrimPrefix(varName, "FEED_")
				feedName = strings.TrimSuffix(feedName, "_ENABLED")

				// Extract enabled value (handles trailing comments)
				value := extractConfigValue(parts[1])
				enabled := (value == "true")

				enabledMap[feedName] = enabled
			}
		}
	}

	return enabledMap
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

	// Step 1: Load all feeds
	fmt.Println("Step 1: Loading feeds from disk...")
	ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, feedsInfo, err := feeds.LoadAllFeeds(feedsDir)
	if err != nil {
		return fmt.Errorf("failed to load feeds: %w", err)
	}

	if len(feedsInfo) == 0 {
		fmt.Println("  ⚠️  No feeds found")
		return nil
	}

	totalEntries := len(ipv4Set) + len(ipv4CIDRSet) + len(ipv6Set) + len(ipv6CIDRSet)

	fmt.Printf("  ✅ Loaded %d feeds\n", len(feedsInfo))
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
		return fmt.Errorf("feed '%s' not found in config\nAvailable feeds: run 'nftban-core feeds list'", feedName)
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
}

// cmdFeedsUpdate downloads all enabled feeds using native Go HTTP (no curl needed)
func cmdFeedsUpdate(feedsDir, configPath string, cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🔄", "Update Feeds"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Step 1: Parse config to get enabled feeds
	fmt.Println("Step 1: Reading feeds configuration...")
	feedConfigs, err := parseFeedsConfig(configPath)
	if err != nil {
		return fmt.Errorf("failed to parse feeds config: %w", err)
	}

	enabledFeeds := []FeedConfig{}
	for _, fc := range feedConfigs {
		if fc.Enabled {
			enabledFeeds = append(enabledFeeds, fc)
		}
	}

	fmt.Printf("  ✅ Found %d feeds (%d enabled)\n", len(feedConfigs), len(enabledFeeds))
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

	successCount := 0
	failCount := 0
	totalIPs := 0

	for i, feed := range enabledFeeds {
		fmt.Printf("\n[%d/%d] %s\n", i+1, len(enabledFeeds), feed.Name)
		fmt.Printf("  Category: %s\n", feed.Category)
		fmt.Printf("  URL: %s\n", feed.URL)

		// Download feed
		feedFile := filepath.Join(feedsDir, strings.ToLower(feed.Name)+".txt")
		ipCount, err := downloadAndParseFeed(feed.URL, feedFile)
		if err != nil {
			fmt.Printf("  ❌ Error: %v\n", err)
			failCount++
			continue
		}

		fmt.Printf("  ✅ Downloaded: %d IPs/CIDRs\n", ipCount)
		successCount++
		totalIPs += ipCount
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("Download Summary:")
	fmt.Printf("  ✅ Success: %d feeds\n", successCount)
	if failCount > 0 {
		fmt.Printf("  ❌ Failed: %d feeds\n", failCount)
	}
	fmt.Printf("  📊 Total IPs/CIDRs: %d\n", totalIPs)
	fmt.Println()

	// Step 4: Auto-load feeds into nftables
	if successCount > 0 {
		fmt.Println("Step 4: Loading feeds into nftables...")
		if err := cmdFeedsLoad(feedsDir, cfg); err != nil {
			if strings.Contains(err.Error(), "conflicting intervals") {
				fmt.Printf("  ⚠️  Some feed IPs overlap with existing blocks (already protected)\n")
			} else {
				fmt.Printf("⚠️  Warning: failed to load feeds: %v\n", err)
				fmt.Println("   You can load manually with: sudo nftban-core feeds load")
			}
		}
	}

	return nil
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
		feedConfigs = append(feedConfigs, fc)
	}

	return feedConfigs, nil
}

// downloadAndParseFeed downloads a feed URL and parses valid IPs/CIDRs
func downloadAndParseFeed(url, outputFile string) (int, error) {
	// Create HTTP client with timeout
	client := &http.Client{
		Timeout: 60 * time.Second,
	}

	resp, err := client.Get(url)
	if err != nil {
		return 0, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("bad HTTP status: %s", resp.Status)
	}

	// Read and parse the feed content
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, fmt.Errorf("failed to read response: %w", err)
	}

	// Parse IPs/CIDRs from the feed
	validIPs := parseIPsFromFeed(string(body))

	if len(validIPs) == 0 {
		return 0, fmt.Errorf("no valid IPs found in feed")
	}

	// Write to output file
	tmpFile := outputFile + ".tmp"
	out, err := os.Create(tmpFile)
	if err != nil {
		return 0, fmt.Errorf("failed to create output file: %w", err)
	}
	defer out.Close()

	writer := bufio.NewWriter(out)
	for _, ip := range validIPs {
		fmt.Fprintln(writer, ip)
	}
	if err := writer.Flush(); err != nil {
		os.Remove(tmpFile)
		return 0, fmt.Errorf("flush failed: %w", err)
	}

	// Atomic rename
	if err := os.Rename(tmpFile, outputFile); err != nil {
		os.Remove(tmpFile)
		return 0, fmt.Errorf("failed to save feed file: %w", err)
	}

	// v1.13.12: Set nftban ownership so unified exporter can read feed files
	if err := setFeedFileOwnership(outputFile); err != nil {
		// Non-fatal - file was created successfully, just warn
		fmt.Printf("⚠️  Warning: failed to set feed file permissions: %v\n", err)
	}

	return len(validIPs), nil
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
