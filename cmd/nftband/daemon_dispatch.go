// =============================================================================
// NFTBan v1.0 - nftband Daemon - IPC request routing and dispatcher
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="IPC request routing and dispatcher"
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

// handleSocketRequest processes a socket request
func (d *Daemon) handleSocketRequest(req SocketRequest) SocketResponse {
	switch req.Method {
	case "status":
		return d.handleStatusRequest()
	case "modules":
		return d.handleModulesRequest()
	case "ban":
		return d.handleBanRequest(req.Params)
	case "unban":
		return d.handleUnbanRequest(req.Params)
	case "add_element":
		return d.handleAddElementRequest(req.Params)
	case "delete_element":
		return d.handleDeleteElementRequest(req.Params)
	case "flush_set":
		return d.handleFlushSetRequest(req.Params)
	case "apply_ruleset":
		return d.handleApplyRulesetRequest(req.Params)
	case "check":
		return d.handleCheckRequest(req.Params)
	case "persist_ban":
		return d.handlePersistBanRequest(req.Params)
	case "unpersist_ban":
		return d.handleUnpersistBanRequest(req.Params)
	case "sync":
		return d.handleSyncRequest(req.Params)
	case "load_ports":
		return d.handleLoadPortsRequest(req.Params)
	case "add_port_element":
		return d.handleAddPortElementRequest(req.Params)
	case "delete_port_element":
		return d.handleDeletePortElementRequest(req.Params)
	case "load_cidrs":
		return d.handleLoadCIDRsRequest(req.Params)
	case "stats":
		return d.handleStatsRequest()
	case "stats_history":
		return d.handleStatsHistoryRequest(req.Params)
	case "snapshot_profile":
		return d.handleSnapshotProfileRequest(req.Params)
	case "ping":
		return SocketResponse{Success: true, Data: "pong"}
	case "watchdog_status":
		return d.handleWatchdogStatusRequest()
	case "watchdog_pressure":
		return d.handleWatchdogPressureRequest()
	case "watchdog_events":
		return d.handleWatchdogEventsRequest(req.Params)
	case "protect_ban":
		return d.handleProtectBanRequest(req.Params)
	case "unprotect_ban":
		return d.handleUnprotectBanRequest(req.Params)
	case "get_evictable_bans":
		return d.handleGetEvictableBansRequest(req.Params)
	case "evict_old_bans":
		return d.handleEvictOldBansRequest(req.Params)
	case "permanent_ban_stats":
		return d.handlePermanentBanStatsRequest()
	// v1.13.0: Async IPC handlers
	case "replace_set":
		return d.handleReplaceSetRequest(req.Params)
	case "flush_source":
		return d.handleFlushSourceRequest(req.Params)
	case "queue_status":
		return d.handleQueueStatusRequest()
	// v1.13.12: Config reload handler
	case "reload":
		return d.handleReloadRequest(req.Params)
	default:
		return SocketResponse{
			Success: false,
			Error:   "unknown method: " + req.Method,
		}
	}
}
