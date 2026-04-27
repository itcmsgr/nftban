// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — TargetAuthority tests (PR-25 §18)
// =============================================================================
// meta:name="restore_target_authority_test"
// meta:type="test"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 1 tests: construction-path invariants, payload invariants per §18.3, closed-enum discipline per §18.4, zero-value equivalence to TargetNone()."
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
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
)

// TestTargetNone_ZeroValueEquivalence verifies that the zero-value
// TargetAuthority is observationally identical to TargetNone(). Contract §18.2
// names this as intentional equivalence.
func TestTargetNone_ZeroValueEquivalence(t *testing.T) {
	zero := TargetAuthority{}
	none := TargetNone()

	if zero != none {
		t.Errorf("zero value != TargetNone(): %#v vs %#v", zero, none)
	}
	if zero.Kind() != TargetAuthorityKindNone {
		t.Errorf("zero value Kind() = %q; want %q", zero.Kind(), TargetAuthorityKindNone)
	}
	if zero.FirewallType() != "" {
		t.Errorf("zero value FirewallType() = %q; want empty", zero.FirewallType())
	}
	if zero.Panel() != detect.PanelNone {
		t.Errorf("zero value Panel() = %q; want PanelNone", zero.Panel())
	}
}

// TestTargetRecordedPrior_ValidFirewallTypes verifies that all four members
// of the §18.2 known set construct successfully.
func TestTargetRecordedPrior_ValidFirewallTypes(t *testing.T) {
	for _, fwt := range []string{"ufw", "firewalld", "iptables", "csf"} {
		t.Run(fwt, func(t *testing.T) {
			ta, err := TargetRecordedPrior(fwt)
			if err != nil {
				t.Fatalf("TargetRecordedPrior(%q) returned error: %v", fwt, err)
			}
			if ta.Kind() != TargetAuthorityKindRecordedPrior {
				t.Errorf("Kind() = %q; want %q", ta.Kind(), TargetAuthorityKindRecordedPrior)
			}
			if ta.FirewallType() != fwt {
				t.Errorf("FirewallType() = %q; want %q", ta.FirewallType(), fwt)
			}
			// §18.3 payload invariant: panel is PanelNone for RecordedPrior.
			if ta.Panel() != detect.PanelNone {
				t.Errorf("Panel() = %q; want PanelNone (§18.3 invariant)", ta.Panel())
			}
		})
	}
}

// TestTargetRecordedPrior_RejectsUnknown verifies that any firewall type
// outside the §18.2 known set is rejected.
func TestTargetRecordedPrior_RejectsUnknown(t *testing.T) {
	cases := []string{"", "nftables", "iptables-legacy", "pf", "windows-firewall", "ufw "}
	for _, fwt := range cases {
		t.Run(fwt, func(t *testing.T) {
			_, err := TargetRecordedPrior(fwt)
			if err == nil {
				t.Fatalf("TargetRecordedPrior(%q) accepted unknown firewall type", fwt)
			}
			if !errors.Is(err, ErrUnknownFirewallType) {
				t.Errorf("TargetRecordedPrior(%q) returned wrong error class: %v", fwt, err)
			}
		})
	}
}

// TestTargetPanelNative_ValidPanels verifies construction succeeds for every
// non-PanelNone PanelType currently defined.
func TestTargetPanelNative_ValidPanels(t *testing.T) {
	cases := []detect.PanelType{
		detect.PanelDirectAdmin,
		detect.PanelCPanel,
		detect.PanelPlesk,
		detect.PanelCyberPanel,
		detect.PanelHestia,
		detect.PanelVesta,
		detect.PanelCWP,
	}
	for _, p := range cases {
		t.Run(string(p), func(t *testing.T) {
			ta, err := TargetPanelNative(p)
			if err != nil {
				t.Fatalf("TargetPanelNative(%q) returned error: %v", p, err)
			}
			if ta.Kind() != TargetAuthorityKindPanelNative {
				t.Errorf("Kind() = %q; want %q", ta.Kind(), TargetAuthorityKindPanelNative)
			}
			if ta.Panel() != p {
				t.Errorf("Panel() = %q; want %q", ta.Panel(), p)
			}
			// §18.3 payload invariant: firewallType is empty for PanelNative.
			if ta.FirewallType() != "" {
				t.Errorf("FirewallType() = %q; want empty (§18.3 invariant)", ta.FirewallType())
			}
		})
	}
}

// TestTargetPanelNative_RejectsPanelNone verifies the §18.2 rejection rule.
func TestTargetPanelNative_RejectsPanelNone(t *testing.T) {
	_, err := TargetPanelNative(detect.PanelNone)
	if err == nil {
		t.Fatalf("TargetPanelNative(PanelNone) accepted; want error")
	}
	if !errors.Is(err, ErrPanelNoneForPanelNative) {
		t.Errorf("TargetPanelNative(PanelNone) wrong error class: %v", err)
	}
}

// TestTargetAuthority_ImmutabilityByTypeDesign verifies that no exported API
// allows post-construction mutation. This is a structural assertion compiled
// at test time: if a future change adds an exported mutator, this test
// stays intact (mutators won't appear in the read-only-accessor set), but
// the contract review (§17.3 INV-PR25-AUTHORITY-IMMUTABILITY) catches it.
//
// At test time we exercise the read-only accessors and confirm the value is
// unchanged after each call.
func TestTargetAuthority_ImmutabilityByTypeDesign(t *testing.T) {
	ta, err := TargetRecordedPrior("ufw")
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	before := ta

	// Exercise every exported accessor.
	_ = ta.Kind()
	_ = ta.FirewallType()
	_ = ta.Panel()

	if ta != before {
		t.Errorf("read-only accessors mutated value: before=%#v after=%#v", before, ta)
	}
}

// TestKnownFirewallTypes_MatchesContract pins the §18.2 set content.
// If the contract changes the set, this test fails — and the change is
// caught at PR review time, not at runtime.
func TestKnownFirewallTypes_MatchesContract(t *testing.T) {
	want := map[string]struct{}{
		"ufw":       {},
		"firewalld": {},
		"iptables":  {},
		"csf":       {},
	}
	if len(knownFirewallTypes) != len(want) {
		t.Fatalf("knownFirewallTypes size = %d; contract §18.2 specifies %d", len(knownFirewallTypes), len(want))
	}
	for k := range want {
		if _, ok := knownFirewallTypes[k]; !ok {
			t.Errorf("knownFirewallTypes missing %q (per contract §18.2)", k)
		}
	}
}

// TestMustBeKnownKind_PanicsOnUnknown verifies the panic helper does what
// §18.4 says it must — panic on a default branch — and is restricted to
// internal use (per guardrail 3).
func TestMustBeKnownKind_PanicsOnUnknown(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("mustBeKnownKind did not panic on unknown kind")
		}
	}()
	mustBeKnownKind(TargetAuthorityKind("not_a_valid_kind"))
}
