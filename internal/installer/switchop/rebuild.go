// =============================================================================
// NFTBan v1.73 - Installer Firewall Rebuild
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-rebuild"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Run nftban firewall rebuild as a MANDATORY convergence step. No outer deadline: the step scales with host firewall state (lab2 ~35s vs srv3 ~453s) and an arbitrary constant killed legitimate convergences. Interruption is its own verdict class and is FATAL to the install — a killed rebuild is not DEGRADED, it is CONVERGENCE DID NOT COMPLETE."
// meta:inventory.files="internal/installer/switchop/rebuild.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// ⛔ v1.229.11 LANE 6A — THE 60-SECOND OUTER TIMEOUT IS GONE, NOT RAISED.
//
// It was `const rebuildTimeout = 60 * time.Second`, applied to a step whose
// duration scales with the host's firewall state:
//
//	lab2  ~35 s      inside the limit, so the defect was invisible there
//	srv3  ~453 s     killed at 60 s, EVERY upgrade
//
// That is more than an order of magnitude, and no constant is correct across it.
// Raising 60 to 600 would only move the threshold to the next larger host.
//
//	A PACKAGE MANAGER KILLING A LEGITIMATE CONVERGENCE BECAUSE THE HOST HAS A
//	LARGE FIREWALL STATE IS DANGEROUS. LONG DOES NOT MEAN HUNG.
//
// Boundedness belongs to the rebuild's own internal operations, which are
// individually bounded and report progress, not to an arbitrary outer clock
// that cannot know the size of the work it is interrupting.

// ═════════════════════════════════════════════════════════════════════════════════
// v1.230.0 Gate 6R — REFUSAL / CONVERGENCE TRUTH
// ═════════════════════════════════════════════════════════════════════════════════
//
// MEASURED, dns1, v1.229.13 -> v1.229.14 (installer log):
//
//	[CMD] FAIL nftban firewall rebuild --install-context (exit=1)
//	stderr=ERROR: convergence already in progress — this rebuild was REFUSED.
//
// Chain: convergence lock held -> rebuild REFUSED BEFORE any firewall mutation ->
// enforcement unchanged -> generic rc=1 -> NO result contract published -> this
// function collapsed ABSENCE OF CONTRACT into FAILED_REBUILD. Budget 300 s, 30 s
// used, no retry attempted.
//
// The three classes are now kept apart end to end:
//
//	REFUSED  the rebuild NEVER STARTED, the firewall was NOT modified
//	FAILED   the rebuild EXECUTED and failed
//	TIMEOUT  the rebuild EXECUTED and did not finish in budget
//
// ⛔ NOTHING HERE PARSES STDERR. The refusal is read from the machine-readable
// contract the shell now publishes. Message text is for operators only.
//
// ═════════════════════════════════════════════════════════════════════════════════
// THE CONVERGENCE ATTRIBUTION INVARIANT
// ═════════════════════════════════════════════════════════════════════════════════
//
//	SUCCESSFUL INSTALL:
//	    PACKAGE  ==  EXPECTED BOOT PROJECTION  ==  EFFECTIVE KERNEL GENERATION
//
// NOT byte-for-byte — the three artifacts have different representations. The
// requirement is that all three are ATTRIBUTABLE TO THE SAME SUCCESSFUL UPDATE
// TRANSACTION. dns1 failed two of the three legs after the refusal:
//
//	PACKAGE          nftban-core 1.229.14, installed 2026-09-12 21:08, dpkg -V clean
//	DISK PROJECTION  /etc/nftban/nftables.conf written 2026-09-08 20:24:11
//	KERNEL RULESET   loaded at boot 2026-09-08 09:16:57 — ELEVEN HOURS EARLIER
//
// with 0 result contracts and 0 ruleset-load events since, and no reboot. So the
// live kernel is attributable to NEITHER the disk projection NOR any .14 rebuild.
//
// A REFUSED rebuild leaves exactly that shape: enforcement is old, healthy, and
// UNATTRIBUTABLE to this transaction.
//
//	⛔ PROTECTED != TRANSACTION COMPLETE.
//
// So the commit decision must never rest on "enforcement is currently protected".
// The only leg this function can establish is the third one — and it establishes it
// POSITIVELY, from a rebuild that actually executed and committed a generation.
// When every attempt is refused, no leg is established and the run is DEFERRED.
//
// ⛔ EVIDENCE TRAPS THAT ALREADY PRODUCED A RETRACTED FINDING — do not repeat them:
//   - mtime is NOT provenance. dpkg preserves package build timestamps, so an
//     installed binary can carry an mtime days before its own install, and a
//     publication path may legitimately no-op on a byte-identical candidate.
//     Identity is hash + provenance; `dpkg -V` is the on-disk authority.
//   - Do NOT hash a rendered artifact against its own template. The template holds
//     placeholders; they differ BY DESIGN and the difference proves nothing.

