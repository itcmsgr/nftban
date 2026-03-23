// =============================================================================
// NFTBan - Whitelist Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Loads and manages IP whitelist entries from config files"
// meta:input="Whitelist configuration files"
// meta:output="IPv4 and IPv6 address sets"
// meta:depends="github.com/itcmsgr/nftban/internal/feeds,github.com/itcmsgr/nftban/internal/netutil"
// meta:inventory.files="/etc/nftban/whitelist.conf,/etc/nftban/whitelist.d/*.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package whitelist

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/setsync"
	"github.com/itcmsgr/nftban/internal/util"
)

// LoadAllWhitelists loads IPs from all whitelist sources:
// - /etc/nftban/whitelist.conf (main file)
// - /etc/nftban/whitelist.d/*.conf (modular files)
// Returns two sets: IPv4 and IPv6 addresses
//
// Now uses optimized generic Set type from pkg/util for:
// - Zero memory overhead (struct{} instead of bool)
// - Consistent API
// - Better performance
func LoadAllWhitelists(configDir string) (map[string]bool, map[string]bool, error) {
	// Use generic Set internally for efficiency
	ipv4Set := util.NewSet[string]()
	ipv6Set := util.NewSet[string]()

	// 1. Load main whitelist.conf (optional - whitelist.d/ is preferred)
	mainFile := filepath.Join(configDir, "whitelist.conf")
	if err := loadWhitelistFile(mainFile, ipv4Set, ipv6Set); err != nil {
		// Non-fatal: file is optional, only log if it exists but has errors
		if !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "Warning: Could not load %s: %v\n", mainFile, err)
		}
	}

	// 2. Load all files from whitelist.d/
	whitelistDir := filepath.Join(configDir, "whitelist.d")
	entries, err := os.ReadDir(whitelistDir)
	if err != nil {
		// Non-fatal: directory might not exist yet
		fmt.Fprintf(os.Stderr, "Warning: Could not read whitelist.d: %v\n", err)

		// Convert to map[string]bool for backwards compatibility
		ipv4Map := make(map[string]bool, ipv4Set.Len())
		for ip := range ipv4Set {
			ipv4Map[ip] = true
		}
		ipv6Map := make(map[string]bool, ipv6Set.Len())
		for ip := range ipv6Set {
			ipv6Map[ip] = true
		}
		return ipv4Map, ipv6Map, nil
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(entry.Name(), ".conf") {
			continue
		}

		filePath := filepath.Join(whitelistDir, entry.Name())
		if err := loadWhitelistFile(filePath, ipv4Set, ipv6Set); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Could not load %s: %v\n", filePath, err)
		}
	}

	// Convert util.Set back to map[string]bool for backwards compatibility
	// TODO: Update all callers to use util.Set directly in future
	ipv4Map := make(map[string]bool, ipv4Set.Len())
	for ip := range ipv4Set {
		ipv4Map[ip] = true
	}

	ipv6Map := make(map[string]bool, ipv6Set.Len())
	for ip := range ipv6Set {
		ipv6Map[ip] = true
	}

	return ipv4Map, ipv6Map, nil
}

// loadWhitelistFile loads IPs from a single whitelist file
// Uses unified ParseFeedLine for consistent parsing across the codebase
func loadWhitelistFile(filePath string, ipv4Set, ipv6Set util.Set[string]) error {
	lineNum := 0

	return util.LoadLines(filePath, func(line string) error {
		lineNum++

		// Use unified parser for consistent handling
		entry := feeds.ParseFeedLineSilent(line)
		if entry == nil {
			return nil // Skip empty/comment lines or invalid entries
		}

		if entry.IPv4 {
			ipv4Set.Add(entry.Value)
		} else {
			ipv6Set.Add(entry.Value)
		}

		return nil
	})
}

