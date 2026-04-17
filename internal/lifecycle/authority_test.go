// =============================================================================
// NFTBan v1.97 - Authority Model Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-authority-test"
// meta:type="test"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Tests for authority resolution logic"
// meta:inventory.files="internal/lifecycle/authority_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package lifecycle

import "testing"

// Test 1: NONE → NFTBAN (fresh install)
func TestResolveAuthorityFreshInstall(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityNone, Health: HealthDown}
	desired := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	resulting, action, err := ResolveAuthority(prior, desired, Detection{SSHSafe: true}, false)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if action != ActionTakeAuthority {
		t.Errorf("action = %s; want TAKE_AUTHORITY", action)
	}
	if resulting.Owner != AuthorityNFTBan {
		t.Errorf("resulting.owner = %s; want NFTBAN", resulting.Owner)
	}
}

// Test 2: NFTBAN + PROTECTED → NFTBAN (update, preserve)
func TestResolveAuthorityPreserve(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	desired := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	resulting, action, err := ResolveAuthority(prior, desired, Detection{SSHSafe: true}, false)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if action != ActionPreserveAuthority {
		t.Errorf("action = %s; want PRESERVE_AUTHORITY", action)
	}
	if resulting.Owner != AuthorityNFTBan {
		t.Errorf("resulting.owner = %s; want NFTBAN", resulting.Owner)
	}
}

// Test 3: NFTBAN + DEGRADED → still owned (INV-LC-004)
func TestResolveAuthorityDegradedStillOwned(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityNFTBan, Health: HealthDegraded}
	desired := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	resulting, action, err := ResolveAuthority(prior, desired, Detection{SSHSafe: true}, false)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if action != ActionPreserveAuthority {
		t.Errorf("action = %s; want PRESERVE_AUTHORITY (degraded is still owned)", action)
	}
	if resulting.Owner != AuthorityNFTBan {
		t.Errorf("resulting.owner = %s; want NFTBAN", resulting.Owner)
	}
}

// Test 4: EXTERNAL → NFTBAN without force → ABORT
func TestResolveAuthorityExternalNoForce(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityExternal, Health: HealthProtected}
	desired := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	_, action, err := ResolveAuthority(prior, desired, Detection{SSHSafe: true}, false)

	if err == nil {
		t.Error("expected error for external authority without force")
	}
	if action != ActionAbort {
		t.Errorf("action = %s; want ABORT", action)
	}
}

// Test 5: EXTERNAL → NFTBAN with force → TAKE_AUTHORITY
func TestResolveAuthorityExternalWithForce(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityExternal, Health: HealthProtected}
	desired := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	resulting, action, err := ResolveAuthority(prior, desired, Detection{SSHSafe: true}, true)

	if err != nil {
		t.Fatalf("unexpected error with force: %v", err)
	}
	if action != ActionTakeAuthority {
		t.Errorf("action = %s; want TAKE_AUTHORITY (forced)", action)
	}
	if resulting.Owner != AuthorityNFTBan {
		t.Errorf("resulting.owner = %s; want NFTBAN", resulting.Owner)
	}
}

// Test 6: NFTBAN + DOWN → NEEDS_RECOVERY
func TestResolveAuthorityNFTBanDown(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityNFTBan, Health: HealthDown}
	desired := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	_, action, err := ResolveAuthority(prior, desired, Detection{SSHSafe: true}, false)

	if err == nil {
		t.Error("expected error for DOWN authority")
	}
	if action != ActionNeedsRecovery {
		t.Errorf("action = %s; want NEEDS_RECOVERY", action)
	}
}

// Test 7: Conflicting firewall → ABORT
func TestResolveAuthorityConflict(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityNone, Health: HealthDown}
	desired := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	_, action, err := ResolveAuthority(prior, desired, Detection{ConflictingFirewall: true}, false)

	if err == nil {
		t.Error("expected error for conflicting firewall")
	}
	if action != ActionAbort {
		t.Errorf("action = %s; want ABORT", action)
	}
}

// Test 8: Uninstall (NFTBAN → NONE)
func TestResolveAuthorityUninstall(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	desired := AuthorityState{Owner: AuthorityNone, Health: HealthDown}

	resulting, action, err := ResolveAuthority(prior, desired, Detection{SSHSafe: true}, false)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if action != ActionTakeAuthority {
		t.Errorf("action = %s; want TAKE_AUTHORITY (release)", action)
	}
	if resulting.Owner != AuthorityNone {
		t.Errorf("resulting.owner = %s; want NONE", resulting.Owner)
	}
}

// Test 9: CanProceed
func TestCanProceed(t *testing.T) {
	tests := []struct {
		action Action
		want   bool
	}{
		{ActionTakeAuthority, true},
		{ActionPreserveAuthority, true},
		{ActionNoop, true},
		{ActionAbort, false},
		{ActionNeedsRecovery, false},
	}
	for _, tt := range tests {
		if got := CanProceed(tt.action); got != tt.want {
			t.Errorf("CanProceed(%s) = %v; want %v", tt.action, got, tt.want)
		}
	}
}

// Test 10: TransitionDescription
func TestTransitionDescription(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityNone, Health: HealthDown}
	resulting := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	desc := TransitionDescription(prior, resulting, ActionTakeAuthority)
	if desc == "" {
		t.Error("description should not be empty")
	}

	desc2 := TransitionDescription(prior, prior, ActionAbort)
	if desc2 == "" {
		t.Error("abort description should not be empty")
	}
}

// Test 11: NONE + PROTECTED gets normalized to NONE + DOWN
func TestResolveAuthorityNoneNormalized(t *testing.T) {
	prior := AuthorityState{Owner: AuthorityNone, Health: HealthProtected}
	desired := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	_, action, _ := ResolveAuthority(prior, desired, Detection{SSHSafe: true}, false)

	// After normalization, NONE+PROTECTED → NONE+DOWN, then TAKE_AUTHORITY
	if action != ActionTakeAuthority {
		t.Errorf("action = %s; want TAKE_AUTHORITY (NONE normalized to DOWN)", action)
	}
}
