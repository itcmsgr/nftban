// =============================================================================
// NFTBan v1.84 - Journal Evidence Reader Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="journal-evidence-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:inventory.files="internal/validator/journal_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Test matrix from A1-1 audit specification:
// A: Happy-path matching (T1-T3)
// B: No match (T4-T5)
// C: Execution failure (T6-T8)
// D: Bounds/truncation (T9-T10)
// E: Pattern correctness (T11-T12)
// F: Integration-safety semantics (T13-T14)
// =============================================================================
package validator

import (
	"context"
	"errors"
	"testing"
	"time"
)

// mockJournalReader returns a fixed result for deterministic testing.
// The mock simulates the SystemdJournalReader output contract without exec.
type mockJournalReader struct {
	lines   []string // raw journal output lines (newest-first)
	errKind ErrKind
	err     error
}

func (m mockJournalReader) Query(_ context.Context, q JournalQuery) JournalEvidence {
	// Simulate error conditions
	if m.errKind != ErrNone {
		return JournalEvidence{ErrKind: m.errKind, Err: m.err}
	}

	if len(m.lines) == 0 {
		return JournalEvidence{ErrKind: ErrEmpty}
	}

	applyDefaults(&q)
	truncated := len(m.lines) >= q.MaxLines

	// Scan for patterns (same logic as production reader)
	if len(q.Patterns) > 0 {
		for i, line := range m.lines {
			for _, pattern := range q.Patterns {
				if containsSubstring(line, pattern) {
					return JournalEvidence{
						Found:        true,
						MatchedLine:  line,
						MatchedIndex: i,
						LinesRead:    len(m.lines),
						Truncated:    truncated,
					}
				}
			}
		}
	}

	return JournalEvidence{
		Found:     false,
		LinesRead: len(m.lines),
		Truncated: truncated,
	}
}

// containsSubstring is a test helper matching production behavior.
func containsSubstring(line, pattern string) bool {
	return len(pattern) > 0 && len(line) >= len(pattern) && indexOf(line, pattern) >= 0
}

func indexOf(s, substr string) int {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}

// =============================================================================
// Category A — Happy-path matching
// =============================================================================

func TestT1_FirstLineMatches(t *testing.T) {
	SetJournalReader(mockJournalReader{lines: []string{
		"module_start: botguard",
		"some other line",
		"another line",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"module_start: botguard"},
	})
	if !r.Found {
		t.Fatal("expected Found=true")
	}
	if r.MatchedIndex != 0 {
		t.Errorf("expected MatchedIndex=0, got %d", r.MatchedIndex)
	}
	if r.MatchedLine != "module_start: botguard" {
		t.Errorf("wrong matched line: %s", r.MatchedLine)
	}
}

func TestT2_LaterLineMatches(t *testing.T) {
	SetJournalReader(mockJournalReader{lines: []string{
		"startup complete",
		"loading modules",
		"[LOGINMON] ssh: /var/log/secure resolved_by=distroconf",
		"other stuff",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"resolved_by=distroconf"},
	})
	if !r.Found {
		t.Fatal("expected Found=true")
	}
	if r.MatchedIndex != 2 {
		t.Errorf("expected MatchedIndex=2, got %d", r.MatchedIndex)
	}
}

func TestT3_MultipleMatches_FirstWins(t *testing.T) {
	SetJournalReader(mockJournalReader{lines: []string{
		"[BOTGUARD] classifier started (newest)",
		"other line",
		"[BOTGUARD] classifier started (older)",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"classifier started"},
	})
	if !r.Found {
		t.Fatal("expected Found=true")
	}
	if r.MatchedIndex != 0 {
		t.Errorf("expected first match (index 0), got %d", r.MatchedIndex)
	}
	if r.MatchedLine != "[BOTGUARD] classifier started (newest)" {
		t.Errorf("expected newest line, got: %s", r.MatchedLine)
	}
}

// =============================================================================
// Category B — No match
// =============================================================================

func TestT4_OutputPresent_NoPatternMatch(t *testing.T) {
	SetJournalReader(mockJournalReader{lines: []string{
		"startup complete",
		"loading config",
		"ready",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"module_start: botguard"},
	})
	if r.Found {
		t.Error("expected Found=false")
	}
	if r.LinesRead != 3 {
		t.Errorf("expected LinesRead=3, got %d", r.LinesRead)
	}
	if r.ErrKind != ErrNone {
		t.Errorf("expected no error, got %s", r.ErrKind)
	}
}

func TestT5_EmptyOutput(t *testing.T) {
	SetJournalReader(mockJournalReader{lines: nil})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"anything"},
	})
	if r.Found {
		t.Error("expected Found=false on empty output")
	}
	if r.ErrKind != ErrEmpty {
		t.Errorf("expected ErrKind=empty, got %s", r.ErrKind)
	}
}

// =============================================================================
// Category C — Execution failure
// =============================================================================

func TestT6_BinaryMissing(t *testing.T) {
	SetJournalReader(mockJournalReader{
		errKind: ErrExec,
		err:     errors.New("exec: \"journalctl\": executable file not found in $PATH"),
	})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{})
	if r.Found {
		t.Error("must not report found on exec error")
	}
	if r.ErrKind != ErrExec {
		t.Errorf("expected ErrKind=exec, got %s", r.ErrKind)
	}
}

