// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-25 — Restore Execute Production Deps
// =============================================================================
// meta:name="nftban-installer-restore-deps"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-27"
// meta:description="Production implementations of restore.ExecuteDeps. Preflight (4B-1, read-only presence), SafetyNet (4B-2, emergency-SSH via switchop), Mutation (4B-3-csf, csf inverse-of-install per Amendment 1), InlineVerify (4B-4, three §21.1 assertions). The mutation dep's safetyNetRemovalSafeFn is wired to the inline-verify dep so A.7 nftban release runs only when post-mutation SSH is observable outside the emergency table."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect,github.com/itcmsgr/nftban/internal/installer/executor,github.com/itcmsgr/nftban/internal/installer/logging,github.com/itcmsgr/nftban/internal/installer/restore,github.com/itcmsgr/nftban/internal/installer/switchop,github.com/itcmsgr/nftban/internal/installer/uninstall"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="csf.service,nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Commit progression (recorded for traceability):
//
//   - 4   :       dispatcher integration with stub deps
//   - 4B-1:       productionPreflightDep real (read-only presence check)
//   - 4B-2:       productionSafetyNetDep real (emergency-SSH allow via switchop)
//   - 4B-3-pre:   productionMutationDep gains read-only evidence fields
//                 (priorRec, panel) plumbed by the dispatcher
//   - 4B-3-csf:   productionMutationDep real for firewallType=="csf" using the
//                 plumbed evidence; non-csf typed-unsupported; A.7 gated on
//                 a safetyNetRemovalSafeFn predicate that 4B-3-csf left nil
//   - 4B-4:       productionInlineVerifyDep real (three §21.1 assertions);
//                 productionMutationDep.safetyNetRemovalSafeFn wired in the
//                 production factory to call inlineVerify.IsSafetyNetRemovalSafe
//
// As of 4B-4, all four deps are production-real. PR-25 is code-complete
// pending §28 lab2/lab4 real-host evidence (commit 5).
//
// =============================================================================

package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/restore"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// =============================================================================
// Production deps — all four are real as of commit 4B-4.
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

// Sentinel errors returned by productionPreflightDep.
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
		// Amendment 2 §54: for CSF-only restore-to-CSF, accept the
		// install-time-disabled binary `/usr/sbin/csf.disabled` as an
		// acceptable restorable candidate. The Amendment-2 orphan
		// evidence chain proves NFTBan disabled CSF by renaming
		// /usr/sbin/csf → /usr/sbin/csf.disabled at install-time
		// (switchop.DisableConflicts step 4, Amendment 1 §31 A.3).
		// §32 A.3 later performs the authoritative rename back.
		// Preflight remains read-only and only verifies that a
		// restorable candidate is present; it does NOT mutate or
		// rename here. The .disabled relaxation is CSF-only — ufw,
		// firewalld, and iptables retain the strict in-PATH check
		// per Amendment 1 §30.2 (CSF-only inverse-of-install scope).
		if firewallType == "csf" && p.exec.FileExists("/usr/sbin/csf.disabled") {
			if p.log != nil {
				p.log.Info("restore preflight: firewallType=%q canonical binary absent from PATH but /usr/sbin/csf.disabled present — accepting (Amendment 2 §54 / restore-to-CSF)",
					firewallType)
			}
			binaryFound = "/usr/sbin/csf.disabled"
		} else {
			if p.log != nil {
				p.log.Info("restore preflight: refusing firewallType=%q — no canonical binary in PATH (looked for %v)",
					firewallType, presence.binaries)
			}
			return false, ErrPreflightBinaryMissing
		}
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

