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
	"os"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/render"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
)

// fileModeFromUint32 converts a uint32 mode bitfield (as recorded in
// the cron-backup manifest) back into os.FileMode. Local helper —
// keeps the os import scoped to this single conversion. PR-26-code-C2.
func fileModeFromUint32(m uint32) os.FileMode {
	return os.FileMode(m)
}

// =============================================================================
// Path / unit constants — every path the §31 A-table references is
// defined here. No string literals scattered through the function body.
// =============================================================================

const (
	csfBinary         = "/usr/sbin/csf"
	csfBinaryDisabled = "/usr/sbin/csf.disabled"
	csfServiceUnit    = "csf.service"
	nftbandUnit       = "nftband.service"
	// v1.148 (delta 2.1): the daemon's socket re-activation vector. Stopping
	// nftband.service alone is insufficient — nftband.socket (Requires/After +
	// Restart=on-failure) re-activates the daemon, which recreates ip/ip6 nftban
	// tables seconds after restore. The disarm must stop AND disable it.
	nftbandSocketUnit = "nftband.socket"

	// csfCronPath / lfdCronPath are referenced by A.4 only. A.4
	// soft-skips in 4B-3-csf because §33 E.5's cron-backup manifest
	// is not yet produced by the install path. Both names live here
	// so when E.5 lands (separate installer-side amendment), A.4 can
	// flip from "soft-skip with warning" to "restore from manifest"
	// without scattering string literals.
	csfCronPath = "/etc/cron.d/csf-cron"
	lfdCronPath = "/etc/cron.d/lfd-cron"
)

// nftbanTableTouchingTimers are the nftban timers that reconcile/recreate the
// ip/ip6 nftban tables. The restore disarm (A.6b, v1.148, delta 2.1,
// SELECT_V148_5C = socket-plus-table-touching-timers) stops them so a
// post-restore timer pass cannot re-apply nftban firewall state. This is the
// table-touching subset only — NOT all ~21 nftban timers.
var nftbanTableTouchingTimers = []string{
	"nftban-rebuild-recovery.timer",
	"nftban-maintenance.timer",
}

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

	// ErrCSFRestoreCronManifestCorrupt is returned by A.4 as a HARD
	// refusal when the §42.2 manifest is present but cannot be
	// trusted: parse failure, schema mismatch, unknown-entry path,
	// or per-entry sha256 mismatch. Per the auditor verdict on
	// PR-26-code-C: when NFTBan has restore evidence on disk but
	// cannot trust it, proceeding to A.5 (start csf.service) would
	// weaken the evidence chain. A.4 stops before A.5, the safety
	// net is retained by the existing Execute failure path, and the
	// operator must inspect.
	//
	// Manifest ABSENT (no manifest.json at all) is the migration-gap
	// case for pre-PR-26 hosts; that path remains a soft-skip and
	// continues to A.5. Only manifest-present-but-untrusted is hard.
	//
	// PR-26-code-C2 addition (semantics revised on auditor pass —
	// originally soft-skip, now hard-refusal).
	ErrCSFRestoreCronManifestCorrupt = errors.New("restore csf: A.4 cron-backup manifest is corrupt or unrecognized — refusing before A.5 (operator must inspect)")

	// ErrCSFRestoreCronTargetExists is returned by A.4 as a HARD
	// refusal when a manifest entry's target /etc/cron.d/<name> is
	// already present on disk at restore time. The operator may have
	// re-created a different version of the cron file post-takeover;
	// A.4 must NOT overwrite operator content. Per the auditor verdict
	// this is treated as an evidence-conflict case — restoration is
	// stopped before A.5 and the operator must reconcile manually.
	// PR-26-code-C2 addition (semantics revised on auditor pass).
	ErrCSFRestoreCronTargetExists = errors.New("restore csf: A.4 target /etc/cron.d/<name> already present — refusing before A.5 (operator-content collision; manual reconcile required)")

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

