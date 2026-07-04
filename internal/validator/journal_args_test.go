// =============================================================================
// NFTBan v1.216.3 - Journal Query Arg Construction Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="journal_args_test"
// meta:type="test"
// meta:version="1.216.3"
// meta:owner="NFTBan Project / Antonios Voulvoulis"
// meta:description="Command-construction guards for buildJournalArgs: pattern queries use server-side -g (regexp.QuoteMeta-escaped OR) placed before -n so the line cap bounds MATCHING lines, not all unit lines (busy-host heartbeat eviction fix); non-pattern queries stay unscoped; regex metacharacters are escaped (no overmatch, no injection); bounds/format flags retained."
// meta:inventory.files="internal/validator/journal_args_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import (
	"context"
	"os/exec"
	"regexp"
	"testing"
	"time"
)

// exit1Err returns a genuine *exec.ExitError with exit code 1 and empty output,
// mirroring `journalctl -g <pattern>` when nothing matches (grep convention).
func exit1Err(t *testing.T) error {
	t.Helper()
	err := exec.Command("false").Run() // exits 1, no output
	if _, ok := err.(*exec.ExitError); !ok {
		t.Fatalf("expected *exec.ExitError from `false`, got %T (%v)", err, err)
	}
	return err
}

// v1.216.3 CRITICAL: with server-side -g, a PATTERN query that matches nothing exits 1
// (empty). That must be reported as ErrNone/Found=false (a definitive absence), NOT
// ErrEmpty — otherwise callers whose guard is `ErrKind == ErrNone` would stop emitting
// VAL-LOGINMON-001 / VAL-BOTGUARD-001 for a genuinely unbound/dead module.
func TestParseJournalResult_PatternNoMatchExit1IsAbsentNotError(t *testing.T) {
	ev := parseJournalResult(JournalQuery{Patterns: []string{"loginmon_source_binding_heartbeat"}}, nil, exit1Err(t), nil)
	if ev.ErrKind != ErrNone {
		t.Errorf("pattern no-match (exit 1) must be ErrNone (absent), got %q", ev.ErrKind)
	}
	if ev.Found {
		t.Error("pattern no-match must have Found=false")
	}
}

// Exit-0 with empty output for a pattern query is likewise a clean no-match → absent.
func TestParseJournalResult_PatternEmptyExit0IsAbsent(t *testing.T) {
	ev := parseJournalResult(JournalQuery{Patterns: []string{"x"}}, []byte("  \n"), nil, nil)
	if ev.ErrKind != ErrNone || ev.Found {
		t.Errorf("pattern empty exit0 must be ErrNone/absent, got %+v", ev)
	}
}

// A match is Found=true, first-match-wins.
func TestParseJournalResult_Match(t *testing.T) {
	out := []byte("noise\n[LOGINMON] loginmon_source_binding_heartbeat resolved_by=heartbeat sources=4 state=running\n")
	ev := parseJournalResult(JournalQuery{Patterns: []string{"loginmon_source_binding_heartbeat"}}, out, nil, nil)
	if !ev.Found || ev.ErrKind != ErrNone {
		t.Errorf("expected Found=true/ErrNone, got %+v", ev)
	}
}

// A real query failure (timeout / exec-not-found) must NOT be reported as absence —
// callers fail safe (no emit) rather than asserting an absence they couldn't determine.
func TestParseJournalResult_HardFailuresAreErrors(t *testing.T) {
	// timeout: ctxErr set
	if ev := parseJournalResult(JournalQuery{Patterns: []string{"x"}}, nil, exit1Err(t), context.DeadlineExceeded); ev.ErrKind != ErrTimeout {
		t.Errorf("ctxErr set must be ErrTimeout, got %q", ev.ErrKind)
	}
	// binary missing: *exec.Error
	if ev := parseJournalResult(JournalQuery{Patterns: []string{"x"}}, nil, &exec.Error{Name: "journalctl", Err: exec.ErrNotFound}, nil); ev.ErrKind != ErrExec {
		t.Errorf("exec.Error must be ErrExec, got %q", ev.ErrKind)
	}
}

// argIndex returns the index of flag in args, or -1.
func argIndex(args []string, flag string) int {
	for i, a := range args {
		if a == flag {
			return i
		}
	}
	return -1
}

