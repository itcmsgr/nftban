// =============================================================================
// NFTBan v1.120 - Installer Safety Session Whitelist (D-UPDATE-OPERATOR-SELF-BAN-GAP-001)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-safety-session"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-18"
// meta:description="Manage time-bounded operator-session whitelist entries with inline EXPIRES_AT TTL"
// meta:inventory.files="internal/installer/safety/session_whitelist.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="SSH_CLIENT,NFTBAN_OPERATOR_SESSION_IP"
// meta:inventory.config_files="/etc/nftban/whitelist.d/00-session.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Why this package exists (Shape E.0 — V120 design):
//
// On 2026-05-18 a real upgrade-window incident proved the gap:
// `D-UPDATE-OPERATOR-SELF-BAN-GAP-001`. The operator/dev egress IP was
// banned by lab2's own nftban LoginMon for 3 ssh_invalid_user events
// during an attempted V119 validation. The pre-existing SeedManualWhitelist
// captures SSH_CLIENT but is gated to `--source` install only and is a
// no-op on subsequent runs. There was no concept of a time-bounded
// "operator session" whitelist for `nftban update`, `firewall takeover`,
// or validation workflows.
//
// This package adds that concept WITHOUT a new nft set, WITHOUT a new
// systemd timer, WITHOUT metrics, and WITHOUT a schema bump — per
// `V120_OPERATOR_TEMP_WHITELIST_SCHEMA_IMPACT_DECISION.md` verdict
// SCHEMA_STAYS_FROZEN (conditional on --json deferral).
//
// Design (Shape E.0):
//   - Time-bounded entries live in /etc/nftban/whitelist.d/00-session.conf
//     with inline `# EXPIRES_AT=<RFC3339>  REASON=<text>  ADDED_BY=<source>`
//     comments.
//   - The whitelist loader (internal/whitelist/loader.go, v1.119 CIDR-aware)
//     is extended to parse the EXPIRES_AT marker and SKIP expired entries
//     at load time. No separate cleanup daemon required.
//   - This package provides Add / Cleanup / Read helpers consumed by the
//     installer (auto-seed during nftban update / firewall takeover) and
//     by the CLI (operator-explicit `nftban firewall whitelist-session`).
//
// Operator content is authoritative: 00-session.conf is managed by nftban
// (header + footer comments mark it as machine-managed); the operator's
// 99-manual.conf and 00-system.conf are NEVER touched by this package.
//
// =============================================================================

package safety

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// sessionWhitelistPath is the canonical path for time-bounded operator-session
// whitelist entries. Distinct from manualWhitelistPath (99-manual.conf) which
// holds permanent operator-owned content. A var (not const) so hermetic tests
// can redirect it to a temp file and restore via t.Cleanup.
var sessionWhitelistPath = "/etc/nftban/whitelist.d/00-session.conf"

// sessionWhitelistLockPath is a volatile, on-demand advisory lock file used to
// serialize the read-modify-write of sessionWhitelistPath ACROSS processes and
// ACROSS languages: Go takes it via syscall.Flock here; the shell CLI takes the
// SAME path via flock(1) in cli/lib/nftban/cli/cmd_firewall.sh. Both use
// flock(2), so they genuinely interlock. It lives under /run (not the config
// dir) so the whitelist `*.conf` loader glob can never see it. A var so tests
// can redirect it.
var sessionWhitelistLockPath = "/run/nftban/session_whitelist.lock"

