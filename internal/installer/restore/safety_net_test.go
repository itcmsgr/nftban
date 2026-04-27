// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Safety-net primitives tests (PR-25 §23.2 / §23.5 / §21.3)
// =============================================================================
// meta:name="restore_safety_net_test"
// meta:type="test"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 3B safety-net tests: insert calls only the emergency-SSH path, remove guarded by verifiedSafe boolean (§21.3), no broader firewall behavior, dependency-injected so tests use a fake (no kernel/systemd/filesystem mutation)."
// meta:depends=""
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
	"context"
	"errors"
	"strings"
	"testing"
)

// fakeSafetyNetDep is a test double for SafetyNetDep. Records calls
// for ordering / count assertions and surfaces injected errors.
type fakeSafetyNetDep struct {
	insertCalls int
	removeCalls int
	insertErr   error
	removeErr   error
	// Order is appended to in call order so tests can check the call
	// sequence without relying on counts alone.
	order []string
}

func (f *fakeSafetyNetDep) InsertEmergencySSH(_ context.Context) error {
	f.insertCalls++
	f.order = append(f.order, "insert")
	return f.insertErr
}

func (f *fakeSafetyNetDep) RemoveEmergencySSH(_ context.Context) error {
	f.removeCalls++
	f.order = append(f.order, "remove")
	return f.removeErr
}

// =============================================================================
// 1. Insert: happy path calls dep exactly once, no other side effects
// =============================================================================

func TestInsertSafetyNet_HappyPath(t *testing.T) {
	dep := &fakeSafetyNetDep{}
	if err := InsertSafetyNet(context.Background(), dep); err != nil {
		t.Fatalf("InsertSafetyNet returned error: %v", err)
	}
	if dep.insertCalls != 1 {
		t.Errorf("insertCalls = %d; want 1", dep.insertCalls)
	}
	if dep.removeCalls != 0 {
		t.Errorf("InsertSafetyNet leaked into removal: removeCalls = %d", dep.removeCalls)
	}
}

// =============================================================================
// 2. Insert: nil dep refuses without calling anything
// =============================================================================

func TestInsertSafetyNet_NilDep(t *testing.T) {
	err := InsertSafetyNet(context.Background(), nil)
	if err == nil {
		t.Fatalf("InsertSafetyNet accepted nil dep; want error")
	}
	if !errors.Is(err, ErrSafetyNetNilDep) {
		t.Errorf("wrong error class for nil dep: %v", err)
	}
}

// =============================================================================
// 3. Insert: dep error is wrapped as ErrSafetyNetInsertFailed
// =============================================================================

func TestInsertSafetyNet_DepError_Wrapped(t *testing.T) {
	depErr := errors.New("simulated kernel failure")
	dep := &fakeSafetyNetDep{insertErr: depErr}
	err := InsertSafetyNet(context.Background(), dep)
	if err == nil {
		t.Fatalf("InsertSafetyNet swallowed dep error")
	}
	if !errors.Is(err, ErrSafetyNetInsertFailed) {
		t.Errorf("wrong error class: %v", err)
	}
	if !strings.Contains(err.Error(), "simulated kernel failure") {
		t.Errorf("dep error not surfaced in message: %v", err)
	}
	if dep.removeCalls != 0 {
		t.Errorf("Insert failure must not call Remove: removeCalls = %d", dep.removeCalls)
	}
}

// =============================================================================
// 4. Remove: refused unless verifiedSafe == true (§21.3)
// =============================================================================

func TestRemoveSafetyNet_RefusedWhenNotVerified(t *testing.T) {
	dep := &fakeSafetyNetDep{}
	err := RemoveSafetyNet(context.Background(), dep, false)
	if err == nil {
		t.Fatalf("RemoveSafetyNet accepted verifiedSafe=false; want refusal")
	}
	if !errors.Is(err, ErrSafetyNetRemoveBeforeVerification) {
		t.Errorf("wrong error class: %v", err)
	}
	// CRITICAL: dep must not have been called at all on the refusal path.
	if dep.removeCalls != 0 {
		t.Errorf("RemoveSafetyNet called dep on refusal path: removeCalls = %d (§21.3 hard invariant violation)",
			dep.removeCalls)
	}
	if dep.insertCalls != 0 {
		t.Errorf("RemoveSafetyNet leaked into insert path: insertCalls = %d", dep.insertCalls)
	}
}

