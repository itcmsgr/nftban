// =============================================================================
// NFTBan v1.73 - Installer Daemon Start
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-daemon"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Enable and start nftband socket+service with retry"
// meta:inventory.files="internal/installer/services/daemon.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftband.socket, nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package services

import (
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const (
	daemonRetries  = 3
	daemonRetrySec = 1
)

// StartDaemon enables nftband.socket and nftband.service.
// Retries up to 3 times with 1s delay. Non-fatal — logs warnings.
func StartDaemon(exec executor.Executor, log *logging.Logger) {
	// daemon-reload first to pick up any unit changes
	if err := exec.DaemonReload(); err != nil {
		log.Warn("daemon-reload: %v", err)
	}

	// Clear start-limit-hit before attempting start. During update/install
	// cycles the daemon may have been stopped/started repeatedly, exhausting
	// systemd's StartLimitBurst. Without reset-failed, all start attempts
	// will fail with "start request repeated too quickly."
	_ = exec.Run("systemctl", "reset-failed", "nftband.service")
	_ = exec.Run("systemctl", "reset-failed", "nftband.socket")

	// Enable socket (primary activation method)
	if err := exec.ServiceEnable("nftband.socket"); err != nil {
		log.Warn("enable nftband.socket: %v", err)
	}

	// Start socket
	for i := 1; i <= daemonRetries; i++ {
		if err := exec.ServiceStart("nftband.socket"); err != nil {
			log.Warn("start nftband.socket attempt %d/%d: %v", i, daemonRetries, err)
			time.Sleep(time.Duration(daemonRetrySec) * time.Second)
			continue
		}
		log.Info("nftband.socket started (attempt %d)", i)
		break
	}

	// Enable service (direct start, belt-and-suspenders)
	if err := exec.ServiceEnable("nftband.service"); err != nil {
		log.Warn("enable nftband.service: %v", err)
	}

	for i := 1; i <= daemonRetries; i++ {
		if err := exec.ServiceStart("nftband.service"); err != nil {
			log.Warn("start nftband.service attempt %d/%d: %v", i, daemonRetries, err)
			time.Sleep(time.Duration(daemonRetrySec) * time.Second)
			continue
		}
		log.Info("nftband.service started (attempt %d)", i)
		break
	}

	// Verify daemon is running
	if exec.ServiceActive("nftband.service") {
		log.Info("nftband daemon verified active")
	} else {
		log.Warn("nftband.service not active after start attempts — non-fatal")
	}

	// Enable nftban-core.service (shell postinst parity — G5)
	if err := exec.ServiceEnable("nftban-core.service"); err != nil {
		log.Debug("enable nftban-core.service: %v (may not exist)", err)
	}

	// Enable nftban-ui-auth.socket (web UI auth — G6)
	for _, unit := range []string{"/etc/systemd/system/nftban-ui-auth.socket", "/usr/lib/systemd/system/nftban-ui-auth.socket"} {
		if exec.FileExists(unit) {
			if err := exec.ServiceEnable("nftban-ui-auth.socket"); err != nil {
				log.Warn("enable nftban-ui-auth.socket: %v", err)
			}
			if err := exec.ServiceStart("nftban-ui-auth.socket"); err != nil {
				log.Warn("start nftban-ui-auth.socket: %v", err)
			} else {
				log.Debug("nftban-ui-auth.socket enabled and started")
			}
			break
		}
	}
}
