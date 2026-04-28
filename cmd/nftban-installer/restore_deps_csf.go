// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-25 — CSF Restore Mutation (commit 4B-3-csf)
// =============================================================================
// meta:name="nftban-installer-restore-deps-csf"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="CSF-only inverse-of-install mutation per Amendment 1 §31 A.1-A.7 / §32 11-step ordering. Consumes priorRec + panel evidence wired by 4B-3-pre. Non-csf firewalls return typed unsupported sentinel; unknown firewallType returns typed unknown sentinel. A.7 (nftban kernel release) refuses with ErrCSFRestoreNftReleaseUnsafe whenever the safety-net-safe predicate is unavailable — 4B-4 wires the predicate."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect,github.com/itcmsgr/nftban/internal/installer/executor,github.com/itcmsgr/nftban/internal/installer/uninstall"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="csf.service,nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Authorization basis: Amendment 1 (§§30-36) appended to the PR-25
// contract on 2026-04-28. The amendment is CSF-only — it does NOT
// authorize inverse-of-install for ufw / firewalld / iptables.
//
// Amendment-1 §31 mutation table (A.1-A.7) and §32 11-step ordering
// are the normative source of truth for this file. The table is
// reproduced in comments on each step below; the spec governs.
//
// 4B-3 scope vs 4B-4:
//
//   - 4B-3-csf wires A.1-A.6 (CSF prerequisites, service start, nftband
//     stop) end-to-end against the executor abstraction.
//   - A.7 (`NftDeleteTable("ip", "nftban")` + `NftDeleteTable("ip6",
//     "nftban")`) is gated on the safety-net-safe predicate. The
//     predicate's wiring lives in 4B-4 (real inline-verify dep). In
//     4B-3-csf the predicate is unwired; A.7 always refuses with
//     ErrCSFRestoreNftReleaseUnsafe and the safety net is retained.
//
// Non-shipping after this commit: PR-25 still cannot land §28 real-host
// evidence — A.7 will not delete tables until 4B-4 lands.
//
// =============================================================================

package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// =============================================================================
// Path / unit constants — every path the §31 A-table references is
// defined here. No string literals scattered through the function body.
// =============================================================================

const (
	csfBinary         = "/usr/sbin/csf"
	csfBinaryDisabled = "/usr/sbin/csf.disabled"
	csfServiceUnit    = "csf.service"
	nftbandUnit       = "nftband.service"

	// csfCronPath / lfdCronPath are referenced by A.4 only. A.4
	// soft-skips in 4B-3-csf because §33 E.5's cron-backup manifest
	// is not yet produced by the install path. Both names live here
	// so when E.5 lands (separate installer-side amendment), A.4 can
	// flip from "soft-skip with warning" to "restore from manifest"
	// without scattering string literals.
	csfCronPath = "/etc/cron.d/csf-cron"
	lfdCronPath = "/etc/cron.d/lfd-cron"
)

// =============================================================================
// Sentinel errors — every refusal path returns a typed sentinel so the
// dispatcher's StateRestoreFailedExecution log + operator output
// distinguish the cause. Wrapped with %w semantics so errors.Is works.
// =============================================================================

