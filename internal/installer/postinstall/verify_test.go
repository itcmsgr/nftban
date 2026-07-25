// =============================================================================
// NFTBan - postinstall verify tests (v1.228.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="postinstall_verify_test"
// meta:type="test"
// meta:version="1.228.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="T1-T10 durable fixtures for the post-install freshness gate. T8/T9 use a SAME-VERSION prior COMMITTED so they cannot pass on a version mismatch; T10 asserts the constructor default is never exposed as persisted evidence."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package postinstall

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/state"
)

const fixtureVersion = "1.228.0"

// writeState materialises an install_state fixture via the canonical path
// helper, so a rename of the state file cannot silently orphan these tests.
func writeState(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := state.NewStateFile(dir).Path()
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		t.Fatalf("fixture dir: %v", err)
	}
	if err := os.WriteFile(p, []byte(body), 0o640); err != nil {
		t.Fatalf("fixture write: %v", err)
	}
	return dir
}

func stamp(d time.Duration) string {
	return time.Now().UTC().Add(d).Format(time.RFC3339Nano)
}

// transactionStart is the --not-before a package script would supply. Fixtures
// place persisted timestamps either after it (current) or before it (historical).
func transactionStart() time.Time { return time.Now().UTC().Add(-time.Minute) }

func verifyDir(dir string) Result {
	return Verify(Options{StateDir: dir, ExpectedVersion: fixtureVersion, NotBefore: transactionStart()})
}

func requireVerdict(t *testing.T, got Result, want Verdict, label string) {
	t.Helper()
	if got.Verdict != want {
		t.Fatalf("%s: verdict = %s (want %s)\n  detail: %s", label, got.Verdict, want, got.Detail)
	}
	if want != CurrentCommitted && got.Verdict.Verified() {
		t.Fatalf("%s: non-committed verdict %s reported Verified()=true", label, got.Verdict)
	}
}

// ---------------------------------------------------------------------------
// T4 first — the positive. Without a green positive every other assertion could
// be satisfied by an implementation that always refuses to verify.
// ---------------------------------------------------------------------------

