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
//   journalctl -u nftband --since "-15m" --no-pager -o cat -r -n 200
//
// Pattern matching is done in Go (substring), not journalctl --grep.
// This avoids repeated subprocess cost and keeps matching deterministic.
// =============================================================================
package validator

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
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

// Query executes a bounded journalctl query and matches patterns in Go.
//
// Strategy: fetch bounded output once with -o cat -r -n N, then scan
// lines for substring matches. No --grep, no shell pipes, no repeated
// subprocess calls.
func (SystemdJournalReader) Query(ctx context.Context, q JournalQuery) JournalEvidence {
	applyDefaults(&q)

	// Apply timeout
	ctx, cancel := context.WithTimeout(ctx, q.Timeout)
	defer cancel()

	// Build command: journalctl -u UNIT --since "-Xm" --no-pager -o cat -r -n N
	sinceArg := fmt.Sprintf("-%dm", int(q.Since.Minutes()))
	cmd := exec.CommandContext(ctx, "journalctl", // #nosec G204 -- args are bounded, not user-controlled
		"-u", q.Unit,
		"--since", sinceArg,
		"--no-pager",
		"-o", "cat",
		"-r",
		"-n", fmt.Sprintf("%d", q.MaxLines),
	)

	out, err := cmd.Output()
	if err != nil {
		return classifyError(ctx, err)
	}

	raw := strings.TrimSpace(string(out))
	if raw == "" {
		return JournalEvidence{ErrKind: ErrEmpty}
	}

	lines := strings.Split(raw, "\n")
	truncated := len(lines) >= q.MaxLines

	// Scan for patterns (substring match, case-sensitive, first match wins)
	if len(q.Patterns) > 0 {
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

	// No pattern match (or no patterns specified)
	return JournalEvidence{
		Found:     false,
		LinesRead: len(lines),
		Truncated: truncated,
	}
}

// classifyError maps exec errors to structured ErrKind.
func classifyError(ctx context.Context, err error) JournalEvidence {
	if ctx.Err() != nil {
		return JournalEvidence{ErrKind: ErrTimeout, Err: err}
	}
	if _, ok := err.(*exec.Error); ok {
		// Binary not found / permission denied
		return JournalEvidence{ErrKind: ErrExec, Err: err}
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		// journalctl exits 1 on no matches with some configurations
		if exitErr.ExitCode() == 1 {
			return JournalEvidence{ErrKind: ErrEmpty}
		}
		return JournalEvidence{ErrKind: ErrNonZero, Err: err}
	}
	return JournalEvidence{ErrKind: ErrExec, Err: err}
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
