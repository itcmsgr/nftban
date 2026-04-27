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

// productionPreflightDep implements restore.PreflightDep with a
// read-only verification of the resolved firewall's runtime presence.
//
// Per PR-25 contract §23.1: preflight refusal is non-mutating. This
// implementation calls only `CommandExists(binary)` and
// `FileExists(unit-path)` on the executor. It does NOT call
// `ServiceActive`, `ServiceStart`, `Run`, or any nft / systemctl
// mutation primitive. It does NOT consult any state outside the
// firewallType argument.
//
// Verifies, for the resolved firewallType:
//   - At least one canonical binary is present in PATH.
//   - At least one canonical service unit file is present at one of
//     the standard systemd-unit locations (/usr/lib/systemd/system,
//     /lib/systemd/system, /etc/systemd/system).
//
// The "at least one of N canonical paths" check is distro-aware
// lookup, NOT fallback: the unit-file location for the SAME
// firewall varies by distro (e.g. RHEL ships in /usr/lib/, Debian
// in /lib/). Per §20.3 this is not a fallback to a different
// firewall — it's the canonical paths for the requested firewall.
type productionPreflightDep struct {
	exec executor.Executor
	log  *logging.Logger
}

// preflightFirewallPresence describes the canonical binary and
// service-unit search paths for each known firewallType (the §18.2
// set: ufw / firewalld / iptables / csf).
//
// Adding a firewall to this map requires repo-backed authority and
// matching installer code in 4B-3 (mutation dep). Until 4B-3 lands,
// preflight may approve targets that 4B-3's mutation cannot serve;
// per the audit at the end of commit 4, that mismatch is acceptable
// because mutation will refuse with its own typed error and the
// safety net is already in place. Mismatch detection itself is a
// 4B-3 / 4B-5 concern.
type preflightFirewallPresence struct {
	binaries  []string // OR-list — at least one must be in PATH
	unitFiles []string // OR-list — at least one path must exist
}

var preflightKnownFirewalls = map[string]preflightFirewallPresence{
	"ufw": {
		binaries: []string{"ufw"},
		unitFiles: []string{
			"/usr/lib/systemd/system/ufw.service",
			"/lib/systemd/system/ufw.service",
			"/etc/systemd/system/ufw.service",
		},
	},
	"firewalld": {
		// firewall-cmd is the universal CLI shipped with firewalld.
		// The daemon binary is "firewalld" but operators interact
		// via firewall-cmd; either being present is acceptable.
		binaries: []string{"firewall-cmd", "firewalld"},
		unitFiles: []string{
			"/usr/lib/systemd/system/firewalld.service",
			"/lib/systemd/system/firewalld.service",
			"/etc/systemd/system/firewalld.service",
		},
	},
	"iptables": {
		binaries: []string{"iptables"},
		// Distro-aware: RHEL/Fedora ship iptables.service;
		// Debian/Ubuntu ship netfilter-persistent.service for
		// rule persistence on top of iptables.
		unitFiles: []string{
			"/usr/lib/systemd/system/iptables.service",
			"/lib/systemd/system/iptables.service",
			"/lib/systemd/system/netfilter-persistent.service",
			"/usr/lib/systemd/system/netfilter-persistent.service",
			"/etc/systemd/system/iptables.service",
			"/etc/systemd/system/netfilter-persistent.service",
		},
	},
	"csf": {
		binaries: []string{"csf"},
		// CSF typically installs to /etc/systemd/system; some
		// distro packagings ship to /usr/lib/. Both are valid.
		unitFiles: []string{
			"/etc/systemd/system/csf.service",
			"/lib/systemd/system/csf.service",
			"/usr/lib/systemd/system/csf.service",
		},
	},
}

// Sentinel errors returned by productionPreflightDep. Distinct from
// ErrRestoreExecutionUnavailable so consumers can tell "the binary
// isn't installed" apart from "the dep isn't implemented yet".
var (
	// ErrPreflightUnknownFirewall is returned when firewallType is
	// not a member of preflightKnownFirewalls. The planner should
	// have already validated firewallType against the §18.2 known
	// set; reaching this branch indicates an upstream invariant
	// violation. Defensive guard.
	ErrPreflightUnknownFirewall = errors.New("restore preflight: firewallType is not in the known set")

	// ErrPreflightBinaryMissing is returned when none of the
	// canonical binary names for the firewall are present in PATH.
	ErrPreflightBinaryMissing = errors.New("restore preflight: no canonical binary present in PATH")

	// ErrPreflightUnitMissing is returned when none of the canonical
	// service-unit file paths exist.
	ErrPreflightUnitMissing = errors.New("restore preflight: no canonical systemd unit file present")

	// ErrPreflightNilExecutor is returned when the dep was
	// constructed without a usable executor. Defensive guard.
	ErrPreflightNilExecutor = errors.New("restore preflight: executor is nil")
)

func (p *productionPreflightDep) PreflightTarget(_ context.Context, firewallType string) (bool, error) {
	if p.exec == nil {
		return false, ErrPreflightNilExecutor
	}

	presence, ok := preflightKnownFirewalls[firewallType]
	if !ok {
		if p.log != nil {
			p.log.Info("restore preflight: refusing unknown firewallType=%q", firewallType)
		}
		return false, ErrPreflightUnknownFirewall
	}

	// Check binaries (OR-list — at least one must be in PATH).
	var binaryFound string
	for _, name := range presence.binaries {
		if p.exec.CommandExists(name) {
			binaryFound = name
			break
		}
	}
	if binaryFound == "" {
		if p.log != nil {
			p.log.Info("restore preflight: refusing firewallType=%q — no canonical binary in PATH (looked for %v)",
				firewallType, presence.binaries)
		}
		return false, ErrPreflightBinaryMissing
	}

	// Check unit files (OR-list — at least one path must exist).
	var unitFound string
	for _, path := range presence.unitFiles {
		if p.exec.FileExists(path) {
			unitFound = path
			break
		}
	}
	if unitFound == "" {
		if p.log != nil {
			p.log.Info("restore preflight: refusing firewallType=%q — no canonical service unit (looked at %v)",
				firewallType, presence.unitFiles)
		}
		return false, ErrPreflightUnitMissing
	}

	if p.log != nil {
		p.log.Info("restore preflight: firewallType=%q present (binary=%s unit=%s)",
			firewallType, binaryFound, unitFound)
	}
	return true, nil
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
