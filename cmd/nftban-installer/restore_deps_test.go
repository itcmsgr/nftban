// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-25 — Restore Stub-Deps tests (commit 4)
// =============================================================================
// meta:name="nftban-installer-restore-deps-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-27"
// meta:description="Tests for the production stub-dep struct methods + the newProductionRestoreDeps factory + the package-level newRestoreDeps default. Confirms every stub method returns ErrRestoreExecutionUnavailable and that no real mutation surface exists in commit 4."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/restore"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"context"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/restore"
)

// =============================================================================
// 1. Every stub method returns ErrRestoreExecutionUnavailable.
// =============================================================================

func TestProductionPreflightDep_ReturnsUnavailable(t *testing.T) {
	d := &productionPreflightDep{}
	ok, err := d.PreflightTarget(context.Background(), "ufw")
	if ok {
		t.Errorf("PreflightTarget returned ok=true; stub must always refuse")
	}
	if !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("PreflightTarget err = %v; want ErrRestoreExecutionUnavailable", err)
	}
}

func TestProductionSafetyNetDep_BothMethodsReturnUnavailable(t *testing.T) {
	d := &productionSafetyNetDep{}
	if err := d.InsertEmergencySSH(context.Background()); !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("InsertEmergencySSH err = %v; want ErrRestoreExecutionUnavailable", err)
	}
	if err := d.RemoveEmergencySSH(context.Background()); !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("RemoveEmergencySSH err = %v; want ErrRestoreExecutionUnavailable", err)
	}
}

func TestProductionMutationDep_ReturnsUnavailable(t *testing.T) {
	d := &productionMutationDep{}
	if err := d.MutateToTarget(context.Background(), "csf"); !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("MutateToTarget err = %v; want ErrRestoreExecutionUnavailable", err)
	}
}

func TestProductionInlineVerifyDep_AllThreeMethodsReturnUnavailable(t *testing.T) {
	d := &productionInlineVerifyDep{}

	active, err := d.IsTargetFirewallActive(context.Background(), "ufw")
	if active {
		t.Errorf("IsTargetFirewallActive returned active=true; stub must refuse")
	}
	if !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("IsTargetFirewallActive err = %v; want ErrRestoreExecutionUnavailable", err)
	}

	auth, err := d.CurrentAuthorityClass(context.Background())
	if string(auth) != "" {
		t.Errorf("CurrentAuthorityClass returned %q; stub must return empty", auth)
	}
	if !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("CurrentAuthorityClass err = %v; want ErrRestoreExecutionUnavailable", err)
	}

	safe, err := d.IsSafetyNetRemovalSafe(context.Background())
	if safe {
		t.Errorf("IsSafetyNetRemovalSafe returned safe=true; stub must refuse")
	}
	if !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("IsSafetyNetRemovalSafe err = %v; want ErrRestoreExecutionUnavailable", err)
	}
}

// =============================================================================
// 2. Factory returns a complete ExecuteDeps with all four fields set.
// =============================================================================

func TestNewProductionRestoreDeps_AllFourFieldsSet(t *testing.T) {
	deps := newProductionRestoreDeps(nil, nil)
	if deps.Preflight == nil {
		t.Errorf("Preflight is nil")
	}
	if deps.SafetyNet == nil {
		t.Errorf("SafetyNet is nil")
	}
	if deps.Mutation == nil {
		t.Errorf("Mutation is nil")
	}
	if deps.InlineVerify == nil {
		t.Errorf("InlineVerify is nil")
	}
}

// =============================================================================
// 3. Default newRestoreDeps points at the production factory.
// =============================================================================

func TestNewRestoreDeps_DefaultIsProductionFactory(t *testing.T) {
	// We compare reflect-pointer addresses to confirm newRestoreDeps
	// is initialized to newProductionRestoreDeps. (Function values
	// are not directly comparable in Go beyond nil; use reflect.)
	got := reflect.ValueOf(newRestoreDeps).Pointer()
	want := reflect.ValueOf(newProductionRestoreDeps).Pointer()
	if got != want {
		t.Errorf("newRestoreDeps default does not point at newProductionRestoreDeps; tests may have leaked a swap")
	}
}

// =============================================================================
// 4. The factory's deps satisfy the restore-package interfaces at
//    compile time. (Smoke check: build the deps and assign each field
//    to its interface variable.)
// =============================================================================

func TestNewProductionRestoreDeps_InterfaceCompliance(t *testing.T) {
	deps := newProductionRestoreDeps(nil, nil)
	var _ restore.PreflightDep = deps.Preflight
	var _ restore.SafetyNetDep = deps.SafetyNet
	var _ restore.MutationDep = deps.Mutation
	var _ restore.InlineVerifyDep = deps.InlineVerify
}

// =============================================================================
// 5. ErrRestoreExecutionUnavailable carries an explicit "not implemented
//    in this commit" message so logs and operator output make the
//    placeholder nature obvious.
// =============================================================================

func TestErrRestoreExecutionUnavailable_MessageIsExplicit(t *testing.T) {
	msg := ErrRestoreExecutionUnavailable.Error()
	required := []string{
		"execution dependency",
		"not implemented",
	}
	for _, sub := range required {
		if !strings.Contains(msg, sub) {
			t.Errorf("ErrRestoreExecutionUnavailable message %q missing substring %q", msg, sub)
		}
	}
}

// =============================================================================
// 6. No real mutation surface in restore_deps.go — file-scan.
// =============================================================================

func TestRestoreDeps_NoMutationSurface_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps.go")
	if err != nil {
		t.Fatalf("read restore_deps.go: %v", err)
	}
	src := string(body)
	forbidden := []string{
		"os/exec",
		"exec.Command",
		"os.WriteFile",
		"os.Create",
		"os.Remove(",
		"os.Rename",
		"syscall.",
		`"nft "`,
		`"systemctl `,
		// Live re-detection — stubs must not classify or probe anything.
		"uninstall.Probe(",
		"uninstall.Classify(",
		"detect.DetectPanel(",
		// History writes
		"writeHistory(",
	}
	for _, pat := range forbidden {
		if strings.Contains(src, pat) {
			t.Errorf("restore_deps.go references forbidden pattern %q (stub must be inert in commit 4)", pat)
		}
	}
}