// productionSafetyNetDep implements restore.SafetyNetDep with the
// emergency-SSH allow rule from internal/installer/switchop. The
// rule is the SAME safety net used by the install transition path:
//
//   - Dedicated `inet` table named "nftban_install_emergency" (covers
//     IPv4 AND IPv6 in a single table — explicit dual-stack support).
//   - Single chain `input` with hook input, priority -1 (evaluated
//     before nftban chains at priority 0).
//   - Single rule `tcp dport <ssh_port> accept`.
//   - Policy `accept` (fail-open — safety net, not security boundary).
//
// SSH port is determined via detect.SSHPort, which uses the §38
// approved priority chain (ss listener → sshd_config → state file →
// nftban.conf.local). If no source yields a port, Insert refuses with
// ErrSafetyNetSSHPortUnknown — there is NO fallback to port 22 or
// any other hardcoded default.
//
// Per PR-25 contract §23.2 / §23.5 / §21.3:
//
//   - Insert mutates kernel ONLY for the emergency-SSH allow rule.
//   - Remove deletes ONLY the emergency table (which contains only
//     the safety-net rule). nftban / nftban6 production tables are
//     untouched in both Insert and Remove.
//   - Insert is idempotent: a stale emergency table from a prior
//     run is deleted-then-recreated. Production tables are not
//     consulted.
//   - No service start/stop/enable/disable/mask.
//   - No file writes outside /tmp/.nftban-emergency-ssh.nft (used by
//     switchop and removed via defer in the same call).
//
// Verified by behavior tests using MockExecutor.
type productionSafetyNetDep struct {
	exec executor.Executor
	log  *logging.Logger

	// sshPortFn returns the SSH port to protect with the safety net.
	// In production, set by newProductionRestoreDeps to a closure that
	// calls detect.SSHPort(exec, log). Tests inject a fixed-port
	// closure to avoid mocking the full detect chain.
	//
	// If sshPortFn is nil, InsertEmergencySSH refuses with
	// ErrSafetyNetSSHPortUnknown.
	sshPortFn func() (int, error)
}

// emergencySafetyNetTable mirrors the unexported emergencyTable
// const in internal/installer/switchop/sshguard.go:30. Documented
// here so a future change to switchop's name forces matching update
// (catch via TestSafetyNetDep_4B2_Insert_TableNameMatchesSwitchop).
const emergencySafetyNetTable = "nftban_install_emergency"

// Sentinel errors specific to the production safety-net dep.
var (
	// ErrSafetyNetNilExecutorProd is returned when the dep was
	// constructed without an executor.
	ErrSafetyNetNilExecutorProd = errors.New("restore safety-net: executor is nil")

	// ErrSafetyNetSSHPortUnknown is returned when sshPortFn returns
	// an error or is nil. PR-25 contract: NO fallback to a hardcoded
	// SSH port. If the source-of-truth chain cannot determine the
	// port, the safety net refuses to mutate the kernel.
	ErrSafetyNetSSHPortUnknown = errors.New("restore safety-net: SSH port could not be determined; no fallback")

	// ErrSafetyNetInvalidSSHPort is returned when the resolved port
	// is outside the legal TCP port range.
	ErrSafetyNetInvalidSSHPort = errors.New("restore safety-net: SSH port outside legal TCP range (1-65535)")

	// ErrSafetyNetSwitchopFailed wraps a non-nil error returned by
	// switchop.InjectEmergencySSH.
	ErrSafetyNetSwitchopFailed = errors.New("restore safety-net: switchop.InjectEmergencySSH failed")

	// ErrSafetyNetRemoveCallFailed is returned when the post-removal
	// verify check finds the emergency table still present.
	ErrSafetyNetRemoveCallFailed = errors.New("restore safety-net: emergency table still present after removal")
)

// InsertEmergencySSH inserts the emergency-SSH allow rule into the
// kernel. Calls switchop.InjectEmergencySSH after resolving the SSH
// port via sshPortFn.
//
// Mutations performed (all via switchop.InjectEmergencySSH):
//
//   - If a stale emergency-table is present, the emergency table
//     itself (and ONLY that table) is removed (idempotent reset).
//     No production tables are touched.
//   - The emergency-rule config is written via the executor's
//     atomic-file API to a /tmp path.
//   - The kernel loads the rule via the executor's nft loader.
//   - The /tmp file is removed via defer.
//
// Mutations NOT performed:
//
//   - No edit to nftban / nftban6 production tables.
//   - No service start/stop/enable/disable/mask.
//   - No edit to blacklist / whitelist sets.
//   - No DaemonReload.
//   - No file writes outside /tmp/.nftban-emergency-ssh.nft.
func (s *productionSafetyNetDep) InsertEmergencySSH(_ context.Context) error {
	if s.exec == nil {
		return ErrSafetyNetNilExecutorProd
	}
	if s.sshPortFn == nil {
		return ErrSafetyNetSSHPortUnknown
	}

	sshPort, err := s.sshPortFn()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrSafetyNetSSHPortUnknown, err)
	}
	if sshPort < 1 || sshPort > 65535 {
		return fmt.Errorf("%w: got %d", ErrSafetyNetInvalidSSHPort, sshPort)
	}

	if s.log != nil {
		s.log.Info("restore safety-net: injecting emergency SSH allow rule (port %d)", sshPort)
	}

	if err := switchop.InjectEmergencySSH(s.exec, sshPort, s.log); err != nil {
		return fmt.Errorf("%w: %v", ErrSafetyNetSwitchopFailed, err)
	}
	return nil
}

