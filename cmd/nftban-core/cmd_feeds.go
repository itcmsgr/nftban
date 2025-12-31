package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/feeds"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/runtime"
	"github.com/itcmsgr/nftban/pkg/sync"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getFeedsPaths returns feeds directory and config paths from central config
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getFeedsPaths() (feedsDir, feedsConfig, configDir string) {
	cfg := nftbanconf.MustLoad()
	return cfg.DataDir + "/feeds", cfg.ConfigDir + "/conf.d/feeds.conf", cfg.ConfigDir
}

func cmdFeeds(action string) error {
	feedsDir, feedsConfig, _ := getFeedsPaths()

	switch action {
	case "list":
		return cmdFeedsList(feedsDir)
	case "load":
		return cmdFeedsLoad(feedsDir)
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
		return cmdFeedsSync(feedsDir, feedsConfig)
	case "update":
		return cmdFeedsUpdate(feedsDir, feedsConfig)
	default:
		return fmt.Errorf("unknown feeds action: %s\nUsage: nftban-core feeds [list|load|stats|update|enable|disable|sync] [FEED_NAME]", action)
	}
}

// getFeedsEnabledStatus reads the feeds config and returns a map of feed name -> enabled status
func getFeedsEnabledStatus(configPath string) map[string]bool {
	enabledMap := make(map[string]bool)

	// Try to read both .conf and .conf.local
	configFiles := []string{configPath, configPath + ".local"}

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

				// Extract enabled value
				value := strings.Trim(parts[1], `"' `)
				enabled := (value == "true")

				enabledMap[feedName] = enabled
			}
		}
	}

	return enabledMap
}

