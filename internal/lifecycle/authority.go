// =============================================================================
// NFTBan v1.97 - Authority Model
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-authority"
// meta:type="lib"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Authority resolution: prior → desired → resulting with health dimension"
// meta:inventory.files="internal/lifecycle/authority.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V197_LIFECYCLE_CONTRACT.md §6 PR-03
// INV-LC-004: Authority owner and health are independent dimensions.
//   NFTBAN + DEGRADED is valid ownership — lifecycle must not treat
//   DEGRADED as "no authority" or trigger unauthorized takeover.
// =============================================================================

package lifecycle

import "fmt"

// ResolveAuthority determines the resulting authority state given
// prior state, desired state, and detection observations.
//
// Rules:
//   - NFTBAN + PROTECTED/IDLE → owned and healthy, allow operations
//   - NFTBAN + DEGRADED → owned but unsafe, proceed with caution
//   - NFTBAN + DOWN → owned but failed, recovery before new lifecycle
//   - EXTERNAL + any → may observe but MUST NOT seize without force
//   - NONE + any → no managed authority, safe for fresh install
func ResolveAuthority(prior, desired AuthorityState, detection Detection, force bool) (resulting AuthorityState, action Action, err error) {
	// Normalize NONE authority
	prior.NormalizeNone()

	// Conflicting firewall blocks all authority changes
	if detection.ConflictingFirewall && desired.Owner == AuthorityNFTBan {
		return prior, ActionAbort, fmt.Errorf(
			"conflicting firewall active — cannot establish NFTBan authority")
	}

	// ─── EXTERNAL authority ─────────────────────────────────────────────
	if prior.Owner == AuthorityExternal {
		if desired.Owner == AuthorityNFTBan {
			if force {
				// Explicit takeover requested
				return desired, ActionTakeAuthority, nil
			}
			return prior, ActionAbort, fmt.Errorf(
				"external firewall controls authority — use --force to override")
		}
		// Uninstall or maintenance on external: observe only
		return prior, ActionNoop, nil
	}

	// ─── NONE authority ─────────────────────────────────────────────────
	if prior.Owner == AuthorityNone {
		if desired.Owner == AuthorityNFTBan {
			// Fresh install — take authority
			return desired, ActionTakeAuthority, nil
		}
		// Uninstall or maintenance with no authority
		return prior, ActionNoop, nil
	}

	// ─── NFTBAN authority ───────────────────────────────────────────────
	if prior.Owner == AuthorityNFTBan {
		if desired.Owner == AuthorityNone {
			// Uninstall — release authority
			result := AuthorityState{Owner: AuthorityNone, Health: HealthDown}
			return result, ActionTakeAuthority, nil
		}

		// Preserve authority for update/maintenance
		if prior.Health == HealthDown {
			return prior, ActionNeedsRecovery, fmt.Errorf(
				"NFTBan authority is DOWN — recovery required before lifecycle operation")
		}

		return prior, ActionPreserveAuthority, nil
	}

	// Should not reach here
	return prior, ActionAbort, fmt.Errorf("unexpected authority state: owner=%s", prior.Owner)
}

// CanProceed returns true if the action allows lifecycle to continue.
func CanProceed(action Action) bool {
	switch action {
	case ActionTakeAuthority, ActionPreserveAuthority, ActionNoop:
		return true
	case ActionAbort, ActionNeedsRecovery:
		return false
	default:
		return false
	}
}

// TransitionDescription returns a human-readable description of
// the authority transition for logging/evidence.
func TransitionDescription(prior, resulting AuthorityState, action Action) string {
	switch action {
	case ActionTakeAuthority:
		if resulting.Owner == AuthorityNone {
			return fmt.Sprintf("releasing authority from %s to NONE", prior.Owner)
		}
		return fmt.Sprintf("taking authority: %s/%s → %s/%s",
			prior.Owner, prior.Health, resulting.Owner, resulting.Health)
	case ActionPreserveAuthority:
		return fmt.Sprintf("preserving authority: %s/%s",
			prior.Owner, prior.Health)
	case ActionNoop:
		return "no authority change needed"
	case ActionAbort:
		return "lifecycle aborted — authority change blocked"
	case ActionNeedsRecovery:
		return fmt.Sprintf("recovery required before lifecycle — current: %s/%s",
			prior.Owner, prior.Health)
	default:
		return "unknown authority action"
	}
}