// RemoveEmergencySSH removes the emergency-SSH allow rule by deleting
// the entire emergency table (which contains nothing else). Idempotent:
// no-op if the table is already gone.
//
// Mutations performed:
//
//   - The emergency-table itself (and ONLY that table) is deleted
//     via switchop.RemoveEmergencySSH if present.
//
// Mutations NOT performed:
//
//   - No touch to nftban / nftban6 / any other table.
//   - No service operations.
//   - No file operations.
//
// Returns ErrSafetyNetRemoveCallFailed if the post-removal
// NftTableExists check still reports the table present (i.e. the
// underlying delete did not take effect).
func (s *productionSafetyNetDep) RemoveEmergencySSH(_ context.Context) error {
	if s.exec == nil {
		return ErrSafetyNetNilExecutorProd
	}

	// Idempotent: if not present, nothing to do.
	if !s.exec.NftTableExists("inet", emergencySafetyNetTable) {
		if s.log != nil {
			s.log.Info("restore safety-net: emergency table absent; nothing to remove")
		}
		return nil
	}

	switchop.RemoveEmergencySSH(s.exec, s.log)

	// Verify-after-removal: switchop.RemoveEmergencySSH is fire-and-
	// forget (logs warnings, doesn't return error). We re-check that
	// the table is actually gone so the dep returns a typed error if
	// removal silently failed.
	if s.exec.NftTableExists("inet", emergencySafetyNetTable) {
		return ErrSafetyNetRemoveCallFailed
	}
	return nil
}

// productionMutationDep implements restore.MutationDep.
//
// 4B-3-pre extended this struct with read-only evidence fields
// (priorRec, panel) plumbed from the dispatcher. 4B-3-csf consumes
// them for the §31 A.1–A.7 evidence gates (E.1, E.2, E.7) on the
// CSF restore path.
//
// Fields are populated at dep construction time via
// newProductionRestoreDepsWithEvidence and are read-only thereafter
// — INV-PR25-AUTHORITY-IMMUTABILITY (§17.3) requires that no
// mid-flight mutation re-resolves authority or evidence.
//
// 4B-4 will wire safetyNetRemovalSafeFn to the inline-verify dep's
// IsSafetyNetRemovalSafe method (§32 step 7 / §31 A.7 precondition
// (c)). In 4B-3-csf the field is left nil by the production factory
// — A.7 (nftban kernel release) refuses with
// ErrCSFRestoreNftReleaseUnsafe. Tests inject a closure to exercise
// the available/true branch.
type productionMutationDep struct {
	exec executor.Executor
	log  *logging.Logger

	// priorRec is the prior-authority record from PR-24's Probe step,
	// passed forward by the dispatcher. May be nil — the planner
	// reaches PROCEED on some paths (G3.3 NoRecord+PanelAuto) without
	// a record. The mutation dep MUST treat nil as "evidence E.1 / E.2
	// absent" rather than re-probing.
	priorRec *uninstall.PriorRecord

	// panel is the panel type detected by PR-24's DetectPanel call,
	// passed forward by the dispatcher. May be detect.PanelNone for
	// non-PanelNative paths. The mutation dep MUST NOT call
	// detect.DetectPanel — INV-PR25-AUTHORITY-IMMUTABILITY (§17.3)
	// + §33 E.7 forbid re-validation.
	panel detect.PanelType

	// safetyNetRemovalSafeFn is the §32 step 7 / §31 A.7 precondition
	// (c) gate: returns true iff SSH connectivity is observable on the
	// post-mutation ruleset OUTSIDE the emergency rule. 4B-3-csf
	// leaves this nil (the production factory does not set it); 4B-4
	// will wire it to the inline-verify dep's IsSafetyNetRemovalSafe
	// method. Tests can inject a closure to exercise A.7.
	//
	// When nil OR returns (false, _) OR returns (_, err): A.7 refuses
	// with ErrCSFRestoreNftReleaseUnsafe and the safety net is
	// retained per §32.1.
	safetyNetRemovalSafeFn func(context.Context) (bool, error)
}

