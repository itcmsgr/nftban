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
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// AssertSSHInLiveSet verifies the SSH port exists in the live nft tcp_ports_in
// sets for both ip and ip6. If missing, adds it. This MUST run before rebuild.
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
