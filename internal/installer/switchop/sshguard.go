// =============================================================================
// NFTBan v1.73 - Installer SSH Port Live Set Guard
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-sshguard"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Ensure SSH port is in live nft sets before rebuild"
// meta:inventory.files="internal/installer/switchop/sshguard.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// emergencyTable is the name of the last-resort SSH safety table.
const emergencyTable = "nftban_install_emergency"

// InjectEmergencySSH creates a minimal inet table that accepts the SSH port.
// This table acts as a last-resort safety net during install transitions.
// It MUST be removed only after nftban rules are proven in the kernel.
// Idempotent: deletes any existing emergency table before creating.
//
// Priority -1: evaluated before nftban chains (priority 0).
// Policy accept: fail-open — safety net, not security boundary.
func InjectEmergencySSH(exec executor.Executor, sshPort int, log *logging.Logger) error {
	// Clean up any pre-existing emergency table (idempotent)
	if exec.NftTableExists("inet", emergencyTable) {
		_ = exec.NftDeleteTable("inet", emergencyTable)
	}

	nftRules := fmt.Sprintf(`table inet %s {
    chain input {
        type filter hook input priority -1; policy accept;
        tcp dport %d accept
    }
}`, emergencyTable, sshPort)

	// Write rules to temp file and load with nft -f
	tmpPath := "/tmp/.nftban-emergency-ssh.nft"
	if err := exec.WriteFileAtomic(tmpPath, []byte(nftRules+"\n"), 0600); err != nil {
		return fmt.Errorf("write emergency SSH rules: %w", err)
	}
	defer func() { _ = exec.Remove(tmpPath) }()

	res := exec.Run("nft", "-f", tmpPath)
	if res.ExitCode != 0 {
		return fmt.Errorf("inject emergency SSH table: %s", strings.TrimSpace(res.Stderr))
	}

	log.Info("injected emergency SSH table (port %d, priority -1)", sshPort)
	return nil
}

// RemoveEmergencySSH removes the emergency SSH table.
// Call only after nftban rules are proven in the kernel with SSH port present.
// No-op if table doesn't exist.
func RemoveEmergencySSH(exec executor.Executor, log *logging.Logger) {
	if !exec.NftTableExists("inet", emergencyTable) {
		return
	}
	if err := exec.NftDeleteTable("inet", emergencyTable); err != nil {
		log.Warn("remove emergency SSH table: %v", err)
	} else {
		log.Info("removed emergency SSH table (nftban rules proven)")
	}
}

// AssertSSHInLiveSet verifies the SSH port exists in the live nft tcp_ports_in
// sets for both ip and ip6. If missing, adds it.
// Call after EnableNftables (nftban tables must exist) and before/after rebuild.
func AssertSSHInLiveSet(exec executor.Executor, sshPort int, log *logging.Logger) {
	portStr := strconv.Itoa(sshPort)

	for _, family := range []string{"ip", "ip6"} {
		if !exec.NftTableExists(family, "nftban") {
			continue
		}
		setData, err := exec.NftListSet(family, "nftban", "tcp_ports_in")
		if err != nil {
			log.Debug("cannot list %s nftban tcp_ports_in: %v", family, err)
			continue
		}
		if strings.Contains(setData, portStr) {
			log.Debug("SSH port %d already in %s nftban tcp_ports_in", sshPort, family)
			continue
		}
		// Port missing — add it
		if err := exec.NftAddElement(family, "nftban", "tcp_ports_in", portStr); err != nil {
			log.Warn("add SSH port %d to %s nftban tcp_ports_in: %v", sshPort, family, err)
		} else {
			log.Info("added SSH port %d to %s nftban tcp_ports_in (was missing)", sshPort, family)
		}
	}
}
