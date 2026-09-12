// =============================================================================
// NFTBan v1.230.0 Gate 6R — rebuild refusal / convergence truth
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-rebuild-refusal-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="Keeps REFUSED, FAILED and TIMEOUT apart end to end in the installer's rebuild consumer. R1 a REFUSED contract is consumed as 'the rebuild never started'; R2 a refusal that clears within the deadline is RETRIED and the install proceeds; R3 refusal through the whole deadline yields REFUSED_BUSY, never FAILED_REBUILD and never a false COMMITTED; R4 a rebuild that executed and failed stays FAILED; R5 a rebuild that timed out stays TIMEOUT; R6 a missing contract is classified by the execution witness, not assumed to be a failure. Guards the dns1 v1.229.13->v1.229.14 defect."
// meta:inventory.files="internal/installer/switchop/rebuild_refusal_v1230_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package switchop

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// argOf returns the value that follows flag in argv, or "".
func argOf(args []string, flag string) string {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

// writeWitness plays the SHELL WRAPPER crossing the execution boundary: it writes the
// witness the moment the convergence lock is held, before the core runs.
func writeWitness(t *testing.T, args []string) {
	t.Helper()
	w, op := argOf(args, "--execution-witness"), argOf(args, "--operation-id")
	if w == "" || op == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(w), 0o750)
	if err := os.WriteFile(w, []byte("operation_id="+op+"\n"), 0o640); err != nil {
		t.Fatalf("test fixture could not write the execution witness: %v", err)
	}
}

// refusalRecord is the record the shell publishes when the convergence lock is held.
// ⛔ It carries NO stderr text: nothing in the consumer may need any.
func refusalRecord(opID string) string {
	return fmt.Sprintf(`{"schema_version":"1","operation_id":%q,"context":"install-deferred",
"disposition":"REFUSED","reason_codes":["CONVERGENCE_LOCK_HELD"],"rollback_performed":false,
"modified":false,"enforcement_unchanged":true,
"transaction":{"committed":false,"reason":"NOT_STARTED"},"retry":{"reason":"REFUSED_CONVERGENCE_LOCK"},
"pre_status":"not-observed","post_status":"not-observed","emitted_at":"2026-09-13T00:00:00Z"}`, opID)
}

func completeRecord(opID string) string {
	return fmt.Sprintf(`{"schema_version":"1","operation_id":%q,"context":"install-deferred",
"disposition":"COMPLETE","reason_codes":[],"rollback_performed":false,
"modified":true,"enforcement_unchanged":false,
"transaction":{"committed":true,"reason":"COMMITTED"},"retry":{"reason":"NONE"},
"pre_status":"protected","post_status":"protected","emitted_at":"2026-09-13T00:00:00Z"}`, opID)
}

func regressionRecord(opID string) string {
	return fmt.Sprintf(`{"schema_version":"1","operation_id":%q,"context":"install-deferred",
"disposition":"REGRESSION","reason_codes":["POSTVALIDATION_REGRESSION"],"rollback_performed":true,
"modified":true,"enforcement_unchanged":false,
"transaction":{"committed":false,"reason":"FAILURE"},"retry":{"reason":"FAILURE_RECOVERY"},
"pre_status":"protected","post_status":"degraded","emitted_at":"2026-09-13T00:00:00Z"}`, opID)
}

