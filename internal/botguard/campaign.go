// =============================================================================
// NFTBan - HTTP Bot Guard: BotScan HTTP campaign consumer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// Package: botguard
// Purpose: apply BotScan cross-IP campaign signals (campaign_prefix / campaign_member)
//
// meta:name="botguard_campaign"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-26"
// meta:description="BotScan HTTP campaign consumer. A campaign_prefix signal escalates an IPv4 /24 into campaign_prefix_ipv4 (HTTP/HTTPS drop); a campaign_member signal bans one IPv6 address in blacklist_manual_ipv6. Same code for BotGuard enabled and disabled. Writes only through the opqueue and never publishes EventBan, so a campaign ban never reaches persistent-offender escalation. Duration is decided here: 3600 s, a fresh recurrence after expiry 5400 s, never 0 (permanent). An active target is never renewed. A /24 is refused whole when it touches never-ban space, a shared CDN edge, or when that protection data is unavailable; it is reported not-enforced when the set or its drop rule is absent."
// meta:inventory.files="campaign.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"fmt"
	"log"
	"net/netip"
	"os"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/safeconv"
)

// campaignSource is the opqueue provenance of every campaign ban.
const campaignSource = "botscan-campaign"

// CampaignKernel is the kernel and never-ban side of the campaign consumer, injected by the
// daemon (SetCampaignKernel). nil = campaign signals are reported not-enforced.
type CampaignKernel interface {
	// CampaignElements returns every element of campaign_prefix_ipv4 with its remaining
	// lifetime; present=false when the set does not exist (a ruleset rendered before it).
	CampaignElements() (elems map[string]time.Duration, present bool, err error)
	// CampaignDropRuleLive reports whether the input chain drops from campaign_prefix_ipv4.
	CampaignDropRuleLive() (bool, error)
	// AdmitPrefix is the whole-prefix, fail-closed never-ban decision (nftbackend).
	AdmitPrefix(prefix string) (bool, string)
}

// SetCampaignKernel injects the kernel side. Safe to call once at daemon init.
func (m *Module) SetCampaignKernel(k CampaignKernel) {
	m.campaignKernel = k
}

func isCampaignSignal(sig *BatchSignal) bool {
	return sig.Kind == SignalKindCampaignPrefix || sig.Kind == SignalKindCampaignMember
}

// campaignPrefix parses s as an IPv4 /24 in canonical (masked) form.
func campaignPrefix(s string) (string, bool) {
	p, err := netip.ParsePrefix(s)
	if err != nil || !p.Addr().Is4() || p.Bits() != 24 || p.Masked() != p {
		return "", false
	}
	return p.String(), true
}

// campaignRecord is one target's campaign ban as the consumer knows it. A prefix ban is
// confirmed only once the kernel has shown it: the apply guard may refuse an enqueued add,
// and an unconfirmed record must then neither suppress the next issue nor make it a
// recurrence. IPv6 member bans have no apply guard and are confirmed when enqueued.
type campaignRecord struct {
	queuedAt  time.Time
	expires   time.Time
	confirmed bool
}

// campaignTTL decides the duration for target at now: a recurrence (5400 s) when a confirmed
// previous campaign ban expired within the recurrence window, otherwise the initial 3600 s.
func (m *Module) campaignTTL(target string, now time.Time) (time.Duration, bool) {
	m.campaignMu.Lock()
	defer m.campaignMu.Unlock()
	if r, ok := m.campaignHistory[target]; ok && r.confirmed && now.After(r.expires) && now.Sub(r.expires) <= constants.BotscanCampaignRecurrenceWindow {
		return constants.BotscanCampaignBanMax, true
	}
	return constants.BotscanCampaignBanInitial, false
}

// campaignActive reports a campaign ban for target that must not be issued again: confirmed
// and still running, or enqueued so recently that the queue may still be applying it.
func (m *Module) campaignActive(target string, now time.Time) bool {
	m.campaignMu.Lock()
	defer m.campaignMu.Unlock()
	r, ok := m.campaignHistory[target]
	if !ok {
		return false
	}
	if r.confirmed {
		return now.Before(r.expires)
	}
	return now.Sub(r.queuedAt) <= constants.BotscanCampaignQueuedWindow
}

