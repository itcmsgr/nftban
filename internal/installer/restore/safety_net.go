// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Restore Safety-Net Primitives (PR-25 §23.2 / §23.5 / §21.3)
// =============================================================================
// meta:name="restore_safety_net"
// meta:type="package"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 3B — emergency-SSH safety-net primitives. InsertSafetyNet/RemoveSafetyNet are the only operations exposed; both go through an injected SafetyNetDep so tests can prove call behavior without touching kernel. Removal refuses unless caller asserts verification said it is safe. No orchestration, no terminal-state selection — that belongs to Execute (commit 3C)."
// meta:depends=""
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package restore

import (
	"context"
	"errors"
	"fmt"
)

// SafetyNetDep is the dependency-injection seam for safety-net
// kernel operations. Every mutation-capable call goes through this
// interface so production code uses a real implementation and tests
// use a fake.
//
// The interface is intentionally narrow:
//
//   - InsertEmergencySSH adds the single emergency-SSH allow rule
//     into the kernel ruleset. No broader firewall edits, no service
//     manipulation, no file writes.
//   - RemoveEmergencySSH removes the same rule. The caller is
//     responsible for not calling this until inline verification
//     said it is safe; the package-level RemoveSafetyNet primitive
//     enforces that with an explicit verifiedSafe argument.
//
// Implementations of this interface are NOT in this package and NOT
// in this commit (3B is primitives only). Production wiring is a
// commit-3C concern; tests in this commit use a fake.
type SafetyNetDep interface {
	// InsertEmergencySSH inserts the single emergency-SSH allow rule.
	// It MUST NOT perform any other firewall edit. Returns an error
	// describing the failure on any non-success outcome.
	InsertEmergencySSH(ctx context.Context) error

	// RemoveEmergencySSH removes the previously-inserted rule.
	// It MUST NOT perform any other firewall edit. It MUST NOT
	// re-flush, rebuild, or otherwise touch unrelated rules. Returns
	// an error describing the failure on any non-success outcome.
	RemoveEmergencySSH(ctx context.Context) error
}

// Sentinel errors returned by safety-net primitives.
var (
	// ErrSafetyNetInsertFailed wraps an underlying SafetyNetDep
	// failure during InsertSafetyNet.
	ErrSafetyNetInsertFailed = errors.New("restore: safety-net insertion failed")

	// ErrSafetyNetRemoveFailed wraps an underlying SafetyNetDep
	// failure during RemoveSafetyNet.
	ErrSafetyNetRemoveFailed = errors.New("restore: safety-net removal failed")

	// ErrSafetyNetRemoveBeforeVerification is returned by
	// RemoveSafetyNet when the caller passed verifiedSafe=false.
	// Per contract §21.3: PR-25 MUST NOT remove the safety net until
	// inline verification (§21.1) passes. The primitive enforces
	// this with an explicit boolean argument so callers cannot omit
	// the gate.
	ErrSafetyNetRemoveBeforeVerification = errors.New("restore: safety-net removal refused — verification has not asserted safety (§21.3)")

	// ErrSafetyNetNilDep is returned when the caller passes a nil
	// SafetyNetDep. The primitive does not invent a default — see
	// §20.3 / §17.2 (no implicit takeover, no default firewall surface).
	ErrSafetyNetNilDep = errors.New("restore: safety-net dep is nil")
)

// InsertSafetyNet calls dep.InsertEmergencySSH. It is intentionally a
// thin wrapper: the only added value over a direct call is uniform
// error wrapping (so callers can use errors.Is(err,
// ErrSafetyNetInsertFailed) to discriminate).
//
// The primitive MUST NOT do any other firewall edit. It MUST NOT
// touch services, files, or the broader ruleset. Verified by the
// file-scan test (no service/firewall manipulation strings in
// safety_net.go).
//
// Ordering relative to the rest of restore execution is enforced by
// the caller (Execute, commit 3C). This primitive does not gate on
// any external state.
func InsertSafetyNet(ctx context.Context, dep SafetyNetDep) error {
	if dep == nil {
		return ErrSafetyNetNilDep
	}
	if err := dep.InsertEmergencySSH(ctx); err != nil {
		return fmt.Errorf("%w: %v", ErrSafetyNetInsertFailed, err)
	}
	return nil
}

// RemoveSafetyNet calls dep.RemoveEmergencySSH but ONLY if the caller
// explicitly asserts verifiedSafe == true.
//
// The verifiedSafe boolean is the §21.3 hard invariant rendered as an
// argument: a caller that has not run inline verification — or that
// ran it and got a non-pass result — must pass false, and the
// primitive then returns ErrSafetyNetRemoveBeforeVerification without
// touching the kernel.
//
// This is deliberately strict. The primitive does NOT call inline
// verification itself; that coupling belongs in Execute (commit 3C),
// which orchestrates the §23 sequence: verify → ask, then call this
// primitive with the verifier's result.
//
// On verifiedSafe=true, the primitive delegates to dep and wraps any
// underlying error in ErrSafetyNetRemoveFailed.
func RemoveSafetyNet(ctx context.Context, dep SafetyNetDep, verifiedSafe bool) error {
	if dep == nil {
		return ErrSafetyNetNilDep
	}
	if !verifiedSafe {
		return ErrSafetyNetRemoveBeforeVerification
	}
	if err := dep.RemoveEmergencySSH(ctx); err != nil {
		return fmt.Errorf("%w: %v", ErrSafetyNetRemoveFailed, err)
	}
	return nil
}