func publishRaw(t *testing.T, args []string, body string) {
	t.Helper()
	p := argOf(args, "--result-file")
	if p == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(p), 0o750)
	if err := os.WriteFile(p, []byte(body), 0o640); err != nil {
		t.Fatalf("test fixture could not publish the result record: %v", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// R1 — a REFUSED contract means the rebuild NEVER STARTED
// ─────────────────────────────────────────────────────────────────────────────
// The unit under test here is the CONSUMER. The producer side (the shell actually
// publishing this record under a held lock) is proven by
// cli/lib/nftban/tests/rebuild_refusal_contract_v1230_test.sh.
func TestR1_RefusedRecord_IsReadAsNeverStarted(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "op.json")
	if err := os.WriteFile(p, []byte(refusalRecord("op-1")), 0o640); err != nil {
		t.Fatal(err)
	}
	r, err := ReadRebuildResult(p, "op-1")
	if err != nil {
		t.Fatalf("a well-formed REFUSED record must be readable: %v", err)
	}
	if r.Disposition != DispositionRefused {
		t.Fatalf("disposition = %q, want REFUSED", r.Disposition)
	}
	if r.Modified {
		t.Error("REFUSED must report modified=false — the firewall was not touched")
	}
	if !r.EnforcementUnchanged {
		t.Error("REFUSED must report enforcement_unchanged=true")
	}
	if r.Transaction.Committed {
		t.Error("REFUSED must never report a committed transaction")
	}
	if got := r.Continuation(); got != RetryRefused {
		t.Errorf("continuation = %q, want RETRY_REFUSED (neither continue nor abort)", got)
	}
	if r.ContradictsExitCode(1) {
		t.Error("REFUSED is consistent with the wrapper's rc=1")
	}
	// ⛔ A REFUSAL CLAIM MUST BE SELF-CONSISTENT. A record that says REFUSED while also
	// reporting a mutation is a broken producer, and the safe reading of a broken
	// producer is never "nothing happened".
	bad := strings.Replace(refusalRecord("op-2"), `"modified":false`, `"modified":true`, 1)
	p2 := filepath.Join(dir, "op2.json")
	if err := os.WriteFile(p2, []byte(bad), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadRebuildResult(p2, "op-2"); err == nil {
		t.Error("a REFUSED record that also claims a mutation must be rejected, not believed")
	}
}

// ⛔ NO STDERR PARSING. The consumer must classify a refusal with the message absent.
func TestR1_RefusalNeedsNoStderr(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	redirectResultDir(t)
	defer SetRefusalBackoffForTest(time.Millisecond, 4*time.Millisecond)()
	var attempts int32
	mock.RunHook = func(_ string, args []string) (executor.Result, bool) {
		if argOf(args, "--result-file") == "" {
			return executor.Result{}, false
		}
		atomic.AddInt32(&attempts, 1)
		publishRaw(t, args, refusalRecord(argOf(args, "--operation-id")))
		// Stderr deliberately EMPTY.
		return executor.Result{ExitCode: 1}, true
	}
	err := Rebuild(context.Background(), mock, newTestLogger())
	if !errors.Is(err, ErrRebuildRefusedBusy) {
		t.Fatalf("a refusal with EMPTY stderr must still classify as REFUSED_BUSY; got %v", err)
	}
	if got := atomic.LoadInt32(&attempts); got != refusalMaxAttempts {
		t.Errorf("attempts = %d, want %d (bounded retry, no infinite loop)", got, refusalMaxAttempts)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// R2 — refusal clears while budget remains -> retry -> the install proceeds
// ─────────────────────────────────────────────────────────────────────────────
func TestR2_RefusalClears_RetrySucceeds(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	redirectResultDir(t)
	var attempts int32
	mock.RunHook = func(_ string, args []string) (executor.Result, bool) {
		if argOf(args, "--result-file") == "" {
			return executor.Result{}, false
		}
		n := atomic.AddInt32(&attempts, 1)
		if n == 1 {
			// lock held: refused BEFORE any mutation, no witness written
			publishRaw(t, args, refusalRecord(argOf(args, "--operation-id")))
			return executor.Result{ExitCode: 1}, true
		}
		// lock released: the rebuild EXECUTES and commits a generation
		writeWitness(t, args)
		publishRaw(t, args, completeRecord(argOf(args, "--operation-id")))
		return executor.Result{ExitCode: 0}, true
	}
	defer SetRefusalBackoffForTest(time.Millisecond, 4*time.Millisecond)()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := Rebuild(ctx, mock, newTestLogger()); err != nil {
		t.Fatalf("a refusal that clears within the deadline must be retried to success; got %v", err)
	}
	if got := atomic.LoadInt32(&attempts); got != 2 {
		t.Errorf("attempts = %d, want 2 (one refusal, one execution)", got)
	}
	if mock.FileExists("/run/nftban/install_failed") {
		t.Error("a successful retry must not leave the install-failed marker")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// R3 — refused through the whole deadline -> REFUSED_BUSY, never FAILED_REBUILD
// ─────────────────────────────────────────────────────────────────────────────
func TestR3_RefusedThroughDeadline_IsDeferredNotFailed(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	redirectResultDir(t)
	var attempts int32
	mock.RunHook = func(_ string, args []string) (executor.Result, bool) {
		if argOf(args, "--result-file") == "" {
			return executor.Result{}, false
		}
		atomic.AddInt32(&attempts, 1)
		publishRaw(t, args, refusalRecord(argOf(args, "--operation-id")))
		return executor.Result{ExitCode: 1, Stderr: "convergence already in progress"}, true
	}
	// A deadline that expires during the first backoff: the loop must stop on ctx,
	// not on its own separate clock. The backoff is deliberately LONGER than the
	// deadline so only ctx can end the loop.
	defer SetRefusalBackoffForTest(5*time.Second, 5*time.Second)()
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	log, dump := readLog(t)
	err := Rebuild(ctx, mock, log)
	out := dump()

	if !errors.Is(err, ErrRebuildRefusedBusy) {
		t.Fatalf("deadline exhausted by refusals must be REFUSED_BUSY; got %v", err)
	}
	if n := atomic.LoadInt32(&attempts); n < 1 || n >= refusalMaxAttempts {
		t.Errorf("attempts = %d — the deadline, not the attempt cap, must have stopped this", n)
	}
	// ⛔ NEVER a claim of convergence: enforcement still being in force is not a
	// completed transaction.
	if !strings.Contains(out, "convergence attribution NOT established") {
		t.Errorf("the run must state that convergence attribution was NOT established:\n%s", out)
	}
	if !strings.Contains(out, "PROTECTED != TRANSACTION COMPLETE") {
		t.Errorf("the run must say protected != complete:\n%s", out)
	}
	for _, forbidden := range []string{"rebuild COMPLETE", "generation committed", "firewall rebuild completed"} {
		if strings.Contains(out, forbidden) {
			t.Errorf("a refusal-exhausted run must never narrate convergence; log contained %q", forbidden)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// R4 (negative control) — a rebuild that EXECUTED and failed stays FAILED
// ─────────────────────────────────────────────────────────────────────────────
func TestR4_ExecutedAndFailed_StaysFailed(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	redirectResultDir(t)
	var attempts int32
	mock.RunHook = func(_ string, args []string) (executor.Result, bool) {
		if argOf(args, "--result-file") == "" {
			return executor.Result{}, false
		}
		atomic.AddInt32(&attempts, 1)
		writeWitness(t, args)
		publishRaw(t, args, regressionRecord(argOf(args, "--operation-id")))
		return executor.Result{ExitCode: 2, Stderr: "rollback performed"}, true
	}
	err := Rebuild(context.Background(), mock, newTestLogger())
	if err == nil {
		t.Fatal("an executed-and-failed rebuild must fail the install")
	}
	if errors.Is(err, ErrRebuildRefusedBusy) || errors.Is(err, ErrRebuildNotExecuted) {
		t.Fatalf("a REAL failure must never be laundered into a deferred outcome: %v", err)
	}
	if !mock.FileExists("/run/nftban/install_failed") {
		t.Error("an executed-and-failed rebuild must write the install-failed marker")
	}
	if got := atomic.LoadInt32(&attempts); got != 1 {
		t.Errorf("attempts = %d, want 1 — only REFUSED is retried", got)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// R5 (negative control) — TIMEOUT stays TIMEOUT
// ─────────────────────────────────────────────────────────────────────────────
func TestR5_TimeoutStaysTimeout(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	redirectResultDir(t)
	var attempts int32
	mock.RunHook = func(_ string, args []string) (executor.Result, bool) {
		if argOf(args, "--result-file") == "" {
			return executor.Result{}, false
		}
		atomic.AddInt32(&attempts, 1)
		// It STARTED — the witness exists — and was then killed mid-flight.
		writeWitness(t, args)
		return executor.Result{ExitCode: -1, TimedOut: true}, true
	}
	err := Rebuild(context.Background(), mock, newTestLogger())
	if err == nil || !strings.Contains(err.Error(), "INTERRUPTED") {
		t.Fatalf("an interrupted rebuild must stay an interruption; got %v", err)
	}
	if errors.Is(err, ErrRebuildRefusedBusy) || errors.Is(err, ErrRebuildNotExecuted) {
		t.Fatalf("a TIMEOUT must never be reclassified as a refusal: %v", err)
	}
	if got := atomic.LoadInt32(&attempts); got != 1 {
		t.Errorf("attempts = %d, want 1 — a timeout is not retried here", got)
	}
	if !mock.FileExists("/run/nftban/install_failed") {
		t.Error("an interrupted convergence must write the install-failed marker")
	}
}

// A refusal record must NEVER be able to mask an interruption: interruption is
// classified before the contract is consulted.
func TestR5_TimeoutBeatsAStaleRefusalRecord(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	redirectResultDir(t)
	mock.RunHook = func(_ string, args []string) (executor.Result, bool) {
		if argOf(args, "--result-file") == "" {
			return executor.Result{}, false
		}
		publishRaw(t, args, refusalRecord(argOf(args, "--operation-id")))
		return executor.Result{ExitCode: -1, TimedOut: true}, true
	}
	err := Rebuild(context.Background(), mock, newTestLogger())
	if err == nil || !strings.Contains(err.Error(), "INTERRUPTED") {
		t.Fatalf("a published REFUSED record must not turn a killed rebuild into a refusal; got %v", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// R6 — a missing contract is classified by the EXECUTION WITNESS
// ─────────────────────────────────────────────────────────────────────────────
func TestR6_MissingContract_ClassifiedByExecutionWitness(t *testing.T) {
	cases := []struct {
		name         string
		writeWit     bool
		wantDeferred bool
		wantMarker   bool
	}{
		// ⛔ THE DEFECT: no record + never executed was read as FAILED_REBUILD.
		{"no witness -> execution NOT established -> deferred", false, true, true},
		// ⛔ THE NEGATIVE CONTROL: execution established, record missing -> still fatal.
		{"witness present -> execution established -> FAILED", true, false, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mock := executor.NewMockExecutor()
			mock.StrictUnregistered = true
			redirectResultDir(t)
			mock.RunHook = func(_ string, args []string) (executor.Result, bool) {
				if argOf(args, "--result-file") == "" {
					return executor.Result{}, false
				}
				if tc.writeWit {
					writeWitness(t, args)
				}
				return executor.Result{ExitCode: 1, Stderr: "aborted"}, true
			}
			err := Rebuild(context.Background(), mock, newTestLogger())
			if err == nil {
				t.Fatal("a missing contract must never authorize continuation")
			}
			if got := errors.Is(err, ErrRebuildNotExecuted); got != tc.wantDeferred {
				t.Errorf("ErrRebuildNotExecuted = %v, want %v (err: %v)", got, tc.wantDeferred, err)
			}
			if got := mock.FileExists("/run/nftban/install_failed"); got != tc.wantMarker {
				t.Errorf("install_failed marker = %v, want %v", got, tc.wantMarker)
			}
		})
	}
}

// ⛔ EXISTENCE IS NOT IDENTITY: a witness from another operation proves nothing about
// this one, exactly as a foreign result record proves nothing.
func TestR6_ForeignWitnessIsNotProofOfExecution(t *testing.T) {
	dir := t.TempDir()
	w := filepath.Join(dir, "op.exec")
	if err := os.WriteFile(w, []byte("operation_id=SOMEONE-ELSE\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if executionWitnessProven(w, "op-mine") {
		t.Error("a witness naming another operation must not prove this operation executed")
	}
	if !executionWitnessProven(w, "SOMEONE-ELSE") {
		t.Error("a witness naming the operation must prove it (non-vacuity)")
	}
	// ⛔ A PREFIX IS NOT THE ID. "SOMEONE" must not be answered for by "SOMEONE-ELSE".
	if executionWitnessProven(w, "SOMEONE") {
		t.Error("a prefix of another operation id must not prove execution")
	}
	if executionWitnessProven(filepath.Join(dir, "absent.exec"), "op-mine") {
		t.Error("an absent witness must not prove execution")
	}
}

// The backoff must be bounded and monotonic — no infinite retry, no unbounded wait.
func TestRefusalBackoffIsBounded(t *testing.T) {
	prev := time.Duration(0)
	for i := 1; i <= 12; i++ {
		d := refusalBackoff(i)
		if d < prev {
			t.Errorf("backoff(%d)=%v is smaller than backoff(%d)=%v", i, d, i-1, prev)
		}
		if d > refusalBackoffMax {
			t.Errorf("backoff(%d)=%v exceeds the cap %v", i, d, refusalBackoffMax)
		}
		prev = d
	}
	if refusalBackoff(1) != refusalBackoffBase {
		t.Errorf("first backoff = %v, want %v", refusalBackoff(1), refusalBackoffBase)
	}
}
