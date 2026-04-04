// =============================================================================
// NFTBan v1.73 - Installer Takeover Operations
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-takeover"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Disable conflicting firewalls during takeover"
// meta:inventory.files="internal/installer/switchop/takeover.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// DisableConflicts stops, disables, and masks all conflicting firewalls.
func DisableConflicts(exec executor.Executor, conflicts []detect.Conflict, log *logging.Logger) error {
	for _, c := range conflicts {
		if c.Service == "" {
			continue
		}
		log.Info("disabling conflicting service: %s (%s)", c.Name, c.Service)

		if err := exec.ServiceStop(c.Service); err != nil {
			log.Warn("stop %s: %v", c.Service, err)
		}
		if err := exec.ServiceDisable(c.Service); err != nil {
			log.Warn("disable %s: %v", c.Service, err)
		}
		if err := exec.ServiceMask(c.Service); err != nil {
			log.Warn("mask %s: %v", c.Service, err)
		}
		log.CmdResult("disable "+c.Service, 0, "")
	}

	// Flush legacy iptables rules
	for _, cmd := range []string{"iptables", "ip6tables"} {
		if exec.CommandExists(cmd) {
			res := exec.Run(cmd, "-F")
			log.CmdResult(cmd+" -F", res.ExitCode, res.Stderr)
			res = exec.Run(cmd, "-X")
			log.CmdResult(cmd+" -X", res.ExitCode, res.Stderr)
		}
	}

	return nil
}
