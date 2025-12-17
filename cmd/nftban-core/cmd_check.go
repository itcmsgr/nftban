package main

import (
	"fmt"
	"net"
	"strings"

	"github.com/itcmsgr/nftban-v1.0-dev/pkg/blacklist"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/feeds"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/nftbanconf"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/version"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/whitelist"
)

// getCheckPaths returns config and data directories from central config
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getCheckPaths() (configDir, dataDir string) {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir, cfg.DataDir
}

func cmdCheck(ipStr string) error {
	fmt.Printf("%s: %s\n", version.BannerWithEmoji("🔍", "Check IP"), ipStr)
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Validate IP
	normalizedIP, isIPv4, err := blacklist.ValidateIP(ipStr)
	if err != nil {
		return fmt.Errorf("invalid IP: %w", err)
	}

	ipType := "IPv6"
	if isIPv4 {
		ipType = "IPv4"
	}

	fmt.Printf("IP Address: %s (%s)\n", normalizedIP, ipType)
	fmt.Println()

	configDir, dataDir := getCheckPaths()

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

	// Check if IP is in individual IP sets
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
	if isIPv4 {
		for cidr := range ipv4CIDRSet {
			_, ipNet, err := net.ParseCIDR(cidr)
			if err != nil {
				continue
			}
			if ipNet.Contains(parsedIP) {
				inCIDR = true
				break
			}
		}
	} else {
		for cidr := range ipv6CIDRSet {
			_, ipNet, err := net.ParseCIDR(cidr)
			if err != nil {
				continue
			}
			if ipNet.Contains(parsedIP) {
				inCIDR = true
				break
			}
		}
	}

	// If found, try to determine which feeds
	if inIP || inCIDR {
		for _, feed := range feedsInfo {
			matchedFeeds = append(matchedFeeds, feed.Name)
		}
	}

	return inIP, inCIDR, matchedFeeds
}
