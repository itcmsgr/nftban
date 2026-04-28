// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Restore Inline Verification (PR-25 §21.1)
// =============================================================================
// meta:name="restore_inline_verify"
// meta:type="package"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 3B — inline verification primitive. Implements ONLY the §21.1 minimum-sufficient three-assertion check (target firewall active / nftban authority class correct / safety-net removal safe). Dependency-injected so production wires the real validator surface and tests use a fake. Not the PR-26 full verification gate."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/uninstall"
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

	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// InlineVerifyDep is the dependency-injection seam for inline
// verification queries. Each method answers ONE of the three
// minimum-sufficient §21.1 questions and nothing more. Production
// implementations are NOT in this commit (3B is primitives only);
// production wiring is a commit-3C concern, tests in this commit
// use a fake.
//
// Crucially: this interface is NOT the full nftban validator surface.
// It is a narrow query interface tailored to §21.1's three assertions.
// Adding methods here for unrelated module health is forbidden — that
// belongs to the PR-26 verification gate, not PR-25.
type InlineVerifyDep interface {
	// IsTargetFirewallActive reports whether the panel-auto-mapped or
	// recorded-prior firewallType is currently active on the host.
	// firewallType is one of the §18.2 known values
	// ({ufw, firewalld, iptables, csf}); callers MUST NOT pass any
	// other value. Returns (active, err).
	//
	// Active means: the firewall's runtime presence is observable
	// (e.g. service running, kernel rules loaded). The exact
	// observability mechanism is the production implementation's
	// concern; it is NOT defined here.
	IsTargetFirewallActive(ctx context.Context, firewallType string) (bool, error)

	// CurrentAuthorityClass returns the host's current authority
	// class as classified after the PR-25 mutation has completed.
	// Returns the same uninstall.CurrentAuthority enum that PR-22 /
	// PR-23 / PR-24 use, so callers can compare the post-mutation
	// classification against an expected value.
	//
	// This MUST reflect a fresh classification, but the *call* is
	// allowed to be expensive — production implementations may
	// shell out. It is NOT a hot-path primitive.
	CurrentAuthorityClass(ctx context.Context) (uninstall.CurrentAuthority, error)

	// IsSafetyNetRemovalSafe reports whether removing the
	// emergency-SSH safety net at this moment is safe. Production
	// implementations must check, at minimum, that:
	//
	//   - SSH connectivity remains observable on the post-mutation
	//     ruleset, OR
	//   - an equivalent operator-recovery path exists that does not
	//     depend on the safety-net rule.
	//
	// The exact predicate is the production implementation's concern.
	// This primitive only carries the boolean result.
	IsSafetyNetRemovalSafe(ctx context.Context) (bool, error)
}

// VerifyResult captures the outcome of one inline-verification call.
//
// Three semantic outcomes:
//
//   - All three assertions PASS → safe-to-remove, all observed flags true,
//     Err == nil.
//   - One or more assertions FAIL deterministically → safe-to-remove
//     == false, the corresponding observed flag is false, Err == nil.
//     Per §21.3 the caller MUST NOT remove the safety net on this path.
//   - Underlying dep error → all observed flags are zero values,
//     safe-to-remove == false, Err != nil. Caller treats this as a
//     verification HARD-FAIL (per §22 "FailedVerification" semantics
//     in commit 3C).
type VerifyResult struct {
	TargetFirewallActive  bool
	AuthorityClassCorrect bool
	SafetyNetRemovalSafe  bool

	// SafeToRemove is true ONLY when all three assertions are true
	// AND no dep error occurred. It is the §21.3 gate value the
	// caller passes to RemoveSafetyNet.
	SafeToRemove bool

	// ObservedAuthority is the value returned by
	// dep.CurrentAuthorityClass — included in the result for caller
	// logging and terminal-state selection (commit 3C). Empty on
	// dep-error path.
	ObservedAuthority uninstall.CurrentAuthority

	// Err is non-nil only when a dep call returned an error.
	// Verification logical-FAIL (one or more assertions returning
	// false) does NOT produce an Err — it produces SafeToRemove=false.
	Err error
}

