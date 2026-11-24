// =============================================================================
// NFTBan v1.0 - Geographic IP Banning
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
	"net/netip"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/model"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

const (
	// BanFilePrefix is the prefix for ban config files
	BanFilePrefix = "50-ban-"

	// WhitelistFilePrefix is the prefix for whitelist config files
	// v1.19.0: Fixed to match shell convention (was "50-whitelist-", shell uses "40-whitelist-")
	WhitelistFilePrefix = "40-whitelist-"
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

	// v1.238 GeoBan country exceptions (owner GO 2026-11-23, option B): addresses of an
	// excepted country (geoban.d/40-whitelist-<CC>.conf) are removed from the GeoBan block
	// set ONLY. Exceptions are not whitelist entries: feeds, detectors and manual bans keep
	// their own authority over these addresses. Before v1.238 the files were written by
	// `nftban geoban whitelist <CC>` and never read (BUG-GEOBAN-WHITELIST-CC-WRITES-FILE-NEVER-LOADED).
	exc, err := loadExceptions(geobanDir)
	if err != nil {
		return nil, err
	}
	if len(exc) > 0 {
		before := data.Count
		applyExceptions(data, exc)
		fmt.Fprintf(os.Stderr, "GeoBan: %d country exception prefix(es) applied; block entries %d -> %d\n",
			len(exc), before, data.Count)
	}

	return data, nil
}

// ExceptionFilePrefix names GeoBan country-exception files (historically "whitelist").
const ExceptionFilePrefix = WhitelistFilePrefix

// loadExceptions reads every geoban.d/40-whitelist-*.conf prefix. An exception file that
// exists but cannot be read is an error: silently dropping an exception would block a
// country the operator excepted.
func loadExceptions(geobanDir string) ([]netip.Prefix, error) {
	entries, err := os.ReadDir(geobanDir)
	if err != nil {
		return nil, nil // no geoban directory: no exceptions (Build already read bans from it)
	}
	var out []netip.Prefix
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasPrefix(name, ExceptionFilePrefix) || !strings.HasSuffix(name, ".conf") {
			continue
		}
		path := filepath.Join(geobanDir, name)
		f, err := os.Open(filepath.Clean(path))
		if err != nil {
			return nil, fmt.Errorf("geoban exception file %s unreadable: %w", path, err)
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if pf, ok := parsePrefix(line); ok {
				out = append(out, pf)
			}
		}
		serr := sc.Err()
		_ = f.Close()
		if serr != nil {
			return nil, fmt.Errorf("geoban exception file %s: %w", path, serr)
		}
	}
	return out, nil
}

func parsePrefix(s string) (netip.Prefix, bool) {
	if pf, err := netip.ParsePrefix(s); err == nil {
		return pf.Masked(), true
	}
	if a, err := netip.ParseAddr(s); err == nil {
		return netip.PrefixFrom(a, a.BitLen()), true
	}
	return netip.Prefix{}, false
}

// applyExceptions removes every excepted address from data (IPv4 and IPv6 separately).
// A block prefix wholly inside an exception is dropped; one that contains an exception is
// split into the smallest set of prefixes that covers the rest.
func applyExceptions(data *model.SetData, exc []netip.Prefix) {
	var v4, v6 []netip.Prefix
	for _, e := range exc {
		if e.Addr().Is4() {
			v4 = append(v4, e)
		} else {
			v6 = append(v6, e)
		}
	}
	data.IPv4 = subtractAll(data.IPv4, v4)
	data.IPv6 = subtractAll(data.IPv6, v6)
	data.Count = len(data.IPv4) + len(data.IPv6)
}

func subtractAll(entries []string, exc []netip.Prefix) []string {
	if len(exc) == 0 {
		return entries
	}
	out := make([]string, 0, len(entries))
	for _, s := range entries {
		p, ok := parsePrefix(s)
		if !ok {
			out = append(out, s) // not ours to judge; the loader already validated it
			continue
		}
		var rel []netip.Prefix
		for _, e := range exc {
			if e.Overlaps(p) {
				rel = append(rel, e)
			}
		}
		if len(rel) == 0 {
			out = append(out, s)
			continue
		}
		for _, r := range excludePrefix(p, rel) {
			out = append(out, r.String())
		}
	}
	return out
}

// excludePrefix returns p minus every prefix in exc (all of which overlap p).
func excludePrefix(p netip.Prefix, exc []netip.Prefix) []netip.Prefix {
	inside := false
	for _, e := range exc {
		if e.Bits() <= p.Bits() && e.Contains(p.Addr()) {
			return nil // p is wholly excepted
		}
		if e.Bits() > p.Bits() && p.Contains(e.Addr()) {
			inside = true
		}
	}
	if !inside {
		return []netip.Prefix{p}
	}
	lo, hi := splitPrefix(p)
	var rel []netip.Prefix
	var out []netip.Prefix
	for _, half := range []netip.Prefix{lo, hi} {
		rel = rel[:0]
		for _, e := range exc {
			if e.Overlaps(half) {
				rel = append(rel, e)
			}
		}
		if len(rel) == 0 {
			out = append(out, half)
		} else {
			out = append(out, excludePrefix(half, rel)...)
		}
	}
	return out
}

// splitPrefix splits p (bits < address length) into its two halves.
func splitPrefix(p netip.Prefix) (netip.Prefix, netip.Prefix) {
	b := p.Bits()
	a := p.Masked().Addr()
	lo := netip.PrefixFrom(a, b+1)
	bs := a.AsSlice()
	bs[b/8] |= 0x80 >> (b % 8)
	ha, _ := netip.AddrFromSlice(bs)
	return lo, netip.PrefixFrom(ha, b+1)
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