// MutateToTarget dispatches on firewallType per Amendment 1 §30:
//
//   - "csf"        → mutateToCSFTarget (real implementation, §31 A.1-A.7)
//   - "ufw" / "firewalld" / "iptables"
//                  → ErrCSFRestoreOnlyAuthorized (§30.2 — known §18.2
//                    members, but Amendment 1 authorizes csf only)
//   - anything else → ErrRestoreMutationUnknownFirewall (defensive guard;
//                    planner should already have rejected)
//
// Per the contract, this function is invoked only after restore.Execute
// has called Preflight + InsertSafetyNet. The safety net is in place
// throughout this call.
func (m *productionMutationDep) MutateToTarget(ctx context.Context, firewallType string) error {
	switch firewallType {
	case "csf":
		if m.log != nil {
			m.log.Info("restore mutation: dispatching csf path (Amendment 1 §31)")
		}
		return mutateToCSFTarget(ctx, m)
	default:
		if knownNonCSFFirewalls[firewallType] {
			if m.log != nil {
				m.log.Info("restore mutation: refusing %q — known firewall but Amendment 1 authorizes csf only", firewallType)
			}
			return ErrCSFRestoreOnlyAuthorized
		}
		if m.log != nil {
			m.log.Error("restore mutation: refusing unknown firewallType=%q (not in §18.2 known set)", firewallType)
		}
		return ErrRestoreMutationUnknownFirewall
	}
}

// =============================================================================
// productionInlineVerifyDep — real implementation (commit 4B-4)
// =============================================================================
//
// Implements the three §21.1 minimum-sufficient assertions:
//
//   1. IsTargetFirewallActive — read-only ServiceActive query.
//   2. CurrentAuthorityClass  — fresh uninstall.Classify call (allowed
//                                 by §21.1 as a verification step; the
//                                 result is consumed by InlineVerify
//                                 ONLY — never fed back into the planner
//                                 or used to re-resolve TargetAuthority,
//                                 per INV-PR25-AUTHORITY-IMMUTABILITY).
//   3. IsSafetyNetRemovalSafe — read-only kernel/service evidence check
//                                 that SSH protection exists outside
//                                 the emergency table.
//
// The dep mutates nothing. It does NOT call uninstall.Probe,
// detect.DetectPanel, or restore.Decide. Its CLI use is bounded to the
// existing executor abstraction.
//
// Amendment 1 §30 scope: only csf is authorized for restore. Methods
// that take a firewallType argument therefore accept "csf" only —
// other §18.2 firewalls return ErrInlineVerifyOnlyCSFAuthorized;
// firewalls outside the §18.2 known set return
// ErrInlineVerifyUnknownFirewall.
type productionInlineVerifyDep struct {
	exec executor.Executor
	log  *logging.Logger

	// firewallType is the resolved §18.2 target the planner committed
	// to. Plumbed by the production factory from the dispatcher's
	// already-resolved TargetAuthority — never re-derived here, per
	// INV-PR25-AUTHORITY-IMMUTABILITY (§17.3). Required for a real
	// production deps invocation; empty value is a defensive guard.
	//
	// PR-26-code-A introduced this field to back the §51.3 Option B
	// target-specific safety-net-safe predicate.
	firewallType string
}

// inlineVerifyKnownFirewallServices is the §18.2 known-set, mapped to
// the canonical service unit each firewall manages. Mirrors
// preflightKnownFirewalls but holds only the unit name (the inline
// verify check is run-state, not file-presence).
var inlineVerifyKnownFirewallServices = map[string]string{
	"ufw":       "ufw.service",
	"firewalld": "firewalld.service",
	"iptables":  "iptables.service",
	"csf":       "csf.service",
}

