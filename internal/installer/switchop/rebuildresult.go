// =============================================================================
// NFTBan v1.229.12 - Rebuild Result Contract (P12-A01 / P12-A01b)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="rebuild-result"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Typed shell->Go rebuild result: the shell reports a RebuildDisposition; Go owns installer continuation. Retires rc as semantic authority."
// meta:inventory.privileges="none"
//
// ⛔ WHY THIS EXISTS
// The shell rebuild compressed a rich transaction outcome into rc 0/1/2, and Go assigned
// installer meaning to it. `return 1` meant ALL of: expected-deferred, template missing,
// publish failed, apply failed, generation-commit failed, and any bash programming error.
// That single overload produced two opposite production defects:
//
//	P12-A01   an EXPECTED pre-daemon degradation was escalated to a fatal rollback
//	P12-A01b  a FAILED GENERATION COMMIT was accepted as "DEGRADED" and the install continued
//
// The authority split is now explicit:
//
//	SHELL  RebuildDisposition   — what happened to this rebuild transaction
//	GO     InstallerContinuation — whether installation may proceed
//
// ⛔ rc IS PROCESS EVIDENCE ONLY. It is NEVER sufficient semantic evidence on this path.
package switchop

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// RebuildResultSchemaSupported is the producer schema this consumer knows how to interpret.
// ⛔ A newer schema is NOT compatible until PROVEN compatible — same rule the shell applies to
// the validator schema. Unknown version => abort, never "assume forward compatible".
const RebuildResultSchemaSupported = "1"

// rebuildResultBaseDir is where per-operation result records are published.
//
// ⛔ PRODUCTION VALUE IS /run/nftban/rebuild-results AND MUST STAY THERE — it is tmpfs,
// root-owned, and cleared on boot, which is what makes a stale record impossible to
// resurrect across reboots.
//
// It is a var solely so TESTS can redirect it. CI runners are not root and cannot write
// /run/nftban, so a hardcoded path made every record-publishing test fail in CI while
// passing locally as root. Overriding the DIRECTORY keeps the protocol identical; it does
// not weaken the contract (uniqueness, atomic rename and operation_id binding are unchanged).
var rebuildResultBaseDir = "/run/nftban/rebuild-results"

// SetRebuildResultBaseDirForTest overrides the publish directory and returns a restore
// func. The variable above exists to be overridden — CI has no writable /run/nftban, so a
// hardcoded path fails there while passing locally as root — but it is package-private,
// which leaves out-of-package callers (cmd/nftban-installer end-to-end tests that drive
// runInstall) unable to use it. This is a TEST AFFORDANCE ONLY: it changes the directory,
// never the protocol. Uniqueness, atomic rename and operation_id binding are unchanged.
func SetRebuildResultBaseDirForTest(dir string) func() {
	old := rebuildResultBaseDir
	rebuildResultBaseDir = dir
	return func() { rebuildResultBaseDir = old }
}

// RebuildDisposition is the SHELL's report about its own transaction.
type RebuildDisposition string

const (
	DispositionComplete        RebuildDisposition = "COMPLETE"
	DispositionDeferredRuntime RebuildDisposition = "DEFERRED_RUNTIME"
	DispositionRegression      RebuildDisposition = "REGRESSION"
	DispositionFatal           RebuildDisposition = "FATAL"

	// DispositionRefused — v1.230.0 Gate 6R. THE REBUILD NEVER STARTED.
	//
	//	REFUSED  rebuild NEVER STARTED, firewall NOT modified (convergence lock held)
	//	FAILED   rebuild EXECUTED and failed
	//	TIMEOUT  rebuild EXECUTED and did not finish in budget
	//
	// Before this existed, a refusal published NO record at all and the consumer
	// collapsed ABSENCE OF CONTRACT into FAILED_REBUILD on a host whose enforcement
	// had not been touched (dns1, v1.229.13 -> v1.229.14).
	//
	// ⛔ THE CONSUMER READS THIS FIELD, NOT THE STDERR SENTENCE. No code on this path
	// may match "convergence already in progress" or any other message text.
	DispositionRefused RebuildDisposition = "REFUSED"
)