// Sentinel errors returned by InlineVerify wrapped in VerifyResult.Err.
var (
	// ErrInlineVerifyNilDep is returned when dep is nil.
	ErrInlineVerifyNilDep = errors.New("restore: inline-verify dep is nil")

	// ErrInlineVerifyDepFailed wraps an underlying dep error from
	// any of the three §21.1 assertion calls.
	ErrInlineVerifyDepFailed = errors.New("restore: inline-verify dep call failed")

	// ErrInlineVerifyInvalidAuthority is returned when the caller
	// passes an expectedAuthority value that is not one of the
	// uninstall.CurrentAuthority constants. Defensive guard against
	// caller-side typos.
	ErrInlineVerifyInvalidAuthority = errors.New("restore: inline-verify expectedAuthority is invalid")

	// ErrInlineVerifyEmptyFirewallType is returned when targetFirewall
	// is the empty string. Per §18.2, an empty FirewallType is only
	// valid for PanelNative kind; the caller (Execute, commit 3C)
	// must resolve the panel to a concrete firewallType via
	// ResolvePanelFirewall BEFORE calling InlineVerify.
	ErrInlineVerifyEmptyFirewallType = errors.New("restore: inline-verify targetFirewall must be a known firewall type, got empty")
)

// InlineVerify performs the §21.1 minimum-sufficient three-assertion
// check. It is the ONLY public entry point in this file.
//
// Inputs:
//
//   - ctx                  — cancellation context.
//   - dep                  — verification dep, must be non-nil.
//   - targetFirewall       — the firewall the operator authorized
//                            (RecordedPrior.FirewallType OR the
//                            ResolvePanelFirewall(panel) output for
//                            PanelNative). Must be a §18.2 known
//                            firewall type; empty string is rejected.
//   - expectedAuthority    — the post-mutation authority class the
//                            caller expects. For RecordedPrior /
//                            PanelNative restoration, this is
//                            uninstall.AuthorityExternal (the panel
//                            or recorded firewall is now authoritative).
//                            Empty / unknown values are rejected.
//
// Outputs (carried in VerifyResult):
//
//   - TargetFirewallActive  — assertion 1
//   - AuthorityClassCorrect — assertion 2
//   - SafetyNetRemovalSafe  — assertion 3
//   - SafeToRemove          — true iff all three assertions are true
//                             AND no dep error occurred
//   - ObservedAuthority     — the actual class returned by the dep
//   - Err                   — non-nil on dep failure / invalid input
//
// The function does NOT call any other restore-package mutation
// primitive. It does NOT remove the safety net. It does NOT decide a
// terminal state. It does NOT interpret SafeToRemove for the caller.
// All of that belongs to Execute (commit 3C).
//
// The function does NOT implement the PR-26 verification gate — see
// §21.4.
func InlineVerify(
	ctx context.Context,
	dep InlineVerifyDep,
	targetFirewall string,
	expectedAuthority uninstall.CurrentAuthority,
) VerifyResult {
	if dep == nil {
		return VerifyResult{Err: ErrInlineVerifyNilDep}
	}
	if targetFirewall == "" {
		return VerifyResult{Err: ErrInlineVerifyEmptyFirewallType}
	}
	// Validate expectedAuthority is one of the known constants. We
	// allow only AuthorityExternal / AuthorityNFTBan / AuthorityNone
	// here; AuthorityAmbiguous would be a contract violation
	// (verification cannot succeed on an ambiguous post-state) and
	// the empty string is also invalid.
	switch expectedAuthority {
	case uninstall.AuthorityExternal, uninstall.AuthorityNFTBan, uninstall.AuthorityNone:
		// valid
	default:
		return VerifyResult{
			Err: fmt.Errorf("%w: %q", ErrInlineVerifyInvalidAuthority, expectedAuthority),
		}
	}

	// Assertion 1 — target firewall active.
	active, err := dep.IsTargetFirewallActive(ctx, targetFirewall)
	if err != nil {
		return VerifyResult{
			Err: fmt.Errorf("%w (assertion 1, IsTargetFirewallActive): %v",
				ErrInlineVerifyDepFailed, err),
		}
	}

	// Assertion 2 — nftban authority class correct after mutation.
	observed, err := dep.CurrentAuthorityClass(ctx)
	if err != nil {
		return VerifyResult{
			Err: fmt.Errorf("%w (assertion 2, CurrentAuthorityClass): %v",
				ErrInlineVerifyDepFailed, err),
		}
	}
	authorityCorrect := observed == expectedAuthority

	// Assertion 3 — safety-net removal safe.
	safe, err := dep.IsSafetyNetRemovalSafe(ctx)
	if err != nil {
		return VerifyResult{
			TargetFirewallActive:  active,
			AuthorityClassCorrect: authorityCorrect,
			ObservedAuthority:     observed,
			Err: fmt.Errorf("%w (assertion 3, IsSafetyNetRemovalSafe): %v",
				ErrInlineVerifyDepFailed, err),
		}
	}

	res := VerifyResult{
		TargetFirewallActive:  active,
		AuthorityClassCorrect: authorityCorrect,
		SafetyNetRemovalSafe:  safe,
		ObservedAuthority:     observed,
	}
	res.SafeToRemove = active && authorityCorrect && safe
	return res
}
