// =============================================================================
// NFTBan v1.0 - nftband Daemon - General daemon status and module handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.54.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="General daemon status and module registry handlers"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"time"

	"github.com/itcmsgr/nftban/pkg/version"
)

// handleStatusRequest returns daemon status
func (d *Daemon) handleStatusRequest() SocketResponse {
	stats := d.bus.Stats()

	// Get config info (thread-safe)
	d.reloadMu.RLock()
	configHash := d.configHash
	lastReload := d.lastReloadTs
	d.reloadMu.RUnlock()

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"version":        version.Version,
			"uptime":         time.Since(d.startedAt).Truncate(time.Second).String(),
			"uptime_seconds": int(time.Since(d.startedAt).Seconds()),
			"modules":        len(d.registry.All()),
			"events_total":   stats.Published,
			"subscriptions":  stats.Subscriptions,
			// v1.13.12: Config reload tracking
			"config_hash":   configHash,
			"config_loaded": lastReload.Format(time.RFC3339),
			// v1.229.2 TRACK B: reload capability, not per-key state. Both values are
			// structurally true for the whole process lifetime and depend on no field
			// classification: a reload refreshes the singleton configuration view and
			// never reconfigures running components.
			"config_reload_mode":      configReloadMode,
			"runtime_reconfiguration": false,
			// Startup lifecycle observability: additive rendering of the ONE
			// canonical lifecycle snapshot (readiness, phase, degraded components).
			// Existing fields above are unchanged for backward compatibility.
			"lifecycle": d.lifecycleStatus(),
		},
	}
}

// lifecycleStatus renders the canonical startup-lifecycle snapshot as a stable,
// additive object for the status IPC. Nil-safe so status never panics if the
// lifecycle was not wired (e.g. degraded construction paths / tests).
func (d *Daemon) lifecycleStatus() map[string]any {
	if d.lifecycle == nil {
		return map[string]any{"available": false}
	}
	s := d.lifecycle.Snapshot()
	return map[string]any{
		"phase":                    string(s.Phase),
		"last_completed_phase":     string(s.LastCompletedPhase),
		"state":                    s.State,
		"ready":                    s.Ready,
		"ready_attempted":          s.ReadyAttempted,
		"ready_sent":               s.ReadySent,
		"notify_expected":          s.NotifyExpected,
		"shutdown_started":         s.ShutdownStarted,
		"ipc_bound":                s.IPCBound,
		"ipc_accepting":            s.IPCAccepting,
		"nft_ready":                s.NFTReady,
		"opqueue_ready":            s.OpQueueReady,
		"modules_initialized":      s.ModulesInitialized,
		"required_modules_started": s.RequiredModulesStarted,
		"http_ready":               s.HTTPReady,
		// v1.229.2 TRACK A — an operator must be able to tell "no HTTP because the
		// port is owned by another service" from "HTTP is unhealthy". Without this
		// key both look identical: http_ready=false.
		"http_disabled_by_design": s.HTTPDisabledByDesign,
		"watchdog_ready":          s.WatchdogReady,
		"degraded_components":     s.DegradedComponents,
	}
}

// handleModulesRequest returns module statuses
func (d *Daemon) handleModulesRequest() SocketResponse {
	statuses := d.registry.StatusAll()
	return SocketResponse{
		Success: true,
		Data:    statuses,
	}
}