// lockSessionWhitelist takes an exclusive advisory lock (flock LOCK_EX) on
// sessionWhitelistLockPath for the full duration of a session-whitelist
// read-modify-write, returning an unlock func the caller MUST defer.
//
// A SEPARATE lock file (not the data file) is used deliberately: the data file
// is replaced via atomic rename, which changes its inode, so a lock held on the
// data fd would not exclude a concurrent writer that opens the new inode. Same
// rationale as internal/persistence/blacklistd.go. The parent runtime dir is
// created on-demand (volatile /run).
func lockSessionWhitelist() (func(), error) {
	if dir := filepath.Dir(sessionWhitelistLockPath); dir != "" {
		_ = os.MkdirAll(dir, 0o750)
	}
	// 0600 root-only: only root processes (installer + CLI firewall verbs) take
	// this lock. filepath.Clean keeps gosec G304 quiet (matches blacklistd.go).
	f, err := os.OpenFile(filepath.Clean(sessionWhitelistLockPath), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open session-whitelist lock %s: %w", sessionWhitelistLockPath, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil { // #nosec G115 -- fd always fits in int
		_ = f.Close()
		return nil, fmt.Errorf("flock session-whitelist lock %s: %w", sessionWhitelistLockPath, err)
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN) // #nosec G115 -- fd always fits in int
		_ = f.Close()
	}, nil
}

// DefaultSessionWhitelistTTL is the default time-to-live for auto-seeded
// operator SSH peer entries during `nftban update` / `firewall takeover`.
// Chosen at 30 minutes to comfortably cover a normal upgrade + validation
// window without leaving long-lived stale allow entries.
const DefaultSessionWhitelistTTL = 30 * time.Minute

// sessionWhitelistHeader is written when 00-session.conf is created. The
// header explicitly marks the file as machine-managed so operators don't
// hand-edit it (use 99-manual.conf for permanent entries instead).
const sessionWhitelistHeader = `# =============================================================================
# NFTBan Session Whitelist (managed by nftban; do not hand-edit)
# =============================================================================
#
# This file holds time-bounded operator-session whitelist entries with
# inline EXPIRES_AT timestamps. Entries past EXPIRES_AT are skipped at
# whitelist-load time and never enter the runtime CIDR-aware membership
# check. Cleanup happens passively on every whitelist reload; explicit
# cleanup is available via ` + "`nftban firewall whitelist-session cleanup`" + `.
#
# FORMAT (one entry per line):
#   <ip-or-cidr>  # EXPIRES_AT=<RFC3339>  REASON=<short-text>  ADDED_BY=<source>
#
# Example:
#   192.0.2.122  # EXPIRES_AT=2026-05-18T10:13:32Z  REASON=v120-update-session  ADDED_BY=nftban-update
#
# Permanent operator entries belong in 99-manual.conf (NOT this file).
# Static host-interface entries belong in 00-system.conf (NOT this file).
#
# =============================================================================

`

// SessionWhitelistEntry captures a time-bounded whitelist entry.
type SessionWhitelistEntry struct {
	IP        string    // exact IP or CIDR (already validated by caller)
	ExpiresAt time.Time // UTC, RFC3339-serialized in the file
	Reason    string    // short human-readable purpose (e.g. "v120-update-session")
	AddedBy   string    // source identifier (e.g. "nftban-update", "nftban-firewall-whitelist-session")
}

