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
	"net/netip"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/setsync"
	"github.com/itcmsgr/nftban/internal/util"
)

// WhitelistEntry is the typed loader output preserving IsCIDR semantics so
// the daemon pre-ban guard can detect IP-in-CIDR membership instead of the
// pre-V119 exact-key map[ip] match. Mirror of blacklist.BlacklistEntry —
// closes the symmetric whitelist half of D-MANUAL-CIDR-LOAD-GAP per
// V116_CAND3_MANUAL_CIDR_DESIGN_FIX_SCOPE.md §3.
type WhitelistEntry struct {
	Value  string // exact normalized form as written: "1.2.3.4" or "1.2.3.0/27"
	IsCIDR bool   // true if Value contains "/"
}

// LoadAllWhitelists loads IPs from all whitelist sources and returns two
// map[string]bool sets for backward compatibility with pre-V119 callers
// (notably cmd/nftban-core/profile_sync.go which iterates keys for pprof
// diff profiling and does not perform membership tests).
//
// New consumers needing CIDR semantics should call LoadAllWhitelistsTyped
// + IsIPInWhitelistFile instead.
//
// V119: thin wrapper around LoadAllWhitelistsTyped (single scanning/parsing
// path, two return shapes) per the dual-API pattern in
// V119_MANUAL_CIDR_PREFLIGHT_PROFILE_SYNC_AUDIT.md §5.
func LoadAllWhitelists(configDir string) (map[string]bool, map[string]bool, error) {
	ipv4Typed, ipv6Typed, err := LoadAllWhitelistsTyped(configDir)
	if err != nil {
		return nil, nil, err
	}
	ipv4Map := make(map[string]bool, len(ipv4Typed))
	for k := range ipv4Typed {
		ipv4Map[k] = true
	}
	ipv6Map := make(map[string]bool, len(ipv6Typed))
	for k := range ipv6Typed {
		ipv6Map[k] = true
	}
	return ipv4Map, ipv6Map, nil
}

// LoadAllWhitelistsTyped loads IPs from all whitelist sources and returns
// map[string]WhitelistEntry preserving IsCIDR semantics. Use in tandem
// with IsIPInWhitelistFile for CIDR-aware membership checks.
//
// V119 A1: closes whitelist half of D-MANUAL-CIDR-LOAD-GAP. Callers in
// V116 §4 allowlist (cmd_check.go, cmd_ban.go, daemon_handlers_ban.go)
// use this typed loader; profile_sync.go remains on legacy LoadAllWhitelists.
func LoadAllWhitelistsTyped(configDir string) (map[string]WhitelistEntry, map[string]WhitelistEntry, error) {
	ipv4 := make(map[string]WhitelistEntry)
	ipv6 := make(map[string]WhitelistEntry)

	// 1. Load main whitelist.conf (optional - whitelist.d/ is preferred)
	mainFile := filepath.Join(configDir, "whitelist.conf")
	if err := loadWhitelistFileTyped(mainFile, ipv4, ipv6); err != nil {
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
		return ipv4, ipv6, nil
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(entry.Name(), ".conf") {
			continue
		}

		filePath := filepath.Join(whitelistDir, entry.Name())
		if err := loadWhitelistFileTyped(filePath, ipv4, ipv6); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Could not load %s: %v\n", filePath, err)
		}
	}

	return ipv4, ipv6, nil
}

// IsIPInWhitelistFile returns true if ip is present as an exact key OR is
// contained within any CIDR entry in the typed map. 1:1 replacement for
// the pre-V119 exact-key `entries[ip]` pattern at callsites needing
// CIDR-aware membership (notably the daemon pre-ban guard).
//
// The ip argument must be a single IP literal (e.g. "1.2.3.45"), not a CIDR.
// To check whether an exact CIDR string is in the file (e.g. "1.2.3.0/27"
// as a literal), use direct map lookup `_, ok := entries[cidr]` instead.
//
// V119 A1: closes whitelist half of D-MANUAL-CIDR-LOAD-GAP — protects an
// IP inside a whitelisted /27 from being banned.
func IsIPInWhitelistFile(ip string, entries map[string]WhitelistEntry) bool {
	// Fast path: exact key match (single-IP entries or literal-CIDR lookups)
	if _, ok := entries[ip]; ok {
		return true
	}
	// Slow path: iterate CIDR entries for containment check
	parsedIP, err := netip.ParseAddr(ip)
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if !entry.IsCIDR {
			continue
		}
		prefix, err := netip.ParsePrefix(entry.Value)
		if err != nil {
			continue
		}
		if prefix.Contains(parsedIP) {
			return true
		}
	}
	return false
}

// loadWhitelistFileTyped loads IPs from a single whitelist file into typed
// maps, preserving IsCIDR semantics from feeds.ParsedEntry.
func loadWhitelistFileTyped(filePath string, ipv4, ipv6 map[string]WhitelistEntry) error {
	return util.LoadLines(filePath, func(line string) error {
		entry := feeds.ParseFeedLineSilent(line)
		if entry == nil {
			return nil
		}
		we := WhitelistEntry{
			Value:  entry.Value,
			IsCIDR: entry.IsCIDR,
		}
		if entry.IPv4 {
			ipv4[entry.Value] = we
		} else {
			ipv6[entry.Value] = we
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
	// Uses shared bogon filter from internal/setsync/cidr.go
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