func TestT4_FreshSameVersionCommitted(t *testing.T) {
	dir := writeState(t, "INSTALL_STATE=COMMITTED\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	got := verifyDir(dir)
	requireVerdict(t, got, CurrentCommitted, "T4")
	if !got.Verdict.Verified() {
		t.Fatal("T4: CURRENT_COMMITTED must report Verified()=true")
	}
}

func TestT1_PriorCommittedThenFailedNoFirewall(t *testing.T) {
	// The installer advanced state within this transaction — the EL9 case.
	dir := writeState(t, "INSTALL_STATE=FAILED_NO_FIREWALL\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	requireVerdict(t, verifyDir(dir), InstallFailed, "T1")
}

func TestT2_FailedAuthorityAbort(t *testing.T) {
	dir := writeState(t, "INSTALL_STATE=FAILED_AUTHORITY_ABORT\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	requireVerdict(t, verifyDir(dir), InstallFailed, "T2")
}

func TestT3_Degraded(t *testing.T) {
	// DEGRADED is a completed-with-issues terminal, but the verification
	// question is binary: did THIS transaction finish as current COMMITTED?
	dir := writeState(t, "INSTALL_STATE=DEGRADED\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	requireVerdict(t, verifyDir(dir), InstallDegraded, "T3")
}

func TestT5_MissingState(t *testing.T) {
	dir := t.TempDir() // exists, but holds no state file
	got := verifyDir(dir)
	requireVerdict(t, got, MissingState, "T5")

	// The verifier must not create the file it failed to find.
	if _, err := os.Stat(state.NewStateFile(dir).Path()); !os.IsNotExist(err) {
		t.Fatal("T5: verification created a state file that did not exist")
	}
}

func TestT5b_MissingStateDirectoryNotCreated(t *testing.T) {
	base := t.TempDir()
	absent := filepath.Join(base, "does-not-exist")
	requireVerdict(t, verifyDir(absent), MissingState, "T5b")
	if _, err := os.Stat(absent); !os.IsNotExist(err) {
		t.Fatal("T5b: verification created the missing state directory")
	}
}

// T6a — malformed: parses, but INSTALL_STATE carries no value.
// Deliberately a SEPARATE test from T6b: when these shared one function, the
// root-only skip in T6b aborted the whole function and this assertion never
// ran. A fixture that silently stops asserting is the defect this suite exists
// to prevent, so the two access paths must never share a skip.
func TestT6a_MalformedEmptyStateValue(t *testing.T) {
	dir := writeState(t, "INSTALL_STATE=\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	got := verifyDir(dir)
	requireVerdict(t, got, InvalidState, "T6a/empty-value")
	if got.PersistedState != unknownField {
		t.Fatalf("T6a: persisted state = %q, want %s", got.PersistedState, unknownField)
	}
}

// T6b — unreadable: access failure, a distinct path from "never installed".
// Skips only itself when running as root, where mode 0000 does not deny access.
func TestT6b_UnreadableStateFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("mode 0000 does not deny access to root; T6a covers the parser path")
	}
	dir := writeState(t, "INSTALL_STATE=COMMITTED\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	if err := os.Chmod(state.NewStateFile(dir).Path(), 0o000); err != nil {
		t.Fatalf("T6b chmod: %v", err)
	}
	got := verifyDir(dir)
	if got.Verdict.Verified() {
		t.Fatal("T6b: an unreadable state file must never verify")
	}
	if got.Verdict != MissingState && got.Verdict != StateReadError {
		t.Fatalf("T6b: verdict = %s, want MISSING_STATE or STATE_READ_ERROR", got.Verdict)
	}
}

func TestT7_DryRunLeavesHistoricalStateUnreported(t *testing.T) {
	dir := writeState(t, "INSTALL_STATE=COMMITTED\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	got := Verify(Options{
		StateDir: dir, ExpectedVersion: fixtureVersion,
		NotBefore: transactionStart(), DryRun: true,
	})
	requireVerdict(t, got, DryRunNotApplied, "T7")
	if got.Verdict.Verified() {
		t.Fatal("T7: a dry run must never be reported as a current commit")
	}
}

// ---------------------------------------------------------------------------
// T8 / T9 — the admission-critical pair.
//
// SAME VERSION is mandatory. With a differing version these would pass on a
// mere VERSION_MISMATCH and prove nothing about freshness — the exact reason
// version equality was rejected as a freshness proof.
// ---------------------------------------------------------------------------

func TestT8_StaleSameVersionCommitted_LockContention(t *testing.T) {
	// Lock contention: the mutating installer exits 75 before the StateFile
	// exists, leaving a prior same-version COMMITTED untouched.
	dir := writeState(t, "INSTALL_STATE=COMMITTED\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(-time.Hour)+"\n")
	got := verifyDir(dir)
	requireVerdict(t, got, StaleState, "T8")

	// Guard the guard: the fixture must genuinely have matching version and a
	// terminal-success state, or it is not testing freshness at all.
	if got.PersistedVersion != fixtureVersion {
		t.Fatalf("T8 fixture invalid: version %q != expected %q — no longer a freshness test",
			got.PersistedVersion, fixtureVersion)
	}
	if got.PersistedState != string(state.StateCommitted) {
		t.Fatalf("T8 fixture invalid: state %q is not COMMITTED — no longer a freshness test",
			got.PersistedState)
	}
}

func TestT9_StaleSameVersionCommitted_PreTransitionTermination(t *testing.T) {
	// Controlled termination before Transition() — a panic or any pre-StateFile
	// exit. Same observable state as T8: unchanged historical evidence.
	dir := writeState(t, "INSTALL_STATE=COMMITTED\nINSTALL_VERSION="+fixtureVersion+
		"\nINSTALL_TIMESTAMP="+stamp(-24*time.Hour)+"\n")
	got := verifyDir(dir)
	requireVerdict(t, got, StaleState, "T9")
	if got.PersistedVersion != fixtureVersion || got.PersistedState != string(state.StateCommitted) {
		t.Fatal("T9 fixture invalid: must be a SAME-VERSION prior COMMITTED")
	}
}

// T10 — the constructor-default trap.
func TestT10_FileWithoutInstallStateField(t *testing.T) {
	dir := writeState(t, "INSTALL_VERSION="+fixtureVersion+"\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	got := verifyDir(dir)
	requireVerdict(t, got, InvalidState, "T10")

	// NewStateFile seeds State with StateFilesInstalled. That default must never
	// be reported as persisted evidence.
	if got.PersistedState != unknownField {
		t.Fatalf("T10: persisted state = %q, want %s (constructor default leaked?)",
			got.PersistedState, unknownField)
	}
	if got.PersistedState == string(state.StateFilesInstalled) {
		t.Fatal("T10: exposed the constructor default FILES_INSTALLED as persisted state")
	}
}

// Version mismatch must not be confused with staleness.
func TestVersionMismatchOnFreshState(t *testing.T) {
	dir := writeState(t, "INSTALL_STATE=COMMITTED\nINSTALL_VERSION=9.9.9\nINSTALL_TIMESTAMP="+stamp(0)+"\n")
	requireVerdict(t, verifyDir(dir), VersionMismatch, "version-mismatch")
}

// Freshness must be evaluated BEFORE the state value: a stale state reports
// STALE_STATE even when the version also mismatches.
func TestFreshnessPrecedesVersionCheck(t *testing.T) {
	dir := writeState(t, "INSTALL_STATE=COMMITTED\nINSTALL_VERSION=9.9.9\nINSTALL_TIMESTAMP="+stamp(-time.Hour)+"\n")
	requireVerdict(t, verifyDir(dir), StaleState, "freshness-precedence")
}

func TestMissingNotBeforeIsInvalid(t *testing.T) {
	dir := writeState(t, "INSTALL_STATE=COMMITTED\nINSTALL_VERSION="+fixtureVersion+"\n")
	got := Verify(Options{StateDir: dir, ExpectedVersion: fixtureVersion})
	requireVerdict(t, got, InvalidState, "no-not-before")
}

// Exactly one verdict may claim verification.
func TestOnlyCurrentCommittedVerifies(t *testing.T) {
	all := []Verdict{
		CurrentCommitted, StaleState, VersionMismatch, InstallFailed, InstallDegraded,
		MissingState, InvalidState, DryRunNotApplied, StateReadError, InvalidInvocation,
	}
	n := 0
	for _, v := range all {
		if v.Verified() {
			n++
			if v != CurrentCommitted {
				t.Fatalf("verdict %s must not report Verified()=true", v)
			}
		}
	}
	if n != 1 {
		t.Fatalf("exactly one verdict must verify, got %d", n)
	}
}

// Every path emits the complete token set, with UNKNOWN rather than blanks.
func TestTokenSetIsCompleteOnEveryPath(t *testing.T) {
	want := []string{
		"NFTBAN_PERSISTED_INSTALL_STATE=", "NFTBAN_PERSISTED_STATE_VERSION=",
		"NFTBAN_PERSISTED_STATE_TIMESTAMP=", "NFTBAN_EXPECTED_VERSION=",
		"NFTBAN_NOT_BEFORE=", "NFTBAN_INSTALL_ATTEMPT_VERDICT=",
		"NFTBAN_INSTALL_VERIFIED=", "NFTBAN_INSTALLER_EXIT=",
	}
	cases := map[string]Result{
		"missing":  {Verdict: MissingState, PersistedState: unknownField, PersistedVersion: unknownField},
		"stale":    {Verdict: StaleState, PersistedState: "COMMITTED", PersistedVersion: fixtureVersion},
		"invalid":  {Verdict: InvalidInvocation},
		"verified": {Verdict: CurrentCommitted, PersistedState: "COMMITTED", PersistedVersion: fixtureVersion},
	}
	opt := Options{ExpectedVersion: fixtureVersion, NotBefore: transactionStart()}
	for name, res := range cases {
		toks := res.Tokens(opt, 0)
		if len(toks) != len(want) {
			t.Fatalf("%s: %d tokens, want %d", name, len(toks), len(want))
		}
		joined := strings.Join(toks, "\n")
		for _, k := range want {
			if !strings.Contains(joined, k) {
				t.Fatalf("%s: token %s missing", name, k)
			}
		}
		for _, ln := range toks {
			if strings.HasSuffix(ln, "=") {
				t.Fatalf("%s: token %q has a blank value — UNKNOWN required", name, ln)
			}
		}
	}
}
