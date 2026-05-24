// =============================================================================
// NFTBan v1.0 - Persistent Offender Tracker
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="tracker"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Tracks persistent offenders from ban log entries"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package escalation

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/banlog"
	"github.com/itcmsgr/nftban/internal/safety"
)

// BanEntry represents a ban logged in bans.log (v1.0: removed fail2ban prefix)
type BanEntry struct {
	Timestamp time.Time
	IP        string
	Jail      string
	Reason    string
}

// LogTempBan logs a temporary ban to the tracking file for escalation tracking.
//
// V127 UX-3 item 2.4 (A1 facade convergence):
// Pre-V127 this function wrote a SPACE-DELIMITED legacy format
// ("2025-11-27T10:00:00Z 1.2.3.4 nftban-sshd SSH brute force") to logPath.
// Callers passed cfg.BanLog (= /var/log/nftban/bans.log), which is the SAME
// file internal/banlog/banlog.go::writeEntryFull writes in BLC-1 pipe format
// to — producing interleaved mixed-format rows that broke nftban stats recent
// (audit item 2.4).
//
// LogTempBan is RETAINED as a backward-compatibility facade so existing
// call sites (cmd/nftban-core/cmd_ban.go, cmd/nftband/daemon_handlers_ban.go,
// and any future callers) keep their unchanged signature, but the body now
// delegates to banlog.LogBanFull so bans.log has ONE writer path and ONE
// canonical 10-field BLC-1 pipe format.
//
// Any future caller of LogTempBan automatically gets BLC-1 — the legacy
// space-delimited format CANNOT reappear unless this function is rewritten
// or a new direct-write code path is added (regression test guards against
// that). For new code, prefer calling banlog.LogBanFull directly with an
// explicit BanClass; reach for LogTempBan only when wrapping an existing
// jail/reason-pair shape from legacy escalation callers.
//
// The logPath parameter is preserved in the signature for backward
// compatibility but is NOT used — banlog routes to the canonical path via
// nftbanconf.MustLoadPaths(). If a legacy caller passes a non-canonical
// path, the entry STILL lands in /var/log/nftban/bans.log (intentional —
// the convergence is the whole point).
//
// (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-3 item 2.4)
func LogTempBan(logPath, ip, jail, reason string) error {
	_ = logPath // intentionally unused; banlog.LogBanFull routes to canonical path
	// Map jail -> banlog source via banlog.normalizeSource (called inside
	// writeEntryFull). "jail" was the fail2ban-era field name; for modern
	// callers it carries the source string (login/portscan/ddos/etc.) directly.
	// The escalation-relevant temp-ban shape: country unknown (caller doesn't
	// have it; banlog defaults to "UNK"), banID empty (LogTempBan callers
	// don't generate a correlation ID), timeoutSec=0 (we don't know the TTL
	// at this layer; the kernel set TTL is the source of truth), class=temp
	// (this function exists specifically for temp bans by name).
	return banlog.LogBanFull(ip, jail, "", reason, "", 0, banlog.ClassTemp)
}

// CountRecentBans counts how many times an IP was banned in the given period
func CountRecentBans(logPath, ip string, period time.Duration) (int, error) {
	f, err := os.Open(logPath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil // Log doesn't exist yet = 0 bans
		}
		return 0, fmt.Errorf("failed to open ban log: %w", err)
	}
	defer f.Close()

	cutoff := time.Now().Add(-period)
	count := 0

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		entry, err := parseBanEntry(line)
		if err != nil {
			continue // Skip malformed lines
		}

		// Count only bans for this IP after the cutoff time
		if entry.IP == ip && entry.Timestamp.After(cutoff) {
			count++
		}
	}

	if err := scanner.Err(); err != nil {
		return 0, fmt.Errorf("failed to read ban log: %w", err)
	}

	return count, nil
}

// parseBanEntry parses a log line into a BanEntry
// Format: "2025-11-27T10:00:00Z 1.2.3.4 nftban-sshd SSH brute force"
func parseBanEntry(line string) (*BanEntry, error) {
	parts := strings.Fields(line)
	if len(parts) < 3 {
		return nil, fmt.Errorf("invalid log line: %s", line)
	}

	timestamp, err := time.Parse(time.RFC3339, parts[0])
	if err != nil {
		return nil, fmt.Errorf("invalid timestamp: %w", err)
	}

	reason := ""
	if len(parts) > 3 {
		reason = strings.Join(parts[3:], " ")
	}

	return &BanEntry{
		Timestamp: timestamp,
		IP:        parts[1],
		Jail:      parts[2],
		Reason:    reason,
	}, nil
}

// AddToPersistentOffenders adds an IP to the persistent offenders config file
func AddToPersistentOffenders(confPath, ip, reason string) error {
	// Check if already in file
	exists, err := isInFile(confPath, ip)
	if err != nil {
		return err
	}
	if exists {
		return nil // Already persistent
	}

	// Append to file (TOCTOU-safe)
	f, err := safety.SafeOpenFile(confPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to open persistent offenders file: %w", err)
	}
	defer f.Close()

	line := fmt.Sprintf("%s  # persistent offender: %s\n", ip, reason)
	if _, err := f.WriteString(line); err != nil {
		return fmt.Errorf("failed to write to persistent offenders file: %w", err)
	}

	return nil
}

// LogPersistentOffender logs to persistent-offenders.log
func LogPersistentOffender(logPath, ip, jail string, banCount int) error {
	// TOCTOU-safe file open
	f, err := safety.SafeOpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to open offenders log: %w", err)
	}
	defer f.Close()

	timestamp := time.Now().Format(time.RFC3339)
	logLine := fmt.Sprintf("%s %s %s %d bans - escalated to permanent\n",
		timestamp, ip, jail, banCount)

	if _, err := f.WriteString(logLine); err != nil {
		return fmt.Errorf("failed to write to offenders log: %w", err)
	}

	return nil
}

// isInFile checks if an IP already exists in a file
func isInFile(path, ip string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Extract IP (first field)
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == ip {
			return true, nil
		}
	}

	return false, scanner.Err()
}