// argValue returns the value immediately following flag, or "".
func argValue(args []string, flag string) string {
	i := argIndex(args, flag)
	if i < 0 || i+1 >= len(args) {
		return ""
	}
	return args[i+1]
}

// The core fix: a pattern query must scope server-side with -g, and -g must come
// BEFORE -n so journalctl's line cap bounds MATCHING lines (not all unit lines).
func TestBuildJournalArgs_PatternQueryUsesGrepBeforeCap(t *testing.T) {
	args := buildJournalArgs(JournalQuery{
		Unit:     "nftband",
		Patterns: []string{"module_start: loginmon", "loginmon_source_binding_heartbeat"},
	})
	gi := argIndex(args, "-g")
	ni := argIndex(args, "-n")
	if gi < 0 {
		t.Fatalf("pattern query must include -g; args=%v", args)
	}
	if ni < 0 {
		t.Fatalf("query must retain -n; args=%v", args)
	}
	if gi > ni {
		t.Errorf("-g (%d) must precede -n (%d) so the cap bounds matching lines; args=%v", gi, ni, args)
	}
	got := argValue(args, "-g")
	want := regexp.QuoteMeta("module_start: loginmon") + "|" + regexp.QuoteMeta("loginmon_source_binding_heartbeat")
	if got != want {
		t.Errorf("-g value = %q, want escaped OR %q", got, want)
	}
}

// Non-pattern queries keep the original unscoped bounded behavior (no -g).
func TestBuildJournalArgs_NonPatternQueryNoGrep(t *testing.T) {
	args := buildJournalArgs(JournalQuery{Unit: "nftband"})
	if argIndex(args, "-g") != -1 {
		t.Errorf("non-pattern query must NOT include -g; args=%v", args)
	}
	if argIndex(args, "-n") == -1 {
		t.Errorf("non-pattern query must retain -n; args=%v", args)
	}
}

// Regex metacharacters in a literal pattern must be escaped so -g does not
// overmatch. "[botguard] loaded" must become a literal, not a character class.
func TestBuildJournalArgs_RegexEscapeNoOvermatch(t *testing.T) {
	args := buildJournalArgs(JournalQuery{
		Unit:     "nftband",
		Patterns: []string{"[botguard] loaded"},
	})
	g := argValue(args, "-g")
	if g != `\[botguard\] loaded` {
		t.Errorf("-g value = %q, want escaped literal %q", g, `\[botguard\] loaded`)
	}
	// Compile as a regex and prove it matches the literal but NOT a single class char.
	re := regexp.MustCompile(g)
	if re.MatchString("b") {
		t.Error("escaped pattern overmatches 'b' — [botguard] was treated as a character class")
	}
	if !re.MatchString("2026 xx [botguard] loaded 3 crawlers") {
		t.Error("escaped pattern should still match the literal line")
	}
}

// Bounds and output format flags are retained (deterministic newest-first, cat, since, unit, cap).
func TestBuildJournalArgs_RetainsBounds(t *testing.T) {
	args := buildJournalArgs(JournalQuery{
		Unit:     "nftband",
		Patterns: []string{"resolved_by="},
		Since:    15 * time.Minute,
		MaxLines: 200,
	})
	if argValue(args, "-u") != "nftband" {
		t.Errorf("missing/incorrect -u: %v", args)
	}
	if argValue(args, "--since") != "-15m" {
		t.Errorf("--since = %q, want -15m; args=%v", argValue(args, "--since"), args)
	}
	if argValue(args, "-n") != "200" {
		t.Errorf("-n = %q, want 200; args=%v", argValue(args, "-n"), args)
	}
	if argValue(args, "-o") != "cat" {
		t.Errorf("-o = %q, want cat; args=%v", argValue(args, "-o"), args)
	}
	if argIndex(args, "-r") == -1 {
		t.Errorf("missing -r (newest-first); args=%v", args)
	}
}

// Defaults apply when zero-valued (self-contained, so the helper is testable standalone).
func TestBuildJournalArgs_AppliesDefaults(t *testing.T) {
	args := buildJournalArgs(JournalQuery{Unit: "nftband", Patterns: []string{"x"}})
	if argValue(args, "--since") == "" || argValue(args, "-n") == "" {
		t.Errorf("defaults for --since/-n not applied; args=%v", args)
	}
}