func cmdFeedsList(feedsDir string) error {
	// Check for --json flag
	jsonOutput := hasFlag("--json")

	// Read config to get enabled/disabled status
	_, configPath, _ := getFeedsPaths()
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

		// Build feeds array with details
		feedsData := []map[string]interface{}{}
		for _, feedName := range feedsList {
			// Check if enabled in config
			enabled := enabledMap[strings.ToUpper(feedName)]

			feedData := map[string]interface{}{
				"name":    feedName,
				"enabled": enabled,
				"count":   0,
			}

			// Find matching stats
			for _, info := range feedsInfo {
				if info.Name == feedName {
					feedData["count"] = info.IPv4Count + info.IPv6Count
					feedData["ipv4_count"] = info.IPv4Count
					feedData["ipv6_count"] = info.IPv6Count
					feedData["last_updated"] = info.LastUpdated
					break
				}
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

func cmdFeedsLoad(feedsDir string) error {
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

	// Step 2: Initialize RuntimeState and load existing blacklists
	fmt.Println("Step 2: Loading existing blacklists...")
	_, _, configDir := getFeedsPaths()
	state := runtime.NewRuntimeState(configDir)
	if err := state.LoadWhitelists(); err != nil {
		return fmt.Errorf("failed to load whitelists: %w", err)
	}
	if err := state.LoadBlacklists(); err != nil {
		return fmt.Errorf("failed to load blacklists: %w", err)
	}
	fmt.Printf("  ✅ Loaded %d existing blacklist entries\n",
		len(state.BlacklistIPv4)+len(state.BlacklistIPv6))
	fmt.Println()

	// Step 3: Create feeds sets in nftables
	fmt.Println("Step 3: Getting blacklist sets from nftables...")
	nft, err := sync.NewNFTManager()
	if err != nil {
		return fmt.Errorf("failed to create nftables manager: %w", err)
	}
	defer nft.Close()

	// Get IPv4 table and blacklist set (v1.0 schema: all sources consolidated)
	tableIPv4, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return fmt.Errorf("failed to get IPv4 table: %w", err)
	}

	// Use blacklist_ipv4 set (consolidates: manual bans + feeds + geoban + countries)
	blacklistIPv4Set, err := nft.GetOrCreateIntervalSet(tableIPv4, "blacklist_ipv4", true)
	if err != nil {
		return fmt.Errorf("failed to get blacklist_ipv4 set: %w", err)
	}
	fmt.Println("  ✅ Using blacklist_ipv4 set (consolidated architecture)")

	// Get IPv6 table and blacklist set
	tableIPv6, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return fmt.Errorf("failed to get IPv6 table: %w", err)
	}

	// Use blacklist_ipv6 set (consolidates all sources)
	blacklistIPv6Set, err := nft.GetOrCreateIntervalSet(tableIPv6, "blacklist_ipv6", false)
	if err != nil {
		return fmt.Errorf("failed to get blacklist_ipv6 set: %w", err)
	}
	fmt.Println("  ✅ Using blacklist_ipv6 set (consolidated architecture)")
	fmt.Println()

	// Step 4: Merge IPs and CIDRs into combined lists for blacklist (interval sets support both)
	fmt.Println("Step 4: Merging feeds into blacklist...")

	// Combine IPv4 IPs (as /32) and CIDRs into single list
	var ipv4Combined []string
	for ip := range ipv4Set {
		ipv4Combined = append(ipv4Combined, ip+"/32") // Convert individual IPs to CIDR notation
	}
	for cidr := range ipv4CIDRSet {
		ipv4Combined = append(ipv4Combined, cidr)
	}

	// Combine IPv6 IPs (as /128) and CIDRs into single list
	var ipv6Combined []string
	for ip := range ipv6Set {
		ipv6Combined = append(ipv6Combined, ip+"/128") // Convert individual IPs to CIDR notation
	}
	for cidr := range ipv6CIDRSet {
		ipv6Combined = append(ipv6Combined, cidr)
	}

	// Load IPv4 feeds into blacklist (with CIDR canonicalization)
	var ipv4Stats *sync.MergeStats
	if len(ipv4Combined) > 0 {
		fmt.Printf("  Loading %d IPv4 entries (IPs + CIDRs) into blacklist...\n", len(ipv4Combined))
		stats, err := nft.AddCIDRElementsWithStats(blacklistIPv4Set, ipv4Combined)
		if err != nil {
			// Check if it's a conflict error (IPs already covered by existing CIDRs)
			if strings.Contains(err.Error(), "conflicting intervals") {
				fmt.Printf("  ⚠️  Some feed IPs overlap with existing GeoIP/CIDR blocks (already blocked)\n")
				fmt.Printf("     This is normal - the overlapping IPs are already protected.\n")
				fmt.Printf("     Non-overlapping IPs were loaded successfully.\n")
			} else {
				return fmt.Errorf("failed to load IPv4 CIDRs: %w", err)
			}
		} else {
			ipv4Stats = stats
			fmt.Printf("  ✅ IPv4 CIDRs loaded successfully\n")
			fmt.Printf("     Canonicalized: %d → %d ranges (%.1f%% reduction)\n",
				stats.InputCIDRs, stats.OutputRanges, stats.ReductionPct)
		}
	} else {
		fmt.Println("  ℹ️  No IPv4 CIDRs to load")
	}

	// Load IPv6 feeds into blacklist (with CIDR canonicalization)
	var ipv6Stats *sync.MergeStats
	if len(ipv6Combined) > 0 {
		fmt.Printf("  Loading %d IPv6 entries (IPs + CIDRs) into blacklist...\n", len(ipv6Combined))
		stats, err := nft.AddCIDRElementsWithStats(blacklistIPv6Set, ipv6Combined)
		if err != nil {
			return fmt.Errorf("failed to load IPv6 feeds: %w", err)
		}
		ipv6Stats = stats
		fmt.Printf("  ✅ IPv6 feeds loaded successfully\n")
		fmt.Printf("     Canonicalized: %d → %d ranges (%.1f%% reduction)\n",
			stats.InputCIDRs, stats.OutputRanges, stats.ReductionPct)
	} else {
		fmt.Println("  ℹ️  No IPv6 feeds to load")
	}
	fmt.Println()

	// Success!
	fmt.Println(strings.Repeat("=", 70))
	fmt.Printf("✅ Feeds loaded into blacklist successfully!\n")
	fmt.Println()
	fmt.Printf("Architecture: v1.0 Consolidated Blacklist\n")
	fmt.Printf("  - All threat feeds merged into blacklist_ipv4/ipv6 sets\n")
	fmt.Printf("  - Firewall rules check @blacklist (no separate @feeds check needed)\n")
	fmt.Println()
	fmt.Printf("Feed entries: %d IPv4 IPs + %d IPv4 CIDRs\n", len(ipv4Set), len(ipv4CIDRSet))
	fmt.Printf("              %d IPv6 IPs + %d IPv6 CIDRs\n", len(ipv6Set), len(ipv6CIDRSet))

	// Show canonicalization results
	if ipv4Stats != nil {
		fmt.Printf("Optimized to:  %d IPv4 ranges (%.1f%% reduction)\n",
			ipv4Stats.OutputRanges, ipv4Stats.ReductionPct)
	}
	if ipv6Stats != nil {
		fmt.Printf("              %d IPv6 ranges (%.1f%% reduction)\n",
			ipv6Stats.OutputRanges, ipv6Stats.ReductionPct)
	}
	fmt.Println()
	fmt.Println("⚠️  NOTE: Existing blacklist entries (manual bans, etc.) preserved.")
	fmt.Println("Feeds are now ACTIVE and blocking traffic.")
	fmt.Println()

	// Performance warning for large sets
	totalRanges := 0
	if ipv4Stats != nil {
		totalRanges += ipv4Stats.OutputRanges
	}
	if ipv6Stats != nil {
		totalRanges += ipv6Stats.OutputRanges
	}

	if totalRanges > 100000 {
		fmt.Println(strings.Repeat("=", 70))
		fmt.Println("⚠️  PERFORMANCE WARNING:")
		fmt.Printf("   You have %d ranges loaded in nftables.\n", totalRanges)
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

	// Read config file
	content, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("failed to read feeds config: %w", err)
	}

	// Convert feed name to uppercase for config variable
	feedNameUpper := strings.ToUpper(feedName)

	// Pattern to match FEED_<NAME>_ENABLED="true" or "false"
	enabledVar := fmt.Sprintf("FEED_%s_ENABLED", feedNameUpper)
	oldValueTrue := fmt.Sprintf(`%s="true"`, enabledVar)
	oldValueFalse := fmt.Sprintf(`%s="false"`, enabledVar)

	// Check if feed exists in config
	if !strings.Contains(string(content), enabledVar) {
		return fmt.Errorf("feed '%s' not found in config\nAvailable feeds: run 'nftban-core feeds list'", feedName)
	}

	// Replace the value
	newContent := string(content)
	if enable {
		newContent = strings.ReplaceAll(newContent, oldValueFalse, oldValueTrue)
	} else {
		newContent = strings.ReplaceAll(newContent, oldValueTrue, oldValueFalse)
	}

	// Check if anything changed
	if newContent == string(content) {
		if enable {
			fmt.Printf("Feed '%s' is already enabled\n", feedName)
		} else {
			fmt.Printf("Feed '%s' is already disabled\n", feedName)
		}
		return nil
	}

	// Write updated config
	err = os.WriteFile(configPath, []byte(newContent), 0640)
	if err != nil {
		return fmt.Errorf("failed to write feeds config: %w", err)
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

func cmdFeedsSync(feedsDir, configPath string) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	// Path to store last config hash - use data dir from central config
	// NO FALLBACK - path must come from /etc/nftban/nftban.conf
	syncCfg := nftbanconf.MustLoad()
	stateFile := syncCfg.DataDir + "/feeds.state"

	// Check both .conf and .conf.local files
	configFiles := []string{
		configPath,
		configPath + ".local",
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
	err := cmdFeedsLoad(feedsDir)
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
func cmdFeedsUpdate(feedsDir, configPath string) error {
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
		if err := cmdFeedsLoad(feedsDir); err != nil {
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
func parseFeedsConfig(configPath string) ([]FeedConfig, error) {
	feedConfigs := []FeedConfig{}

	// Read both .conf and .conf.local
	configFiles := []string{configPath, configPath + ".local"}

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
				value := strings.Trim(parts[1], `"' `)

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
	writer.Flush()

	// Atomic rename
	if err := os.Rename(tmpFile, outputFile); err != nil {
		os.Remove(tmpFile)
		return 0, fmt.Errorf("failed to save feed file: %w", err)
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
