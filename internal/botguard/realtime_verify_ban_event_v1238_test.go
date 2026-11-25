// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package botguard

// v1.238 BUG-BOTGUARD-REALTIME-EVENTBAN-ON-ANY-STATE-CHANGE-INCL-ALLOW (owner 2026-11-24).
// Scope of this test, stated exactly: the DNS answers are controlled at the resolver boundary
// (dnsResolver); from there the REAL FCrDNS verifier (verify), the REAL classifier and the REAL decision
// handler (applyVerification) run, and the ban events reaching the bus are counted. The path from a public
// FCrDNS answer to the kernel is not exercised here (no runtime confirmation).
// Expected: verified allowed crawler → Allow → 0 ban events; verified denied bot → Ban → 1 ban event;
// failed verification → Grey → 0 ban events. BotGuard never removes anything from a blacklist set.

import (
	"context"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/opqueue"
)

// fakeDNS answers PTR and A/AAAA lookups from fixed tables (the DNS boundary).
type fakeDNS struct {
	ptr map[string][]string
	fwd map[string][]string
}

func (f fakeDNS) LookupAddr(_ context.Context, addr string) ([]string, error) {
	return f.ptr[addr], nil
}
func (f fakeDNS) LookupHost(_ context.Context, host string) ([]string, error) {
	return f.fwd[strings.TrimSuffix(host, ".")], nil
}

// delRecBackend records which sets had elements removed.
type delRecBackend struct {
	mu      sync.Mutex
	deleted []string
}

func (b *delRecBackend) FlushSet(table, set string) error { return nil }
func (b *delRecBackend) AddElements(table, set string, els []opqueue.SetElement) (int, error) {
	return len(els), nil
}
func (b *delRecBackend) DeleteElements(table, set string, els []opqueue.SetElement) error {
	b.mu.Lock()
	b.deleted = append(b.deleted, set)
	b.mu.Unlock()
	return nil
}
func (b *delRecBackend) GetSetElements(table, set string) ([]string, error)           { return nil, nil }
func (b *delRecBackend) ReplaceSet(table, set string, els []opqueue.SetElement) error { return nil }

func TestRealtimeVerifyOnlyBanPublishesBanEvent(t *testing.T) {
	const (
		allowIP  = "198.51.100.61" // PTR → crawl.googlebot.com → same IP
		deniedIP = "198.51.100.62" // PTR → spider.deniedbot.example → same IP (bot on the denied list)
		failIP   = "198.51.100.63" // PTR claims googlebot, forward does not confirm
	)
	dns := fakeDNS{
		ptr: map[string][]string{
			allowIP:  {"crawl-61.googlebot.com."},
			deniedIP: {"spider-62.deniedbot.example."},
			failIP:   {"crawl-63.googlebot.com."},
		},
		fwd: map[string][]string{
			"crawl-61.googlebot.com":      {allowIP},
			"spider-62.deniedbot.example": {deniedIP},
			"crawl-63.googlebot.com":      {"203.0.113.9"},
		},
	}
	bots := []BotConfig{
		{Name: "GOOGLEBOT", Domains: []string{"googlebot.com"}, VerifyMode: "fcrdns"},
		{Name: "DENIEDBOT", Domains: []string{"deniedbot.example"}, VerifyMode: "fcrdns"},
	}

	b := &delRecBackend{}
	qcfg := opqueue.DefaultQueueConfig()
	qcfg.FlushThreshold = 1
	qcfg.FlushInterval = 5 * time.Millisecond
	q := opqueue.NewOpQueue(b, qcfg)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	q.Start(ctx)

	m := New()
	m.config.Enabled = true
	m.config.AllowedCrawlersFile = "/nonexistent/allowed"
	m.config.DeniedCrawlersFile = "/nonexistent/denied"
	m.bus = eventbus.New()
	m.InitEnforcer(q)
	v := NewFCrDNSVerifier(m.config, bots)
	v.resolver = dns
	cls, err := NewClassifier(m.config, v)
	if err != nil {
		t.Fatal(err)
	}
	cls.mu.Lock()
	cls.allowedBots = bots
	v.allowedBots = bots
	cls.deniedBots = map[string]bool{"DENIEDBOT": true}
	cls.mu.Unlock()
	m.verifier, m.classifier = v, cls

	var mu sync.Mutex
	events := map[string]int{}
	m.bus.Subscribe(eventbus.EventBan, func(e eventbus.Event) {
		mu.Lock()
		events[e.IP]++
		mu.Unlock()
	})

	for _, c := range []struct {
		ip        string
		wantState IPState
		wantBans  int
	}{
		{allowIP, StateAllow, 0},
		{deniedIP, StateBan, 1},
		{failIP, StateGrey, 0},
	} {
		ip := netip.MustParseAddr(c.ip)
		rec := m.getOrCreate(ip)
		rec.State = StatePending // a claimed crawler awaiting verification
		vr := v.verify(ctx, ip)  // real FCrDNS logic, controlled DNS answers
		m.applyVerification(vr)  // real decision handler
		if got, _ := m.GetIPRecord(ip); got.State != c.wantState {
			t.Fatalf("%s: state %s, want %s (verify=%s)", c.ip, got.State, c.wantState, vr.Status)
		}
		time.Sleep(20 * time.Millisecond)
		mu.Lock()
		n := events[c.ip]
		mu.Unlock()
		if n != c.wantBans {
			t.Errorf("%s (%s): %d ban events, want %d", c.ip, c.wantState, n, c.wantBans)
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, set := range b.deleted {
		if strings.HasPrefix(set, "blacklist") {
			t.Errorf("BotGuard removed an element from %s (a ban from another source must be kept)", set)
		}
	}
}