// ErrRebuildRefusedBusy — every attempt inside the caller's deadline was REFUSED.
//
// ⛔ THIS IS NOT A FAILURE AND MUST NEVER BE MAPPED TO FAILED_REBUILD. No rebuild
// executed, so nothing failed; the convergence is simply still owed and the install
// is DEFERRED pending a retry.
var ErrRebuildRefusedBusy = errors.New("rebuild REFUSED_BUSY: every attempt within the installer deadline was refused by the convergence lock; no rebuild executed, the firewall was not modified, and the effective kernel generation is NOT attributable to this update transaction — convergence is DEFERRED, not complete")

// ErrRebuildNotExecuted — no result contract AND no execution witness.
//
// The root-cause guard for a missing record. "No record" has two root causes with
// OPPOSITE safety meanings:
//
//	never started    -> the firewall was NOT touched  -> deferred, retry
//	started, aborted -> the firewall MAY be touched   -> FAILED_REBUILD, fail closed
//
// Which one occurred is established from the execution witness, never assumed.
var ErrRebuildNotExecuted = errors.New("rebuild produced no result contract and no execution witness: execution was NOT established, so this is not a rebuild failure; the effective kernel generation is NOT attributable to this update transaction — convergence is DEFERRED, not complete")

// refusalMaxAttempts bounds the refusal retry loop when the caller's context carries
// no deadline. With a deadline, ctx is the bound and this is only a backstop.
//
// ⛔ NOT A SECOND TIMEOUT. It is an attempt count, not a clock: the wall-clock bound
// stays the installer's single global deadline.
const refusalMaxAttempts = 5

// refusalBackoffBase / refusalBackoffMax bound the wait BETWEEN refused attempts.
// The shell already waits for the lock itself (constants.ReconciliationLockTimeout,
// 30 s, under --install-context), so this backoff exists only to stop a hot loop.
// They are vars ONLY so tests can shrink them; production values are the ones above
// and the protocol is identical either way — the same bounded, monotonic, capped
// backoff, just measured in smaller units.
var (
	refusalBackoffBase = 2 * time.Second
	refusalBackoffMax  = 16 * time.Second
)

// SetRefusalBackoffForTest shrinks the retry backoff and returns a restore func.
// ⛔ TEST AFFORDANCE ONLY. It changes the DURATION, never the bound: the attempt cap
// and the caller's deadline remain the two things that stop the loop.
func SetRefusalBackoffForTest(base, ceiling time.Duration) func() {
	ob, om := refusalBackoffBase, refusalBackoffMax
	refusalBackoffBase, refusalBackoffMax = base, ceiling
	return func() { refusalBackoffBase, refusalBackoffMax = ob, om }
}

func refusalBackoff(attempt int) time.Duration {
	d := refusalBackoffBase
	for i := 1; i < attempt; i++ {
		d *= 2
		if d >= refusalBackoffMax {
			return refusalBackoffMax
		}
	}
	return d
}

