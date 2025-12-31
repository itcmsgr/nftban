// Package banlog provides centralized ban logging for NFTBan
// All ban actions (from any source) should log here for stats tracking
package banlog

import (
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// =============================================================================
// NFTBan Central Ban Log
// =============================================================================
// Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS
// Example: 2025-12-09|14:30:45|manual|192.168.1.100|US|BANNED
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
// Format: DATE|TIME|SOURCE|IP|COUNTRY|BANNED
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
	logMutex.Lock()
	defer logMutex.Unlock()

	logPath := getBanLogPath()

	// Ensure log directory exists (use LogDir from central config)
	cfg := nftbanconf.MustLoad()
	if err := os.MkdirAll(cfg.LogDir, 0755); err != nil {
		return fmt.Errorf("failed to create log directory: %w", err)
	}

	// Open file for append
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return fmt.Errorf("failed to open ban log: %w", err)
	}
	defer f.Close()

	// Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS
	now := time.Now()
	date := now.Format("2006-01-02")
	timeStr := now.Format("15:04:05")

	// Default country if empty
	if country == "" {
		country = "UNK"
	}

	// Normalize source
	source = normalizeSource(source)

	logLine := fmt.Sprintf("%s|%s|%s|%s|%s|%s\n", date, timeStr, source, ip, country, status)

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

// LogBanWithReason writes a ban entry with an optional reason (stored in extended format)
// This is for detailed logging - the reason is NOT used by stats but is useful for audit
func LogBanWithReason(ip, source, country, reason string) error {
	// For now, just call LogBan - reason can be added to extended log format later
	return LogBan(ip, source, country)
}
