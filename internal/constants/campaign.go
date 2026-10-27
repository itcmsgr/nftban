// =============================================================================
// NFTBan - BotScan HTTP campaign prefix constants
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="constants/campaign"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Set name and ban durations of the BotScan HTTP campaign prefix escalation (owner decision: 3600 s initial, at most 5400 s for a fresh recurrence, never permanent)"
// meta:inventory.files="campaign.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package constants

import "time"

// CampaignPrefixSetIPv4 is the schema-declared timed interval set (install/nftables/nftables.conf.tpl)
// that holds BotScan HTTP campaign /24 prefixes. HTTP/HTTPS drop only. There is no IPv6 twin:
// IPv6 campaign enforcement is per address.
const CampaignPrefixSetIPv4 = "campaign_prefix_ipv4"

// CampaignEnabledMarker (relative to the data dir) exists while BotScan's HTTP campaign is
// enabled: BotScan publishes it each enabled cycle and removes it when disabled. The daemon
// applies campaign signals and the reload/rebuild carries campaign elements only while it
// exists, so a disable empties the set at the next reload and nothing queued refills it.
const CampaignEnabledMarker = "botscan/campaign.enabled"

const (
	// BotscanCampaignBanInitial is the kernel timeout of a first campaign prefix ban.
	BotscanCampaignBanInitial = 3600 * time.Second

	// BotscanCampaignBanMax caps every campaign ban, including a fresh recurrence after the
	// previous one expired. A campaign ban is never permanent and never longer than this.
	BotscanCampaignBanMax = 5400 * time.Second

	// BotscanCampaignRecurrenceWindow: a target banned again within this time after its
	// previous campaign ban EXPIRED is a recurrence (BotscanCampaignBanMax).
	BotscanCampaignRecurrenceWindow = 24 * time.Hour

	// BotscanCampaignReenableGrace: for this long after the campaign is (re)enabled (the
	// marker's mtime), a queued campaign add is refused at application time. A queued add
	// lives at most the bounded write-boundary wait (60 s), so any add from before a
	// disable is gone before the grace ends: a disable/re-enable cannot revive it.
	BotscanCampaignReenableGrace = 120 * time.Second
)

const (
	// BotscanCampaignMaxActionsPerCycle bounds the bans one consumer cycle may write; the
	// excess is counted and not applied (overflow never widens enforcement).
	BotscanCampaignMaxActionsPerCycle = 64

	// BotscanCampaignHistoryMax bounds the remembered expiries (recurrence decisions). When
	// full, a new target is not remembered: its next ban is an initial one (the shorter).
	BotscanCampaignHistoryMax = 4096
)