// executionWitnessProven reports whether the shell recorded that THIS operation
// crossed the execution boundary.
//
// ⛔ NEVER mtime, never bare existence: the file must NAME this operation. A stale
// witness from an earlier run is a foreign artifact, and reading it as proof of this
// run's execution is the same identity error the result contract's operation_id
// check exists to prevent.
//
//	EXISTENCE IS NOT IDENTITY.
func executionWitnessProven(path, wantOperationID string) bool {
	if strings.TrimSpace(path) == "" || strings.TrimSpace(wantOperationID) == "" {
		return false
	}
	dir, base := filepath.Split(path)
	if dir == "" || base == "" || base != filepath.Base(base) {
		return false
	}
	// ⛔ ROOTED READ, NOT ARBITRARY VARIABLE-PATH ACCESS (gosec G304), exactly as
	// ReadRebuildResult does. This repository runs `gosec -nosec`, so a `#nosec`
	// comment is not a control here and confinement is the only answer.
	raw, err := fs.ReadFile(os.DirFS(filepath.Clean(dir)), base)
	if err != nil {
		return false
	}
	// ⛔ WHOLE-LINE MATCH, NOT A SUBSTRING. "operation_id=abc" is a prefix of
	// "operation_id=abcdef"; a substring test would let a DIFFERENT operation's
	// witness answer for this one, which is the identity error this check exists
	// to prevent.
	for _, line := range bytes.Split(raw, []byte("\n")) {
		if string(bytes.TrimSpace(line)) == "operation_id="+wantOperationID {
			return true
		}
	}
	return false
}

// rebuildAttempt is one invocation of the shell rebuild plus the reading of its
// contract. It is separated from Rebuild so the refusal retry loop cannot
// accidentally reuse an operation id, a result path or a witness path.
type rebuildAttempt struct {
	res     executor.Result
	result  *RebuildResult
	readErr error
	// executed — did this attempt cross the execution boundary? Established from the
	// witness (or, trivially, from a contract that exists at all).
	executed bool
}

