// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package botguard

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/opqueue"
)

// fakeCampaignKernel is the kernel/never-ban side under test control.
type fakeCampaignKernel struct {
	elems   map[string]time.Duration
	present bool
	live    bool
	refuse  map[string]string // prefix -> refusal reason
}

func (k *fakeCampaignKernel) CampaignElements() (map[string]time.Duration, bool, error) {
	if !k.present {
		return nil, false, nil
	}
	out := map[string]time.Duration{}
	for p, d := range k.elems {
		out[p] = d
	}
	return out, true, nil
}
func (k *fakeCampaignKernel) CampaignDropRuleLive() (bool, error) { return k.live, nil }
func (k *fakeCampaignKernel) AdmitPrefix(p string) (bool, string) {
	if why, ok := k.refuse[p]; ok {
		return false, why
	}
	return true, ""
}

type campaignHarness struct {
	m        *Module
	b        *ttlBackend
	k        *fakeCampaignKernel
	eventBan atomic.Int64
}

func newCampaignHarness(t *testing.T) *campaignHarness {
	t.Helper()
	h := &campaignHarness{
		b: &ttlBackend{ttl: map[string]uint32{}},
		k: &fakeCampaignKernel{elems: map[string]time.Duration{}, present: true, live: true, refuse: map[string]string{}},
	}
	qcfg := opqueue.DefaultQueueConfig()
	qcfg.FlushThreshold = 1
	qcfg.FlushInterval = 5 * time.Millisecond
	q := opqueue.NewOpQueue(h.b, qcfg)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	q.Start(ctx)
	h.m = New()
	h.m.bus = eventbus.New()
	h.m.bus.Subscribe(eventbus.EventBan, func(eventbus.Event) { h.eventBan.Add(1) })
	h.m.InitEnforcer(q)
	h.m.SetCampaignKernel(h.k)
	dir := t.TempDir()
	h.m.config.BatchSignalFile = filepath.Join(dir, "batch_signals.jsonl")
	edges := filepath.Join(dir, "edges.txt")
	if err := os.WriteFile(edges, []byte("104.16.0.0/13\n2606:4700::/32\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.m.config.SharedEdgeFiles = []string{edges}
	marker := filepath.Join(dir, "campaign.enabled") // BotScan's "campaign enabled" publication
	if err := os.WriteFile(marker, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	h.m.config.CampaignMarkerFile = marker
	return h
}

// Disabled (marker absent): a queued signal writes nothing, so it cannot refill the set.
func TestCampaignDisabledMarkerWritesNothing(t *testing.T) {
	h := newCampaignHarness(t)
	if err := os.Remove(h.m.config.CampaignMarkerFile); err != nil {
		t.Fatal(err)
	}
	if n := h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24"), memberSig("2a01:4f8:c0c:1234::7")}); n != 0 {
		t.Fatalf("applied %d while disabled", n)
	}
	if h.m.stats.CampaignDisabled != 2 {
		t.Fatalf("campaign_disabled=%d, want 2", h.m.stats.CampaignDisabled)
	}
	if !h.neverApplied(constants.CampaignPrefixSetIPv4, "45.33.32.0/24") {
		t.Fatal("a queued signal refilled the set after disable")
	}
}

// A signal produced before the current enable (queued across a disable/re-enable) is never
// revived: the marker's mtime is the enabled-since time.
func TestCampaignStaleSignalAcrossReenable(t *testing.T) {
	h := newCampaignHarness(t)
	reenabled := time.Now().Add(30 * time.Second)
	if err := os.Chtimes(h.m.config.CampaignMarkerFile, reenabled, reenabled); err != nil {
		t.Fatal(err)
	}
	s := prefixSig("45.33.32.0/24") // TS = now, i.e. before the re-enable
	if n := h.m.applyCampaignSignals([]BatchSignal{s}); n != 0 {
		t.Fatalf("a pre-enable signal was applied (%d)", n)
	}
	if h.m.stats.CampaignDisabled != 1 {
		t.Fatalf("campaign_disabled=%d, want 1", h.m.stats.CampaignDisabled)
	}
	if !h.neverApplied(constants.CampaignPrefixSetIPv4, "45.33.32.0/24") {
		t.Fatal("a stale signal was revived after re-enable")
	}
}

// A ban written by an earlier cycle and still queued (not yet in the kernel read) is not
// written a second time.
func TestCampaignQueuedBanNotReissued(t *testing.T) {
	h := newCampaignHarness(t)
	h.m.campaignHistory = map[string]campaignRecord{"45.33.32.0/24": {
		queuedAt: time.Now().Add(-10 * time.Second), expires: time.Now().Add(3590 * time.Second)}}
	if n := h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24")}); n != 0 {
		t.Fatalf("a queued/running ban was re-issued (%d)", n)
	}
	if h.m.stats.CampaignDuplicate != 1 {
		t.Fatalf("duplicate=%d, want 1", h.m.stats.CampaignDuplicate)
	}
}

// RC regression (found by the v1.236 RC kernel tests on EL9/EL10): an enqueued prefix ban that
// the apply guard refused (re-enable grace) never reached the kernel, yet its record kept the
// /24 "active" for 3600 s, so the next cycle never issued it. An unconfirmed record past the
// queued window is forgotten: the next signal issues an INITIAL ban (not a recurrence).
func TestCampaignRefusedAtApplyIsReissued(t *testing.T) {
	h := newCampaignHarness(t)
	h.m.campaignHistory = map[string]campaignRecord{"45.33.32.0/24": {
		queuedAt: time.Now().Add(-5 * time.Minute), expires: time.Now().Add(55 * time.Minute)}}
	if n := h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24")}); n != 1 {
		t.Fatalf("a ban refused at application was not re-issued (%d)", n)
	}
	if ttl, ok := h.waitTTL(constants.CampaignPrefixSetIPv4, "45.33.32.0/24"); !ok || ttl != 3600 {
		t.Fatalf("ttl=%d ok=%v, want an initial 3600 (an unapplied ban is not a recurrence)", ttl, ok)
	}
}

