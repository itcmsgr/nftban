// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-25 — Restore Execute Stub Deps (commit 4 only)
// =============================================================================
// meta:name="nftban-installer-restore-deps"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-27"
// meta:description="Stub implementations of the four restore.Execute dep interfaces. Each method returns ErrRestoreExecutionUnavailable. Real production deps are deferred to commit 4B; this commit only proves dispatcher integration."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/executor,github.com/itcmsgr/nftban/internal/installer/logging,github.com/itcmsgr/nftban/internal/installer/restore,github.com/itcmsgr/nftban/internal/installer/uninstall"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Scope (commit 4 only):
//
//   This file ships the dependency-injection seam that the dispatcher
//   uses to satisfy restore.ExecuteDeps. Every method on every
//   production*Dep struct is a STUB that returns
//   ErrRestoreExecutionUnavailable. No kernel call. No service call.
//   No filesystem mutation. No `nft`. No `systemctl`.
//
//   Commit 4's purpose is to prove that the dispatcher can:
//
//     - call PlanFromDecision on PROCEED
//     - construct ExecuteDeps from the executor
//     - call restore.Execute with those deps
//     - persist whatever terminal state Execute returns
//     - never write update-history success on the restore mode
//
//   Real production deps (real `nft` insert/remove of emergency-SSH,
//   real service start/stop, real classify, etc.) are commit-4B
//   scope. Until they land, the stub Preflight refuses with
//   ErrRestoreExecutionUnavailable, Execute short-circuits to
//   StateRestoreFailedExecution at Stage="preflight", and the
//   dispatcher persists that terminal truthfully.
//
//   This is NOT a real-host restore execution. PR-25 §28 evidence
//   work CANNOT cite commit 4 as proof that restoration mutated a
//   host. The first commit that produces such evidence is the one
//   that replaces these stubs (commit 4B).
//
// =============================================================================

package main

import (
	"context"
	"errors"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/restore"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// ErrRestoreExecutionUnavailable is the typed sentinel returned by
// every stub-dep method in this commit. It is distinct from the
// restore-package sentinels (ErrUnmappedPanel, ErrSafetyNetNilDep,
// etc.) so callers can tell "no real implementation exists yet" apart
// from "real implementation refused for a contract reason".
//
// Tests assert that this error reaches the persisted terminal — i.e.
// commit 4's PROCEED-path execution always lands at
// StateRestoreFailedExecution with this error in the chain.
var ErrRestoreExecutionUnavailable = errors.New("restore: execution dependency not implemented in this commit (commit 4 = dispatcher integration only; real deps land in commit 4B)")

// =============================================================================
// Production*Dep stubs — every method returns ErrRestoreExecutionUnavailable.
// =============================================================================

// productionPreflightDep implements restore.PreflightDep.
//
// Real implementation will check that the resolved firewall package
// is installed and the corresponding service unit exists. Commit 4
// stub refuses every call.
type productionPreflightDep struct {
	exec executor.Executor //nolint:unused // commit 4B will use this
	log  *logging.Logger   //nolint:unused // commit 4B will use this
}

func (p *productionPreflightDep) PreflightTarget(_ context.Context, firewallType string) (bool, error) {
	if p.log != nil {
		p.log.Info("restore exec stub: PreflightTarget(%q) refusing — commit 4 stub", firewallType)
	}
	return false, ErrRestoreExecutionUnavailable
}

// productionSafetyNetDep implements restore.SafetyNetDep.
type productionSafetyNetDep struct {
	exec executor.Executor //nolint:unused
	log  *logging.Logger   //nolint:unused
}

func (s *productionSafetyNetDep) InsertEmergencySSH(_ context.Context) error {
	if s.log != nil {
		s.log.Info("restore exec stub: InsertEmergencySSH refusing — commit 4 stub")
	}
	return ErrRestoreExecutionUnavailable
}

func (s *productionSafetyNetDep) RemoveEmergencySSH(_ context.Context) error {
	if s.log != nil {
		s.log.Info("restore exec stub: RemoveEmergencySSH refusing — commit 4 stub")
	}
	return ErrRestoreExecutionUnavailable
}

// productionMutationDep implements restore.MutationDep.
type productionMutationDep struct {
	exec executor.Executor //nolint:unused
	log  *logging.Logger   //nolint:unused
}

func (m *productionMutationDep) MutateToTarget(_ context.Context, firewallType string) error {
	if m.log != nil {
		m.log.Info("restore exec stub: MutateToTarget(%q) refusing — commit 4 stub", firewallType)
	}
	return ErrRestoreExecutionUnavailable
}

// productionInlineVerifyDep implements restore.InlineVerifyDep.
type productionInlineVerifyDep struct {
	exec executor.Executor //nolint:unused
	log  *logging.Logger   //nolint:unused
}

func (v *productionInlineVerifyDep) IsTargetFirewallActive(_ context.Context, firewallType string) (bool, error) {
	if v.log != nil {
		v.log.Info("restore exec stub: IsTargetFirewallActive(%q) refusing — commit 4 stub", firewallType)
	}
	return false, ErrRestoreExecutionUnavailable
}

func (v *productionInlineVerifyDep) CurrentAuthorityClass(_ context.Context) (uninstall.CurrentAuthority, error) {
	if v.log != nil {
		v.log.Info("restore exec stub: CurrentAuthorityClass refusing — commit 4 stub")
	}
	return uninstall.CurrentAuthority(""), ErrRestoreExecutionUnavailable
}

func (v *productionInlineVerifyDep) IsSafetyNetRemovalSafe(_ context.Context) (bool, error) {
	if v.log != nil {
		v.log.Info("restore exec stub: IsSafetyNetRemovalSafe refusing — commit 4 stub")
	}
	return false, ErrRestoreExecutionUnavailable
}

// =============================================================================
// Factory — used by the dispatcher to construct the stub set, and by
// tests to swap in fakes via the package-level newRestoreDeps var.
// =============================================================================

// newProductionRestoreDeps returns the four-tuple of production stub
// deps wired around the given executor + logger. Commit 4's dispatcher
// uses this. Tests swap newRestoreDeps (below) to inject fakes.
func newProductionRestoreDeps(exec executor.Executor, log *logging.Logger) restore.ExecuteDeps {
	return restore.ExecuteDeps{
		Preflight:    &productionPreflightDep{exec: exec, log: log},
		SafetyNet:    &productionSafetyNetDep{exec: exec, log: log},
		Mutation:     &productionMutationDep{exec: exec, log: log},
		InlineVerify: &productionInlineVerifyDep{exec: exec, log: log},
	}
}

// newRestoreDeps is the dispatcher's deps-factory hook. Production
// callers reach the stubs above; tests overwrite this var with a
// fixture factory before calling runRestoreDecide. This is the only
// approved test-time injection point for commit 4.
//
// Restoring this to its zero (production) value at end of test is the
// caller's responsibility (defer pattern).
var newRestoreDeps = newProductionRestoreDeps