// Rebuild runs "nftban firewall rebuild" and returns an error if it fails.
// Shell rebuild exit code contract (authoritative — do not redefine):
//
//	0 = PROTECTED (all checks passed)
//	1 = DEGRADED  (firewall operational, some module checks failed) or REFUSED
//	2 = FAILED    (rollback happened)
//	3 = FATAL     (rollback also failed)
//
// rc is PROCESS EVIDENCE ONLY. The structured result contract is the authority; rc 1
// no longer distinguishes anything on its own, which is precisely why the refusal had
// to become a contract rather than a new number.
//
// ctx BOUNDS THE REFUSAL RETRIES AND NOTHING ELSE.
//
// ⛔ THE REBUILD EXECUTION STAYS ON context.Background() (LANE 6A, 219bd781): its
// duration scales with host firewall state (lab2 ~35 s vs srv3 ~453 s) and no outer
// constant is correct across that range. A REFUSED attempt executed nothing, so
// waiting to try again is legitimately bounded by the installer's existing deadline —
// there is no second, independent timeout here.
func Rebuild(ctx context.Context, exec executor.Executor, log *logging.Logger) error {
	log.Info("running nftban firewall rebuild (no outer deadline; bounded by its own operations)")

	resultDir := rebuildResultBaseDir
	if err := os.MkdirAll(resultDir, 0o750); err != nil {
		// ⛔ FAIL CLOSED: if we cannot allocate a result path we cannot obtain the
		// contract, and rc must never substitute for it.
		if werr := exec.WriteFileAtomic(fhs.InstallFailedMarker, []byte("NFTBAN_INSTALL_FAILED=1\n"), 0644); werr != nil {
			log.Warn("failed to write install-failed marker: %v", werr)
		}
		return fmt.Errorf("cannot allocate rebuild result directory %s: %w", resultDir, err)
	}

	var last rebuildAttempt
	for attempt := 1; ; attempt++ {
		last = runRebuildAttempt(exec, log, resultDir)

		// ⛔ INTERRUPTION IS CLASSIFIED FIRST, AND IT IS FATAL.
		//
		//	completed successfully          -> continue install
		//	explicitly non-fatal condition  -> DEGRADED, protection contract intact
		//	timeout / killed / incomplete   -> INSTALL FAILURE
		//
		// A killed rebuild is not "some module chain might be missing". It is
		// CONVERGENCE DID NOT COMPLETE, and the installer must not carry on as
		// though the result were acceptably degraded.
		//
		// ⛔ TIMEOUT STAYS TIMEOUT. It is checked before the contract precisely so a
		// stale or partial record can never turn an interrupted execution into a
		// refusal — the two differ on whether anything ran at all.
		if last.res.TimedOut {
			markInstallFailed(exec, log)
			return fmt.Errorf("nftban firewall rebuild was INTERRUPTED before completion — convergence did not complete; the generation was not advanced and the host retains its last completed convergence")
		}
		// A process that died by signal without a deadline is equally incomplete:
		// it never chose an exit code, so it never reported a verdict.
		if last.res.ExitCode < 0 {
			markInstallFailed(exec, log)
			return fmt.Errorf("nftban firewall rebuild did not produce an exit status (killed, or not executable): %s", last.res.Stderr)
		}

		if last.readErr != nil || last.result == nil {
			break
		}
		if last.result.Continuation() != RetryRefused {
			break
		}

		// ── REFUSED ────────────────────────────────────────────────────────────────
		// The rebuild never started. Nothing was mutated, nothing failed, and there is
		// nothing to roll back — the convergence is simply still owed.
		log.Warn("firewall rebuild REFUSED (attempt %d): %s — the rebuild did not start and the firewall was not modified (modified=%t enforcement_unchanged=%t)",
			attempt, strings.Join(last.result.ReasonCodes, ","), last.result.Modified, last.result.EnforcementUnchanged)

		if attempt >= refusalMaxAttempts {
			log.Error("firewall rebuild REFUSED on every one of %d attempts — no rebuild executed", attempt)
			logAttributionNotEstablished(log)
			markInstallIncomplete(exec, log)
			return fmt.Errorf("%w (reasons=%s, attempts=%d)", ErrRebuildRefusedBusy,
				strings.Join(last.result.ReasonCodes, ","), attempt)
		}
		wait := refusalBackoff(attempt)
		log.Info("retrying the refused rebuild in %s, inside the installer's existing deadline", wait)
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			log.Error("installer deadline expired while the convergence lock was held — every attempt was REFUSED, no rebuild executed")
			logAttributionNotEstablished(log)
			markInstallIncomplete(exec, log)
			return fmt.Errorf("%w (reasons=%s, attempts=%d, deadline: %v)", ErrRebuildRefusedBusy,
				strings.Join(last.result.ReasonCodes, ","), attempt, ctx.Err())
		case <-timer.C:
		}
	}

	// ═══════════════════════════════════════════════════════════════════════════════
	// v1.229.12 P12-A01/A01b — THE STRUCTURED RESULT IS THE AUTHORITY. rc IS NOT.
	// ═══════════════════════════════════════════════════════════════════════════════
	// ⛔ THE OLD BEHAVIOUR IS DELETED:  rc==1  =>  "DEGRADED"  =>  continue install.
	// That mapping accepted a FAILED GENERATION COMMIT, an unpublishable ruleset and a
	// missing template as tolerable degradation (P12-A01b), while a legitimately deferred
	// pre-daemon projection was separately escalated to a fatal rollback (P12-A01).
	//
	// ⛔ EVERY RESULT PROBLEM IS FATAL — ONCE EXECUTION IS ESTABLISHED. That is what makes
	// UNKNOWN shell failures safe without modelling bash: a rebuild that started and then
	// aborted publishes no record, and a missing record aborts the install.
	//
	// v1.230.0 Gate 6R adds the missing precondition. A missing record when the rebuild
	// NEVER STARTED is not the same event, and reading it as FAILED_REBUILD is the exact
	// root-cause error this gate exists to remove.
	//     ABSENCE OF A CONTRACT IS NOT EVIDENCE OF A FAILED TRANSACTION.
	if last.readErr != nil {
		if !last.executed {
			log.Error("firewall rebuild produced no usable result contract AND no execution witness — execution was NOT established")
			logAttributionNotEstablished(log)
			markInstallIncomplete(exec, log)
			return fmt.Errorf("%w (exit %d): %v", ErrRebuildNotExecuted, last.res.ExitCode, last.readErr)
		}
		markInstallFailed(exec, log)
		return fmt.Errorf("nftban firewall rebuild produced no usable result contract (exit %d; execution WAS established by the witness): %w",
			last.res.ExitCode, last.readErr)
	}
	result := last.result

	// ⛔ rc MAY CORROBORATE THE RESULT; IT MAY NEVER AUTHORIZE CONTINUATION ALONE.
	// A contradiction means the producer and the process disagree — abort rather than
	// pick a winner.
	if result.ContradictsExitCode(last.res.ExitCode) {
		markInstallFailed(exec, log)
		return fmt.Errorf("rebuild contract violation: disposition %q contradicts exit code %d",
			result.Disposition, last.res.ExitCode)
	}

	switch result.Continuation() {
	case ContinueComplete:
		log.Info("firewall rebuild COMPLETE (generation committed)")
	case ContinueDeferred:
		// Not a failure, and NOT a silent success: the generation was deliberately NOT
		// advanced, so the convergence debt is still owed and is discharged by the retry.
		log.Warn("firewall rebuild DEFERRED_RUNTIME: %s", strings.Join(result.ReasonCodes, ","))
		log.Warn("module projection requires the daemon; generation NOT advanced (%s) — convergence debt outstanding",
			result.Transaction.Reason)
	default: // Abort
		markInstallFailed(exec, log)
		return fmt.Errorf("nftban firewall rebuild %s (exit %d, rollback_performed=%t, reasons=%s): %s",
			result.Disposition, last.res.ExitCode, result.RollbackPerformed,
			strings.Join(result.ReasonCodes, ","), last.res.Stderr)
	}

	// v1.151 BUG-REBUILD-DEGRADED-EMPTY-REASON: never log "completed (exit 1)" — that
	// contradicts the DEGRADED warning above and reads as a FAILED takeover, tempting
	// the operator to Ctrl+C / rollback at the worst moment when it actually recovered.
	if last.res.ExitCode == 0 {
		log.Info("firewall rebuild completed")
	} else {
		log.Info("firewall rebuild finished DEGRADED (exit %d) — module chains deferred to daemon start (recovery expected)", last.res.ExitCode)
	}

	// Write schema version file (G7 parity with shell postinst).
	// The shell postinst wrote: echo "$CURRENT_SCHEMA" > /etc/nftban/.schema_version
	// We use the installed version as the schema identifier.
	versionData, err := exec.ReadFile(fhs.VersionFile)
	if err == nil {
		version := string(versionData)
		// Trim whitespace/newlines
		for len(version) > 0 && (version[len(version)-1] == '\n' || version[len(version)-1] == '\r' || version[len(version)-1] == ' ') {
			version = version[:len(version)-1]
		}
		if err := exec.WriteFileAtomic(fhs.SchemaVersionFile, []byte(version+"\n"), 0640); err != nil {
			log.Warn("write schema version: %v", err)
		} else {
			log.Debug("wrote schema version %s to %s", version, fhs.SchemaVersionFile)
		}
	}

	return nil
}