// reconcileCampaignPrefixes aligns the prefix records with the kernel read of this cycle: a
// record whose prefix is in the set is confirmed; an unconfirmed one past the queued window
// was never applied (refused at application) and is forgotten, so the next signal issues it.
func (m *Module) reconcileCampaignPrefixes(elems map[string]time.Duration, now time.Time) {
	m.campaignMu.Lock()
	defer m.campaignMu.Unlock()
	for t, r := range m.campaignHistory {
		if !strings.Contains(t, "/") {
			continue // IPv6 members: not in this set
		}
		if _, in := elems[t]; in {
			r.confirmed = true
			m.campaignHistory[t] = r
		} else if !r.confirmed && now.Sub(r.queuedAt) > constants.BotscanCampaignQueuedWindow {
			delete(m.campaignHistory, t)
		}
	}
}

// rememberCampaign records an enqueued campaign ban. Entries whose ban ended more than the
// recurrence window ago are pruned first; a full history does not record (the next ban is
// then an initial one).
func (m *Module) rememberCampaign(target string, exp, now time.Time, confirmed bool) {
	m.campaignMu.Lock()
	defer m.campaignMu.Unlock()
	if m.campaignHistory == nil {
		m.campaignHistory = make(map[string]campaignRecord)
	}
	if _, ok := m.campaignHistory[target]; !ok && len(m.campaignHistory) >= constants.BotscanCampaignHistoryMax {
		for t, r := range m.campaignHistory {
			if now.Sub(r.expires) > constants.BotscanCampaignRecurrenceWindow {
				delete(m.campaignHistory, t)
			}
		}
		if len(m.campaignHistory) >= constants.BotscanCampaignHistoryMax {
			log.Printf("[botguard] campaign history full (%d): %s not remembered (its next ban is an initial one)", constants.BotscanCampaignHistoryMax, target)
			return
		}
	}
	m.campaignHistory[target] = campaignRecord{queuedAt: now, expires: exp, confirmed: confirmed}
}

