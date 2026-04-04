// =============================================================================
// NFTBan v1.73 - Installer Ghost Table Cleanup
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-ghost"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Remove ghost nftables tables from conflicting firewalls"
// meta:inventory.files="internal/installer/switchop/ghost.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// ghostTables is the exact list from the shell %post.
var ghostTables = []struct {
	family string
	table  string
}{
	{"ip", "filter"},
	{"ip6", "filter"},
	{"ip", "nat"},
	{"ip6", "nat"},
	{"ip", "mangle"},
	{"ip6", "mangle"},
	{"ip", "security"},
	{"ip6", "security"},
	{"inet", "firewalld"},
	{"inet", "filter"},
}

// CleanGhostTables removes all known ghost nftables tables.
// Ignores errors for tables that don't exist.
func CleanGhostTables(exec executor.Executor, log *logging.Logger) {
	for _, gt := range ghostTables {
		if exec.NftTableExists(gt.family, gt.table) {
			if err := exec.NftDeleteTable(gt.family, gt.table); err != nil {
				log.Warn("delete ghost table %s %s: %v", gt.family, gt.table, err)
			} else {
				log.Info("removed ghost table: %s %s", gt.family, gt.table)
			}
		}
	}

	// NOTE: Do NOT clean inet nftban_install_emergency here.
	// Its lifecycle is managed by InjectEmergencySSH / RemoveEmergencySSH
	// in sshguard.go — phaseSwitch controls when it's safe to remove.
}
