// =============================================================================
// NFTBan - bans.log source label for a ban (shared by the event subscriber and the IPC ban handler)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband-ban-source-label"
// meta:type="lib"
// meta:version="1.238.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.238 BUG-BANS-LOG-LABELS-BOTSCAN-ESCALATION-AS-DDOS (owner 2026-11-24): one mapping from the producer's source to the bans.log source column, used by both writers. The real source reaches the writer: a BotScan signal arrives as module botguard with event data source=clock3_batch (internal/botguard/guard.go), a direct BotScan ban as IPC source botscan. Both were mislabelled (ddos / manual). Realtime BotGuard bans keep their previous label (ddos)."
// meta:inventory.files="cmd/nftband/ban_source_label.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/banlog"
)

// botscanBatchSource is the event-data source the BotGuard module sets on a ban that came from a
// BotScan batch signal (internal/botguard/guard.go, WithData("source", "clock3_batch")).
const botscanBatchSource = "clock3_batch"

// banSourceLabel maps a ban's producer source (and, for module events, the event-data "source")
// to the bans.log source column and the persistence key used for permanent module bans.
// Order matters: "botscan" is tested before the generic labels it could otherwise collide with.
func banSourceLabel(source, dataSource string) (label, persistKey string) {
	switch {
	case strings.Contains(source, "botscan"):
		return banlog.SourceBotScan, "persistent"
	case strings.Contains(source, "portscan"):
		return banlog.SourcePortscan, "portscan"
	case strings.Contains(source, "login"):
		return banlog.SourceLogin, "login"
	case strings.Contains(source, "ddos"):
		return banlog.SourceDDoS, "ddos"
	case strings.Contains(source, "feed"):
		return banlog.SourceFeeds, "persistent"
	case strings.Contains(source, "suricata"):
		return banlog.SourceSuricata, "persistent"
	case strings.Contains(source, "botguard"):
		if dataSource == botscanBatchSource {
			return banlog.SourceBotScan, "persistent" // BotScan signal enforced by the BotGuard module
		}
		return banlog.SourceDDoS, "persistent" // realtime BotGuard: label unchanged
	}
	return banlog.SourceManual, "persistent"
}
