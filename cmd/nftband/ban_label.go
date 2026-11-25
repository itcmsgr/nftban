// =============================================================================
// NFTBan - bans.log source label for daemon bans (label only; class/duration/set unaffected)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband-ban-label"
// meta:type="lib"
// meta:version="1.238.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.238 BUG-BANS-LOG-LABELS-BOTSCAN-ESCALATION-AS-DDOS (owner 2026-11-24, audit KERNEL_WRITER_AUDIT_d016f838 §0). The two label switches of the bans.log writers moved here verbatim; the only change: a BotScan signal enforced by BotGuard (event data source=clock3_batch) and a direct BotScan IPC ban are logged as botscan. In the event subscriber class/duration come from the timeout and the kernel set from the backend, not from the label. In the IPC handler the class keeps using the previous label (classSource), so a direct BotScan ban stays class manual."
// meta:inventory.files="cmd/nftband/ban_label.go"
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

// botscanBatchSource is the event-data "source" the BotGuard module sets on a ban that came from a
// BotScan batch signal (internal/botguard/guard.go, WithData("source", "clock3_batch")).
const botscanBatchSource = "clock3_batch"

// subscriberBanLabel is the event subscriber's label switch (daemon_init.go), unchanged except for
// the BotScan batch branch. Returns the bans.log label and the persistence key.
func subscriberBanLabel(source, dataSource string) (banSource, persistKey string) {
	banSource = banlog.SourceManual
	persistKey = "persistent"
	switch {
	case strings.Contains(source, "portscan"):
		banSource = banlog.SourcePortscan
		persistKey = "portscan"
	case strings.Contains(source, "login"):
		banSource = banlog.SourceLogin
		persistKey = "login"
	case strings.Contains(source, "ddos"):
		banSource = banlog.SourceDDoS
		persistKey = "ddos"
	case strings.Contains(source, "feed"):
		banSource = banlog.SourceFeeds
	case strings.Contains(source, "suricata"):
		banSource = banlog.SourceSuricata
	case strings.Contains(source, "botguard"):
		banSource = banlog.SourceDDoS // realtime Bot guard bans categorized as DDoS
		if dataSource == botscanBatchSource {
			banSource = banlog.SourceBotScan // v1.238: BotScan signal enforced by the BotGuard module
		}
	}
	return banSource, persistKey
}

// ipcBanLabels is the IPC ban handler's label switch (daemon_handlers_ban.go), unchanged.
// classSource is what the handler derives the ban class from (as before); logSource is what bans.log
// shows — identical except that a direct BotScan ban is logged as botscan.
func ipcBanLabels(source string) (classSource, logSource string) {
	classSource = banlog.SourceManual
	switch {
	case strings.Contains(source, "portscan"):
		classSource = banlog.SourcePortscan
	case strings.Contains(source, "login"):
		classSource = banlog.SourceLogin
	case strings.Contains(source, "ddos"):
		classSource = banlog.SourceDDoS
	case strings.Contains(source, "feed"):
		classSource = banlog.SourceFeeds
	case strings.Contains(source, "suricata"):
		classSource = banlog.SourceSuricata
	}
	logSource = classSource
	if strings.Contains(source, "botscan") {
		logSource = banlog.SourceBotScan // v1.238: direct BotScan ban; class stays from classSource
	}
	return classSource, logSource
}
