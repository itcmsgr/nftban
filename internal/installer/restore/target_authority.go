// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Restore TargetAuthority (PR-25 §18)
// =============================================================================
// meta:name="restore_target_authority"
// meta:type="package"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 TargetAuthority concretization per contract §18 — struct with unexported fields, closed Kind enum, per-Kind constructors, payload invariants. Construction-only in this commit; no execution behavior."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package restore

import (
	"errors"
	"fmt"

	"github.com/itcmsgr/nftban/internal/installer/detect"
)

// TargetAuthorityKind is the closed enum of authority kinds PR-25 can act on.
//
// Per contract §18.4: adding a new variant requires a §12-style review.
type TargetAuthorityKind string

const (
	// TargetAuthorityKindNone is the zero value. PR-25 must not execute on a
	// None target; the dispatcher refuses before any mutation (contract §24).
	TargetAuthorityKindNone TargetAuthorityKind = ""

	// TargetAuthorityKindRecordedPrior names a target whose firewall identity
	// came from a recorded prior-record on disk and was already validated and
	// approved by PR-24's PROCEED path.
	TargetAuthorityKindRecordedPrior TargetAuthorityKind = "recorded_prior"

	// TargetAuthorityKindPanelNative names a target whose firewall identity
	// is determined statically by panel detection (PR-25 §20 mapping).
	TargetAuthorityKindPanelNative TargetAuthorityKind = "panel_native"
)

// TargetAuthority is the authorized execution target for PR-25.
//
// Per contract §18: struct with unexported fields; construction is constrained
// to one of three paths (TargetNone, TargetRecordedPrior, TargetPanelNative).
//
// Zero value is equivalent to TargetNone() (contract §18.2). This is
// intentional. PR-25 execution must reject a None target before any
// mutation; the type alone does not enforce that — the Execute path does
// (contract §24, enforced in commit 3).
//
// INV-PR25-AUTHORITY-IMMUTABILITY (contract §17.3): once constructed, a
// TargetAuthority value is read-only. There are no exported mutators.
type TargetAuthority struct {
	kind         TargetAuthorityKind
	firewallType string
	panel        detect.PanelType
}

// Kind returns the authority kind. Zero-value TargetAuthority returns
// TargetAuthorityKindNone.
func (t TargetAuthority) Kind() TargetAuthorityKind { return t.kind }

// FirewallType returns the firewall-type string. Empty for None and
// PanelNative per the §18.3 payload invariants.
func (t TargetAuthority) FirewallType() string { return t.firewallType }

// Panel returns the panel type. PanelNone for None and RecordedPrior per
// the §18.3 payload invariants.
func (t TargetAuthority) Panel() detect.PanelType { return t.panel }

// TargetNone returns the None-kind target. Equivalent to the zero value.
func TargetNone() TargetAuthority {
	return TargetAuthority{}
}

// knownFirewallTypes is the set of firewall-type strings that are valid
// payloads for TargetAuthorityKindRecordedPrior.
//
// Local to the restore package per code-phase guardrail 4. The set content
// is identical by contract §18.2 to internal/installer/uninstall.knownFirewallType
// (defined at uninstall/prior.go:278-284) but the package boundary is
// preserved — restore does not import uninstall authority types.
var knownFirewallTypes = map[string]struct{}{
	"ufw":       {},
	"firewalld": {},
	"iptables":  {},
	"csf":       {},
}

// ErrUnknownFirewallType is returned by TargetRecordedPrior when the
// firewallType argument is not a member of the known set (§18.2).
var ErrUnknownFirewallType = errors.New("restore: unknown firewall type")

// ErrPanelNoneForPanelNative is returned by TargetPanelNative when the
// panel argument is detect.PanelNone (§18.2).
var ErrPanelNoneForPanelNative = errors.New("restore: PanelNone is not a valid PanelNative target")

// TargetRecordedPrior constructs a TargetAuthority of kind RecordedPrior.
// The firewallType argument must be a member of the known set (§18.2)
// or ErrUnknownFirewallType is returned.
//
// Per code-phase guardrail 3, this public constructor returns an error
// rather than panicking on invalid input.
func TargetRecordedPrior(firewallType string) (TargetAuthority, error) {
	if _, ok := knownFirewallTypes[firewallType]; !ok {
		return TargetAuthority{}, fmt.Errorf("%w: %q", ErrUnknownFirewallType, firewallType)
	}
	return TargetAuthority{
		kind:         TargetAuthorityKindRecordedPrior,
		firewallType: firewallType,
		// Payload invariant §18.3: panel is structurally PanelNone for
		// RecordedPrior. This is also the zero value for detect.PanelType.
		panel: detect.PanelNone,
	}, nil
}

// TargetPanelNative constructs a TargetAuthority of kind PanelNative.
// panel must not be detect.PanelNone or ErrPanelNoneForPanelNative is
// returned.
//
// Per code-phase guardrail 3, this public constructor returns an error
// rather than panicking on invalid input.
func TargetPanelNative(panel detect.PanelType) (TargetAuthority, error) {
	if panel == detect.PanelNone {
		return TargetAuthority{}, ErrPanelNoneForPanelNative
	}
	return TargetAuthority{
		kind: TargetAuthorityKindPanelNative,
		// Payload invariant §18.3: firewallType is structurally empty for
		// PanelNative. The actual firewall is resolved at execution time
		// via the static §20 mapping (commit 3).
		firewallType: "",
		panel:        panel,
	}, nil
}

// mustBeKnownKind is an internal assertion helper used by Kind switches to
// detect closed-enum violations (contract §18.4: default branch in any
// Kind switch MUST panic at runtime).
//
// Per code-phase guardrail 3: panic is restricted to impossible internal
// default branches. Public constructors return errors, never panic.
//
// Callers use this in switch-default arms only:
//
//	switch t.Kind() {
//	case TargetAuthorityKindNone:           ...
//	case TargetAuthorityKindRecordedPrior:  ...
//	case TargetAuthorityKindPanelNative:    ...
//	default:
//	    mustBeKnownKind(t.Kind())
//	}
func mustBeKnownKind(k TargetAuthorityKind) {
	panic(fmt.Sprintf("restore: unhandled TargetAuthorityKind %q (closed enum violation)", k))
}