// A kernel read that shows the prefix confirms its record (then it can count as a recurrence).
func TestCampaignKernelReadConfirms(t *testing.T) {
	h := newCampaignHarness(t)
	h.m.campaignHistory = map[string]campaignRecord{"45.33.32.0/24": {
		queuedAt: time.Now().Add(-10 * time.Minute), expires: time.Now().Add(50 * time.Minute)}}
	h.k.elems["45.33.32.0/24"] = 3000 * time.Second
	h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24")})
	if r := h.m.campaignHistory["45.33.32.0/24"]; !r.confirmed {
		t.Fatal("a prefix seen in the kernel was not confirmed")
	}
}

func prefixSig(prefix string) BatchSignal {
	return BatchSignal{IP: "45.33.32.61", Action: "ban", Score: 90, TS: time.Now().Unix(),
		Kind: SignalKindCampaignPrefix, Prefix: prefix, CampaignID: "site.log:query_complexity:1"}
}

func memberSig(ip string) BatchSignal {
	return BatchSignal{IP: ip, Action: "ban", Score: 90, TS: time.Now().Unix(), Kind: SignalKindCampaignMember}
}

// waitTTL waits for the opqueue to apply set|elem; ok=false if it never did.
func (h *campaignHarness) waitTTL(set, elem string) (uint32, bool) {
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if v, ok := h.b.get(set, elem); ok {
			return v, true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return 0, false
}

// neverApplied waits a little and reports whether set|elem stayed unwritten.
func (h *campaignHarness) neverApplied(set, elem string) bool {
	time.Sleep(60 * time.Millisecond)
	_, ok := h.b.get(set, elem)
	return !ok
}

func TestCampaignPrefixInitialTTLAndNoEventBan(t *testing.T) {
	h := newCampaignHarness(t)
	if n := h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24")}); n != 1 {
		t.Fatalf("applied %d, want 1", n)
	}
	ttl, ok := h.waitTTL(constants.CampaignPrefixSetIPv4, "45.33.32.0/24")
	if !ok || ttl != 3600 {
		t.Fatalf("kernel write ttl=%d ok=%v, want 3600", ttl, ok)
	}
	time.Sleep(30 * time.Millisecond)
	if n := h.eventBan.Load(); n != 0 {
		t.Fatalf("campaign path published %d EventBan: it must never reach persistent escalation", n)
	}
}