// applyCampaignSignals applies one consumer cycle's campaign signals. The kernel is read
// once per cycle; returns the number of bans written.
func (m *Module) applyCampaignSignals(sigs []BatchSignal) int {
	if len(sigs) == 0 {
		return 0
	}
	var applied, duplicate, refused, notEnforced, recurrence, capHits int64
	defer func() {
		m.mu.Lock()
		m.stats.CampaignSignals += int64(len(sigs))
		m.stats.CampaignRequested += applied
		m.stats.CampaignDuplicate += duplicate
		m.stats.CampaignRefused += refused
		m.stats.CampaignNotEnforced += notEnforced
		m.stats.CampaignRecurrence += recurrence
		m.stats.CampaignCycleCapHits += capHits
		m.mu.Unlock()
		if m.logger != nil {
			m.logger.LogEvent("INFO", fmt.Sprintf("botscan campaign: signals=%d requested=%d duplicate=%d refused=%d not_enforced=%d recurrence=%d over_cycle_cap=%d",
				len(sigs), applied, duplicate, refused, notEnforced, recurrence, capHits))
		}
	}()

	// Disabled (marker absent): nothing is written, so a signal queued before the disable
	// cannot refill the set after it was emptied. The marker's mtime is when the feature was
	// enabled: a signal produced before it (queued across a disable/re-enable) is stale.
	var enabledSince time.Time
	if m.config != nil && m.config.CampaignMarkerFile != "" {
		if fi, err := os.Stat(m.config.CampaignMarkerFile); err == nil {
			enabledSince = fi.ModTime()
		}
	}
	if enabledSince.IsZero() {
		m.mu.Lock()
		m.stats.CampaignDisabled += int64(len(sigs))
		m.mu.Unlock()
		notEnforced = int64(len(sigs))
		log.Printf("[botguard] campaign disabled (no %s): %d campaign signal(s) not applied", constants.CampaignEnabledMarker, len(sigs))
		return 0
	}
	k := m.campaignKernel
	if k == nil || m.opQueue == nil {
		notEnforced = int64(len(sigs))
		return 0
	}

	// Enforcement evidence for the prefix path: the set exists and the drop rule is live.
	elems, present, eerr := k.CampaignElements()
	live, rerr := k.CampaignDropRuleLive()
	prefixEnforceable := eerr == nil && present && rerr == nil && live
	if elems == nil {
		elems = map[string]time.Duration{}
	}
	if eerr == nil && present {
		m.reconcileCampaignPrefixes(elems, time.Now()) // only on a valid read of the set
	}
	if !prefixEnforceable {
		log.Printf("[botguard] campaign prefixes NOT enforceable (set present=%v err=%v, drop rule live=%v err=%v): prefix signals reported, nothing written",
			present, eerr, live, rerr)
	}
	edges := m.sharedEdgeRanges()
	now := time.Now()
	actions := 0

	for i := range sigs {
		sig := &sigs[i]
		if actions >= constants.BotscanCampaignMaxActionsPerCycle {
			capHits++
			continue
		}
		if sig.TS != 0 && time.Unix(sig.TS, 0).Before(enabledSince.Truncate(time.Second)) {
			m.mu.Lock()
			m.stats.CampaignDisabled++
			m.mu.Unlock()
			notEnforced++ // produced before the current enable: never revived
			continue
		}
		var setName, target string
		switch sig.Kind {
		case SignalKindCampaignPrefix:
			p, ok := campaignPrefix(sig.Prefix)
			if !ok {
				refused++
				continue
			}
			if !prefixEnforceable {
				notEnforced++
				continue
			}
			if _, active := elems[p]; active || m.campaignActive(p, now) {
				// Running ban (kernel), or written by an earlier cycle and still queued or
				// running (history): never renewed by a repeated scan or duplicate signal.
				duplicate++
				continue
			}
			if edges.Size() == 0 {
				refused++ // shared-edge data unavailable: a prefix is not admitted without it
				continue
			}
			if label, hit := edges.Overlaps(netip.MustParsePrefix(p)); hit {
				refused++
				log.Printf("[botguard] campaign prefix %s refused: overlaps shared CDN edge %s", p, label)
				continue
			}
			if ok, why := k.AdmitPrefix(p); !ok {
				refused++
				log.Printf("[botguard] campaign prefix %s refused by never-ban admission: %s", p, why)
				continue
			}
			setName, target = constants.CampaignPrefixSetIPv4, p
		case SignalKindCampaignMember:
			ip, err := netip.ParseAddr(sig.IP)
			if err != nil || !ip.Unmap().Is6() || ip.Is4In6() {
				refused++ // IPv4 campaign sources stay on the per-IP path; members are IPv6 only
				continue
			}
			target = ip.String()
			if m.campaignActive(target, now) {
				duplicate++
				continue
			}
			if _, hit := edges.Match(ip); hit {
				refused++
				continue
			}
			setName = botscanManualSetV6
			if exempt, why := m.opQueue.CheckExempt(setName, target); exempt {
				refused++
				log.Printf("[botguard] campaign member %s refused: never-ban exempt (%s)", target, why)
				continue
			}
		default:
			refused++
			continue
		}

		ttl, isRecurrence := m.campaignTTL(target, now)
		ttlSec := safeconv.ToUint32OrZero(int(ttl / time.Second))
		if ttlSec == 0 || ttl > constants.BotscanCampaignBanMax {
			refused++ // a zero timeout would be permanent: never written
			continue
		}
		reason := campaignSource
		if sig.CampaignID != "" {
			reason += ":" + sig.CampaignID
		}
		if err := m.opQueue.EnqueueBan(setName, target, ttlSec, campaignSource, reason); err != nil {
			log.Printf("[botguard] campaign enqueue error %s -> %s: %v", target, setName, err)
			notEnforced++
			continue
		}
		// A prefix is confirmed by a later kernel read (the apply guard may still refuse it);
		// an IPv6 member has no apply guard.
		m.rememberCampaign(target, now.Add(ttl), now, setName != constants.CampaignPrefixSetIPv4)
		if setName == constants.CampaignPrefixSetIPv4 {
			elems[target] = ttl // a second signal for it in this cycle is a duplicate
		}
		m.appendBotscanEvidence(sig, setName, ttlSec)
		applied++
		actions++
		if isRecurrence {
			recurrence++
		}
		if m.logger != nil {
			m.logger.LogEvent("INFO", fmt.Sprintf("botscan campaign ban requested → %s %s ttl=%ds recurrence=%v reason=%s (the queue's apply guard decides; enforcement = kernel counter)", setName, target, ttlSec, isRecurrence, reason))
		}
	}
	return int(applied)
}