// (PR-26-code-A — §51.3 Option B): the previous
// `inlineVerifyExternalFirewallServices` list (any of csf / ufw /
// firewalld / iptables / netfilter-persistent active was sufficient)
// is REMOVED. The safety-net-safe predicate is now target-specific:
// it consults inlineVerifyKnownFirewallServices[v.firewallType] to
// derive the unit and gates exclusively on that unit's ServiceActive
// state. A non-target external firewall being active no longer
// satisfies CSF restore safety — that was the §41 looseness that
// PR-26-code-A tightens.
//
// Sentinel errors for the productionInlineVerifyDep.
var (
	// ErrInlineVerifyNilExecutor is returned when the dep was
	// constructed without an executor.
	ErrInlineVerifyNilExecutor = errors.New("restore inline-verify: executor is nil")

	// ErrInlineVerifyOnlyCSFAuthorized is the typed unsupported sentinel
	// for the §18.2 known firewalls other than csf. Mirror of
	// ErrCSFRestoreOnlyAuthorized on the mutation side — Amendment 1
	// authorizes csf only.
	ErrInlineVerifyOnlyCSFAuthorized = errors.New("restore inline-verify: amendment 1 authorizes csf only; this firewallType is in the §18.2 known set but inline verify is not yet authorized for it")

	// ErrInlineVerifyUnknownFirewall is returned when firewallType is
	// outside the §18.2 known set.
	ErrInlineVerifyUnknownFirewall = errors.New("restore inline-verify: firewallType is not in the §18.2 known set")

	// ErrInlineVerifyClassifyFailed is returned when uninstall.Classify
	// returned a nil result. Defensive guard — the production
	// implementation always returns a non-nil result, but the dep
	// guards in case future refactors break the invariant.
	ErrInlineVerifyClassifyFailed = errors.New("restore inline-verify: uninstall.Classify returned nil result")

	// ErrInlineVerifySSHPortUnknown is returned when detect.SSHPort
	// cannot resolve a port from any of its 4 sources. Per §21.1.3
	// "SSH connectivity remains observable" — if the port itself is
	// not observable, the predicate refuses (no fallback to assumption).
	ErrInlineVerifySSHPortUnknown = errors.New("restore inline-verify: SSH port could not be determined; safety-net removal is not safe")

	// ErrInlineVerifyTargetFirewallTypeMissing is returned when the
	// dep is invoked without a firewallType field set. Defensive guard
	// against a factory that constructs the dep without plumbing the
	// resolved target. PR-26-code-A.
	ErrInlineVerifyTargetFirewallTypeMissing = errors.New("restore inline-verify: target firewallType is empty; production factory must plumb the resolved target identity (§51.4)")

	// ErrInlineVerifyTargetMismatch is returned when the firewallType
	// passed to IsTargetFirewallActive differs from the
	// constructor-injected v.firewallType. Per §51.4 firewallType
	// plumbing, the dispatcher resolves the target ONCE; any mismatch
	// indicates an upstream invariant violation (e.g., a fake test
	// passing a value the production factory did not authorize).
	ErrInlineVerifyTargetMismatch = errors.New("restore inline-verify: caller-passed firewallType disagrees with constructor-injected target")

	// ErrInlineVerifyInvalidSSHPort is returned when the resolved port
	// is outside the legal TCP port range. Defensive guard.
	ErrInlineVerifyInvalidSSHPort = errors.New("restore inline-verify: SSH port outside legal TCP range (1-65535)")
)

// productionInlineVerifyDep struct fields — 4B-4 declared exec + log.
// PR-26-code-A adds firewallType: the resolved §18.2 target firewall
// the planner committed to. Plumbed by the production factory from
// the dispatcher's already-resolved TargetAuthority — never re-derived
// here, per INV-PR25-AUTHORITY-IMMUTABILITY (§17.3).
//
// firewallType is consumed by:
//   - IsTargetFirewallActive: cross-checked against the firewallType
//     argument the caller passes (defensive: must match the
//     constructor-injected value).
//   - IsSafetyNetRemovalSafe: replaces PR-25's any-external-FW
//     heuristic with a target-specific check. Per §51.3 Option B,
//     the predicate gates safety-net removal on the target's
//     specific service being active, not "any external firewall".
//
// firewallType MUST be non-empty for a real production deps
// invocation. Empty value is a defensive guard producing
// ErrInlineVerifyTargetFirewallTypeMissing.
//
// IsTargetFirewallActive — §21.1 assertion 1.
//
// Maps firewallType to its canonical service unit and returns
// ServiceActive(unit). Read-only. No process spawn beyond the
// underlying systemctl is-active query the executor's ServiceActive
// performs internally.
//
// Amendment 1 scope: csf only. ufw / firewalld / iptables return
// ErrInlineVerifyOnlyCSFAuthorized. Unknown firewallType returns
// ErrInlineVerifyUnknownFirewall. Both refusals are non-mutating.
func (v *productionInlineVerifyDep) IsTargetFirewallActive(_ context.Context, firewallType string) (bool, error) {
	if v.exec == nil {
		return false, ErrInlineVerifyNilExecutor
	}
	// PR-26-code-A: defensive cross-check — when the production factory
	// has plumbed v.firewallType, any caller-passed value MUST match.
	// Disagreement signals an upstream invariant violation
	// (INV-PR25-AUTHORITY-IMMUTABILITY §17.3). When v.firewallType is
	// empty (test fixtures that pre-date PR-26-code-A or fakes that
	// intentionally exercise the dispatch table), the check is skipped.
	if v.firewallType != "" && firewallType != v.firewallType {
		if v.log != nil {
			v.log.Error("restore inline-verify: caller-passed firewallType=%q disagrees with constructor-injected v.firewallType=%q",
				firewallType, v.firewallType)
		}
		return false, ErrInlineVerifyTargetMismatch
	}
	if firewallType == "csf" {
		active := v.exec.ServiceActive("csf.service")
		if v.log != nil {
			v.log.Info("restore inline-verify: assertion-1 ServiceActive(csf.service)=%v", active)
		}
		return active, nil
	}
	if _, ok := inlineVerifyKnownFirewallServices[firewallType]; ok {
		if v.log != nil {
			v.log.Info("restore inline-verify: refusing %q — known firewall but Amendment 1 authorizes csf only", firewallType)
		}
		return false, ErrInlineVerifyOnlyCSFAuthorized
	}
	if v.log != nil {
		v.log.Error("restore inline-verify: refusing unknown firewallType=%q (not in §18.2 known set)", firewallType)
	}
	return false, ErrInlineVerifyUnknownFirewall
}

