// =============================================================================
// NFTBan - IP Check Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_check"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Check IP against whitelist, blacklist, and threat feeds"
// meta:input="IP address string"
// meta:output="Console output with IP status"
// meta:depends="github.com/itcmsgr/nftban/internal/blacklist,github.com/itcmsgr/nftban/internal/feeds,github.com/itcmsgr/nftban/internal/whitelist"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"fmt"
	"net"
	"strings"

	"github.com/itcmsgr/nftban/internal/blacklist"
	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/itcmsgr/nftban/internal/whitelist"
)

// getCheckPaths returns config and data directories from passed config
func getCheckPaths(cfg *nftbanconf.Config) (configDir, dataDir string) {
	return cfg.ConfigDir, cfg.DataDir
}

func cmdCheck(ipStr string, cfg *nftbanconf.Config) error {
	fmt.Printf("%s: %s\n", version.BannerWithEmoji("🔍", "Check IP"), ipStr)
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Validate IP
	normalizedIP, isIPv4, err := netutil.ValidateAndNormalizeIP(ipStr)
	if err != nil {
		return fmt.Errorf("invalid IP: %w", err)
	}

	ipType := "IPv6"
	if isIPv4 {
		ipType = "IPv4"
	}

	fmt.Printf("IP Address: %s (%s)\n", normalizedIP, ipType)
	fmt.Println()

	configDir, dataDir := getCheckPaths(cfg)

	// Check whitelist
	fmt.Println("Checking whitelist...")
	whitelistIPv4, whitelistIPv6, err := whitelist.LoadAllWhitelists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load whitelists: %w", err)
	}

	isWhitelisted := false
	if isIPv4 {
		isWhitelisted = whitelistIPv4[normalizedIP]
	} else {
		isWhitelisted = whitelistIPv6[normalizedIP]
	}

	if isWhitelisted {
		fmt.Println("  ✅ WHITELISTED")
		fmt.Println("     This IP is allowed through the firewall.")
		fmt.Println()
	} else {
		fmt.Println("  ⚪ Not whitelisted")
		fmt.Println()
	}

	// Check blacklist
	fmt.Println("Checking blacklist...")
	blacklistIPv4, blacklistIPv6, err := blacklist.LoadAllBlacklists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load blacklists: %w", err)
	}

	isBlacklisted := false
	if isIPv4 {
		isBlacklisted = blacklistIPv4[normalizedIP]
	} else {
		isBlacklisted = blacklistIPv6[normalizedIP]
	}

	if isBlacklisted {
		fmt.Println("  ❌ BLACKLISTED")
		fmt.Println("     This IP is BLOCKED by the firewall.")
		fmt.Println()
	} else {
		fmt.Println("  ⚪ Not blacklisted")
		fmt.Println()
	}

	// Check feeds
	fmt.Println("Checking threat intelligence feeds...")
	feedsDir := dataDir + "/feeds"
	inFeedsIP, inFeedsCIDR, matchedFeeds := checkIPInFeeds(normalizedIP, isIPv4, feedsDir)

	if inFeedsIP || inFeedsCIDR {
		fmt.Println("  ⚠️  FOUND IN FEEDS")
		if inFeedsIP {
			fmt.Println("     Found as individual IP in feeds")
		}
		if inFeedsCIDR {
			fmt.Println("     Found in CIDR range(s) in feeds")
		}
		if len(matchedFeeds) > 0 {
			fmt.Printf("     Matched feeds: %s\n", strings.Join(matchedFeeds, ", "))
		}
		fmt.Println()
	} else {
		fmt.Println("  ⚪ Not found in feeds")
		fmt.Println()
	}

	// Summary
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("VERDICT:")
	fmt.Println()

	if isWhitelisted {
		fmt.Println("  ✅ ALLOWED - IP is whitelisted")
		fmt.Println()
		fmt.Println("  This IP has unrestricted access through the firewall.")
		if isBlacklisted {
			fmt.Println("  ⚠️  WARNING: IP is also in blacklist but whitelist takes precedence!")
		}
		if inFeedsIP || inFeedsCIDR {
			fmt.Println("  ⚠️  WARNING: IP is also in threat feeds but whitelist takes precedence!")
		}
	} else if isBlacklisted {
		fmt.Println("  ❌ BLOCKED - IP is blacklisted")
		fmt.Println()
		fmt.Println("  This IP is being blocked by the firewall.")
		fmt.Println()
		fmt.Println("  To unban: nftban-core unban", normalizedIP)
	} else if inFeedsIP || inFeedsCIDR {
		fmt.Println("  ⚠️  POTENTIALLY BLOCKED - IP found in threat feeds")
		fmt.Println()
		fmt.Println("  This IP may be blocked by the firewall if feeds are loaded.")
		fmt.Println("  Check firewall rules to confirm current status.")
	} else {
		fmt.Println("  ⚪ NEUTRAL - IP is not listed anywhere")
		fmt.Println()
		fmt.Println("  Standard firewall rules apply to this IP.")
	}

	fmt.Println()

	return nil
}

// checkIPInFeeds checks if an IP is present in threat intelligence feeds
func checkIPInFeeds(ip string, isIPv4 bool, feedsDir string) (bool, bool, []string) {
	// Load all feeds
	ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, feedsInfo, err := feeds.LoadAllFeeds(feedsDir)
	if err != nil {
		// If feeds can't be loaded, return false
		return false, false, nil
	}

	parsedIP := net.ParseIP(ip)
	if parsedIP == nil {
		return false, false, nil
	}

	var matchedFeeds []string
	inIP := false
	inCIDR := false

	// Check if IP is in individual IP sets - O(1) lookup
	if isIPv4 {
		if ipv4Set[ip] {
			inIP = true
		}
	} else {
		if ipv6Set[ip] {
			inIP = true
		}
	}

	// Check if IP is in any CIDR range
	// Optimization: Pre-parse all CIDRs once instead of parsing on each iteration
	if isIPv4 {
		parsedNets := make([]*net.IPNet, 0, len(ipv4CIDRSet))
		for cidr := range ipv4CIDRSet {
			_, ipNet, err := net.ParseCIDR(cidr)
			if err == nil {
				parsedNets = append(parsedNets, ipNet)
			}
		}
		for _, ipNet := range parsedNets {
			if ipNet.Contains(parsedIP) {
				inCIDR = true
				break
			}
		}
	} else {
		parsedNets := make([]*net.IPNet, 0, len(ipv6CIDRSet))
		for cidr := range ipv6CIDRSet {
			_, ipNet, err := net.ParseCIDR(cidr)
			if err == nil {
				parsedNets = append(parsedNets, ipNet)
			}
		}
		for _, ipNet := range parsedNets {
			if ipNet.Contains(parsedIP) {
				inCIDR = true
				break
			}
		}
	}

	// Note: Currently returns all enabled feed names when IP is found.
	// Per-feed IP tracking would require changes to feeds.LoadAllFeeds().
	// For now, list enabled feeds as potential sources.
	if inIP || inCIDR {
		for _, feed := range feedsInfo {
			if feed.IPv4Count > 0 || feed.IPv6Count > 0 {
				matchedFeeds = append(matchedFeeds, feed.Name)
			}
		}
	}

	return inIP, inCIDR, matchedFeeds
}