var (
	// ErrCSFRestoreOnlyAuthorized is returned when MutateToTarget is
	// called with a known §18.2 firewall other than csf. Amendment 1
	// is CSF-only — ufw / firewalld / iptables remain unsupported
	// until separately amended.
	ErrCSFRestoreOnlyAuthorized = errors.New("restore mutation: amendment 1 authorizes csf only; this firewallType is in the §18.2 known set but not authorized for inverse-of-install")

	// ErrRestoreMutationUnknownFirewall is returned when MutateToTarget
	// is called with a firewallType outside the §18.2 known set.
	// Defensive guard — the planner should already have validated.
	ErrRestoreMutationUnknownFirewall = errors.New("restore mutation: firewallType is not in the §18.2 known set")

	// ErrCSFRestoreNilExecutor is returned when the dep is invoked
	// without an executor.
	ErrCSFRestoreNilExecutor = errors.New("restore csf: executor is nil")

	// ErrCSFRestoreEvidenceMissing is returned when neither E.1 (prior
	// record + FirewallType==csf) nor E.7 (PanelDirectAdmin) holds.
	// The dispatcher SHOULD route csf only on those two paths; reaching
	// this branch is an upstream invariant violation.
	ErrCSFRestoreEvidenceMissing = errors.New("restore csf: neither prior-record nor panel evidence authorizes csf restore")

	// ErrCSFRestoreCSFUninstalled is returned when E.3 finds neither
	// /usr/sbin/csf nor /usr/sbin/csf.disabled present. csf is fully
	// uninstalled; restore is impossible.
	ErrCSFRestoreCSFUninstalled = errors.New("restore csf: neither /usr/sbin/csf nor /usr/sbin/csf.disabled present — csf is uninstalled, restore impossible")

	// ErrCSFRestoreAmbiguousBinary is returned when E.3 finds BOTH
	// /usr/sbin/csf and /usr/sbin/csf.disabled present. Operator must
	// resolve manually — we will not pick one over the other (§31 A.3
	// "Refuse the entire restore if both /usr/sbin/csf and
	// /usr/sbin/csf.disabled are present").
	ErrCSFRestoreAmbiguousBinary = errors.New("restore csf: both /usr/sbin/csf and /usr/sbin/csf.disabled present — ambiguous, operator must resolve")

	// ErrCSFRestoreUnmaskFailed wraps a non-nil systemctl-unmask error.
	ErrCSFRestoreUnmaskFailed = errors.New("restore csf: A.1 ServiceUnmask(csf.service) failed")

	// ErrCSFRestoreEnableFailed wraps a non-nil ServiceEnable error.
	ErrCSFRestoreEnableFailed = errors.New("restore csf: A.2 ServiceEnable(csf.service) failed")

	// ErrCSFRestoreBinaryRestoreFailed wraps a non-nil rename error.
	ErrCSFRestoreBinaryRestoreFailed = errors.New("restore csf: A.3 binary restore (rename csf.disabled -> csf) failed")

	// ErrCSFRestoreServiceStartFailed wraps a non-nil ServiceStart error.
	ErrCSFRestoreServiceStartFailed = errors.New("restore csf: A.5 ServiceStart(csf.service) failed")

	// ErrCSFRestorePostStartInactive is returned when, after A.5
	// reports nil, ServiceActive(csf.service) is false. §32 step 5.
	ErrCSFRestorePostStartInactive = errors.New("restore csf: post-A.5 ServiceActive(csf.service) returned false")

	// ErrCSFRestoreServiceStopFailed wraps a non-nil ServiceStop error.
	ErrCSFRestoreServiceStopFailed = errors.New("restore csf: A.6 ServiceStop(nftband.service) failed")

	// ErrCSFRestoreNftReleaseUnsafe is returned by A.7 whenever the
	// safety-net-safe predicate is either unavailable (nil — the
	// 4B-3-csf default) or returns false / error. The host is left
	// with both csf running AND nftban tables present — non-success
	// but non-destructive. Operator must decide.
	ErrCSFRestoreNftReleaseUnsafe = errors.New("restore csf: A.7 nftban table release refused — safety-net-safe predicate unavailable or false (4B-3-csf intentionally leaves predicate unwired; 4B-4 lands the wiring)")
)

// knownNonCSFFirewalls is the set of §18.2 firewall types other than
// csf. MutateToTarget returns ErrCSFRestoreOnlyAuthorized for any of
// these. Member of an explicit allow-list (not a subtraction) so adding
// a new known firewall to §18.2 forces an explicit decision here.
var knownNonCSFFirewalls = map[string]bool{
	"ufw":       true,
	"firewalld": true,
	"iptables":  true,
}

// =============================================================================
// Small helpers — kept package-private and minimal. Each one corresponds
// to exactly one §31 / §32 concern.
// =============================================================================

// evidenceE1 holds: priorRec is non-nil AND FirewallType == "csf".
// E.1 alone is enough for the (a) branch of A.1's evidence gate; A.3
// also accepts (a) or PanelDirectAdmin (E.7).
func evidenceE1(m *productionMutationDep) bool {
	return m.priorRec != nil && m.priorRec.FirewallType == "csf"
}

