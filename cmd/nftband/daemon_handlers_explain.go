// =============================================================================
// NFTBan v1.191.0 - nftband Daemon - BotGuard read-only explain handler
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.191.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Read-only IPC handler: explain an IP's temporary BotGuard decision-cache state"
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
	"context"
	"net/netip"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard"
)

// explainIPBudget is the strict short query budget for the read-only explain path.
const explainIPBudget = 200 * time.Millisecond

// handleExplainIPRequest is a READ-ONLY query of an IP's TEMPORARY BotGuard decision-cache
// state. It never mutates: no ban/grey/whitelist/blacklist, no cache add/transition/TTL
// refresh. It degrades cleanly (cache_available=false) when the module/cache is unavailable
// or the short budget is exceeded, and never implies the IP is safe/not-banned. Durable
// nft-set truth is a separate concern (increment 6B shell fallback).
func (d *Daemon) handleExplainIPRequest(params map[string]any) SocketResponse {
	ipStr, _ := params["ip"].(string)
	if ipStr == "" {
		return SocketResponse{Success: false, Error: "explain_ip: missing 'ip' parameter"}
	}
	ip, err := netip.ParseAddr(ipStr)
	if err != nil {
		return SocketResponse{Success: false, Error: "explain_ip: invalid ip: " + err.Error()}
	}

	unavailable := func(note string) SocketResponse {
		return SocketResponse{Success: true, Data: botguard.ExplainResponse{
			IP:               ip.String(),
			Temporary:        true,
			State:            "unavailable",
			CacheAvailable:   false,
			DurableAuthority: "not_evaluated",
			Source:           botguard.ExplainSource,
			Note:             note,
		}}
	}

	mod, ok := d.registry.Get(botguard.ModuleName)
	if !ok {
		return unavailable("botguard module not registered")
	}
	bg, ok := mod.(*botguard.Module)
	if !ok {
		return unavailable("botguard module type mismatch")
	}

	ctx, cancel := context.WithTimeout(context.Background(), explainIPBudget)
	defer cancel()
	return SocketResponse{Success: true, Data: bg.ExplainIP(ctx, ip)}
}
