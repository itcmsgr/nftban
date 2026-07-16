// =============================================================================
// NFTBan v1.84 - Bounded Journal Evidence Reader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="journal-evidence"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Bounded journal query for daemon runtime evidence"
// meta:inventory.files="internal/validator/journal.go"
// meta:inventory.binaries="journalctl"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// A1-1: Bounded journal evidence reader, consumed by BotGuard (A1-2)
// and LoginMon (A1-3) module evaluators for runtime evidence beyond
// systemctl is-active.
//
// Design contract:
// - Bounded: time window (-15m) + line count (-n 200), no full scan
// - Deterministic: same input → same output, newest-first (-r)
// - Fail-safe: command failure returns structured error, never panics
// - Silent: no impact on validator status, findings, or exit code
//
// Command shape:
//
//	journalctl -u nftband --since "-15m" --no-pager -o cat -r [-g REGEX] -n 200
//
// v1.216.3: pattern queries are scoped SERVER-SIDE with `-g <regex>` (a
// regexp.QuoteMeta-escaped OR of the literal patterns) so the `-n` line cap
// bounds MATCHING lines, not all unit lines. Without this, a high-volume
// journal (e.g. a host under auth attack emitting hundreds of [EVENT]/[BAN]
// lines per minute) evicts low-rate evidence — the LoginMon 5-minute
// heartbeat — from the returned window, reintroducing a false VAL-LOGINMON-001.
// The Go-side substring scan is retained as first-match confirmation.
// =============================================================================
package validator

import (
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/procenv"
)

// JournalQuery defines a bounded journal search.
type JournalQuery struct {
	Unit     string        // systemd unit to filter (e.g. "nftband")
	Patterns []string      // substring patterns to match (first match wins)
	Since    time.Duration // how far back to look (default 15m)
	MaxLines int           // max lines from journalctl -n (default 200)
	Timeout  time.Duration // exec timeout (default 2s)
}

// ErrKind classifies journal query failures.
type ErrKind string

const (
	ErrNone    ErrKind = ""        // success (may still have Found=false)
	ErrTimeout ErrKind = "timeout" // context deadline exceeded
	ErrExec    ErrKind = "exec"    // binary not found / permission denied
	ErrNonZero ErrKind = "nonzero" // journalctl exited non-zero (not "no matches")
	ErrEmpty   ErrKind = "empty"   // command succeeded but zero output
)

// JournalEvidence holds the result of a bounded journal query.
type JournalEvidence struct {
	Found        bool    // true if at least one pattern matched
	MatchedLine  string  // first matching line (newest-first order)
	MatchedIndex int     // index of matched line in output (0-based)
	LinesRead    int     // total lines read from journal
	Truncated    bool    // true if journalctl hit -n limit
	ErrKind      ErrKind // failure classification
	Err          error   // underlying error (nil on success)
}

// JournalReader abstracts journal queries for testability.
type JournalReader interface {
	Query(ctx context.Context, q JournalQuery) JournalEvidence
}

// SystemdJournalReader is the production implementation using journalctl.
type SystemdJournalReader struct{}

// buildJournalArgs constructs the journalctl argv for a bounded query.
//
// v1.216.3: when Patterns are present, a server-side `-g <regex>` is added — a
// regexp.QuoteMeta-escaped OR of the literal patterns — placed before `-n` so the
// line cap bounds MATCHING lines, not all unit lines. This is the fix for busy-host
// eviction: previously `-n 200` capped total output before the Go-side match, so a
// high-volume journal could hide low-rate evidence (the LoginMon 5m heartbeat).
//
// Security: every pattern is a compile-time internal constant, each is escaped with
// regexp.QuoteMeta (so e.g. "[botguard] loaded" is a literal, not a character class),
// and args are passed as argv to exec.Command — no shell, no injection, no overmatch.
// Callers still get idempotent defaulting, so this is safe to unit-test standalone.
func buildJournalArgs(q JournalQuery) []string {
	applyDefaults(&q) // q is a value copy; local defaulting only
	args := []string{
		"-u", q.Unit,
		"--since", fmt.Sprintf("-%dm", int(q.Since.Minutes())),
		"--no-pager",
		"-o", "cat",
		"-r",
	}
	if len(q.Patterns) > 0 {
		escaped := make([]string, len(q.Patterns))
		for i, p := range q.Patterns {
			escaped[i] = regexp.QuoteMeta(p)
		}
		args = append(args, "-g", strings.Join(escaped, "|"))
	}
	args = append(args, "-n", fmt.Sprintf("%d", q.MaxLines))
	return args
}

