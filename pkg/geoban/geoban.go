// =============================================================================
// NFTBan v1.0 - Geographic IP Banning
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="geoban"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Geographic IP banning using country-based CIDR blocks"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package geoban

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/pkg/feeds"
	"github.com/itcmsgr/nftban/pkg/model"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

const (
	// BanFilePrefix is the prefix for ban config files
	BanFilePrefix = "50-ban-"

	// WhitelistFilePrefix is the prefix for whitelist config files
	WhitelistFilePrefix = "50-whitelist-"
)

// getDefaultGeobanDir returns geoban directory from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getDefaultGeobanDir() string {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir + "/geoban.d"
}

// Build loads all geoban country files and returns consolidated SetData
// This replaces the slow bash implementation with fast Go parsing
//
// Performance: <2s for 2,259 CIDRs (vs 120s timeout in bash)
//
// Features:
// - Reads from /etc/nftban/geoban.d/50-ban-*.conf files
// - IPv4/IPv6 automatic separation
// - CIDR normalization
// - Comment and empty line filtering
// - Streaming parsing (memory efficient)
func Build(geobanDir string, countries []string) (*model.SetData, error) {
	if geobanDir == "" {
		geobanDir = getDefaultGeobanDir()
	}

	data := model.NewSetData("geoban")

	// If no countries specified, load ALL ban files
	if len(countries) == 0 {
		entries, err := os.ReadDir(geobanDir)
		if err != nil {
			return nil, fmt.Errorf("failed to read geoban directory: %w", err)
		}

		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			// Load all 50-ban-*.conf files
			if strings.HasPrefix(entry.Name(), BanFilePrefix) && strings.HasSuffix(entry.Name(), ".conf") {
				countryCode := strings.TrimSuffix(strings.TrimPrefix(entry.Name(), BanFilePrefix), ".conf")
				countries = append(countries, countryCode)
			}
		}
	}

	// Load each country
	for _, country := range countries {
		if err := loadCountry(data, geobanDir, country); err != nil {
			// Log error but continue with other countries
			fmt.Fprintf(os.Stderr, "WARNING: Failed to load country %s: %v\n", country, err)
		}
	}

	return data, nil
}

// loadCountry loads a single country's ban file
func loadCountry(data *model.SetData, geobanDir, country string) error {
	// Normalize country code (uppercase)
	countryCode := strings.ToUpper(country)

	// Build filename: 50-ban-CN.conf
	filename := fmt.Sprintf("%s%s.conf", BanFilePrefix, countryCode)
	path := filepath.Join(geobanDir, filename)

	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("country file not found: %s", path)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineNum := 0

	for scanner.Scan() {
		lineNum++
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Parse CIDR
		if err := addCIDR(data, line); err != nil {
			// Log but don't fail on individual line errors
			fmt.Fprintf(os.Stderr, "WARNING: %s:%d: invalid CIDR: %s (%v)\n",
				path, lineNum, line, err)
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("error reading country file %s: %w", path, err)
	}

	return nil
}

// addCIDR adds a CIDR to the appropriate set (IPv4 or IPv6)
// Uses unified ParseFeedLine for consistent parsing across the codebase
func addCIDR(data *model.SetData, cidrStr string) error {
	entry, err := feeds.ParseFeedLine(cidrStr)
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

// ListBannedCountries returns list of currently banned countries
func ListBannedCountries(geobanDir string) ([]string, error) {
	if geobanDir == "" {
		geobanDir = getDefaultGeobanDir()
	}

	entries, err := os.ReadDir(geobanDir)
	if err != nil {
		return nil, fmt.Errorf("failed to read geoban directory: %w", err)
	}

	var countries []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if strings.HasPrefix(entry.Name(), BanFilePrefix) && strings.HasSuffix(entry.Name(), ".conf") {
			countryCode := strings.TrimSuffix(strings.TrimPrefix(entry.Name(), BanFilePrefix), ".conf")
			countries = append(countries, countryCode)
		}
	}

	return countries, nil
}

// ListWhitelistedCountries returns list of currently whitelisted countries
func ListWhitelistedCountries(geobanDir string) ([]string, error) {
	if geobanDir == "" {
		geobanDir = getDefaultGeobanDir()
	}

	entries, err := os.ReadDir(geobanDir)
	if err != nil {
		return nil, fmt.Errorf("failed to read geoban directory: %w", err)
	}

	var countries []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if strings.HasPrefix(entry.Name(), WhitelistFilePrefix) && strings.HasSuffix(entry.Name(), ".conf") {
			countryCode := strings.TrimSuffix(strings.TrimPrefix(entry.Name(), WhitelistFilePrefix), ".conf")
			countries = append(countries, countryCode)
		}
	}

	return countries, nil
}

// Stats returns statistics about geoban data
type Stats struct {
	Countries   int
	TotalCIDRs  int
	IPv4CIDRs   int
	IPv6CIDRs   int
	BannedList  []string
	WhitelistList []string
}

// GetStats returns statistics about current geoban configuration
func GetStats(geobanDir string) (*Stats, error) {
	banned, err := ListBannedCountries(geobanDir)
	if err != nil {
		return nil, err
	}

	whitelisted, err := ListWhitelistedCountries(geobanDir)
	if err != nil {
		return nil, err
	}

	data, err := Build(geobanDir, banned)
	if err != nil {
		return nil, err
	}

	return &Stats{
		Countries:     len(banned),
		TotalCIDRs:    data.Count,
		IPv4CIDRs:     len(data.IPv4),
		IPv6CIDRs:     len(data.IPv6),
		BannedList:    banned,
		WhitelistList: whitelisted,
	}, nil
}
