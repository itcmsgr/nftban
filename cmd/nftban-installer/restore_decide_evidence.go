// =============================================================================
// NFTBan v1.100 Amendment 2 — Orphan-NFTBan restore evidence reader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-restore-decide-evidence"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="§54.1 read-only evidence predicate for the G1 orphan-intent split"
// meta:inventory.files="cmd/nftban-installer/restore_decide_evidence.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Amendment 2 (contract.md §§52–61) defines a 13-row evidence predicate
// (§54.1) that gates the G1/AuthorityNFTBan/OrphanProceed sub-rule. This
// file implements the predicate as a pure read-only reader against the
// live host state.
//
// Discipline:
//   - Read-only only. NO mutating systemctl verbs (start/stop/enable/
//     disable/mask/unmask/restart/daemon-reload). NO file writes. NO
//     nft mutation. NO iptables introspection (preserves §51.3 Option B).
//   - Read failures map to false on the failing row, NOT to
//     REQUIRE_EXPLICIT_INTENT (§54.2 final bullet).
//   - Caller (`runRestoreDecide`) invokes this only when the candidate
//     triple is present, to avoid unnecessary live reads.
//
// =============================================================================
package main

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/restore"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

const (
	csfServiceUnitForEvidence = "csf.service"
	nftbandServiceUnit        = "nftband.service"
	csfBinaryPath             = "/usr/sbin/csf"
	csfDisabledBinaryPath     = "/usr/sbin/csf.disabled"
)

// gatherOrphanEvidence reads the 13 §54.1 rows from the live host
// using only read-only executor surfaces. Returns a populated
// restore.OrphanEvidence struct; AllTrue() reports whether every row
// holds.
//
// Rows E.1, E.2, E.3, E.4, E.5 are derived from inputs the dispatcher
// already gathered (`detect.DetectPanel`, `uninstall.Classify`,
// `uninstall.Probe`, CLI flags). Rows E.6–E.13 are read from the
// kernel/service/file surfaces.
func gatherOrphanEvidence(
	exec executor.Executor,
	log *logging.Logger,
	panel detect.PanelType,
	auth *uninstall.ClassifyResult,
	probe *uninstall.ProbeResult,
	cfg *config,
) restore.OrphanEvidence {
	ev := restore.OrphanEvidence{}

	// E.1 panel = DirectAdmin
	ev.E1PanelDirectAdmin = panel == detect.PanelDirectAdmin

	// E.2 entry-condition row.
	//
	// Amendment 2 §54.1: E.2 = (Authority == AuthorityNFTBan).
	// Amendment 3 §64.1: E.2 reframed to
	//   (Authority == AuthorityAmbiguous AND
	//    Ambiguity == AmbiguityConflictExternal AND
	//    external == "csf").
	//
	// The dispatcher sets E.2=true when EITHER entry condition
	// holds, so the same OrphanEvidence struct serves both
	// AllTrue() (Amendment 2 path) and AllTrueAmendment3()
	// (Amendment 3 path). The engine selects which predicate to
	// evaluate based on the lattice entry it took
	// (decideAuthorityNFTBan vs decideAmbiguityConflictExternal);
	// E.2's reframed semantic is upheld in both because the
	// dispatcher only enters this gathering function when EITHER
	// candidate quintuple holds.
	ev.E2AuthorityNFTBan = auth.State == uninstall.AuthorityNFTBan ||
		(auth.State == uninstall.AuthorityAmbiguous &&
			auth.Ambiguity == uninstall.AmbiguityConflictExternal &&
			auth.External == "csf")

	// E.3 prior = NoRecord
	ev.E3PriorNoRecord = probe.State == uninstall.PriorNoRecord

	// E.4 --panel-auto-takeover present
	ev.E4PanelAutoTakeover = cfg.panelAutoTakeover

	// E.5 --accept-orphan-nftban present (CLI argv only — env-var
	// fallback is rejected at flag-parse time per §55).
	ev.E5AcceptOrphanNFTBan = cfg.acceptOrphanNFTBan

	// E.6 csf.service exists AND not active AND is-enabled in {masked, disabled}.
	// Three sub-checks. Any failure → E6 false.
	ev.E6CSFServiceDisabled = csfServiceIsDisabledOrMasked(exec, log)

	// E.7 /usr/sbin/csf.disabled exists
	ev.E7CSFDisabledExists = exec.FileExists(csfDisabledBinaryPath)

	// E.8 /usr/sbin/csf does NOT exist
	ev.E8CSFAbsent = !exec.FileExists(csfBinaryPath)

	// E.9 ip:nftban table present
	ev.E9NftIPNftbanPresent = exec.NftTableExists("ip", "nftban")

	// E.10 ip6:nftban table present
	ev.E10NftIP6NftbanPres = exec.NftTableExists("ip6", "nftban")

	// E.11 nftband.service active
	ev.E11NftbandActive = exec.ServiceActive(nftbandServiceUnit)

	// E.12 no AuthorityExternal / no AmbiguityConflictExternal.
	// Classifier output already established AuthorityNFTBan (caller),
	// so this is implicit; recorded explicitly per §54.1 to avoid
	// inferential gaps.
	ev.E12NoConflictExternal = auth.State != uninstall.AuthorityExternal &&
		auth.Ambiguity != uninstall.AmbiguityConflictExternal

	// E.13 no AmbiguityOrphanNFTBan.
	//
	// Amendment 2 §54.1 wording: "no AmbiguityOrphanNFTBan". The
	// original implementation used the stricter
	// `auth.State != AuthorityAmbiguous` because under Amendment 2's
	// entry condition (AuthorityNFTBan) the two are equivalent —
	// AuthorityNFTBan implies Ambiguity==None which implies
	// !OrphanNFTBan. Under Amendment 3's entry condition
	// (AuthorityAmbiguous + AmbiguityConflictExternal + external=csf),
	// the strict form returns false even though the contract
	// requires E.13=true; the operator-intent override does NOT
	// extend to orphan-nftban-with-conflict cases (§66 forbidden
	// bullet) but DOES extend to orphan-CSF-with-csf-residue
	// (§63 lattice extension).
	//
	// Match the §64.1 wording exactly: E.13 = (Ambiguity !=
	// AmbiguityOrphanNFTBan). Both Amendment 2 and Amendment 3
	// entry conditions satisfy this; only the AmbiguityOrphanNFTBan
	// path itself fails E.13. Test rows AMD2-E.13 (Amendment 2
	// fixture) and AMD3-E.13 (Amendment 3 fixture, equivalent
	// to AMD3-10's classifier shape) both pin this.
	ev.E13NoAmbiguous = auth.Ambiguity != uninstall.AmbiguityOrphanNFTBan

	return ev
}

