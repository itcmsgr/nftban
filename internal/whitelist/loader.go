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
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
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
	// ExpiresAt carries the absolute RFC3339 timestamp from an inline
	// `# EXPIRES_AT=<ts>` marker (V120 session-whitelist convention). Zero
	// value = non-expiring (durable/trust entry) → permanent in the kernel.
	// A future timestamp = the element must carry a kernel timeout anchored
	// to this absolute instant, so a daemon FullSync/rebuild REFRESHES the
	// remaining TTL instead of clobbering the entry to permanent (CLI-BUG-2,
	// v1.168). Past timestamps are skipped at load and never reach here.
	ExpiresAt time.Time
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
//
// V120 (D-UPDATE-OPERATOR-SELF-BAN-GAP-001): if the line carries an inline
// `# EXPIRES_AT=<RFC3339>` marker, the entry is loaded only when the
// timestamp is in the future. Expired entries are skipped at load time so
// the runtime CIDR-aware membership check never sees them. Lines without an
// EXPIRES_AT marker continue to be loaded unchanged (backward compatibility
// with 00-system.conf, 99-manual.conf, and any pre-V120 whitelist files).
// Malformed EXPIRES_AT markers (no value, unparseable RFC3339) cause the
// entry to be skipped conservatively — operator-intent ambiguity is treated
// as "do not honor as whitelist."
func loadWhitelistFileTyped(filePath string, ipv4, ipv6 map[string]WhitelistEntry) error {
	return util.LoadLines(filePath, func(line string) error {
		entry := feeds.ParseFeedLineSilent(line)
		if entry == nil {
			return nil
		}
		// V120: skip if the entry carries an EXPIRES_AT marker that is past
		// or unparseable. No marker → load normally (backward compat).
		// v1.168 (CLI-BUG-2): for future markers, carry the absolute timestamp
		// so the daemon sync can apply a kernel timeout (not skip-only).
		expiresAt, skip := parseExpiresAt(line)
		if skip {
			return nil
		}
		we := WhitelistEntry{
			Value:     entry.Value,
			IsCIDR:    entry.IsCIDR,
			ExpiresAt: expiresAt,
		}
		if entry.IPv4 {
			ipv4[entry.Value] = we
		} else {
			ipv6[entry.Value] = we
		}
		return nil
	})
}

// shouldSkipDueToExpiresAt inspects the raw whitelist line for an inline
// `EXPIRES_AT=<RFC3339>` marker (V120 session-whitelist convention) and
// returns true if the entry should be SKIPPED — either because the marker
// is present-but-malformed, or because the timestamp has already passed.
// Returns false when there is no marker (the entry is non-expiring and
// loads normally) or when the marker is parseable and the timestamp is
// still in the future.
//
// V120 (D-UPDATE-OPERATOR-SELF-BAN-GAP-001): keeps the EXPIRES_AT contract
// in one place so AddSessionWhitelist (writer) and the loader (reader)
// stay byte-compatible. See internal/installer/safety/session_whitelist.go.
//
// v1.168 (CLI-BUG-2): thin wrapper over parseExpiresAt, preserving the
// original skip-only boolean contract for callers/tests that only care
// whether an entry must be dropped.
func shouldSkipDueToExpiresAt(line string) bool {
	_, skip := parseExpiresAt(line)
	return skip
}

// parseExpiresAt inspects the raw whitelist line for an inline
// `EXPIRES_AT=<RFC3339>` marker and returns:
//   - expiresAt: the parsed absolute timestamp for a still-future marker
//     (zero time when there is no marker — i.e. a non-expiring entry);
//   - skip: true when the entry must be DROPPED — marker present-but-malformed
//     (no value / unparseable) or already past.
//
// v1.168 (CLI-BUG-2): the daemon needs the absolute timestamp (not just a
// skip decision) so FullSync can apply a kernel timeout anchored to it. A
// re-sync recomputes remaining = expiresAt − now, so the timeout is REFRESHED
// rather than clobbered to permanent. Entries with no marker return
// (zero, false) → loaded as permanent (durable/trust).
func parseExpiresAt(line string) (expiresAt time.Time, skip bool) {
	const marker = "EXPIRES_AT="
	idx := strings.Index(line, marker)
	if idx < 0 {
		// No marker — entry is non-expiring; load normally as permanent.
		return time.Time{}, false
	}
	rest := line[idx+len(marker):]
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		// Marker present but no value — malformed; skip conservatively.
		return time.Time{}, true
	}
	ts, err := time.Parse(time.RFC3339, fields[0])
	if err != nil {
		// Unparseable timestamp — skip conservatively.
		return time.Time{}, true
	}
	if time.Now().UTC().After(ts) {
		// Already expired — skip.
		return time.Time{}, true
	}
	// Still future — carry the absolute timestamp for kernel-timeout sync.
	return ts.UTC(), false
}