// (PR-26-code-B / §43.2 lock — the prior unmaskCSFService and
// renameAtomicViaExec helper functions are removed. Both routed
// through the raw `Run("systemctl","unmask",…)` and `Run("mv",…)`
// indirections that PR-26-code-B closes by promoting the operations
// to typed `executor.ServiceUnmask` and `executor.Rename` methods.
// The §31 A.1 + A.3 call sites in mutateToCSFTarget call those typed
// methods directly — no thin wrapper is needed.)

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
		if err := m.exec.ServiceUnmask(csfServiceUnit); err != nil {
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
		if err := m.exec.Rename(csfBinaryDisabled, csfBinary); err != nil {
			return fmt.Errorf("%w: %v", ErrCSFRestoreBinaryRestoreFailed, err)
		}
	} else if m.log != nil {
		m.log.Info("restore csf: A.3 skip — %s present, no rename needed", csfBinary)
	}

	// A.4: Cron restore from manifest (PR-26-code-C2 / §42.2 lock,
	// auditor-revised semantics — corrupt manifest is HARD refusal).
	//
	// Branches:
	//
	//   - Manifest ABSENT (pre-PR-26 host): graceful soft-skip with
	//     an operator warning. A.4 does not act; control falls
	//     through to A.5. This is the migration-gap path.
	//   - Manifest present but UNTRUSTED (parse failure / schema
	//     mismatch / unknown-entry / per-entry sha256 mismatch):
	//     return ErrCSFRestoreCronManifestCorrupt — A.5 does NOT
	//     run, the existing §32 step-3 failure path retains the
	//     safety net, and the operator must inspect. Proceeding to
	//     start csf.service while restore evidence is on disk but
	//     untrusted would weaken the evidence chain (auditor
	//     verdict on PR-26-code-C).
	//   - Target ALREADY exists on disk (operator-content collision):
	//     return ErrCSFRestoreCronTargetExists. Same hard-refusal
	//     semantics as corrupt-manifest — A.4 must not overwrite
	//     operator content, and the surrounding evidence-conflict
	//     warrants stopping before A.5.
	//   - Manifest present + integrity-clean + targets absent: for
	//     each entry, restore the content via exec.WriteFileAtomic
	//     (preserves mode) + exec.Chown (preserves uid/gid). Then
	//     fall through to A.5.
	//
	// Absolutely no:
	//   - template regeneration (only restore-from-backup, never
	//     synthesize content)
	//   - writes outside the two §42.2-locked target paths
	//   - DirectAdmin custombuild rewrites
	//   - cron files that NFTBan did not back up itself
	manifest, manifestPresent, manifestErr := switchop.ReadCronBackupManifest(m.exec, m.log)
	switch {
	case manifestErr != nil:
		if m.log != nil {
			m.log.Error("restore csf: A.4 manifest untrusted: %v — refusing before A.5", manifestErr)
		}
		return fmt.Errorf("%w: %v", ErrCSFRestoreCronManifestCorrupt, manifestErr)

	case !manifestPresent:
		if m.log != nil {
			m.log.Warn("restore csf: A.4 soft-skip — cron-backup manifest absent (pre-PR-26 host); %s and %s NOT auto-restored",
				csfCronPath, lfdCronPath)
		}

	default:
		a4Restored := 0
		for _, entry := range manifest.Files {
			// Defense-in-depth: only the two §42.2-locked paths.
			// (The reader already rejects unknown-entry manifests;
			// this is belt-and-braces.)
			if entry.Path != csfCronPath && entry.Path != lfdCronPath {
				if m.log != nil {
					m.log.Error("restore csf: A.4 manifest entry has unauthorized path %q — refusing before A.5", entry.Path)
				}
				return fmt.Errorf("%w: unauthorized entry path %q", ErrCSFRestoreCronManifestCorrupt, entry.Path)
			}
			// Verify sha256 integrity against the on-disk backup.
			// Mismatch is HARD refusal — restore evidence on disk
			// is untrusted; do not start csf with bad evidence.
			content, vErr := switchop.VerifyCronBackupEntry(m.exec, entry)
			if vErr != nil {
				if m.log != nil {
					m.log.Error("restore csf: A.4 sha256 verify failed for %s: %v — refusing before A.5", entry.Path, vErr)
				}
				return fmt.Errorf("%w: %v", ErrCSFRestoreCronManifestCorrupt, vErr)
			}
			// Operator-content collision: target already exists.
			// HARD refuse — A.4 must not overwrite operator content
			// and the conflict warrants stopping before A.5.
			if m.exec.FileExists(entry.Path) {
				if m.log != nil {
					m.log.Error("restore csf: A.4 target %s already present — refusing before A.5 (operator-content collision)", entry.Path)
				}
				return fmt.Errorf("%w: %s", ErrCSFRestoreCronTargetExists, entry.Path)
			}
			// Restore: WriteFileAtomic preserves mode; Chown
			// applies uid/gid for fidelity.
			if err := m.exec.WriteFileAtomic(entry.Path, content, fileModeFromUint32(entry.Mode)); err != nil {
				if m.log != nil {
					m.log.Error("restore csf: A.4 WriteFileAtomic(%s) failed: %v — refusing before A.5", entry.Path, err)
				}
				return fmt.Errorf("%w: WriteFileAtomic(%s): %v", ErrCSFRestoreCronManifestCorrupt, entry.Path, err)
			}
			if err := m.exec.Chown(entry.Path, entry.UID, entry.GID); err != nil {
				if m.log != nil {
					m.log.Warn("restore csf: A.4 Chown(%s, %d, %d) failed: %v — content restored but ownership may be wrong",
						entry.Path, entry.UID, entry.GID, err)
				}
			}
			a4Restored++
			if m.log != nil {
				m.log.Info("restore csf: A.4 restored %s from manifest (sha256=%s, mode=%o, uid=%d, gid=%d)",
					entry.Path, entry.SHA256, entry.Mode, entry.UID, entry.GID)
			}
		}
		if m.log != nil {
			m.log.Info("restore csf: A.4 manifest-restore complete (restored=%d)", a4Restored)
		}
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
	// §32 step 6b — A.6b: full boot-persistent disarm via MASK (v1.148, delta 2.1).
	// `disable` is NOT a valid restore-disarm primitive here — every unit is
	// pulled back by design (reboot-proven):
	//   - nftband.service: TriggeredBy=nftband.socket AND RequiredBy=
	//     nftban-unified-exporter.service → restarts on boot via the exporter even
	//     when disabled.
	//   - nftband.socket: re-activates the daemon.
	//   - nftban-maintenance.timer: "Always Active", self-healed (re-enabled) by
	//     the installer core-timer auto-fix; its reconcile recreates the tables.
	//   - nftban-rebuild-recovery.timer: table-recreation timer.
	// MASK blocks start by ANY path (socket trigger, Requires=, manual, self-heal)
	// and survives reboot. Restore-specific override of the intentional
	// always-active/socket-activation design: SELECT_V148_RESTORE_MASK_DAEMON_UNITS
	// + SELECT_V148_RESTORE_MASK_TABLE_TIMERS = yes. install/update/reinstall
	// unmask + re-enable normally; cmd/nftband daemon code is untouched; only these
	// four nftban units are masked (NOT all timers, NOT nftables.service).
	// =========================================================================
	maskUnits := append([]string{nftbandUnit, nftbandSocketUnit}, nftbanTableTouchingTimers...)
	for _, u := range maskUnits {
		if m.exec.ServiceActive(u) {
			if m.log != nil {
				m.log.Info("restore csf: A.6b stopping %s", u)
			}
			if err := m.exec.ServiceStop(u); err != nil && m.log != nil {
				m.log.Warn("restore csf: A.6b could not stop %s (non-fatal): %v", u, err)
			}
		}
		if err := m.exec.ServiceMask(u); err != nil {
			if m.log != nil {
				m.log.Warn("restore csf: A.6b could not mask %s (non-fatal): %v", u, err)
			}
		} else if m.log != nil {
			m.log.Info("restore csf: A.6b masked %s (blocks re-activation by socket/Requires/self-heal across reboot)", u)
		}
	}

	// =========================================================================
	// §32 step 6c — A.6c: Shape-B boot-include disarm (v1.148, delta 2.1,
	// SELECT_V148_RESTORE_SHAPE_B_INCLUDE_DISARM=yes). Even with the daemon +
	// socket + timers disabled, nftables.service still `nft -f`-loads
	// /etc/nftban/nftables.conf via the v1.146 Shape-B include in the distro
	// nftables.conf, recreating ip/ip6 nftban tables on the next boot. Restore
	// strips that include (restore-specific reversal of Shape-B persistence — NOT
	// a general rollback; install/update keep Shape-B). Idempotent + backed up;
	// /etc/nftban/nftables.conf itself is never deleted. Both distro paths are
	// attempted (Debian /etc/nftables.conf, EL /etc/sysconfig/nftables.conf);
	// each is a no-op when the include is absent. Non-fatal (the service-level
	// disarm above already succeeded).
	// =========================================================================
	for _, p := range []string{"/etc/nftables.conf", "/etc/sysconfig/nftables.conf"} {
		if err := render.DisarmSystemConf(m.exec, p, m.log); err != nil && m.log != nil {
			m.log.Warn("restore csf: A.6c could not disarm Shape-B include in %s (non-fatal): %v", p, err)
		}
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