// evidenceE7 holds: panel == PanelDirectAdmin (the only panel mapped
// by §20.1 / commit 3A's static mapping).
func evidenceE7(m *productionMutationDep) bool {
	return m.panel == detect.PanelDirectAdmin
}

// isCSFServiceMasked queries systemctl is-enabled to detect the
// "masked" state. systemctl prints "masked" on stdout when the unit
// is masked; we check the trimmed stdout exactly.
//
// Routes through the executor's Run abstraction — the call is
// recorded in MockExecutor.Commands so tests can pin the surface.
//
// is-enabled is read-only (does not mutate); routing through Run is
// purely so the call shows up in the exec-trace gate's audit.
func isCSFServiceMasked(exec executor.Executor) bool {
	res := exec.Run("systemctl", "is-enabled", csfServiceUnit)
	return strings.TrimSpace(res.Stdout) == "masked"
}

// unmaskCSFService runs systemctl unmask via the executor abstraction.
// The Executor interface does not expose a typed ServiceUnmask method
// (only ServiceMask). Routing the inverse through Run is the chosen
// in-scope option for 4B-3-csf — it stays inside cmd/ and uses the
// existing executor seam without expanding the interface mid-PR.
func unmaskCSFService(exec executor.Executor) error {
	res := exec.Run("systemctl", "unmask", csfServiceUnit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl unmask %s: %s", csfServiceUnit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

// renameAtomicViaExec performs an atomic rename via the executor's
// Run("mv", ...) — same-filesystem mv is atomic at the syscall level.
// The Executor interface does not expose a Rename method; routing
// through Run keeps the surface inside the executor abstraction. The
// direct stdlib rename API (in the os package) is forbidden by the
// file-scan and intentionally not used here.
func renameAtomicViaExec(exec executor.Executor, oldpath, newpath string) error {
	res := exec.Run("mv", oldpath, newpath)
	if res.ExitCode != 0 {
		return fmt.Errorf("mv %s -> %s: %s", oldpath, newpath, strings.TrimSpace(res.Stderr))
	}
	return nil
}

// =============================================================================
// mutateToCSFTarget — the §31/§32 entry point invoked by
// productionMutationDep.MutateToTarget when firewallType=="csf".
// =============================================================================
//
// Returns nil iff every authorized step succeeded or skipped per its
// precondition. On any failure returns a typed sentinel (errors.Is
// matchable) wrapped with the underlying call detail.
//
// Ordering follows §32 verbatim. Comments mark step boundaries.
//
// Safety-net handling: this function does NOT touch the safety net.
// restore.Execute (commit 3C) inserts the net before MutateToTarget
// is called, and decides on retention/removal based on (a) whether
// MutateToTarget returned nil and (b) the inline-verify result. On
// any error from this function, the caller's §32.1 table dictates
// retention.
func mutateToCSFTarget(ctx context.Context, m *productionMutationDep) error {
	if m == nil {
		return ErrCSFRestoreNilExecutor
	}
	if m.exec == nil {
		return ErrCSFRestoreNilExecutor
	}

	// =========================================================================
	// §32 step 1 — Preflight evidence collection.
	// =========================================================================
	//
	// E.1 / E.7: at least one of (prior-record-is-csf) and
	// (panel-is-DirectAdmin) MUST hold. The dispatcher routes csf
	// only on those two paths; if we got here without either,
	// upstream is broken.
	e1 := evidenceE1(m)
	e7 := evidenceE7(m)
	if !e1 && !e7 {
		if m.log != nil {
			m.log.Error("restore csf: refusing — neither E.1 (prior-record csf) nor E.7 (PanelDirectAdmin) holds")
		}
		return ErrCSFRestoreEvidenceMissing
	}

	// E.3: csf binary state. Three legal states:
	//   - only csf present       → ok, A.3 will skip
	//   - only csf.disabled      → ok, A.3 will rename
	//   - both present           → ambiguous, refuse
	//   - neither present        → uninstalled, refuse
	csfPresent := m.exec.FileExists(csfBinary)
	csfDisabledPresent := m.exec.FileExists(csfBinaryDisabled)

	if csfPresent && csfDisabledPresent {
		if m.log != nil {
			m.log.Error("restore csf: refusing at preflight — both %s and %s present (ambiguous; operator must resolve)",
				csfBinary, csfBinaryDisabled)
		}
		return ErrCSFRestoreAmbiguousBinary
	}
	if !csfPresent && !csfDisabledPresent {
		if m.log != nil {
			m.log.Error("restore csf: refusing at preflight — neither %s nor %s present (csf is uninstalled)",
				csfBinary, csfBinaryDisabled)
		}
		return ErrCSFRestoreCSFUninstalled
	}

	if m.log != nil {
		m.log.Info("restore csf: preflight evidence ok (e1=%v e7=%v csfPresent=%v csfDisabledPresent=%v)",
			e1, e7, csfPresent, csfDisabledPresent)
	}

	// =========================================================================
	// §32 step 3 — CSF prerequisite restoration (A.1, A.2, A.3, A.4).
	// =========================================================================
	//
	// (Step 2 — safety-net insertion — is performed by restore.Execute
	// before MutateToTarget is called. We do not touch the safety net
	// from inside this function.)
	//
	// A.1: ServiceUnmask("csf.service") — only if currently masked.
	if isCSFServiceMasked(m.exec) {
		if m.log != nil {
			m.log.Info("restore csf: A.1 unmasking %s", csfServiceUnit)
		}
		if err := unmaskCSFService(m.exec); err != nil {
			return fmt.Errorf("%w: %v", ErrCSFRestoreUnmaskFailed, err)
		}
	} else if m.log != nil {
		m.log.Info("restore csf: A.1 skip — %s not currently masked", csfServiceUnit)
	}

	// A.2: ServiceEnable("csf.service") — runs because we already
	// proved E.1 OR E.7 above (§31 A.2 evidence == A.1's, plus A.1
	// returned nil/skipped, which it did since we are still here).
	if m.log != nil {
		m.log.Info("restore csf: A.2 enabling %s", csfServiceUnit)
	}
	if err := m.exec.ServiceEnable(csfServiceUnit); err != nil {
		return fmt.Errorf("%w: %v", ErrCSFRestoreEnableFailed, err)
	}

	// A.3: Restore CSF binary (rename .disabled -> csf) only if
	// .disabled is present and csf is absent (E.3 disabled-only state).
	// (a) and (b) preconditions verified; (c) is E.1 OR E.7, already
	// proved. Ambiguous-and-uninstalled cases were refused above.
	if csfDisabledPresent && !csfPresent {
		if m.log != nil {
			m.log.Info("restore csf: A.3 renaming %s -> %s", csfBinaryDisabled, csfBinary)
		}
		if err := renameAtomicViaExec(m.exec, csfBinaryDisabled, csfBinary); err != nil {
			return fmt.Errorf("%w: %v", ErrCSFRestoreBinaryRestoreFailed, err)
		}
	} else if m.log != nil {
		m.log.Info("restore csf: A.3 skip — %s present, no rename needed", csfBinary)
	}

	// A.4: Cron restore — soft-skipped in 4B-3-csf because §33 E.5
	// (cron-backup manifest) is not produced by the current install
	// path. The amendment authorizes A.4 only when E.5 holds; it does
	// not, therefore A.4 is NOT executed. Operator-warning logged.
	//
	// When the installer-side prerequisite lands (separate amendment
	// to switchop.disarmCSFArtifacts to write a backup), this branch
	// flips from soft-skip to manifest-restore. csfCronPath and
	// lfdCronPath constants are defined above so the change is
	// localized.
	if m.log != nil {
		m.log.Warn("restore csf: A.4 soft-skip — cron-backup manifest (E.5) not produced by current install path; %s and %s NOT auto-restored. Operator must restore manually if needed.",
			csfCronPath, lfdCronPath)
	}

	// =========================================================================
	// §32 step 4 — A.5: ServiceStart("csf.service").
	// =========================================================================
	if m.log != nil {
		m.log.Info("restore csf: A.5 starting %s", csfServiceUnit)
	}
	if err := m.exec.ServiceStart(csfServiceUnit); err != nil {
		return fmt.Errorf("%w: %v", ErrCSFRestoreServiceStartFailed, err)
	}

	// =========================================================================
	// §32 step 5 — Post-start verification.
	// =========================================================================
	if !m.exec.ServiceActive(csfServiceUnit) {
		if m.log != nil {
			m.log.Error("restore csf: post-A.5 verification — ServiceActive(%s)=false; aborting", csfServiceUnit)
		}
		return ErrCSFRestorePostStartInactive
	}
	if m.log != nil {
		m.log.Info("restore csf: post-A.5 verification ok — ServiceActive(%s)=true", csfServiceUnit)
	}

	// =========================================================================
	// §32 step 6 — A.6: ServiceStop("nftband.service") — idempotent.
	// =========================================================================
	if m.exec.ServiceActive(nftbandUnit) {
		if m.log != nil {
			m.log.Info("restore csf: A.6 stopping %s", nftbandUnit)
		}
		if err := m.exec.ServiceStop(nftbandUnit); err != nil {
			return fmt.Errorf("%w: %v", ErrCSFRestoreServiceStopFailed, err)
		}
	} else if m.log != nil {
		m.log.Info("restore csf: A.6 skip — %s already inactive (idempotent)", nftbandUnit)
	}

	// =========================================================================
	// §32 step 7 — SSH-still-protected / safety-net-safe gate.
	// =========================================================================
	//
	// In 4B-3-csf the safety-net-safe predicate is unwired — 4B-4 lands
	// the wiring (a function that consults the inline-verify dep's
	// IsSafetyNetRemovalSafe method). Until then, the predicate is nil
	// and A.7 always refuses. Tests can inject a closure to exercise
	// the available/true branch.
	//
	// §32.1 retention table: refusal here yields StateRestoreFailedExecution
	// with safety-net retained (csf running, nftband stopped, nftban
	// tables present, emergency-SSH rule present — non-success but
	// non-destructive).
	if m.safetyNetRemovalSafeFn == nil {
		if m.log != nil {
			m.log.Warn("restore csf: A.7 refused — safety-net-safe predicate unwired in 4B-3-csf (4B-4 lands the wiring); nftban tables retained, safety-net retained")
		}
		return ErrCSFRestoreNftReleaseUnsafe
	}
	safe, err := m.safetyNetRemovalSafeFn(ctx)
	if err != nil {
		if m.log != nil {
			m.log.Warn("restore csf: A.7 refused — safety-net-safe predicate returned error: %v", err)
		}
		return fmt.Errorf("%w: %v", ErrCSFRestoreNftReleaseUnsafe, err)
	}
	if !safe {
		if m.log != nil {
			m.log.Warn("restore csf: A.7 refused — safety-net-safe predicate returned false")
		}
		return ErrCSFRestoreNftReleaseUnsafe
	}

	// =========================================================================
	// §32 step 8 — A.7: Release nftban kernel authority.
	// =========================================================================
	//
	// Only the two authoritative tables. No flush, no per-rule, no
	// per-set-element. NftDeleteTable is the entire-table-at-once
	// primitive (§34: "no nftban table flush").
	if m.log != nil {
		m.log.Info("restore csf: A.7 releasing nftban authority — NftDeleteTable ip:nftban + ip6:nftban")
	}
	if err := m.exec.NftDeleteTable("ip", "nftban"); err != nil {
		return fmt.Errorf("restore csf: A.7 NftDeleteTable ip:nftban failed: %v", err)
	}
	if err := m.exec.NftDeleteTable("ip6", "nftban"); err != nil {
		return fmt.Errorf("restore csf: A.7 NftDeleteTable ip6:nftban failed: %v", err)
	}

	if m.log != nil {
		m.log.Info("restore csf: mutateToCSFTarget completed; caller proceeds to inline-verify (§23.4)")
	}
	return nil
}