// AddSessionWhitelist appends an entry to /etc/nftban/whitelist.d/00-session.conf.
// File is created with seed header on first add. Entries are deduplicated
// by IP (a new add for the same IP REFRESHES the EXPIRES_AT/REASON/ADDED_BY
// fields rather than creating a duplicate line).
//
// Caller responsibility: validate `entry.IP` is a routable IP or CIDR.
// This function does NOT re-validate (mirrors SeedManualWhitelist's contract).
//
// Atomic write semantics: the function reads the current file (if any),
// removes any prior entry for the same IP, appends the new entry, and
// writes the result via exec.WriteFileAtomic (which uses temp-file + rename
// to guarantee race-free updates).
func AddSessionWhitelist(exec executor.Executor, log *logging.Logger, entry SessionWhitelistEntry) error {
	if entry.IP == "" {
		return fmt.Errorf("AddSessionWhitelist: empty IP")
	}
	if entry.ExpiresAt.IsZero() {
		return fmt.Errorf("AddSessionWhitelist: zero ExpiresAt for %s", entry.IP)
	}
	if entry.AddedBy == "" {
		entry.AddedBy = "unknown"
	}
	if entry.Reason == "" {
		entry.Reason = "session"
	}

	// Serialize the whole read-modify-write against concurrent Go/shell writers
	// (cross-process, cross-language lost-update guard, §4.1).
	unlock, lerr := lockSessionWhitelist()
	if lerr != nil {
		return fmt.Errorf("AddSessionWhitelist: %w", lerr)
	}
	defer unlock()

	// Read existing content if file exists.
	var existing []byte
	if exec.FileExists(sessionWhitelistPath) {
		data, err := exec.ReadFile(sessionWhitelistPath)
		if err != nil {
			return fmt.Errorf("read %s: %w", sessionWhitelistPath, err)
		}
		existing = data
	}

	// Build new content: preserve header + lines that are NOT for this IP,
	// then append the new entry.
	var b bytes.Buffer
	hasHeader := bytes.Contains(existing, []byte("# NFTBan Session Whitelist"))
	if !hasHeader {
		b.WriteString(sessionWhitelistHeader)
	}

	// Carry forward all existing lines except a prior entry for this IP.
	// Lines are matched by the first whitespace-delimited token before the
	// first '#' (the IP/CIDR field).
	for _, line := range strings.Split(string(existing), "\n") {
		if extractIPField(line) == entry.IP {
			// drop — will be re-appended fresh below
			continue
		}
		// Preserve everything else (header lines, other entries, blanks).
		b.WriteString(line)
		b.WriteString("\n")
	}

	// Ensure there's a single trailing newline before the new entry block.
	trimmed := strings.TrimRight(b.String(), "\n") + "\n"
	b.Reset()
	b.WriteString(trimmed)

	// Append the new entry. RFC3339 in UTC.
	expiresStr := entry.ExpiresAt.UTC().Format(time.RFC3339)
	fmt.Fprintf(&b, "%s  # EXPIRES_AT=%s  REASON=%s  ADDED_BY=%s\n",
		entry.IP, expiresStr, entry.Reason, entry.AddedBy)

	if err := exec.WriteFileAtomic(sessionWhitelistPath, b.Bytes(), 0640); err != nil {
		return fmt.Errorf("write %s: %w", sessionWhitelistPath, err)
	}

	log.Info("session-whitelist add: %s (expires %s, reason=%s, added_by=%s)",
		entry.IP, expiresStr, entry.Reason, entry.AddedBy)
	return nil
}

// CleanupExpiredSessionWhitelist removes entries past EXPIRES_AT from
// 00-session.conf. Returns (removed_count, error). Idempotent: safe to
// call when the file is absent (returns 0, nil) or has no expired entries.
//
// The whitelist loader already skips expired entries at runtime, so this
// function is OPTIONAL for correctness — it is provided as a file-hygiene
// helper so the on-disk file doesn't accumulate stale entries indefinitely.
func CleanupExpiredSessionWhitelist(exec executor.Executor, log *logging.Logger) (int, error) {
	// Serialize the read-modify-write (cross-process, cross-language, §4.1).
	unlock, lerr := lockSessionWhitelist()
	if lerr != nil {
		return 0, fmt.Errorf("CleanupExpiredSessionWhitelist: %w", lerr)
	}
	defer unlock()

	if !exec.FileExists(sessionWhitelistPath) {
		return 0, nil
	}
	data, err := exec.ReadFile(sessionWhitelistPath)
	if err != nil {
		return 0, fmt.Errorf("read %s: %w", sessionWhitelistPath, err)
	}

	now := time.Now().UTC()
	var b bytes.Buffer
	removed := 0

	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			// Preserve blank/comment lines (incl. header)
			b.WriteString(line)
			b.WriteString("\n")
			continue
		}
		// Entry line — check EXPIRES_AT marker
		if expired, _ := lineIsExpired(line, now); expired {
			removed++
			continue
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	if err := scanner.Err(); err != nil {
		return 0, fmt.Errorf("scan %s: %w", sessionWhitelistPath, err)
	}

	if removed == 0 {
		return 0, nil
	}

	if err := exec.WriteFileAtomic(sessionWhitelistPath, b.Bytes(), 0640); err != nil {
		return 0, fmt.Errorf("write %s: %w", sessionWhitelistPath, err)
	}

	log.Info("session-whitelist cleanup: removed %d expired entries", removed)
	return removed, nil
}

