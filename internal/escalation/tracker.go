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
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/banlog"
	"github.com/itcmsgr/nftban/internal/persistence"
	"github.com/itcmsgr/nftban/internal/safety"
)

// BanEntry represents a ban logged in bans.log (v1.0: removed fail2ban prefix)
type BanEntry struct {
	Timestamp time.Time
	IP        string
	Jail      string // BLC-1 SOURCE field
	Reason    string
	Status    string // BLC-1 STATUS field (BANNED/UNBANNED/RESYNC)
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

		// Count only BANNED events for this IP after the cutoff time.
		// (BLC-1 also logs UNBANNED/RESYNC rows for the same IP — those are
		// not bans and must not inflate the repeat-offender count.)
		if entry.IP == ip && entry.Status == banlog.StatusBanned && entry.Timestamp.After(cutoff) {
			count++
		}
	}

	if err := scanner.Err(); err != nil {
		return 0, fmt.Errorf("failed to read ban log: %w", err)
	}

	return count, nil
}

// parseBanEntry parses a canonical BLC-1 bans.log line into a BanEntry.
//
// D-UXV-16 fix: bans.log is written by internal/banlog in BLC-1 pipe format
// (DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON|BAN_ID|TIMEOUT|CLASS), where DATE
// is "2006-01-02", TIME is "15:04:05", both in local time (see banlog
// writeEntryFull). The pre-fix parser used strings.Fields + RFC3339 — the
// long-dead space-delimited format — so it failed on EVERY BLC-1 row, making
// CountRecentBans return 0 for every IP and silently disabling repeat-offender
// escalation. BLC-1 is now canonical; the legacy space format is not parsed.
func parseBanEntry(line string) (*BanEntry, error) {
	fields := strings.Split(line, "|")
	if len(fields) < 6 {
		return nil, fmt.Errorf("not a BLC-1 bans.log line: %q", line)
	}

	timestamp, err := time.ParseInLocation("2006-01-02 15:04:05", fields[0]+" "+fields[1], time.Local)
	if err != nil {
		return nil, fmt.Errorf("invalid BLC-1 timestamp %q %q: %w", fields[0], fields[1], err)
	}

	reason := ""
	if len(fields) > 6 {
		reason = fields[6]
	}

	return &BanEntry{
		Timestamp: timestamp,
		IP:        fields[3],
		Jail:      fields[2],
		Reason:    reason,
		Status:    fields[5],
	}, nil
}

// AddToPersistentOffenders adds an IP to the persistent offenders config file.
//
// D-UXV-17 fix: this used an UNLOCKED O_APPEND write that raced the persistence
// package's flock+temp+rename writer on the SAME file
// (blacklist.d/30-persistent-offenders.conf) — a concurrent rename could clobber
// the appended line, and the two paths emitted different comment formats. It now
// delegates to persistence.PersistBan, the single canonical writer (stable-lock
// flock + atomic temp+rename + IP dedup + normalized "IP  # reason" format), so
// there is exactly ONE writer path for that file.
func AddToPersistentOffenders(confPath, ip, reason string) error {
	// confPath is <configDir>/blacklist.d/<file>; PersistBan takes the config
	// root and derives blacklist.d/30-persistent-offenders.conf for source
	// "persistent" (see persistence fileMapping).
	configDir := filepath.Dir(filepath.Dir(confPath))
	if _, _, err := persistence.PersistBan(configDir, ip, reason, "persistent"); err != nil {
		return fmt.Errorf("failed to persist offender %s: %w", ip, err)
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