// InstallerContinuation is GO's policy decision. This is the authority that moved.
type InstallerContinuation string

const (
	ContinueComplete InstallerContinuation = "CONTINUE_COMPLETE"
	ContinueDeferred InstallerContinuation = "CONTINUE_DEFERRED"
	Abort            InstallerContinuation = "ABORT"

	// RetryRefused — v1.230.0 Gate 6R. NOT a continuation and NOT an abort: nothing
	// happened, so the convergence is still entirely owed. The caller retries within
	// the deadline it already has; if every attempt is refused the install is DEFERRED,
	// never FAILED.
	RetryRefused InstallerContinuation = "RETRY_REFUSED"
)

type rebuildTransaction struct {
	Committed bool   `json:"committed"`
	Reason    string `json:"reason"` // COMMITTED | DEFERRED_CONVERGENCE | NOT_STARTED | FAILURE
}

type rebuildRetry struct {
	Reason string `json:"reason"` // DEFERRED_CONVERGENCE | FAILURE_RECOVERY | NONE
}

// RebuildResult is the per-operation record the shell publishes atomically.
type RebuildResult struct {
	SchemaVersion     string             `json:"schema_version"`
	OperationID       string             `json:"operation_id"`
	Context           string             `json:"context"`
	Disposition       RebuildDisposition `json:"disposition"`
	ReasonCodes       []string           `json:"reason_codes"`
	RollbackPerformed bool               `json:"rollback_performed"`
	// Modified / EnforcementUnchanged — v1.230.0 Gate 6R mutation facts.
	//
	// ⛔ CONSUMED FOR REFUSED ONLY. The producer can PROVE them there (the convergence
	// lock was never acquired, so nothing downstream of it ran) and emits fail-closed
	// placeholders — modified=true, enforcement_unchanged=false — everywhere else.
	// Reading them for any other disposition would be reading a placeholder as a fact.
	//     A FIELD MAY ONLY BE CONSUMED WHERE ITS VALUE IS PROVEN, NOT MERELY PRESENT.
	Modified             bool               `json:"modified"`
	EnforcementUnchanged bool               `json:"enforcement_unchanged"`
	Transaction          rebuildTransaction `json:"transaction"`
	Retry                rebuildRetry       `json:"retry"`
	PreStatus            string             `json:"pre_status"`
	PostStatus           string             `json:"post_status"`
	EmittedAt            string             `json:"emitted_at"`
}