// logAttributionNotEstablished states, in the installer log, the leg of the
// convergence attribution invariant this run could not establish.
//
// ⛔ IT IS A STATEMENT OF WHAT IS NOT KNOWN, NOT A PROBE. It deliberately does not
// go looking at /etc/nftban/nftables.conf, package metadata or `nft list ruleset` to
// "check" the other two legs: a rebuild that never executed cannot have made them
// current, and an inspection that found them plausible would only invite the false
// COMMITTED this whole path exists to prevent.
func logAttributionNotEstablished(log *logging.Logger) {
	log.Warn("convergence attribution NOT established for this transaction: PACKAGE == EXPECTED BOOT PROJECTION == EFFECTIVE KERNEL GENERATION requires a rebuild that EXECUTED and committed a generation; none did")
	log.Warn("existing enforcement is unchanged and still in force — that is NOT evidence of a completed transaction (PROTECTED != TRANSACTION COMPLETE); a retry is owed")
}

// markInstallIncomplete records the same marker for a DEFERRED outcome.
//
// ⛔ THE MARKER MEANS "THIS INSTALLATION DID NOT COMPLETE", NOT "THE REBUILD FAILED".
// It is one flag with one bit and it is written fail-closed: a run that reached no
// valid contract must never leave the host looking cleanly installed. The truthful
// three-way distinction is NOT carried here — it lives in install_state
// (REBUILD_REFUSED_BUSY / REBUILD_NOT_EXECUTED / FAILED_REBUILD), which is what
// report(), history and --repair actually read.
//
// Named apart from markInstallFailed so the call sites stay readable about which
// claim they are making; the effect on disk is deliberately identical.
func markInstallIncomplete(exec executor.Executor, log *logging.Logger) {
	markInstallFailed(exec, log)
}

