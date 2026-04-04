// =============================================================================
// NFTBan v1.73 - Installer Stale File Cleanup
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-cleanup"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Remove stale files, polkit rules, and legacy units from prior versions"
// meta:inventory.files="internal/installer/services/cleanup.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package services

import (
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// staleFiles are files removed during every install/upgrade.
// Sources: forensic audit of shell %post cleanup phase.
var staleFiles = []string{
	// Legacy systemd units (removed v1.55+)
	"/etc/systemd/system/nftban-loginmon.service",
	"/etc/systemd/system/nftban-loginmon.timer",
	"/etc/systemd/system/nftban-collector.service",
	"/etc/systemd/system/nftban-collector.timer",
	"/etc/systemd/system/nftban-reporter.service",
	"/etc/systemd/system/nftban-reporter.timer",
	"/etc/systemd/system/nftban-update.service",
	"/etc/systemd/system/nftban-update.timer",

	// Legacy lock/pid/run files
	"/run/nftban/loginmon.pid",
	"/run/nftban/collector.pid",
	"/var/lib/nftban/state/collector.state",
	"/var/lib/nftban/.loginmon_running",

	// Legacy config stubs
	"/etc/nftban/conf.d/loginmon.conf",
	"/etc/nftban/conf.d/collector.conf",

	// Legacy scripts (moved or replaced)
	"/usr/lib/nftban/sbin/nftban-loginmon",
	"/usr/lib/nftban/sbin/nftban-collector",
	"/usr/lib/nftban/sbin/nftban-reporter",
	"/usr/lib/nftban/cli/cmd_collector.sh",
	"/usr/lib/nftban/cli/cmd_reporter.sh",
}

// polkitRules are stale polkit rules from pre-v1.57 installations.
var polkitRules = []string{
	"/etc/polkit-1/rules.d/49-nftban-collector.rules",
	"/etc/polkit-1/rules.d/49-nftban-reporter.rules",
	"/etc/polkit-1/rules.d/49-nftban-loginmon.rules",
	"/usr/share/polkit-1/rules.d/49-nftban-collector.rules",
	"/usr/share/polkit-1/rules.d/49-nftban-reporter.rules",
	"/usr/share/polkit-1/rules.d/49-nftban-loginmon.rules",
}

// logrotateStale are stale logrotate configs.
var logrotateStale = []string{
	"/etc/logrotate.d/nftban-collector",
	"/etc/logrotate.d/nftban-reporter",
	"/etc/logrotate.d/nftban-loginmon",
}

// CleanStaleFiles removes all known stale files from prior NFTBan versions.
// Errors are logged but never fatal.
func CleanStaleFiles(exec executor.Executor, log *logging.Logger) {
	removed := 0

	for _, path := range staleFiles {
		if exec.FileExists(path) {
			if err := exec.Remove(path); err != nil {
				log.Warn("remove stale %s: %v", path, err)
			} else {
				removed++
			}
		}
	}

	for _, path := range polkitRules {
		if exec.FileExists(path) {
			if err := exec.Remove(path); err != nil {
				log.Warn("remove polkit %s: %v", path, err)
			} else {
				removed++
			}
		}
	}

	for _, path := range logrotateStale {
		if exec.FileExists(path) {
			if err := exec.Remove(path); err != nil {
				log.Warn("remove logrotate %s: %v", path, err)
			} else {
				removed++
			}
		}
	}

	// Stop + disable stale units before removing (belt-and-suspenders)
	staleUnits := []string{
		"nftban-loginmon.service",
		"nftban-loginmon.timer",
		"nftban-collector.service",
		"nftban-collector.timer",
		"nftban-reporter.service",
		"nftban-reporter.timer",
		"nftban-update.service",
		"nftban-update.timer",
	}
	for _, unit := range staleUnits {
		if exec.ServiceActive(unit) {
			_ = exec.ServiceStop(unit)
		}
		_ = exec.ServiceDisable(unit)
	}

	if removed > 0 {
		log.Info("cleaned %d stale files", removed)
		// daemon-reload after removing units
		_ = exec.DaemonReload()
	} else {
		log.Debug("no stale files found")
	}
}
