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
// meta:depends="github.com/itcmsgr/nftban/internal/feeds,github.com/itcmsgr/nftban/internal/netutil"
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
	"net/netip"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/util"
)

// BlacklistEntry is the typed loader output preserving IsCIDR semantics so
// downstream callers can do CIDR-containment lookups instead of exact-key
// map[ip] match. The pre-V119 loader dropped IsCIDR on the entry.Value path,
// silently turning entries like "1.2.3.0/27" into opaque map keys that no
// longer matched "1.2.3.5" — closes D-MANUAL-CIDR-LOAD-GAP per
// V116_CAND3_MANUAL_CIDR_DESIGN_FIX_SCOPE.md §3.
type BlacklistEntry struct {
	Value  string // exact normalized form as written: "1.2.3.4" or "1.2.3.0/27"
	IsCIDR bool   // true if Value contains "/"
}

// LoadAllBlacklists loads IPs from all blacklist sources and returns two
// map[string]bool sets for backward compatibility with pre-V119 callers
// (notably cmd/nftban-core/profile_sync.go which iterates keys for pprof
// diff profiling and does not perform membership tests).
//
// New consumers needing CIDR semantics should call LoadAllBlacklistsTyped
// + IsIPInBlacklistFile instead.
//
// V119: thin wrapper around LoadAllBlacklistsTyped (single scanning/parsing
// path, two return shapes) per the dual-API pattern in
// V119_MANUAL_CIDR_PREFLIGHT_PROFILE_SYNC_AUDIT.md §5.
func LoadAllBlacklists(configDir string) (map[string]bool, map[string]bool, error) {
	ipv4Typed, ipv6Typed, err := LoadAllBlacklistsTyped(configDir)
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

// LoadAllBlacklistsTyped loads IPs from all blacklist sources and returns
// map[string]BlacklistEntry preserving IsCIDR semantics. Use in tandem
// with IsIPInBlacklistFile for CIDR-aware membership checks.
//
// V119 A1: closes D-MANUAL-CIDR-LOAD-GAP. Callers in V116 §4 allowlist
// (cmd_check.go, cmd_ban.go, cmd_unban.go, daemon_handlers_ban.go) use
// this typed loader; profile_sync.go remains on legacy LoadAllBlacklists.
func LoadAllBlacklistsTyped(configDir string) (map[string]BlacklistEntry, map[string]BlacklistEntry, error) {
	ipv4 := make(map[string]BlacklistEntry)
	ipv6 := make(map[string]BlacklistEntry)

	blacklistDir := filepath.Join(configDir, "blacklist.d")
	entries, err := os.ReadDir(blacklistDir)
	if err != nil {
		// Non-fatal: directory might not exist yet
		fmt.Fprintf(os.Stderr, "Warning: Could not read blacklist.d: %v\n", err)
		return ipv4, ipv6, nil
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(entry.Name(), ".conf") {
			continue
		}

		filePath := filepath.Join(blacklistDir, entry.Name())
		if err := loadBlacklistFileTyped(filePath, ipv4, ipv6); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Could not load %s: %v\n", filePath, err)
		}
	}

	return ipv4, ipv6, nil
}

// IsIPInBlacklistFile returns true if ip is present as an exact key OR is
// contained within any CIDR entry in the typed map. 1:1 replacement for
// the pre-V119 exact-key `entries[ip]` pattern at callsites needing
// CIDR-aware membership.
//
// The ip argument must be a single IP literal (e.g. "1.2.3.45"), not a CIDR.
// To check whether an exact CIDR string is in the file (e.g. "1.2.3.0/27"
// as a literal), use direct map lookup `_, ok := entries[cidr]` instead.
//
// V119 A1: closes D-MANUAL-CIDR-LOAD-GAP.
func IsIPInBlacklistFile(ip string, entries map[string]BlacklistEntry) bool {
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

// loadBlacklistFile loads IPs from a single blacklist file (legacy
// signature retained for any future direct callers; current internal
// users have migrated to loadBlacklistFileTyped via the dual-API).
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

// loadBlacklistFileTyped loads IPs from a single blacklist file into typed
// maps, preserving IsCIDR semantics from feeds.ParsedEntry.
func loadBlacklistFileTyped(filePath string, ipv4, ipv6 map[string]BlacklistEntry) error {
	return util.LoadLines(filePath, func(line string) error {
		entry := feeds.ParseFeedLineSilent(line)
		if entry == nil {
			return nil
		}
		be := BlacklistEntry{
			Value:  entry.Value,
			IsCIDR: entry.IsCIDR,
		}
		if entry.IPv4 {
			ipv4[entry.Value] = be
		} else {
			ipv6[entry.Value] = be
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