// csfServiceIsDisabledOrMasked returns true iff csf.service:
//   - exists (systemctl status is parseable, not "could not be found")
//   - is NOT active (is-active returns "inactive" or "failed")
//   - is-enabled is one of {"masked", "disabled"}; "enabled" or
//     "static" or anything else returns false.
//
// Routes through the executor's Run abstraction for read-only
// systemctl probes (§43.3 — raw Run permitted in restore deps for
// read-only probes only). NO mutating systemctl verb is invoked.
func csfServiceIsDisabledOrMasked(exec executor.Executor, log *logging.Logger) bool {
	// Sub-check 1: existence via `systemctl status csf.service`.
	statusRes := exec.Run("systemctl", "status", "--no-pager", "--lines=0", csfServiceUnitForEvidence)
	combined := statusRes.Stdout + statusRes.Stderr
	if strings.Contains(combined, "could not be found") || strings.Contains(combined, "not-found") {
		log.Info("amd2-evidence: E.6 csf.service not present on host")
		return false
	}

	// Sub-check 2: must NOT be active. Use the typed read-only seam.
	if exec.ServiceActive(csfServiceUnitForEvidence) {
		log.Info("amd2-evidence: E.6 csf.service is active — orphan precondition violated")
		return false
	}

	// Sub-check 3: is-enabled must be in {masked, disabled}. Reject
	// {enabled, static, anything else}. Forbidden values:
	//   - "enabled"  — csf would return at next boot
	//   - "static"   — csf has no install dependency relations; would
	//                  re-arm via Wants= at boot
	enabledRes := exec.Run("systemctl", "is-enabled", csfServiceUnitForEvidence)
	enabledState := strings.TrimSpace(enabledRes.Stdout)
	switch enabledState {
	case "masked", "disabled":
		// Acceptable. (masked = strongest, matches install-time
		// switchop.DisableConflicts; disabled = acceptable fallback.)
		return true
	default:
		log.Info("amd2-evidence: E.6 csf.service is-enabled=%q (forbidden; want masked or disabled)", enabledState)
		return false
	}
}
