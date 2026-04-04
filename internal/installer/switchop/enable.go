// =============================================================================
// NFTBan v1.73 - Installer nftables Service Enable
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-enable"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Enable and start nftables service"
// meta:inventory.files="internal/installer/switchop/enable.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftables.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"fmt"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// EnableNftables enables and starts the nftables service, then verifies.
func EnableNftables(exec executor.Executor, log *logging.Logger) error {
	if err := exec.ServiceEnable("nftables"); err != nil {
		log.Warn("enable nftables: %v", err)
	}
	if err := exec.ServiceStart("nftables"); err != nil {
		return fmt.Errorf("start nftables: %w", err)
	}
	if !exec.ServiceActive("nftables") {
		return fmt.Errorf("nftables service not active after start")
	}
	log.Info("nftables service enabled and active")
	return nil
}
