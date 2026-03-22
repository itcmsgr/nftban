// =============================================================================
// NFTBan v1.0 - nftband Daemon - Watchdog, status, modules, and reload handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Watchdog, status, modules, and reload handlers"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="8080/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"time"

	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/itcmsgr/nftban/pkg/watchdog"
)

// =============================================================================
// WATCHDOG IPC HANDLERS
// =============================================================================

// handleWatchdogStatusRequest returns watchdog status
func (d *Daemon) handleWatchdogStatusRequest() SocketResponse {
	if d.watchdog == nil {
		return SocketResponse{
			Success: false,
			Error:   "watchdog not initialized",
		}
	}

	state := d.watchdog.GetState()
	snapshot := d.watchdog.GetSnapshot()

	data := map[string]any{
		"running": d.watchdog.IsRunning(),
		"mode":    string(state.Mode),
		"mode_duration_seconds": state.ModeDuration.Seconds(),
	}

	// Add per-dimension info
	dimensions := make(map[string]any)
	for dim, score := range state.Scores {
		dimensions[string(dim)] = map[string]any{
			"score": score,
			"level": string(state.Levels[dim]),
		}
	}
	data["dimensions"] = dimensions

	// Add key metrics if snapshot available
	if snapshot != nil {
		data["metrics"] = map[string]any{
			"rss_bytes":             snapshot.Process.RSS,
			"cpu_percent":           snapshot.Process.CPUPct,
			"goroutines":            snapshot.Runtime.Goroutines,
			"heap_alloc_bytes":      snapshot.Runtime.HeapAlloc,
			"conntrack_utilization": snapshot.Kernel.ConntrackUtilization,
			"iowait_percent":        snapshot.System.IOWaitPct,
		}
	}

	return SocketResponse{
		Success: true,
		Data:    data,
	}
}

// handleWatchdogPressureRequest returns detailed pressure info
func (d *Daemon) handleWatchdogPressureRequest() SocketResponse {
	if d.watchdog == nil {
		return SocketResponse{
			Success: false,
			Error:   "watchdog not initialized",
		}
	}

	state := d.watchdog.GetState()

	// Build detailed pressure response
	data := map[string]any{
		"timestamp": state.Timestamp.Format(time.RFC3339),
		"mode":      string(state.Mode),
	}

	dimensions := make(map[string]any)
	for _, dim := range watchdog.AllDimensions() {
		dimensions[string(dim)] = map[string]any{
			"score": state.Scores[dim],
			"level": string(state.Levels[dim]),
		}
	}
	data["dimensions"] = dimensions

	// Runtime controls
	controls := d.watchdog.GetControls()
	data["controls"] = map[string]any{
		"max_workers":               controls.MaxWorkers.Load(),
		"expensive_collectors":      controls.EnableExpensiveCollectors.Load(),
		"nft_ruleset_scan":          controls.EnableNFTRulesetScan.Load(),
		"sampling_factor":           controls.GetSamplingFactor(),
	}

	return SocketResponse{
		Success: true,
		Data:    data,
	}
}

// handleWatchdogEventsRequest returns recent watchdog events
func (d *Daemon) handleWatchdogEventsRequest(params map[string]any) SocketResponse {
	if d.watchdog == nil {
		return SocketResponse{
			Success: false,
			Error:   "watchdog not initialized",
		}
	}

	count := 20
	if c, ok := params["count"].(float64); ok && c > 0 {
		count = int(c)
		if count > 100 {
			count = 100
		}
	}

	events := d.watchdog.GetRecentEvents(count)

	// Convert to simple format
	eventList := make([]map[string]any, len(events))
	for i, e := range events {
		eventList[i] = map[string]any{
			"type":      string(e.Type),
			"timestamp": e.Timestamp.Format(time.RFC3339),
			"message":   e.Message,
		}
		if e.Action != nil {
			eventList[i]["action"] = string(e.Action.Type)
		}
		if e.Dimension != "" {
			eventList[i]["dimension"] = string(e.Dimension)
			eventList[i]["score"] = e.Score
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"count":  len(events),
			"events": eventList,
		},
	}
}

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
			"events_total":  stats.Published,
			"subscriptions": stats.Subscriptions,
			// v1.13.12: Config reload tracking
			"config_hash":   configHash,
			"config_loaded": lastReload.Format(time.RFC3339),
		},
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

// handleReloadRequest handles config reload request via IPC
// Returns the new config hash and reload timestamp for verification
func (d *Daemon) handleReloadRequest(params map[string]any) SocketResponse {
	// Perform config reload
	if err := d.reloadConfig(); err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	d.reloadMu.RLock()
	hash := d.configHash
	ts := d.lastReloadTs
	d.reloadMu.RUnlock()

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"reloaded":    true,
			"config_hash": hash,
			"reloaded_at": ts.Format(time.RFC3339),
		},
	}
}
