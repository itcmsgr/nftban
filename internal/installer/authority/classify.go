// =============================================================================
// NFTBan v1.73 - Installer Authority Classification
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-authority-classify"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Authority decision tree: UPDATE/TAKEOVER/FRESH/ABORT/AMBIGUOUS"
// meta:inventory.files="internal/installer/authority/classify.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_TAKEOVER, NFTBAN_PANEL_AUTO_TAKEOVER"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package authority

import (
	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// NftbanDaemonUnit is the systemd unit name of the nftban daemon. Kept
// as a package-level constant so the shared authoritative predicate and
// any future consumer cannot drift apart on unit-name spelling.
const NftbanDaemonUnit = "nftband.service"

// IsNftbanAuthoritative is the CANONICAL predicate for "nftban currently
// owns the firewall on this host." It is the single source of truth; any
// other module that needs to answer the question (e.g. update.Preflight
// P-1) must call this function rather than re-implementing it.
//
// The predicate requires THREE conditions to hold simultaneously:
//
//  1. The ip nftban table exists in the kernel.
//  2. The input chain inside that table exists.
//  3. The nftband.service unit is currently active.
//
// Previous versions of this package checked only (1) and (2). PR-22B
// tightened it: an orphan table left by a crashed prior install used
// to satisfy the predicate and classify the host as Update, causing
// phaseSwitch to skip the emergency SSH injection path. Requiring the
// active daemon forces that case into the Ambiguous branch instead.
//
// All three probes are read-only.
func IsNftbanAuthoritative(exec executor.Executor) bool {
	if !exec.NftTableExists("ip", "nftban") {
		return false
	}
	if exec.Run("nft", "list", "chain", "ip", "nftban", "input").ExitCode != 0 {
		return false
	}
	if !exec.ServiceActive(NftbanDaemonUnit) {
		return false
	}
	return true
}

// hasOrphanNftbanArtifacts reports whether any nftban kernel or service
// artifact is present without all three constituting an authoritative
// install. Used to distinguish "clean Fresh host" from "half-installed
// Ambiguous host." Read-only.
func hasOrphanNftbanArtifacts(exec executor.Executor) bool {
	if exec.NftTableExists("ip", "nftban") {
		return true
	}
	if exec.ServiceActive(NftbanDaemonUnit) {
		return true
	}
	return false
}

// Classify determines the installation authority based on the current system state.
//
// Decision tree (PR-22B tightened):
//
//  1. UPDATE — nftban currently owns the firewall (IsNftbanAuthoritative
//     returns true — table + chain + active daemon).
//
//  2. AMBIGUOUS — nftban artifacts are present but not all three conditions
//     hold (orphan table, daemon without table, etc.). Never silent-continue —
//     phaseSwitch must inject emergency SSH before any mutation.
//
//  3. FRESH — No conflicting firewalls detected AND no nftban artifacts
//     observed.
//
//  4. TAKEOVER — Conflicts exist, AND takeover is explicitly approved via one
//     of:
//     a. NFTBAN_TAKEOVER=1 environment variable
//     b. --takeover CLI flag (forceApprove=true)
//     c. Panel auto-approve ONLY when panelAutoApprove=true
//     (default is panelAutoApprove=false per PR-22B).
//
//  5. ABORT — Conflicts exist and no takeover approval was granted.
//
// PR-22B change: panel auto-approve is no longer implicit. An operator who
// wants the old behaviour must pass --panel-auto-takeover (or set
// NFTBAN_PANEL_AUTO_TAKEOVER=1). This closes the audit finding that a
// panel-managed host disabled its own firewall silently on install.
func Classify(
	exec executor.Executor,
	conflicts []detect.Conflict,
	panel detect.PanelType,
	forceApprove bool,
	panelAutoApprove bool,
	log *logging.Logger,
) Decision {
	// 1. NFTBan fully authoritative — UPDATE.
	if IsNftbanAuthoritative(exec) {
		log.Detect("authority", "decision", string(Update))
		log.Detect("authority", "reason", "nftban table+chain+daemon all present")
		return Update
	}

	// 2. Orphan nftban artifacts without full authority — AMBIGUOUS.
	// A later phase must NOT treat this as a clean Fresh or ignore it:
	// the operator needs to see that the host carries stale state, and
	// the emergency-SSH path must kick in before any mutation.
	if hasOrphanNftbanArtifacts(exec) {
		log.Detect("authority", "decision", string(Ambiguous))
		log.Detect("authority", "reason", "nftban artifact present but not authoritative (table or daemon in partial state)")
		return Ambiguous
	}

	// 3. No conflicts → FRESH install
	if len(conflicts) == 0 {
		log.Detect("authority", "decision", string(Fresh))
		log.Detect("authority", "reason", "no conflicts; no nftban artifacts")
		return Fresh
	}

	// 4. Conflicts exist — check explicit takeover approval
	// 4a. Environment variable
	if exec.Getenv("NFTBAN_TAKEOVER") == "1" {
		log.Detect("authority", "decision", string(Takeover))
		log.Detect("authority", "reason", "NFTBAN_TAKEOVER=1")
		return Takeover
	}

	// 4b. CLI --takeover flag
	if forceApprove {
		log.Detect("authority", "decision", string(Takeover))
		log.Detect("authority", "reason", "--takeover flag")
		return Takeover
	}

	// 4c. Panel auto-approve — PR-22B requires explicit opt-in.
	if panelAutoApprove && detect.HasPanel(panel) {
		log.Detect("authority", "decision", string(Takeover))
		log.Detect("authority", "reason", "panel auto-approve ("+string(panel)+") with --panel-auto-takeover")
		return Takeover
	}

	// 5. No approval → ABORT
	log.Detect("authority", "decision", string(Abort))
	if detect.HasPanel(panel) && !panelAutoApprove {
		log.Detect("authority", "reason", "conflicts + panel detected; --panel-auto-takeover not set (PR-22B: implicit panel auto-approve removed)")
	} else {
		log.Detect("authority", "reason", "conflicts detected, no takeover approval")
	}
	return Abort
}
