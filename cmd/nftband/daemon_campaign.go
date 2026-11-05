// =============================================================================
// NFTBan Daemon - BotScan HTTP campaign: kernel side of the campaign consumer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="daemon_campaign"
// meta:type="daemon"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-26"
// meta:description="botguard.CampaignKernel for the daemon: read-only kernel evidence (campaign_prefix_ipv4 elements with remaining lifetime, and whether the input chain drops from it) through the ruleset readers, and the whole-prefix never-ban admission through the authoritative backend. Writes nothing: campaign bans are written by the botguard consumer through the opqueue."
// meta:inventory.binaries="nft"
// meta:inventory.privileges="root (nft read)"
// =============================================================================

package main

import (
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/nftbackend"
	"github.com/itcmsgr/nftban/internal/opqueue"
	"github.com/itcmsgr/nftban/internal/ruleset"
)

type campaignKernel struct {
	backend *nftbackend.Backend
}

func (k campaignKernel) CampaignElements() (map[string]time.Duration, bool, error) {
	elems, present, err := ruleset.NftSetReaderPresent("ip", constants.CampaignPrefixSetIPv4)
	if err != nil || !present {
		return nil, present, err
	}
	out := make(map[string]time.Duration, len(elems))
	for _, e := range elems {
		out[e.Key] = e.Remaining
	}
	return out, true, nil
}

func (k campaignKernel) CampaignDropRuleLive() (bool, error) {
	return ruleset.NftChainDropsFromSet("ip", "input", constants.CampaignPrefixSetIPv4)
}

func (k campaignKernel) AdmitPrefix(prefix string) (bool, string) {
	return k.backend.AdmitPrefix(prefix)
}

// applyGuard re-decides every campaign_prefix_ipv4 add when the opqueue applies it, not when
// it was enqueued: disabled (no marker), (re)enabled within the grace, the drop rule gone
// (which also means the set is gone: a rule cannot reference an absent set) or the prefix no
// longer admitted refuses it, before the backend runs, so nothing is created or refilled.
func (k campaignKernel) applyGuard(markerFile string) opqueue.ApplyGuard {
	return func(set, element string) error {
		if set != constants.CampaignPrefixSetIPv4 {
			return nil
		}
		fi, err := os.Stat(markerFile)
		if err != nil {
			return errors.New("campaign disabled")
		}
		if age := time.Since(fi.ModTime()); age < constants.BotscanCampaignReenableGrace {
			return fmt.Errorf("campaign enabled %s ago (grace %s): a queued add may predate it", age.Truncate(time.Second), constants.BotscanCampaignReenableGrace)
		}
		live, err := k.CampaignDropRuleLive()
		if err != nil || !live {
			return fmt.Errorf("drop rule not live (err=%v)", err)
		}
		if ok, why := k.AdmitPrefix(element); !ok {
			return errors.New("never-ban admission: " + why)
		}
		return nil
	}
}