// ReadSessionWhitelist returns all non-expired entries from 00-session.conf.
// Used by the CLI list subcommand. Returns an empty slice (not an error)
// when the file is absent.
func ReadSessionWhitelist(exec executor.Executor, log *logging.Logger) ([]SessionWhitelistEntry, error) {
	if !exec.FileExists(sessionWhitelistPath) {
		return nil, nil
	}
	data, err := exec.ReadFile(sessionWhitelistPath)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", sessionWhitelistPath, err)
	}

	now := time.Now().UTC()
	var out []SessionWhitelistEntry
	for _, line := range strings.Split(string(data), "\n") {
		entry, ok := parseSessionLine(line)
		if !ok {
			continue
		}
		if now.After(entry.ExpiresAt) {
			continue
		}
		out = append(out, entry)
	}
	return out, nil
}

// RemoveSessionWhitelist deletes any entry for the given IP from 00-session.conf.
// Returns (removed_count, error). 0 removed is not an error.
func RemoveSessionWhitelist(exec executor.Executor, log *logging.Logger, ip string) (int, error) {
	if ip == "" {
		return 0, fmt.Errorf("RemoveSessionWhitelist: empty IP")
	}
	// Serialize the read-modify-write (cross-process, cross-language, §4.1).
	unlock, lerr := lockSessionWhitelist()
	if lerr != nil {
		return 0, fmt.Errorf("RemoveSessionWhitelist: %w", lerr)
	}
	defer unlock()

	if !exec.FileExists(sessionWhitelistPath) {
		return 0, nil
	}
	data, err := exec.ReadFile(sessionWhitelistPath)
	if err != nil {
		return 0, fmt.Errorf("read %s: %w", sessionWhitelistPath, err)
	}

	var b bytes.Buffer
	removed := 0
	for _, line := range strings.Split(string(data), "\n") {
		if extractIPField(line) == ip {
			removed++
			continue
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	// Strip the trailing extra "\n" we added.
	trimmed := strings.TrimRight(b.String(), "\n") + "\n"

	if removed == 0 {
		return 0, nil
	}

	if err := exec.WriteFileAtomic(sessionWhitelistPath, []byte(trimmed), 0640); err != nil {
		return 0, fmt.Errorf("write %s: %w", sessionWhitelistPath, err)
	}

	log.Info("session-whitelist remove: %s (%d entries)", ip, removed)
	return removed, nil
}

// CaptureSSHPeerIP returns the active SSH peer IP, preferring the explicit
// NFTBAN_OPERATOR_SESSION_IP env-mirror (set by `nftban update` wrapper in
// cli/lib/nftban/cli/cmd_update.sh) and falling back to the first
// whitespace-delimited field of $SSH_CLIENT. Returns empty string if both
// sources are absent or the resulting token is not a routable IP.
//
// The explicit env-mirror takes precedence because the update wrapper
// captures SSH_CLIENT before any sudo / package-scriptlet hop that might
// scrub it. Direct invocations of nftban-installer (without the wrapper)
// still get SSH_CLIENT fallback if the SSH session env is intact.
//
// SSH_CLIENT format set by sshd: "client_ip client_port server_port".
// In non-SSH contexts (cron, systemd timer, etc.) both sources are empty —
// callers must treat empty return as "no SSH session; skip seeding."
func CaptureSSHPeerIP() string {
	// Explicit env-mirror first (set by `nftban update` wrapper; survives
	// sudo / package-scriptlet hops that scrub SSH_CLIENT).
	if explicit := strings.TrimSpace(os.Getenv("NFTBAN_OPERATOR_SESSION_IP")); explicit != "" {
		if isRoutableIP(explicit) {
			return explicit
		}
	}
	sshClient := os.Getenv("SSH_CLIENT")
	if sshClient == "" {
		return ""
	}
	fields := strings.Fields(sshClient)
	if len(fields) == 0 {
		return ""
	}
	if !isRoutableIP(fields[0]) {
		return ""
	}
	return fields[0]
}

// extractIPField returns the first whitespace-delimited token from a line,
// stopping at any '#' comment. Returns empty string for blank/comment-only
// lines. Used for IP-keyed deduplication and removal.
func extractIPField(line string) string {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, "#") {
		return ""
	}
	// Trim at first '#'
	if idx := strings.Index(trimmed, "#"); idx >= 0 {
		trimmed = strings.TrimSpace(trimmed[:idx])
	}
	fields := strings.Fields(trimmed)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

// lineIsExpired returns (true, expiresAt) if the line carries an EXPIRES_AT
// marker that has already passed `now`, OR is malformed (conservative skip).
// Returns (false, zeroTime) if no marker or marker is parseable and still
// in the future.
func lineIsExpired(line string, now time.Time) (bool, time.Time) {
	const marker = "EXPIRES_AT="
	idx := strings.Index(line, marker)
	if idx < 0 {
		return false, time.Time{}
	}
	rest := line[idx+len(marker):]
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		// Marker present but no value — malformed; conservative skip.
		return true, time.Time{}
	}
	ts, err := time.Parse(time.RFC3339, fields[0])
	if err != nil {
		// Unparseable; conservative skip.
		return true, time.Time{}
	}
	if now.After(ts) {
		return true, ts
	}
	return false, ts
}

// parseSessionLine parses a session-whitelist file line into a
// SessionWhitelistEntry. Returns (entry, true) on success; (zero, false) for
// blank/comment-only lines, missing EXPIRES_AT, or unparseable timestamps.
//
// Unlike lineIsExpired, this requires a parseable EXPIRES_AT — used by
// ReadSessionWhitelist which needs structured data, not just expiry status.
func parseSessionLine(line string) (SessionWhitelistEntry, bool) {
	ip := extractIPField(line)
	if ip == "" {
		return SessionWhitelistEntry{}, false
	}
	commentIdx := strings.Index(line, "#")
	if commentIdx < 0 {
		return SessionWhitelistEntry{}, false
	}
	comment := line[commentIdx+1:]

	entry := SessionWhitelistEntry{IP: ip}

	// Token-by-token parse: EXPIRES_AT=<val>, REASON=<val>, ADDED_BY=<val>.
	// Tokens are whitespace-delimited; values are single-token (no spaces).
	for _, tok := range strings.Fields(comment) {
		switch {
		case strings.HasPrefix(tok, "EXPIRES_AT="):
			ts, err := time.Parse(time.RFC3339, strings.TrimPrefix(tok, "EXPIRES_AT="))
			if err != nil {
				return SessionWhitelistEntry{}, false
			}
			entry.ExpiresAt = ts
		case strings.HasPrefix(tok, "REASON="):
			entry.Reason = strings.TrimPrefix(tok, "REASON=")
		case strings.HasPrefix(tok, "ADDED_BY="):
			entry.AddedBy = strings.TrimPrefix(tok, "ADDED_BY=")
		}
	}

	if entry.ExpiresAt.IsZero() {
		return SessionWhitelistEntry{}, false
	}
	return entry, true
}

// (isRoutableIP is defined in this package's whitelist.go and reused here.)