// AddIP adds an IP to the appropriate whitelist file
// Creates whitelist.d/99-manual.conf for manual additions
func AddIP(configDir string, ipStr string) error {
	// Reject /0 and /1 CIDR prefixes - would match entire address space
	if strings.Contains(ipStr, "/") {
		_, ipNet, err := net.ParseCIDR(ipStr)
		if err == nil {
			ones, _ := ipNet.Mask.Size()
			if ones <= 1 {
				return fmt.Errorf("refusing to whitelist /%d: would match entire address space", ones)
			}
		}
	}

	// v1.19.0: Reject bogon/reserved ranges (R23)
	// Uses shared bogon filter from pkg/sync/cidr.go
	filtered, stats := setsync.FilterProblematicCIDRs([]string{ipStr})
	if stats.Bogon > 0 || stats.TooLarge > 0 {
		return fmt.Errorf("refusing to whitelist %s: bogon/reserved range", ipStr)
	}
	if len(filtered) == 0 {
		return fmt.Errorf("refusing to whitelist %s: filtered as problematic", ipStr)
	}

	// Validate IP
	normalizedIP, isIPv4, err := netutil.ValidateAndNormalizeIP(ipStr)
	if err != nil {
		return err
	}

	// Target file: whitelist.d/99-manual.conf
	whitelistDir := filepath.Join(configDir, "whitelist.d")
	if err := os.MkdirAll(whitelistDir, 0750); err != nil {
		return fmt.Errorf("failed to create whitelist.d: %w", err)
	}

	manualFile := filepath.Join(whitelistDir, "99-manual.conf")

	// Check if IP already exists
	ipv4Set, ipv6Set, err := LoadAllWhitelists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load whitelists: %w", err)
	}

	if isIPv4 {
		if ipv4Set[normalizedIP] {
			return fmt.Errorf("IP %s already whitelisted", normalizedIP)
		}
	} else {
		if ipv6Set[normalizedIP] {
			return fmt.Errorf("IP %s already whitelisted", normalizedIP)
		}
	}

	// Append to manual file
	f, err := os.OpenFile(manualFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0640)
	if err != nil {
		return fmt.Errorf("failed to open manual whitelist: %w", err)
	}
	defer f.Close()

	// Add header if file is empty
	stat, _ := f.Stat()
	if stat.Size() == 0 {
		fmt.Fprintf(f, "# Manual Whitelist Entries\n")
		fmt.Fprintf(f, "# Added via nftban whitelist add command\n")
		fmt.Fprintf(f, "# Format: One IP or CIDR per line\n\n")
	}

	fmt.Fprintf(f, "%s\n", normalizedIP)
	return nil
}

// RemoveIP removes an IP from all whitelist files
// Note: This searches all .conf files and removes the IP
func RemoveIP(configDir string, ipStr string) error {
	// Validate and normalize IP
	normalizedIP, _, err := netutil.ValidateAndNormalizeIP(ipStr)
	if err != nil {
		return err
	}

	removed := false

	// Check main whitelist.conf
	mainFile := filepath.Join(configDir, "whitelist.conf")
	if err := removeIPFromFile(mainFile, normalizedIP); err == nil {
		removed = true
	}

	// Check all files in whitelist.d/
	whitelistDir := filepath.Join(configDir, "whitelist.d")
	entries, err := os.ReadDir(whitelistDir)
	if err == nil {
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".conf") {
				continue
			}

			// Skip system-critical files (00-system.conf, 01-nftban-init.conf)
			if entry.Name() == "00-system.conf" || entry.Name() == "01-nftban-init.conf" {
				continue
			}

			filePath := filepath.Join(whitelistDir, entry.Name())
			if err := removeIPFromFile(filePath, normalizedIP); err == nil {
				removed = true
			}
		}
	}

	if !removed {
		return fmt.Errorf("IP %s not found in whitelist", normalizedIP)
	}

	return nil
}

// removeIPFromFile removes an IP from a specific file
// Uses util.RemoveLineFromFile for atomic file operations
func removeIPFromFile(filePath string, ipToRemove string) error {
	removed, err := util.RemoveLineFromFile(filePath, func(line string) bool {
		trimmed := strings.TrimSpace(line)
		// Check if this line contains the IP (exact match or with whitespace/comment after)
		return trimmed == ipToRemove ||
			strings.HasPrefix(trimmed, ipToRemove+" ") ||
			strings.HasPrefix(trimmed, ipToRemove+"\t")
	})

	if err != nil {
		return err
	}
	if !removed {
		return fmt.Errorf("IP not found in %s", filePath)
	}
	return nil
}
