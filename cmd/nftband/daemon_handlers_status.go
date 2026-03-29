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
