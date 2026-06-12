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
// meta:inventory.systemd_units="nftban-maintenance.timer, nftban-health.timer, nftban-unified-exporter.timer, nftban-core-geoip.timer, nftban-core-feeds.timer, nftban-watchdog.timer, nftban-queue.timer, nftban-update-check.timer, nftban-geoban-refresh.timer"
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
	"nftban-geoban-refresh.timer",
}

// optionalTimers are started only if their unit file exists (panel-dependent).
var optionalTimers = []string{
	"nftban-botscan.timer",
	"nftban-botscan-collector.timer",
}

// allKnownTimers is the canonical, exhaustive list of every nftban systemd
// timer unit shipped under install/systemd/*.timer. It is the single source of
// truth for any code that must iterate over the full set of nftban timers
// (e.g. the D-INSTALL-TIMER-RELOAD post-install wedge-recovery hardening in
// timers_post_install.go).
//
// coreTimers / optionalTimers above are reconcile-policy SUBSETS of this list;
// this slice is the SUPERSET. If a new install/systemd/*.timer is added (or one
// is removed), this slice MUST be updated — the drift-parity test
// (timers_post_install_parity_test.go) fails otherwise.
var allKnownTimers = []string{
	"nftban-botscan-collector.timer",
	"nftban-botscan.timer",
	"nftban-community-stats.timer",
	"nftban-core-feeds.timer",
	"nftban-core-geoip.timer",
	"nftban-geoban-refresh.timer",
	"nftban-health.timer",
	"nftban-maintenance.timer",
	"nftban-pro-inventory.timer",
	"nftban-pro-license.timer",
	"nftban-queue.timer",
	"nftban-rbl-check.timer",
	"nftban-rebuild-recovery.timer",
	"nftban-report-daily.timer",
	"nftban-rollback.timer",
	"nftban-snapshot.timer",
	"nftban-soak.timer",
	"nftban-suricata-update.timer",
	"nftban-tunnel.timer",
	"nftban-unified-exporter.timer",
	"nftban-update-apply.timer",
	"nftban-update-check.timer",
	"nftban-watchdog.timer",
}

// KnownTimers returns a copy of the canonical full list of nftban timer unit
// names (every install/systemd/*.timer). Callers that need to iterate all
// nftban timers — such as the post-install wedge-recovery hardening — use this
// rather than duplicating a const list. The returned slice is a copy; callers
// may sort/mutate it freely.
func KnownTimers() []string {
	out := make([]string, len(allKnownTimers))
	copy(out, allKnownTimers)
	return out
}

// criticalCoreTimers is the subset of coreTimers whose failure to be enabled
// + (active OR scheduled) DEGRADES the install (v1.135 D-MAINTENANCE-TIMER-
// SILENT-ENABLE). nftban-maintenance.timer backs maintenance, trend data,
// auto-heal, and SSH/IP lockout-prevention. The other core timers are NOT
// critical here so transient exporter/feed issues never DEGRADE the install.
var criticalCoreTimers = []string{
	"nftban-maintenance.timer",
}

// CriticalCoreTimers returns the critical core timer unit names, for the
// install_state critical-timer validator (which lives in another package).
func CriticalCoreTimers() []string {
	out := make([]string, len(criticalCoreTimers))
	copy(out, criticalCoreTimers)
	return out
}

// ReconcileTimers enables and starts all core timers.
// Controlled by NFTBAN_RECONCILE_CORE_TIMERS in nftban.conf (default: true).
func ReconcileTimers(exec executor.Executor, log *logging.Logger) {
	if !ShouldReconcile(exec) {
		log.Info("timer reconciliation disabled (NFTBAN_RECONCILE_CORE_TIMERS != true)")
		return
	}

	log.Info("reconciling %d core timers + %d optional", len(coreTimers), len(optionalTimers))

	for _, timer := range coreTimers {
		enableAndStart(exec, timer, log)
	}

	for _, timer := range optionalTimers {
		// Only start if unit file exists
		if exec.FileExists("/etc/systemd/system/"+timer) ||
			exec.FileExists("/usr/lib/systemd/system/"+timer) {
			enableAndStart(exec, timer, log)
		} else {
			log.Debug("optional timer %s not installed — skipping", timer)
		}
	}
}

// ShouldReconcile checks if NFTBAN_RECONCILE_CORE_TIMERS is set to true
// in nftban.conf or nftban.conf.local. Default: true (reconcile).
func ShouldReconcile(exec executor.Executor) bool {
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
