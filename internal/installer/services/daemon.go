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
	// v1.185 INSTALL-UPGRADE-NO-DAEMON-RESTART: capture whether the daemon was ALREADY
	// running before we touch it. On an upgrade over a live daemon, the `start` below is
	// a no-op (systemd won't cycle an active unit), so the OLD binary would keep running
	// with the new files on disk (live-proven on dns2 during the v1.184 fleet rollout).
	// If it was already active, try-restart at the end to load the new binary. Fresh
	// installs (inactive here) just start — no redundant cycle.
	wasActive := exec.ServiceActive("nftband.service")

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

	// v1.100.4 (UPSTREAM-UNINSTALL-INCOMPLETE-001) — defensive unmask
	// symmetry. A prior uninstall may have left a phantom mask symlink
	// at /etc/systemd/system/nftband.service -> /dev/null (the
	// "Unit file is masked" reinstall failure surfaced by VANILLA_MATRIX
	// Round 1 RE-RUN cross-distro). Soft-fail: unmask of an unmasked
	// unit is a no-op on systemd >= 242, and a hard failure here should
	// not block install.
	_ = exec.ServiceUnmask("nftband.service")

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

	// v1.185 INSTALL-UPGRADE-NO-DAEMON-RESTART: if the daemon was already running when
	// this phase began, the `start` above was a no-op and the OLD binary is still live.
	// try-restart idempotently cycles it to load the freshly-installed binary. Only on
	// the upgrade-over-live-daemon path (wasActive) — fresh installs skip it (already a
	// clean first-start above). Non-fatal; covers DEB/RPM/source (one shared path).
	if wasActive {
		if err := exec.ServiceTryRestart("nftband.service"); err != nil {
			log.Warn("try-restart nftband.service (upgrade reload): %v — non-fatal", err)
		} else {
			log.Info("nftband.service try-restarted to load the upgraded binary")
		}
	}

	// Enable nftban-core.service (shell postinst parity — G5)
	if err := exec.ServiceEnable("nftban-core.service"); err != nil {
		log.Debug("enable nftban-core.service: %v (may not exist)", err)
	}
}
