// =============================================================================
// NFTBan v1.73 - Installer Authority Classification
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-authority-classify"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Authority decision tree: UPDATE/TAKEOVER/FRESH/ABORT"
// meta:inventory.files="internal/installer/authority/classify.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_TAKEOVER"
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

// Classify determines the installation authority based on the current system state.
//
// Decision tree (matches shell %post _check_authority exactly):
//
//  1. UPDATE — NFTBan already owns the firewall:
//     nft list table ip nftban succeeds AND nft list chain ip nftban input succeeds
//
//  2. FRESH — No conflicting firewalls detected (conflicts slice is empty)
//
//  3. TAKEOVER — Conflicts exist, but takeover is approved:
//     a. NFTBAN_TAKEOVER=1 environment variable, OR
//     b. Panel is detected (auto-approve for managed hosting), OR
//     c. forceApprove flag is true (from --takeover CLI flag)
//
//  4. ABORT — Conflicts exist, no approval granted
func Classify(
	exec executor.Executor,
	conflicts []detect.Conflict,
	panel detect.PanelType,
	forceApprove bool,
	log *logging.Logger,
) Decision {
	// 1. Check if NFTBan already owns the firewall (UPDATE)
	if nftbanAuthoritative(exec) {
		log.Detect("authority", "decision", string(Update))
		log.Detect("authority", "reason", "nftban table+chain exist")
		return Update
	}

	// 2. No conflicts → FRESH install
	if len(conflicts) == 0 {
		log.Detect("authority", "decision", string(Fresh))
		log.Detect("authority", "reason", "no conflicts")
		return Fresh
	}

	// 3. Conflicts exist — check takeover approval
	// 3a. Environment variable
	if exec.Getenv("NFTBAN_TAKEOVER") == "1" {
		log.Detect("authority", "decision", string(Takeover))
		log.Detect("authority", "reason", "NFTBAN_TAKEOVER=1")
		return Takeover
	}

	// 3b. CLI --takeover flag
	if forceApprove {
		log.Detect("authority", "decision", string(Takeover))
		log.Detect("authority", "reason", "--takeover flag")
		return Takeover
	}

	// 3c. Panel auto-approve (managed hosting systems)
	if detect.HasPanel(panel) {
		log.Detect("authority", "decision", string(Takeover))
		log.Detect("authority", "reason", "panel auto-approve ("+string(panel)+")")
		return Takeover
	}

	// 4. No approval → ABORT
	log.Detect("authority", "decision", string(Abort))
	log.Detect("authority", "reason", "conflicts detected, no takeover approval")
	return Abort
}

// nftbanAuthoritative returns true if NFTBan already owns the firewall.
// Checks: nft list table ip nftban AND nft list chain ip nftban input.
func nftbanAuthoritative(exec executor.Executor) bool {
	if !exec.NftTableExists("ip", "nftban") {
		return false
	}
	// Also verify the input chain exists (not just an empty table)
	res := exec.Run("nft", "list", "chain", "ip", "nftban", "input")
	return res.ExitCode == 0
}
