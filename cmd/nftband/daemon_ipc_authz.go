// NFTBan - per-peer IPC method authorization for the nftban service account
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="nftband_ipc_authz"
// meta:type="core"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-31"
// meta:description="v1.236 SEC-IPC-NFTBAN-GROUP-SERVES-ALL-METHODS-TO-SERVICE-ACCOUNTS. The socket admits root and members of the nftban group (validatePeerCredentials). Root and the operators in that group keep every method. The nftban SERVICE ACCOUNT (the uid the unprivileged units run as: BotScan, health, queue, exporter, watchdog ...) is limited to the read-only methods and sync: measured on lab4, eight of its nine units send no IPC at all, and the task queue needs sync (feeds_sync / geoban_apply tasks). A compromised service process can therefore no longer flush sets, unban, load a ruleset or open access over IPC."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"os/user"
	"strconv"
)

// serviceAccountUID caches the uid of the nftban service account; -1 when it does not exist
// (then nothing is restricted, because no peer can have that uid).
var serviceAccountUID = -1

func init() {
	if u, err := user.Lookup("nftban"); err == nil {
		if id, err := strconv.Atoi(u.Uid); err == nil {
			serviceAccountUID = id
		}
	}
}

// serviceAccountMethods are the IPC methods the nftban service account may call: methods that
// only read daemon or kernel state, plus sync, which the task queue sends for queued feeds and
// geoban tasks. Every other method, and any method not listed, is refused for that account.
var serviceAccountMethods = map[string]bool{
	"status": true, "modules": true, "check": true, "explain_ip": true, "ping": true,
	"queue_status": true, "set_counts": true, "source_index_count": true, "stats": true,
	"stats_history": true, "permanent_ban_stats": true, "get_evictable_bans": true,
	"watchdog_status": true, "watchdog_events": true, "watchdog_pressure": true,
	"sync": true,
}

// methodPermitted reports whether a peer with the given uid may call method. Only the nftban
// service account is restricted.
func methodPermitted(uid uint32, method string) bool {
	if serviceAccountUID < 0 || int64(uid) != int64(serviceAccountUID) {
		return true
	}
	return serviceAccountMethods[method]
}