// CurrentAuthorityClass — §21.1 assertion 2.
//
// Calls uninstall.Classify and returns its CurrentAuthority. The
// classifier itself is read-only (per its contract — only
// NftTableExists, ServiceActive, and FileExists probes). The result
// is consumed by InlineVerify ONLY: it is not fed back into the
// planner, not used to re-derive TargetAuthority, not compared
// against the original PR-24 decision. INV-PR25-AUTHORITY-IMMUTABILITY
// is preserved because the planner's TargetAuthority is already
// frozen by the time this method runs.
//
// uninstall.Probe, detect.DetectPanel, and restore.Decide are NOT
// called here.
func (v *productionInlineVerifyDep) CurrentAuthorityClass(_ context.Context) (uninstall.CurrentAuthority, error) {
	if v.exec == nil {
		return "", ErrInlineVerifyNilExecutor
	}
	res := uninstall.Classify(v.exec, v.log)
	if res == nil {
		return "", ErrInlineVerifyClassifyFailed
	}
	if v.log != nil {
		v.log.Info("restore inline-verify: assertion-2 CurrentAuthorityClass=%s ambiguity=%s",
			res.State, res.Ambiguity)
	}
	return res.State, nil
}

// IsSafetyNetRemovalSafe — §21.1 assertion 3, target-specific per
// §51.3 Option B.
//
// Returns true iff ALL of the following hold:
//
//   1. detect.SSHPort succeeds — proves sshd is observable on the
//      host (typically via `ss -tlnp` listener parse). Without an
//      observable port, the predicate refuses; there is NO fallback
//      to a hardcoded port.
//
//   2. The constructor-injected v.firewallType is non-empty AND in
//      the §18.2 known set AND equals "csf" (Amendment 1 §30.2 lock).
//      Defensive guards against an upstream factory that forgot to
//      plumb the resolved target.
//
//   3. The TARGET firewall's specific service unit (e.g.
//      csf.service for v.firewallType=="csf") is currently active —
//      derived via the inlineVerifyKnownFirewallServices map.
//
// PR-25's any-external-FW heuristic is REMOVED: a host where csf is
// inactive but ufw / firewalld / iptables happen to be active no
// longer satisfies CSF restore safety. The §41 looseness is closed.
//
// Per §51.3 Option B, exact CSF SSH-rule kernel evidence (the row 6
// "target firewall has loaded an SSH-allow rule" assertion) is
// **ADVISORY**, not BLOCKING; it is intentionally NOT checked here.
// Layered protection (sshd listener observable + csf.service active
// + downstream kernel/service evidence checked by Execute step 4)
// remains strong without iptables-legacy introspection. Any future
// upgrade to BLOCKING requires a contract amendment promoting Option A.
//
// All evidence comes from the executor abstraction (ServiceActive +
// the Run-based ss / sshd_config probes inside detect.SSHPort). No
// nft-list parsing, no CLI-truth dependency, no kernel mutation,
// no iptables introspection.
func (v *productionInlineVerifyDep) IsSafetyNetRemovalSafe(_ context.Context) (bool, error) {
	if v.exec == nil {
		return false, ErrInlineVerifyNilExecutor
	}

	port, err := detect.SSHPort(v.exec, v.log)
	if err != nil {
		if v.log != nil {
			v.log.Warn("restore inline-verify: assertion-3 refused — SSH port unknown: %v", err)
		}
		return false, fmt.Errorf("%w: %v", ErrInlineVerifySSHPortUnknown, err)
	}
	if port < 1 || port > 65535 {
		if v.log != nil {
			v.log.Warn("restore inline-verify: assertion-3 refused — SSH port out of range: %d", port)
		}
		return false, fmt.Errorf("%w: got %d", ErrInlineVerifyInvalidSSHPort, port)
	}

	if v.firewallType == "" {
		if v.log != nil {
			v.log.Error("restore inline-verify: assertion-3 refused — production factory did not plumb firewallType (§51.4 violation)")
		}
		return false, ErrInlineVerifyTargetFirewallTypeMissing
	}
	targetUnit, ok := inlineVerifyKnownFirewallServices[v.firewallType]
	if !ok {
		if v.log != nil {
			v.log.Error("restore inline-verify: assertion-3 refused — firewallType=%q is not in the §18.2 known set", v.firewallType)
		}
		return false, ErrInlineVerifyUnknownFirewall
	}
	if v.firewallType != "csf" {
		if v.log != nil {
			v.log.Info("restore inline-verify: assertion-3 refused — firewallType=%q is known but Amendment 1 authorizes csf only (§30.2)", v.firewallType)
		}
		return false, ErrInlineVerifyOnlyCSFAuthorized
	}

	if !v.exec.ServiceActive(targetUnit) {
		if v.log != nil {
			v.log.Warn("restore inline-verify: assertion-3 refused — target firewall %s not active (sshd port %d observable but target unit inactive); a non-target external firewall being active is no longer sufficient under §51.3 Option B",
				targetUnit, port)
		}
		return false, nil
	}

	if v.log != nil {
		v.log.Info("restore inline-verify: assertion-3 ok — target %s active (sshd port %d observable)",
			targetUnit, port)
	}
	return true, nil
}