// markInstallFailed records the install-failed marker for the runtime CLI.
func markInstallFailed(exec executor.Executor, log *logging.Logger) {
	if err := exec.WriteFileAtomic(fhs.InstallFailedMarker, []byte("NFTBAN_INSTALL_FAILED=1\n"), 0644); err != nil {
		log.Warn("failed to write install-failed marker: %v", err)
	}
}

// runRebuildAttempt performs ONE rebuild invocation.
//
// ⛔ EVERY ATTEMPT IS ITS OWN OPERATION: fresh operation id, fresh result path, fresh
// witness path. Reusing them across a retry would recreate exactly the stale-record and
// cross-run hazards the per-operation contract was introduced to remove.
func runRebuildAttempt(exec executor.Executor, log *logging.Logger, resultDir string) rebuildAttempt {
	// v1.229.12 P12-A01: THE CALLER ALLOCATES A UNIQUE PER-OPERATION RESULT PATH.
	// ⛔ Never a fixed global path — a shared name reintroduces stale-result and
	// concurrency hazards across runs.
	opID := fmt.Sprintf("rebuild-%d-%d", os.Getpid(), time.Now().UTC().UnixNano())
	resultPath := filepath.Join(resultDir, opID+".json")
	witnessPath := filepath.Join(resultDir, opID+".exec")
	defer func() { _ = os.Remove(resultPath) }()
	defer func() { _ = os.Remove(witnessPath) }()

	// v1.228.5: PASS the execution context explicitly. This rebuild runs BEFORE
	// services.StartDaemon (phaseConfigure), and AddSessionWhitelist writes
	// 00-session.conf AFTER it — so the durable whitelist cannot be verified here
	// even if the daemon happened to be reachable. --install-context tells the
	// rebuild to DEFER that projection rather than treat the expected daemon
	// absence as a failure. services.SyncWhitelist is the convergence authority.
	// Context is passed, never inferred: `systemctl is-active` cannot distinguish
	// "operator stopped it" from "installer has not started it yet".
	//
	// ⛔ context.Background() — DELIBERATE. See the Rebuild doc comment: the caller's
	// deadline bounds the REFUSAL RETRIES, never the execution of a rebuild that has
	// actually started.
	a := rebuildAttempt{}
	a.res = exec.RunContext(context.Background(), fhs.NftbanCLI, "firewall", "rebuild",
		"--install-context", "--result-file", resultPath, "--operation-id", opID,
		"--execution-witness", witnessPath)
	log.CmdResult("nftban firewall rebuild --install-context", a.res.ExitCode, a.res.Stderr)

	a.result, a.readErr = ReadRebuildResult(resultPath, opID)
	// A contract that exists is itself proof the rebuild ran; otherwise the witness is
	// the only evidence, and its ABSENCE is what distinguishes "never started" from
	// "started and aborted".
	a.executed = a.readErr == nil || executionWitnessProven(witnessPath, opID)
	return a
}
