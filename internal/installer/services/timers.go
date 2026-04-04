// =============================================================================
// NFTBan v1.75.1 - Installer Timer Reconciliation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-timers"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Reconcile core systemd timers (enable+start)"
// meta:inventory.files="internal/installer/services/timers.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftban-maintenance.timer, nftban-health.timer, nftban-unified-exporter.timer, nftban-core-geoip.timer, nftban-core-feeds.timer, nftban-watchdog.timer, nftban-queue.timer, nftban-update-check.timer"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package services

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// coreTimers are the timers enabled by default when NFTBAN_RECONCILE_CORE_TIMERS="true".
var coreTimers = []string{
	"nftban-maintenance.timer",
	"nftban-health.timer",
	"nftban-unified-exporter.timer",
	"nftban-core-geoip.timer",
	"nftban-core-feeds.timer",
	"nftban-watchdog.timer",
	"nftban-queue.timer",
	"nftban-update-check.timer",
}

// optionalTimers are started only if their unit file exists (panel-dependent).
var optionalTimers = []string{
	"nftban-botscan.timer",
}

// ReconcileTimers enables and starts all core timers.
// Controlled by NFTBAN_RECONCILE_CORE_TIMERS in nftban.conf (default: true).
func ReconcileTimers(exec executor.Executor, log *logging.Logger) {
	if !shouldReconcile(exec) {
		log.Info("timer reconciliation disabled (NFTBAN_RECONCILE_CORE_TIMERS != true)")
		return
	}

	log.Info("reconciling %d core timers + %d optional", len(coreTimers), len(optionalTimers))

	for _, timer := range coreTimers {
		enableAndStart(exec, timer, log)
	}

	for _, timer := range optionalTimers {
		// Only start if unit file exists
		if exec.FileExists("/etc/systemd/system/" + timer) ||
			exec.FileExists("/usr/lib/systemd/system/" + timer) {
			enableAndStart(exec, timer, log)
		} else {
			log.Debug("optional timer %s not installed — skipping", timer)
		}
	}
}

// shouldReconcile checks if NFTBAN_RECONCILE_CORE_TIMERS is set to true
// in nftban.conf or nftban.conf.local. Default: true (reconcile).
func shouldReconcile(exec executor.Executor) bool {
	// Check conf.local first (overrides main conf)
	for _, path := range []string{
		"/etc/nftban/nftban.conf.local",
		"/etc/nftban/nftban.conf",
	} {
		data, err := exec.ReadFile(path)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "NFTBAN_RECONCILE_CORE_TIMERS=") {
				val := strings.TrimPrefix(line, "NFTBAN_RECONCILE_CORE_TIMERS=")
				val = strings.Trim(val, "\"")
				return val != "false"
			}
		}
	}
	// Default: reconcile
	return true
}

// enableAndStart enables and starts a single timer. Logs warnings, never fatal.
func enableAndStart(exec executor.Executor, timer string, log *logging.Logger) {
	if err := exec.ServiceEnable(timer); err != nil {
		log.Warn("enable %s: %v", timer, err)
	}
	if err := exec.ServiceStart(timer); err != nil {
		log.Warn("start %s: %v", timer, err)
	} else {
		log.Debug("timer %s enabled and started", timer)
	}
}