// =============================================================================
// Factory — used by the dispatcher to construct the stub set, and by
// tests to swap in fakes via the package-level newRestoreDeps var.
// =============================================================================

// newProductionRestoreDeps returns the four-tuple of production deps
// wired around the given executor + logger, with NO evidence
// (priorRec=nil, panel=PanelNone, firewallType=""). Used in commit 4
// baseline only; 4B-3-pre introduced newProductionRestoreDepsWithEvidence
// which the dispatcher uses for the real flow, and PR-26-code-A
// extended its signature to also carry the resolved target firewallType.
//
// Commit progression:
//   - 4B-1: Preflight dep is real (read-only presence check)
//   - 4B-2: SafetyNet dep is real (emergency-SSH allow via switchop)
//   - 4B-3-pre: Mutation dep gains read-only evidence fields
//               (priorRec, panel). Method is STILL STUB.
//   - 4B-3-csf: Mutation dep becomes real for firewallType=="csf"
//               using the evidence wired by 4B-3-pre. Other targets
//               typed-unsupported.
//   - 4B-4: InlineVerify dep is real (any-external-FW heuristic).
//   - PR-26-code-A: InlineVerify safety predicate is target-specific
//               via newly-plumbed firewallType.
//
// Tests swap the package-level newRestoreDeps var to inject fakes.
func newProductionRestoreDeps(exec executor.Executor, log *logging.Logger) restore.ExecuteDeps {
	return newProductionRestoreDepsWithEvidence(exec, log, nil, detect.PanelNone, "")
}

// newProductionRestoreDepsWithEvidence is the evidence-aware
// production deps factory. The dispatcher uses this on the PROCEED
// path so the mutation dep receives the same priorRec + panel that
// the planner consumed, without re-probing or re-detecting.
//
// Per §33 E.7 + INV-PR25-AUTHORITY-IMMUTABILITY (§17.3): the dep
// MUST NOT re-derive these values; they are read-only inputs for
// 4B-3-csf's §31 A.1–A.7 evidence gates.
//
// 4B-4 wires the §32 step 7 / §31 A.7 precondition (c) safety-net-safe
// predicate. The mutation dep's safetyNetRemovalSafeFn closure points
// at the inline-verify dep's IsSafetyNetRemovalSafe method — meaning
// A.7 (nftban kernel release) now actually executes when the
// inline-verify says safe-to-remove.
//
// PR-26-code-A extends the signature to accept the dispatcher's
// resolved firewallType (§51.4 lock — `firewallType` plumbing, not
// precomputed `targetUnit`). The inline-verify dep stores this value
// and uses it for the target-specific safety-net-safe predicate
// (§51.3 Option B). The mutation dep's A.7 gate flows through the
// same inline-verify instance, so target-specificity propagates to
// A.7 automatically.
//
// Wiring order: InlineVerify is constructed first so the closure has
// a non-nil reference to capture. The same instance is then passed
// in ExecuteDeps.InlineVerify, so Execute step 4's verification call
// hits the same dep that the mutation dep's closure consults at A.7.
func newProductionRestoreDepsWithEvidence(
	exec executor.Executor,
	log *logging.Logger,
	priorRec *uninstall.PriorRecord,
	panel detect.PanelType,
	firewallType string,
) restore.ExecuteDeps {
	inlineVerify := &productionInlineVerifyDep{
		exec:         exec,
		log:          log,
		firewallType: firewallType,
	}

	return restore.ExecuteDeps{
		Preflight: &productionPreflightDep{exec: exec, log: log},
		SafetyNet: &productionSafetyNetDep{
			exec: exec,
			log:  log,
			sshPortFn: func() (int, error) {
				// detect.SSHPort is the §38 source-of-truth chain.
				// Returns error if no source yields a port; we
				// surface that error so the safety-net refuses to
				// mutate without a valid port.
				return detect.SSHPort(exec, log)
			},
		},
		Mutation: &productionMutationDep{
			exec:     exec,
			log:      log,
			priorRec: priorRec,
			panel:    panel,
			// 4B-4 wiring: A.7 consults the inline-verify dep's
			// IsSafetyNetRemovalSafe assertion. PR-26-code-A makes
			// that assertion target-specific via the firewallType
			// field carried inside the same inlineVerify instance —
			// A.7's gate is automatically target-aware.
			safetyNetRemovalSafeFn: func(ctx context.Context) (bool, error) {
				return inlineVerify.IsSafetyNetRemovalSafe(ctx)
			},
		},
		InlineVerify: inlineVerify,
	}
}