// Query executes a bounded journalctl query and matches patterns in Go.
//
// Strategy: fetch server-side pattern-scoped output (-g, v1.216.3) bounded by
// -o cat -r -n N, then scan lines for substring matches (first match wins).
func (SystemdJournalReader) Query(ctx context.Context, q JournalQuery) JournalEvidence {
	applyDefaults(&q)

	// Apply timeout
	ctx, cancel := context.WithTimeout(ctx, q.Timeout)
	defer cancel()

	// Fixed binary "journalctl"; buildJournalArgs returns bounded internal constants,
	// each pattern regexp.QuoteMeta-escaped, passed as argv (no shell, no tainted input).
	cmd := procenv.CommandContext(ctx, "journalctl", buildJournalArgs(q)...) // #nosec G204 -- args are bounded internal constants, escaped, argv-only (no shell)

	out, err := cmd.Output()
	return parseJournalResult(q, out, err, ctx.Err())
}

// parseJournalResult maps a journalctl invocation (stdout, exec error, and the
// context error) to structured evidence. Pure and unit-testable without a live journal.
//
// v1.216.3 CRITICAL semantics with server-side -g: journalctl exits 1 with empty output
// when nothing matches (grep convention, verified on systemd 252/255). For a PATTERN
// query that is a definitive "evidence absent" result — returned as ErrNone/Found=false
// so callers still emit their "no evidence" finding (e.g. VAL-LOGINMON-001 must still
// fire when a module is genuinely unbound/dead). If this were classified ErrEmpty, the
// callers' `ErrKind == ErrNone` guard would suppress the finding entirely. Real failures
// (timeout, exec-not-found, other non-zero exit) still classify as errors so the caller
// fails safe (no emit) rather than asserting absence it could not determine.
func parseJournalResult(q JournalQuery, out []byte, err error, ctxErr error) JournalEvidence {
	hasPatterns := len(q.Patterns) > 0
	if err != nil {
		if ctxErr != nil {
			return JournalEvidence{ErrKind: ErrTimeout, Err: err}
		}
		if _, ok := err.(*exec.Error); ok {
			return JournalEvidence{ErrKind: ErrExec, Err: err} // binary missing / perm denied
		}
		if exitErr, ok := err.(*exec.ExitError); ok {
			if exitErr.ExitCode() == 1 {
				// exit 1 = grep-style "no match". For a pattern query this is a
				// successful absence, not a failure.
				if hasPatterns {
					return JournalEvidence{ErrKind: ErrNone, Found: false}
				}
				return JournalEvidence{ErrKind: ErrEmpty}
			}
			return JournalEvidence{ErrKind: ErrNonZero, Err: err}
		}
		return JournalEvidence{ErrKind: ErrExec, Err: err}
	}

	raw := strings.TrimSpace(string(out))
	if raw == "" {
		// Ran clean (exit 0) but no output. For a pattern query (-g) that is a
		// definitive no-match; treat as ErrNone/Found=false (absent), same as exit 1.
		if hasPatterns {
			return JournalEvidence{ErrKind: ErrNone, Found: false}
		}
		return JournalEvidence{ErrKind: ErrEmpty}
	}

	lines := strings.Split(raw, "\n")
	truncated := len(lines) >= q.MaxLines

	// Scan for patterns (substring match, case-sensitive, first match wins).
	if hasPatterns {
		for i, line := range lines {
			for _, pattern := range q.Patterns {
				if strings.Contains(line, pattern) {
					return JournalEvidence{
						Found:        true,
						MatchedLine:  line,
						MatchedIndex: i,
						LinesRead:    len(lines),
						Truncated:    truncated,
					}
				}
			}
		}
	}

	// No pattern match (or no patterns specified).
	return JournalEvidence{
		Found:     false,
		LinesRead: len(lines),
		Truncated: truncated,
	}
}

// applyDefaults sets safe defaults for zero-value query fields.
func applyDefaults(q *JournalQuery) {
	if q.Since <= 0 {
		q.Since = 15 * time.Minute
	}
	if q.MaxLines <= 0 {
		q.MaxLines = 200
	}
	if q.Timeout <= 0 {
		q.Timeout = 2 * time.Second
	}
	if q.Unit == "" {
		q.Unit = "nftband"
	}
}

// defaultJournalReader is the package-level reader, overridable for tests.
var defaultJournalReader JournalReader = SystemdJournalReader{}

// SetJournalReader replaces the journal reader (for testing only).
func SetJournalReader(r JournalReader) {
	defaultJournalReader = r
}

// queryJournal runs a bounded journal query using the default reader.
// This is the function module evaluators will call (when wired in A1-2/A1-3).
func queryJournal(ctx context.Context, q JournalQuery) JournalEvidence {
	return defaultJournalReader.Query(ctx, q)
}