// ReadRebuildResult loads and validates the per-operation record.
//
// ⛔ EVERY FAILURE HERE IS FATAL TO THE INSTALL. That is the property that makes unexpected
// shell aborts safe WITHOUT Go having to model bash: an aborted shell publishes no record,
// and a missing record aborts the install. We do not need to enumerate bash failure modes.
func ReadRebuildResult(path, wantOperationID string) (*RebuildResult, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("no rebuild result path was allocated")
	}
	// ⛔ ROOTED READ, NOT ARBITRARY VARIABLE-PATH ACCESS (gosec G304).
	// This repository runs `gosec -nosec`, which DISABLES `#nosec` annotations by policy —
	// so a comment can never resolve this finding, and dismissing the alert externally would
	// bypass that policy for a new candidate-caused finding. The read is therefore CONFINED.
	//
	// The allocator in Rebuild() remains the authority for the path; this consumer only
	// DECOMPOSES what it was handed and refuses anything that is not a single component
	// inside that directory. It does not reinvent filename policy.
	//
	// ⛔ COMMENT DIRECTIVE != CONTROL WHEN THE SCANNER INVOCATION DISABLES THAT DIRECTIVE.
	dir, base := filepath.Split(path)
	if dir == "" || base == "" || base != filepath.Base(base) ||
		base == "." || base == ".." || strings.ContainsRune(base, filepath.Separator) {
		return nil, fmt.Errorf("rebuild result path %q is not a single component inside a result directory", path)
	}
	root := os.DirFS(filepath.Clean(dir))
	raw, err := fs.ReadFile(root, base)
	if err != nil {
		return nil, fmt.Errorf("rebuild result missing (%s): %w — the rebuild did not publish a final record", path, err)
	}
	if len(raw) == 0 {
		return nil, fmt.Errorf("rebuild result is empty (%s)", path)
	}
	var r RebuildResult
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("rebuild result is malformed (%s): %w", path, err)
	}
	if r.SchemaVersion != RebuildResultSchemaSupported {
		return nil, fmt.Errorf("rebuild result schema %q is not supported (this consumer understands %q) — a newer producer contract is not compatible until proven compatible",
			r.SchemaVersion, RebuildResultSchemaSupported)
	}
	// ⛔ STALE / CROSS-RUN GUARD: the record must belong to THIS operation.
	if wantOperationID != "" && r.OperationID != wantOperationID {
		return nil, fmt.Errorf("rebuild result operation_id %q does not match this operation %q — refusing a foreign or stale record",
			r.OperationID, wantOperationID)
	}
	switch r.Disposition {
	case DispositionComplete, DispositionDeferredRuntime, DispositionRegression, DispositionFatal:
	case DispositionRefused:
		// ⛔ A REFUSAL CLAIM MUST BE SELF-CONSISTENT OR IT IS NOT A REFUSAL.
		// REFUSED asserts the strongest safety property in this contract — that the
		// firewall was not touched. A record that asserts it while also reporting a
		// mutation or a commit is a broken producer, and the safe reading of a broken
		// producer is never "nothing happened".
		if r.Modified || !r.EnforcementUnchanged || r.Transaction.Committed {
			return nil, fmt.Errorf("REFUSED record is self-contradictory (modified=%t enforcement_unchanged=%t committed=%t) — refusing to read it as an untouched firewall",
				r.Modified, r.EnforcementUnchanged, r.Transaction.Committed)
		}
	default:
		return nil, fmt.Errorf("rebuild result disposition %q is unknown — aborting rather than guessing", r.Disposition)
	}
	return &r, nil
}

// Continuation maps the shell's disposition to Go's installer policy.
//
// ⛔ UNKNOWN VALUES ABORT. Schema evolution must default to safe, never to "continue".
func (r *RebuildResult) Continuation() InstallerContinuation {
	switch r.Disposition {
	case DispositionComplete:
		return ContinueComplete
	case DispositionDeferredRuntime:
		return ContinueDeferred
	case DispositionRegression, DispositionFatal:
		return Abort
	case DispositionRefused:
		return RetryRefused
	default:
		return Abort
	}
}

// ContradictsExitCode reports whether the record and the process rc disagree.
//
// ⛔ rc is not the authority, but a CONTRADICTION is itself evidence of a broken contract
// and must abort. Consistent pairs: COMPLETE/0, DEFERRED_RUNTIME/1, REGRESSION|FATAL/>=2.
func (r *RebuildResult) ContradictsExitCode(rc int) bool {
	switch r.Disposition {
	case DispositionComplete:
		return rc != 0
	case DispositionDeferredRuntime:
		return rc != 1
	case DispositionRegression, DispositionFatal:
		return rc < 2
	case DispositionRefused:
		// The refusal path returns the wrapper's existing rc=1. A DEDICATED CODE WAS
		// DELIBERATELY NOT INTRODUCED: rc is secondary here, and the rc-only consumers of
		// `nftban firewall rebuild` (lib/service_control.sh, helpers/autoheal.sh) have not
		// been analysed under a new code in this lane.
		return rc != 1
	}
	return true
}