// =============================================================================
// 5. Remove: verifiedSafe=true calls dep exactly once
// =============================================================================

func TestRemoveSafetyNet_HappyPath(t *testing.T) {
	dep := &fakeSafetyNetDep{}
	if err := RemoveSafetyNet(context.Background(), dep, true); err != nil {
		t.Fatalf("RemoveSafetyNet returned error: %v", err)
	}
	if dep.removeCalls != 1 {
		t.Errorf("removeCalls = %d; want 1", dep.removeCalls)
	}
	if dep.insertCalls != 0 {
		t.Errorf("RemoveSafetyNet leaked into insert: insertCalls = %d", dep.insertCalls)
	}
}

// =============================================================================
// 6. Remove: nil dep refuses
// =============================================================================

func TestRemoveSafetyNet_NilDep(t *testing.T) {
	err := RemoveSafetyNet(context.Background(), nil, true)
	if err == nil {
		t.Fatalf("RemoveSafetyNet accepted nil dep; want error")
	}
	if !errors.Is(err, ErrSafetyNetNilDep) {
		t.Errorf("wrong error class for nil dep: %v", err)
	}
}

// =============================================================================
// 7. Remove: dep error is wrapped as ErrSafetyNetRemoveFailed
// =============================================================================

func TestRemoveSafetyNet_DepError_Wrapped(t *testing.T) {
	depErr := errors.New("simulated rule-not-found")
	dep := &fakeSafetyNetDep{removeErr: depErr}
	err := RemoveSafetyNet(context.Background(), dep, true)
	if err == nil {
		t.Fatalf("RemoveSafetyNet swallowed dep error")
	}
	if !errors.Is(err, ErrSafetyNetRemoveFailed) {
		t.Errorf("wrong error class: %v", err)
	}
	if !strings.Contains(err.Error(), "simulated rule-not-found") {
		t.Errorf("dep error not surfaced: %v", err)
	}
}

// =============================================================================
// 8. No broad-cleanup behavior: file-scan
// =============================================================================

func TestSafetyNet_NoBroadBehavior_FileScan(t *testing.T) {
	// Forbidden patterns in safety_net.go content. These cover the
	// broad-cleanup / fix-all / fallback / panic-without-discipline
	// behaviors the locked rules forbid for primitives.
	forbidden := []string{
		"os/exec",
		"exec.Command",
		"os.WriteFile",
		"os.Create",
		"os.Remove(", // filesystem remove (substring guarded with paren)
		"os.Rename",
		"syscall.",
		`"nft "`,        // shell-out fragment
		`"systemctl `,   // service manipulation
		"systemctl ",    // any inline service text
		"enable",        // forbidden broad behavior verbs
		"disable",
		"mask",
		"unmask",
		"purge",
		"force-delete",
		"fix all",
		"fallback",
		"best effort",
		"best-effort",
	}
	body, err := readSelf("safety_net.go")
	if err != nil {
		t.Fatalf("read safety_net.go: %v", err)
	}
	for _, pat := range forbidden {
		if strings.Contains(body, pat) {
			t.Errorf("safety_net.go references forbidden pattern %q (broad-behavior / mutation surface)", pat)
		}
	}
}

// (No host-mutation file-scan on the test file itself: that test would
// be circular — listing forbidden patterns as string literals would
// make the file match its own forbidden list. The production-code
// file-scan in TestSafetyNet_NoBroadBehavior_FileScan above is the
// real enforcement; tests in this file use the fake exclusively, by
// construction.)