func TestCampaignActivePrefixIsNotRenewed(t *testing.T) {
	h := newCampaignHarness(t)
	h.k.elems["45.33.32.0/24"] = 1200 * time.Second
	if n := h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24")}); n != 0 {
		t.Fatalf("an active prefix was re-applied (%d)", n)
	}
	if h.m.stats.CampaignDuplicate != 1 {
		t.Fatalf("duplicate=%d, want 1", h.m.stats.CampaignDuplicate)
	}
	if !h.neverApplied(constants.CampaignPrefixSetIPv4, "45.33.32.0/24") {
		t.Fatal("an active prefix's timer was written again (renewal)")
	}
}

func TestCampaignDuplicateInOneCycleAppliedOnce(t *testing.T) {
	h := newCampaignHarness(t)
	s := prefixSig("45.33.32.0/24")
	if n := h.m.applyCampaignSignals([]BatchSignal{s, s, s}); n != 1 {
		t.Fatalf("applied %d, want 1", n)
	}
	if h.m.stats.CampaignDuplicate != 2 {
		t.Fatalf("duplicate=%d, want 2", h.m.stats.CampaignDuplicate)
	}
}

func TestCampaignRecurrenceWindow(t *testing.T) {
	cases := []struct {
		name    string
		expired time.Duration // how long ago the previous ban expired
		want    uint32
	}{
		{"fresh recurrence after expiry", 10 * time.Minute, 5400},
		{"recurrence outside the window", 25 * time.Hour, 3600},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newCampaignHarness(t)
			h.m.campaignHistory = map[string]campaignRecord{"45.33.32.0/24": {
				queuedAt: time.Now().Add(-c.expired - time.Hour), expires: time.Now().Add(-c.expired), confirmed: true}}
			h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24")})
			ttl, ok := h.waitTTL(constants.CampaignPrefixSetIPv4, "45.33.32.0/24")
			if !ok || ttl != c.want {
				t.Fatalf("ttl=%d ok=%v, want %d", ttl, ok, c.want)
			}
			if ttl > uint32(constants.BotscanCampaignBanMax/time.Second) {
				t.Fatalf("ttl %d above the campaign maximum", ttl)
			}
		})
	}
}

func TestCampaignNotEnforcedWritesNothing(t *testing.T) {
	cases := []struct {
		name    string
		present bool
		live    bool
	}{
		{"set absent", false, true},
		{"drop rule absent", true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newCampaignHarness(t)
			h.k.present, h.k.live = c.present, c.live
			if n := h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24")}); n != 0 {
				t.Fatalf("applied %d with no enforcement path", n)
			}
			if h.m.stats.CampaignNotEnforced != 1 {
				t.Fatalf("not_enforced=%d, want 1", h.m.stats.CampaignNotEnforced)
			}
			if !h.neverApplied(constants.CampaignPrefixSetIPv4, "45.33.32.0/24") {
				t.Fatal("written although the set or its drop rule is absent")
			}
		})
	}
	t.Run("no kernel side", func(t *testing.T) {
		h := newCampaignHarness(t)
		h.m.SetCampaignKernel(nil)
		h.m.applyCampaignSignals([]BatchSignal{prefixSig("45.33.32.0/24")})
		if h.m.stats.CampaignNotEnforced != 1 {
			t.Fatalf("not_enforced=%d, want 1", h.m.stats.CampaignNotEnforced)
		}
	})
}

func TestCampaignPrefixRefusals(t *testing.T) {
	cases := []struct {
		name, prefix string
		setup        func(h *campaignHarness)
	}{
		{"never-ban overlap", "45.33.32.0/24", func(h *campaignHarness) { h.k.refuse["45.33.32.0/24"] = "overlaps-exempt" }},
		{"wider than /24", "45.33.0.0/16", nil},
		{"narrower than /24", "45.33.32.0/25", nil},
		{"not the network address", "45.33.32.7/24", nil},
		{"IPv6 prefix", "2a01:4f8::/48", nil},
		{"shared CDN edge", "104.16.5.0/24", nil},
		{"shared-edge data unavailable", "45.33.32.0/24", func(h *campaignHarness) {
			h.m.config.SharedEdgeFiles = []string{filepath.Join(t.TempDir(), "missing")}
			h.m.sharedEdges = newSharedEdgeSet(h.m.config.SharedEdgeFiles)
			h.m.sharedEdgesOnce.Do(func() {})
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newCampaignHarness(t)
			if c.setup != nil {
				c.setup(h)
			}
			if n := h.m.applyCampaignSignals([]BatchSignal{prefixSig(c.prefix)}); n != 0 {
				t.Fatalf("%s applied", c.prefix)
			}
			if h.m.stats.CampaignRefused != 1 {
				t.Fatalf("refused=%d, want 1", h.m.stats.CampaignRefused)
			}
		})
	}
}

