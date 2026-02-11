// =============================================================================
// NFTBan v1.0 - Threat Intelligence Feeds Builder
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="feeds"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Builds consolidated SetData from threat feed files"
// meta:inventory.files=""
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

	"github.com/itcmsgr/nftban/pkg/model"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// getDefaultFeedsDir returns feeds directory from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getDefaultFeedsDir() string {
	cfg := nftbanconf.MustLoad()
	return cfg.DataDir + "/feeds"
}

// Build loads all feed files and returns consolidated SetData
// This replaces the slow bash implementation with fast Go parsing
//
// Performance: <2s for 50,000+ IPs (vs 45s in bash)
//
// Features:
// - IPv4/IPv6 automatic separation
// - CIDR normalization
// - Comment and empty line filtering
// - Streaming parsing (memory efficient)
func Build(feedsDir string, feedNames []string) (map[string]*model.SetData, error) {
	if feedsDir == "" {
		feedsDir = getDefaultFeedsDir()
	}

	result := make(map[string]*model.SetData)

	// If no feed names specified, load all *.txt files
	if len(feedNames) == 0 {
		entries, err := os.ReadDir(feedsDir)
		if err != nil {
			return nil, fmt.Errorf("failed to read feeds directory: %w", err)
		}

		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			if strings.HasSuffix(entry.Name(), ".txt") {
				feedName := strings.TrimSuffix(entry.Name(), ".txt")
				feedNames = append(feedNames, feedName)
			}
		}
	}

	// Load each feed
	for _, feedName := range feedNames {
		data, err := LoadFeed(feedsDir, feedName)
		if err != nil {
			// Log error but continue with other feeds
			fmt.Fprintf(os.Stderr, "WARNING: Failed to load feed %s: %v\n", feedName, err)
			continue
		}

		if !data.IsEmpty() {
			result[feedName] = data
		}
	}

	return result, nil
}

// LoadFeed loads a single feed file and returns SetData
func LoadFeed(feedsDir, feedName string) (*model.SetData, error) {
	// Normalize feed name (uppercase, underscores)
	normalizedName := strings.ToUpper(strings.ReplaceAll(feedName, "-", "_"))

	// Try multiple filename patterns
	filenames := []string{
		filepath.Join(feedsDir, normalizedName+".txt"),
		filepath.Join(feedsDir, feedName+".txt"),
		filepath.Join(feedsDir, strings.ToLower(feedName)+".txt"),
	}

	var file *os.File
	var err error
	var foundPath string

	for _, path := range filenames {
		file, err = os.Open(path)
		if err == nil {
			foundPath = path
			break
		}
	}

	if file == nil {
		return nil, fmt.Errorf("feed file not found: tried %v", filenames)
	}
	defer file.Close()

	data := model.NewSetData(normalizedName)

	scanner := bufio.NewScanner(file)
	lineNum := 0

	for scanner.Scan() {
		lineNum++
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}

		// Parse IP or CIDR
		if err := addIP(data, line); err != nil {
			// Log but don't fail on individual line errors
			fmt.Fprintf(os.Stderr, "WARNING: %s:%d: invalid IP/CIDR: %s (%v)\n",
				foundPath, lineNum, line, err)
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error reading feed %s: %w", foundPath, err)
	}

	return data, nil
}

// addIP adds an IP address or CIDR to the appropriate set (IPv4 or IPv6)
// Uses unified ParseFeedLine for consistent parsing across the codebase
func addIP(data *model.SetData, ipStr string) error {
	entry, err := ParseFeedLine(ipStr)
	if err != nil {
		return err
	}
	if entry == nil {
		return nil // Skip (comment or empty)
	}

	if entry.IPv4 {
		data.AddIPv4(entry.Value)
	} else {
		data.AddIPv6(entry.Value)
	}
	return nil
}

// Merge combines multiple SetData into one
// Useful for consolidating multiple feeds into a single nftables set
func Merge(feeds map[string]*model.SetData) *model.SetData {
	merged := model.NewSetData("merged_feeds")

	for _, feed := range feeds {
		for _, ip := range feed.IPv4 {
			merged.AddIPv4(ip)
		}
		for _, ip := range feed.IPv6 {
			merged.AddIPv6(ip)
		}
	}

	return merged
}