// restoreDepsFactory is the function shape the dispatcher calls to
// build deps. 4B-3-pre tightened the signature to require priorRec +
// panel; PR-26-code-A extends it once more to require the resolved
// firewallType (§51.4 plumbing lock). The dispatcher resolves
// firewallType from the planner-emitted TargetAuthority before
// calling this factory.
type restoreDepsFactory func(
	exec executor.Executor,
	log *logging.Logger,
	priorRec *uninstall.PriorRecord,
	panel detect.PanelType,
	firewallType string,
) restore.ExecuteDeps

// newRestoreDeps is the dispatcher's deps-factory hook. Production
// callers reach newProductionRestoreDepsWithEvidence; tests overwrite
// this var with a fixture factory.
//
// Restoring this to its zero (production) value at end of test is the
// caller's responsibility (defer / t.Cleanup pattern).
var newRestoreDeps restoreDepsFactory = newProductionRestoreDepsWithEvidence

// resolveFirewallTypeForDeps maps a planner-emitted TargetAuthority
// to the §18.2 firewallType identity the inline-verify dep stores.
//
// Per §51.4 lock: the dispatcher passes raw firewallType (not a
// precomputed targetUnit). The inline-verify dep maps firewallType
// → service unit at call time using inlineVerifyKnownFirewallServices,
// keeping the seam consistent with the 4B-3-pre priorRec/panel pattern.
//
// This helper lives next to the factory (NOT in restore_decide.go)
// because:
//
//   - It is purely a deps-construction concern: the planner produces
//     TargetAuthority; the factory needs firewallType; this helper
//     bridges the two without leaking Group→Kind mapping into the
//     dispatcher (the dispatcher's no-Group-Kind-mapping invariant
//     is structural, enforced by TestDispatcher_NoLocalGroupKindMapping).
//   - The TargetAuthorityKind* constants required for the switch
//     therefore appear ONLY in restore_deps.go, never in restore_decide.go.
//
// RecordedPrior: TargetAuthority carries firewallType directly (§18.3
// invariant: non-empty + member of the §18.2 known set).
//
// PanelNative: TargetAuthority's FirewallType() is structurally empty
// per §18.3; the resolved value lives in the static §20 panel mapping.
// We call the public restore.ResolvePanelFirewall so the firewallType
// reaching the inline-verify dep is identical to the one Execute uses
// for preflight + mutation.
//
// None: should be unreachable — Execute refuses Kind=None before deps
// are consulted — but guard defensively.
func resolveFirewallTypeForDeps(t restore.TargetAuthority) (string, error) {
	switch t.Kind() {
	case restore.TargetAuthorityKindRecordedPrior:
		return t.FirewallType(), nil
	case restore.TargetAuthorityKindPanelNative:
		return restore.ResolvePanelFirewall(t.Panel())
	case restore.TargetAuthorityKindNone:
		return "", fmt.Errorf("deps factory: cannot resolve firewallType for TargetAuthority kind=None (upstream invariant violation)")
	default:
		return "", fmt.Errorf("deps factory: unknown TargetAuthority kind=%q", t.Kind())
	}
}