func TestCampaignMemberIPv6PerAddress(t *testing.T) {
	h := newCampaignHarness(t)
	ip := "2a01:4f8:c0c:1234::7"
	if n := h.m.applyCampaignSignals([]BatchSignal{memberSig(ip)}); n != 1 {
		t.Fatalf("applied %d, want 1", n)
	}
	ttl, ok := h.waitTTL("blacklist_manual_ipv6", ip)
	if !ok || ttl != 3600 {
		t.Fatalf("ttl=%d ok=%v, want 3600 in blacklist_manual_ipv6", ttl, ok)
	}
	// Running in history: a second signal is a duplicate, not a renewal.
	if n := h.m.applyCampaignSignals([]BatchSignal{memberSig(ip)}); n != 0 {
		t.Fatalf("an active member was re-applied (%d)", n)
	}
	// IPv4 and IPv4-mapped members stay on the per-IP path.
	for _, v4 := range []string{"45.33.32.61", "::ffff:45.33.32.61"} {
		h.m.applyCampaignSignals([]BatchSignal{memberSig(v4)})
	}
	if h.m.stats.CampaignRefused != 2 {
		t.Fatalf("refused=%d, want 2 (IPv4 members)", h.m.stats.CampaignRefused)
	}
	// A shared CDN edge address is never a member ban.
	h.m.applyCampaignSignals([]BatchSignal{memberSig("2606:4700::1")})
	if h.m.stats.CampaignRefused != 3 {
		t.Fatalf("refused=%d, want 3 (CDN edge)", h.m.stats.CampaignRefused)
	}
}

func TestCampaignCycleCap(t *testing.T) {
	h := newCampaignHarness(t)
	var sigs []BatchSignal
	for i := 0; i < constants.BotscanCampaignMaxActionsPerCycle+6; i++ {
		sigs = append(sigs, prefixSig(fmt.Sprintf("45.%d.%d.0/24", 40+i/200, i%200)))
	}
	if n := h.m.applyCampaignSignals(sigs); n != constants.BotscanCampaignMaxActionsPerCycle {
		t.Fatalf("applied %d, want %d", n, constants.BotscanCampaignMaxActionsPerCycle)
	}
	if h.m.stats.CampaignCycleCapHits != 6 {
		t.Fatalf("over_cycle_cap=%d, want 6", h.m.stats.CampaignCycleCapHits)
	}
}

// Both BotGuard routes (enabled and disabled) take the campaign path from the signal file,
// and neither publishes EventBan for it.
func TestCampaignSignalFileBothRoutes(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(fmt.Sprintf("botguard_enabled=%v", enabled), func(t *testing.T) {
			h := newCampaignHarness(t)
			h.m.config.Enabled = enabled
			line, err := json.Marshal(prefixSig("45.33.32.0/24"))
			if err != nil {
				t.Fatal(err)
			}
			path := h.m.config.BatchSignalFile + ".consuming"
			if err := os.WriteFile(path, append(line, '\n'), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := h.m.consumeSignalFile(path); err != nil {
				t.Fatal(err)
			}
			if ttl, ok := h.waitTTL(constants.CampaignPrefixSetIPv4, "45.33.32.0/24"); !ok || ttl != 3600 {
				t.Fatalf("ttl=%d ok=%v, want 3600", ttl, ok)
			}
			if _, ok := h.b.get("blacklist_manual_ipv4", "45.33.32.61"); ok {
				t.Fatal("campaign signal also took the per-IP route")
			}
			time.Sleep(30 * time.Millisecond)
			if n := h.eventBan.Load(); n != 0 {
				t.Fatalf("EventBan published %d times", n)
			}
		})
	}
}
