// =============================================================================
// NFTBan - Blacklist Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Loads and manages IP blacklist entries from config files"
// meta:input="Blacklist configuration files"
// meta:output="IPv4 and IPv6 address sets"
// meta:depends="github.com/itcmsgr/nftban/pkg/feeds,github.com/itcmsgr/nftban/pkg/netutil"
// meta:inventory.files="/etc/nftban/blacklist.d/*.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package blacklist

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/pkg/feeds"
	"github.com/itcmsgr/nftban/pkg/netutil"
	"github.com/itcmsgr/nftban/pkg/util"
)

// LoadAllBlacklists loads IPs from all blacklist sources:
// - /etc/nftban/blacklist.d/*.conf (modular files organized by category)
// Returns two sets: IPv4 and IPv6 addresses
//
// Now uses optimized generic Set type from pkg/util for:
// - Zero memory overhead (struct{} instead of bool)
// - Consistent API
// - Better performance
func LoadAllBlacklists(configDir string) (map[string]bool, map[string]bool, error) {
	// Use generic Set internally for efficiency
	ipv4Set := util.NewSet[string]()
	ipv6Set := util.NewSet[string]()

	// Load all files from blacklist.d/
	blacklistDir := filepath.Join(configDir, "blacklist.d")
	entries, err := os.ReadDir(blacklistDir)
	if err != nil {
		// Non-fatal: directory might not exist yet
		fmt.Fprintf(os.Stderr, "Warning: Could not read blacklist.d: %v\n", err)

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

		filePath := filepath.Join(blacklistDir, entry.Name())
		if err := loadBlacklistFile(filePath, ipv4Set, ipv6Set); err != nil {
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

// loadBlacklistFile loads IPs from a single blacklist file
// Uses unified ParseFeedLine for consistent parsing across the codebase
func loadBlacklistFile(filePath string, ipv4Set, ipv6Set util.Set[string]) error {
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

// AddIP adds an IP to the appropriate blacklist file
// Creates blacklist.d/99-manual.conf for manual additions
// Deprecated: Use AddIPWithSource for source-specific files
func AddIP(configDir string, ipStr string, reason string) error {
	return AddIPWithSource(configDir, ipStr, reason, "manual")
}

// AddIPWithSource adds an IP to a source-specific blacklist file
// Source determines the target file:
//   - "login"    -> login-auto.conf
//   - "portscan" -> portscan-auto.conf
//   - "ddos"     -> ddos-auto.conf
//   - "manual"   -> 99-manual.conf (default)
//   - others     -> 99-manual.conf
func AddIPWithSource(configDir string, ipStr string, reason string, source string) error {
	// Validate IP
	normalizedIP, isIPv4, err := netutil.ValidateAndNormalizeIP(ipStr)
	if err != nil {
		return err
	}

	// Determine target file based on source
	blacklistDir := filepath.Join(configDir, "blacklist.d")
	if err := os.MkdirAll(blacklistDir, 0750); err != nil {
		return fmt.Errorf("failed to create blacklist.d: %w", err)
	}

	var targetFile string
	var fileHeader string
	switch source {
	case "login":
		targetFile = filepath.Join(blacklistDir, "login-auto.conf")
		fileHeader = "# Login Monitor Auto-Ban Entries\n# Added automatically by nftban-login-monitor\n# Format: IP  # reason\n\n"
	case "portscan":
		targetFile = filepath.Join(blacklistDir, "portscan-auto.conf")
		fileHeader = "# Port Scan Auto-Ban Entries\n# Added automatically by nftban-portscan\n# Format: IP  # reason\n\n"
	case "ddos":
		targetFile = filepath.Join(blacklistDir, "ddos-auto.conf")
		fileHeader = "# DDoS Auto-Ban Entries\n# Added automatically by nftban-ddos\n# Format: IP  # reason\n\n"
	case "persistent":
		targetFile = filepath.Join(blacklistDir, "30-persistent-offenders.conf")
		fileHeader = "# Persistent Offenders - Permanent Bans\n# IPs that exceeded ban thresholds and were escalated\n# Format: IP  # reason\n\n"
	default:
		targetFile = filepath.Join(blacklistDir, "99-manual.conf")
		fileHeader = "# Manual Blacklist Entries\n# Added via nftban ban command\n# Format: IP  # reason\n\n"
	}

	manualFile := targetFile

	// Check if IP already exists
	ipv4Set, ipv6Set, err := LoadAllBlacklists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load blacklists: %w", err)
	}

	if isIPv4 {
		if ipv4Set[normalizedIP] {
			return fmt.Errorf("IP %s already blacklisted", normalizedIP)
		}
	} else {
		if ipv6Set[normalizedIP] {
			return fmt.Errorf("IP %s already blacklisted", normalizedIP)
		}
	}

	// Append to manual file
	f, err := os.OpenFile(manualFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0640)
	if err != nil {
		return fmt.Errorf("failed to open manual blacklist: %w", err)
	}
	defer f.Close()

	// Add header if file is empty
	stat, _ := f.Stat()
	if stat.Size() == 0 {
		fmt.Fprintf(f, "%s", fileHeader)
	}

	if reason != "" {
		fmt.Fprintf(f, "%s  # %s\n", normalizedIP, reason)
	} else {
		fmt.Fprintf(f, "%s\n", normalizedIP)
	}

	return nil
}

// RemoveIP removes an IP from all blacklist files
func RemoveIP(configDir string, ipStr string) error {
	// Validate and normalize IP
	normalizedIP, _, err := netutil.ValidateAndNormalizeIP(ipStr)
	if err != nil {
		return err
	}

	removed := false

	// Check all files in blacklist.d/
	blacklistDir := filepath.Join(configDir, "blacklist.d")
	entries, err := os.ReadDir(blacklistDir)
	if err != nil {
		return fmt.Errorf("could not read blacklist.d: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".conf") {
			continue
		}

		filePath := filepath.Join(blacklistDir, entry.Name())
		if err := removeIPFromFile(filePath, normalizedIP); err == nil {
			removed = true
		}
	}

	if !removed {
		return fmt.Errorf("IP %s not found in blacklist", normalizedIP)
	}

	return nil
}

// removeIPFromFile removes an IP from a specific file
// Uses util.RemoveLineFromFile for atomic file operations
func removeIPFromFile(filePath string, ipToRemove string) error {
	removed, err := util.RemoveLineFromFile(filePath, func(line string) bool {
		trimmed := strings.TrimSpace(line)

		// Handle inline comments
		ipPart := trimmed
		if idx := strings.Index(trimmed, "#"); idx >= 0 {
			ipPart = strings.TrimSpace(trimmed[:idx])
		}
		fields := strings.Fields(ipPart)
		if len(fields) > 0 {
			ipPart = fields[0]
		}

		return ipPart == ipToRemove
	})

	if err != nil {
		return err
	}
	if !removed {
		return fmt.Errorf("IP not found in %s", filePath)
	}
	return nil
}

// GetBlacklistByCategory returns IPs from a specific category file
func GetBlacklistByCategory(configDir string, category string) ([]string, []string, error) {
	fileName := filepath.Join(configDir, "blacklist.d", category+".conf")

	ipv4Set := util.NewSet[string]()
	ipv6Set := util.NewSet[string]()

	if err := loadBlacklistFile(fileName, ipv4Set, ipv6Set); err != nil {
		return nil, nil, err
	}

	// Convert maps to slices with pre-allocation to avoid reallocations
	ipv4List := make([]string, 0, ipv4Set.Len())
	for ip := range ipv4Set {
		ipv4List = append(ipv4List, ip)
	}

	ipv6List := make([]string, 0, ipv6Set.Len())
	for ip := range ipv6Set {
		ipv6List = append(ipv6List, ip)
	}

	return ipv4List, ipv6List, nil
}
