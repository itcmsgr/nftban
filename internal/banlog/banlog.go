// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// Package banlog provides centralized ban logging for NFTBan
// All ban actions (from any source) should log here for stats tracking
//
// meta:name="banlog"
// meta:type="package"
// meta:version="1.41.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Central ban logging with audit trail support"
// meta:inventory.files="/var/log/nftban/bans.log"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="write:/var/log/nftban/"
package banlog

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/safety"
)

// =============================================================================
// NFTBan Central Ban Log
// =============================================================================
// Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON|BAN_ID
// Example: 2025-12-09|14:30:45|manual|192.168.1.100|US|BANNED|brute_force_ssh|a1b2c3d4e5f6g7h8
// Note: REASON field is optional (empty string if not provided)
// Note: BAN_ID field (v1.41.0) links BAN→UNBAN entries. Empty for pre-v1.41.0 compat.
//
// This log is read by nftban_stats.sh for ACTIVITY HISTORY dashboard:
// - login (SSH/auth failures)
// - portscan (port scan detection)
// - ddos (DDoS protection)
// - manual (manual bans)
// - feeds (threat intelligence feeds)
// - suricata (IDS alerts)
// =============================================================================

// Source constants for ban log entries
const (
	SourceManual    = "manual"
	SourceLogin     = "login"
	SourcePortscan  = "portscan"
	SourceDDoS      = "ddos"
	SourceFeeds     = "feeds"
	SourceSuricata  = "suricata"
	SourceFail2ban  = "fail2ban" // Legacy compatibility
)

// Status constants
const (
	StatusBanned   = "BANNED"
	StatusUnbanned = "UNBANNED"
)

var (
	logMutex sync.Mutex
)

// getBanLogPath returns the path to bans.log from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getBanLogPath() string {
	paths := nftbanconf.MustLoadPaths()
	if paths.BansLog != "" {
		return paths.BansLog
	}
	cfg := nftbanconf.MustLoad()
	return cfg.LogDir + "/bans.log"
}

// LogBan writes a ban entry to the central ban.log
// Parameters:
//   - ip: IP address being banned
//   - source: Ban source (manual, login, portscan, ddos, feeds, suricata)
//   - country: Country code (e.g., "US", "CN", "UNK" if unknown)
//
// Format: DATE|TIME|SOURCE|IP|COUNTRY|BANNED|REASON (reason empty for this func)
// Use LogBanWithReason for audit trail with reason
func LogBan(ip, source, country string) error {
	return writeEntry(ip, source, country, StatusBanned)
}

// LogUnban writes an unban entry to the central ban.log
// Parameters:
//   - ip: IP address being unbanned
//   - source: Unban source (usually "manual")
//   - country: Country code
//
// Format: DATE|TIME|SOURCE|IP|COUNTRY|UNBANNED
func LogUnban(ip, source, country string) error {
	return writeEntry(ip, source, country, StatusUnbanned)
}

// writeEntry writes a log entry to ban.log
func writeEntry(ip, source, country, status string) error {
	return writeEntryWithReason(ip, source, country, status, "")
}

// writeEntryWithReason writes a log entry to ban.log with optional reason for audit
func writeEntryWithReason(ip, source, country, status, reason string) error {
	return writeEntryWithReasonAndID(ip, source, country, status, reason, "")
}

// writeEntryWithReasonAndID writes a log entry with optional reason and ban correlation ID
// v1.41.0: Format is now 8 fields: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON|BAN_ID
// The 8th field is backward compatible — existing parsers using cut -d'|' -fN with N<=7 ignore it
func writeEntryWithReasonAndID(ip, source, country, status, reason, banID string) error {
	logMutex.Lock()
	defer logMutex.Unlock()

	logPath := getBanLogPath()

	// Ensure log directory exists (use LogDir from central config)
	cfg := nftbanconf.MustLoad()
	if err := safety.SafeMkdirAll(cfg.LogDir, 0755); err != nil {
		return fmt.Errorf("failed to create log directory: %w", err)
	}

	// Open file for append (TOCTOU-safe with O_NOFOLLOW)
	f, err := safety.SafeOpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return fmt.Errorf("failed to open ban log: %w", err)
	}
	defer f.Close()

	// Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON|BAN_ID
	now := time.Now()
	date := now.Format("2006-01-02")
	timeStr := now.Format("15:04:05")

	// Default country if empty
	if country == "" {
		country = "UNK"
	}

	// Normalize source
	source = normalizeSource(source)

	// Sanitize reason (remove pipe characters to preserve format)
	reason = sanitizeReason(reason)

	logLine := fmt.Sprintf("%s|%s|%s|%s|%s|%s|%s|%s\n", date, timeStr, source, ip, country, status, reason, banID)

	if _, err := f.WriteString(logLine); err != nil {
		return fmt.Errorf("failed to write to ban log: %w", err)
	}

	return nil
}

// normalizeSource ensures source string matches expected values for stats parsing
func normalizeSource(source string) string {
	switch source {
	case "manual", "user":
		return SourceManual
	case "login", "ssh", "auth", "login-monitor", "nftban-sshd":
		return SourceLogin
	case "portscan", "scan", "port-scan":
		return SourcePortscan
	case "ddos", "flood", "synflood", "rate-limit":
		return SourceDDoS
	case "feeds", "feed", "threat-intel":
		return SourceFeeds
	case "suricata", "ids":
		return SourceSuricata
	case "fail2ban":
		return SourceFail2ban
	default:
		// Keep original for unknown sources
		return source
	}
}

// LogBanWithReason writes a ban entry with a reason for audit trail
// Format: DATE|TIME|SOURCE|IP|COUNTRY|BANNED|REASON
func LogBanWithReason(ip, source, country, reason string) error {
	return writeEntryWithReason(ip, source, country, StatusBanned, reason)
}

// LogUnbanWithReason writes an unban entry with a reason for audit trail
// Format: DATE|TIME|SOURCE|IP|COUNTRY|UNBANNED|REASON
func LogUnbanWithReason(ip, source, country, reason string) error {
	return writeEntryWithReason(ip, source, country, StatusUnbanned, reason)
}

// LogBanWithID writes a ban entry with a reason and correlation ID (v1.41.0)
// The banID links this BAN entry to a future UNBAN entry for the same incident
// Format: DATE|TIME|SOURCE|IP|COUNTRY|BANNED|REASON|BAN_ID
func LogBanWithID(ip, source, country, reason, banID string) error {
	return writeEntryWithReasonAndID(ip, source, country, StatusBanned, reason, banID)
}

// LogUnbanWithID writes an unban entry with a correlation ID (v1.41.0)
// The banID should match the ID from the original ban entry
// Format: DATE|TIME|SOURCE|IP|COUNTRY|UNBANNED|REASON|BAN_ID
func LogUnbanWithID(ip, source, country, reason, banID string) error {
	return writeEntryWithReasonAndID(ip, source, country, StatusUnbanned, reason, banID)
}

// GenerateBanID creates a unique 16-char hex ban correlation ID
func GenerateBanID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		// Fallback: use timestamp-based ID if crypto/rand fails
		return fmt.Sprintf("%016x", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

// sanitizeReason removes pipe characters from reason to preserve log format
func sanitizeReason(reason string) string {
	// Replace pipes with dashes to preserve field separation
	result := ""
	for _, c := range reason {
		if c == '|' {
			result += "-"
		} else if c == '\n' || c == '\r' {
			result += " "
		} else {
			result += string(c)
		}
	}
	return result
}
