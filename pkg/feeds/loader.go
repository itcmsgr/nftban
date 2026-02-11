// =============================================================================
// NFTBan - Threat Feed Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Loads threat feeds from feed files into IP sets"
// meta:input="Feed directory with .txt files"
// meta:output="IPv4/IPv6 IP and CIDR sets"
// meta:depends="bufio,os"
// meta:inventory.files="/var/lib/nftban/feeds/*.txt"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package feeds

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// FeedInfo represents metadata about a threat feed
type FeedInfo struct {
	Name        string
	FilePath    string
	IPv4Count   int
	IPv6Count   int
	LastUpdated string
}

// LoadAllFeeds loads all feed files from the feeds directory
// Returns IPv4 IPs, IPv6 IPs, IPv4 CIDRs, IPv6 CIDRs, and feed info
func LoadAllFeeds(feedsDir string) (map[string]bool, map[string]bool, map[string]bool, map[string]bool, []FeedInfo, error) {
	// Pre-allocate maps with estimated capacity to reduce rehashing
	// Typical feeds have 10K-50K entries; this prevents ~5-7 rehash operations
	ipv4Set := make(map[string]bool, 10000)       // Single IPv4 addresses
	ipv6Set := make(map[string]bool, 1000)        // Single IPv6 addresses
	ipv4CIDRSet := make(map[string]bool, 50000)   // IPv4 CIDR ranges
	ipv6CIDRSet := make(map[string]bool, 1000)    // IPv6 CIDR ranges
	var feedsInfo []FeedInfo

	// Check if feeds directory exists
	if _, err := os.Stat(feedsDir); os.IsNotExist(err) {
		// No feeds directory - return empty sets
		return ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, feedsInfo, nil
	}

	// Read all .txt files in feeds directory
	entries, err := os.ReadDir(feedsDir)
	if err != nil {
		return nil, nil, nil, nil, nil, fmt.Errorf("failed to read feeds directory: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(entry.Name(), ".txt") {
			continue
		}

		filePath := filepath.Join(feedsDir, entry.Name())

		// Load this feed
		ipv4Count, ipv6Count, ipv4CIDRCount, ipv6CIDRCount, err := loadFeedFile(filePath, ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Failed to load feed %s: %v\n", entry.Name(), err)
			continue
		}

		// Get file modification time
		info, _ := entry.Info()
		lastUpdated := ""
		if info != nil {
			lastUpdated = info.ModTime().Format("2006-01-02 15:04:05")
		}

		// Store feed info (total = single IPs + CIDRs)
		feedsInfo = append(feedsInfo, FeedInfo{
			Name:        strings.TrimSuffix(entry.Name(), ".txt"),
			FilePath:    filePath,
			IPv4Count:   ipv4Count + ipv4CIDRCount,
			IPv6Count:   ipv6Count + ipv6CIDRCount,
			LastUpdated: lastUpdated,
		})
	}

	return ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, feedsInfo, nil
}

// loadFeedFile loads IPs and CIDRs from a single feed file
// Returns counts of IPv4 IPs, IPv6 IPs, IPv4 CIDRs, IPv6 CIDRs
// Uses unified ParseFeedLine for consistent parsing across the codebase
func loadFeedFile(filePath string, ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet map[string]bool) (int, int, int, int, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return 0, 0, 0, 0, err
	}
	defer file.Close()

	ipv4Count := 0
	ipv6Count := 0
	ipv4CIDRCount := 0
	ipv6CIDRCount := 0
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		// Use unified parser (silently skip invalid entries)
		entry := ParseFeedLineSilent(scanner.Text())
		if entry == nil {
			continue
		}

		// Add to appropriate set based on type
		if entry.IsCIDR {
			if entry.IPv4 {
				if !ipv4CIDRSet[entry.Value] {
					ipv4CIDRSet[entry.Value] = true
					ipv4CIDRCount++
				}
			} else {
				if !ipv6CIDRSet[entry.Value] {
					ipv6CIDRSet[entry.Value] = true
					ipv6CIDRCount++
				}
			}
		} else {
			if entry.IPv4 {
				if !ipv4Set[entry.Value] {
					ipv4Set[entry.Value] = true
					ipv4Count++
				}
			} else {
				if !ipv6Set[entry.Value] {
					ipv6Set[entry.Value] = true
					ipv6Count++
				}
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return ipv4Count, ipv6Count, ipv4CIDRCount, ipv6CIDRCount, fmt.Errorf("error reading file: %w", err)
	}

	return ipv4Count, ipv6Count, ipv4CIDRCount, ipv6CIDRCount, nil
}

//nolint:U1000 // Helper function for future CIDR operations

// GetFeedStats returns statistics about all feeds
func GetFeedStats(feedsDir string) ([]FeedInfo, error) {
	_, _, _, _, feedsInfo, err := LoadAllFeeds(feedsDir)
	return feedsInfo, err
}

// LoadSpecificFeed loads a single feed by name
// Returns IPv4 IPs, IPv6 IPs, IPv4 CIDRs, IPv6 CIDRs
func LoadSpecificFeed(feedsDir string, feedName string) ([]string, []string, []string, []string, error) {
	fileName := feedName + ".txt"
	filePath := filepath.Join(feedsDir, fileName)

	// Check if file exists
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		return nil, nil, nil, nil, fmt.Errorf("feed '%s' not found", feedName)
	}

	// Load this feed
	ipv4Set := make(map[string]bool)
	ipv6Set := make(map[string]bool)
	ipv4CIDRSet := make(map[string]bool)
	ipv6CIDRSet := make(map[string]bool)
	_, _, _, _, err := loadFeedFile(filePath, ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet)
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("failed to load feed: %w", err)
	}

	// Convert maps to slices with pre-allocation to avoid reallocations
	ipv4List := make([]string, 0, len(ipv4Set))
	for ip := range ipv4Set {
		ipv4List = append(ipv4List, ip)
	}

	ipv6List := make([]string, 0, len(ipv6Set))
	for ip := range ipv6Set {
		ipv6List = append(ipv6List, ip)
	}

	ipv4CIDRList := make([]string, 0, len(ipv4CIDRSet))
	for cidr := range ipv4CIDRSet {
		ipv4CIDRList = append(ipv4CIDRList, cidr)
	}

	ipv6CIDRList := make([]string, 0, len(ipv6CIDRSet))
	for cidr := range ipv6CIDRSet {
		ipv6CIDRList = append(ipv6CIDRList, cidr)
	}

	return ipv4List, ipv6List, ipv4CIDRList, ipv6CIDRList, nil
}

// ListAvailableFeeds returns a list of all available feed names
func ListAvailableFeeds(feedsDir string) ([]string, error) {
	entries, err := os.ReadDir(feedsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("failed to read feeds directory: %w", err)
	}

	// Files to exclude (helper/library files, not actual feeds)
	excludeFiles := map[string]bool{
		"library": true, // Internal library/helper file
	}

	// Pre-allocate slice with estimated capacity
	feeds := make([]string, 0, len(entries))

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if strings.HasSuffix(entry.Name(), ".txt") {
			feedName := strings.TrimSuffix(entry.Name(), ".txt")

			// Skip excluded files
			if excludeFiles[feedName] {
				continue
			}

			feeds = append(feeds, feedName)
		}
	}

	return feeds, nil
}