func TestT7_NonZeroExit(t *testing.T) {
	SetJournalReader(mockJournalReader{
		errKind: ErrNonZero,
		err:     errors.New("exit status 2"),
	})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{})
	if r.Found {
		t.Error("must not report found on non-zero exit")
	}
	if r.ErrKind != ErrNonZero {
		t.Errorf("expected ErrKind=nonzero, got %s", r.ErrKind)
	}
}

func TestT8_Timeout(t *testing.T) {
	SetJournalReader(mockJournalReader{
		errKind: ErrTimeout,
		err:     context.DeadlineExceeded,
	})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{})
	if r.Found {
		t.Error("must not report found on timeout")
	}
	if r.ErrKind != ErrTimeout {
		t.Errorf("expected ErrKind=timeout, got %s", r.ErrKind)
	}
}

// =============================================================================
// Category D — Bounds / truncation
// =============================================================================

func TestT9_Truncated(t *testing.T) {
	// Simulate MaxLines=3, output has exactly 3 lines (at limit)
	lines := make([]string, 3)
	for i := range lines {
		lines[i] = "line"
	}
	SetJournalReader(mockJournalReader{lines: lines})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		MaxLines: 3,
		Patterns: []string{"nonexistent"},
	})
	if r.Truncated != true {
		t.Error("expected Truncated=true when lines >= MaxLines")
	}
}

func TestT10_LargeOutput_MatchNearBeginning(t *testing.T) {
	// 200 lines, match at line 0 (newest-first = fast path)
	lines := make([]string, 200)
	lines[0] = "module_start: botguard"
	for i := 1; i < 200; i++ {
		lines[i] = "noise line"
	}
	SetJournalReader(mockJournalReader{lines: lines})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"module_start: botguard"},
	})
	if !r.Found {
		t.Fatal("expected Found=true")
	}
	if r.MatchedIndex != 0 {
		t.Errorf("expected match at index 0 (newest), got %d", r.MatchedIndex)
	}
}

// =============================================================================
// Category E — Pattern correctness
// =============================================================================

func TestT11_SubstringFalsePositiveGuard(t *testing.T) {
	SetJournalReader(mockJournalReader{lines: []string{
		"module_start: botguard_legacy",  // near-match
		"module_started: botguard",       // near-match (different verb)
		"xmodule_start: botguard",        // prefix noise
	}})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"module_start: botguard"},
	})
	// "module_start: botguard_legacy" DOES contain "module_start: botguard"
	// as a substring — this is expected behavior for substring matching.
	// A1-2 must use sufficiently specific patterns.
	if !r.Found {
		t.Fatal("substring match should find 'module_start: botguard' in 'module_start: botguard_legacy'")
	}
}

func TestT12_CaseSensitive(t *testing.T) {
	SetJournalReader(mockJournalReader{lines: []string{
		"MODULE_START: BOTGUARD",
		"Module_Start: BotGuard",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"module_start: botguard"},
	})
	if r.Found {
		t.Error("case-sensitive matching should NOT match uppercase input")
	}
}

// =============================================================================
// Category F — Integration-safety semantics
// =============================================================================

func TestT13_FailureMustNotFabricateEvidence(t *testing.T) {
	// Every error kind must result in Found=false
	for _, ek := range []ErrKind{ErrTimeout, ErrExec, ErrNonZero, ErrEmpty} {
		SetJournalReader(mockJournalReader{errKind: ek, err: errors.New("test")})
		r := queryJournal(context.Background(), JournalQuery{
			Patterns: []string{"anything"},
		})
		if r.Found {
			t.Errorf("ErrKind=%s must not fabricate evidence (Found=true)", ek)
		}
	}
	SetJournalReader(SystemdJournalReader{})
}

func TestT14_EmptyOutputNotImplyingStopped(t *testing.T) {
	// Empty journal output = evidence unavailable, NOT daemon state
	SetJournalReader(mockJournalReader{lines: nil})
	defer SetJournalReader(SystemdJournalReader{})

	r := queryJournal(context.Background(), JournalQuery{
		Patterns: []string{"module_start"},
	})

	// Result must be neutral — no Found, no fabricated error beyond "empty"
	if r.Found {
		t.Error("empty output must not report found")
	}
	// The caller (A1-2/A1-3) decides what "empty" means for module state.
	// The reader must not pre-interpret it.
	if r.ErrKind != ErrEmpty {
		t.Errorf("expected ErrKind=empty, got %s", r.ErrKind)
	}
}

// =============================================================================
// Defaults
// =============================================================================

func TestDefaults(t *testing.T) {
	q := JournalQuery{}
	applyDefaults(&q)

	if q.Unit != "nftband" {
		t.Errorf("default unit = %s, want nftband", q.Unit)
	}
	if q.Since != 15*time.Minute {
		t.Errorf("default since = %v, want 15m", q.Since)
	}
	if q.MaxLines != 200 {
		t.Errorf("default maxlines = %d, want 200", q.MaxLines)
	}
	if q.Timeout != 2*time.Second {
		t.Errorf("default timeout = %v, want 2s", q.Timeout)
	}
}
