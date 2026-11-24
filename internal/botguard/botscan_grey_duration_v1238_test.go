// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package botguard

// v1.238 (owner 2026-11-24; audit KERNEL_WRITER_AUDIT_d016f838 §0, lab2 evidence):
//   BUG-BOTSCAN-GREY-SIGNAL-ALSO-CREATES-1H-BLACKLIST-BAN — a BotScan grey (30 min throttle) also became a
//   1 h blacklist ban, because every BotGuard state change published EventBan;
//   BUG-BOTSCAN-BATCH-BAN-TTL-IGNORED-ALWAYS-3600 — a BotScan ban lasted BanTTL in the BotGuard set and 3600 s
//   in the blacklist, whatever BotScan requested.
// Criteria: a real grey applies the throttle with no ban event (so no blacklist entry); two ban decisions with
// different allowed durations end with those durations in the BotGuard set and in the ban event the daemon
// turns into the blacklist ban; a duration above the path maximum is capped; without one, the maximum applies.

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/opqueue"
)

// ttlRecBackend records every added element with its TTL, per set.
type ttlRecBackend struct {
	mu   sync.Mutex
	adds map[string]map[string]uint32
}

func (b *ttlRecBackend) FlushSet(table, set string) error { return nil }
func (b *ttlRecBackend) AddElements(table, set string, els []opqueue.SetElement) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.adds[set] == nil {
		b.adds[set] = map[string]uint32{}
	}
	for _, e := range els {
		b.adds[set][e.Value] = e.TTL
	}
	return len(els), nil
}
func (b *ttlRecBackend) DeleteElements(table, set string, els []opqueue.SetElement) error { return nil }
func (b *ttlRecBackend) GetSetElements(table, set string) ([]string, error)               { return nil, nil }
func (b *ttlRecBackend) ReplaceSet(table, set string, els []opqueue.SetElement) error     { return nil }
func (b *ttlRecBackend) ttl(set, ip string) (uint32, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	v, ok := b.adds[set][ip]
	return v, ok
}

type banEvents struct {
	mu  sync.Mutex
	got map[string]eventbus.Event // by IP
}

func newEnabledBatchModule(t *testing.T) (*Module, *ttlRecBackend, *banEvents) {
	t.Helper()
	b := &ttlRecBackend{adds: map[string]map[string]uint32{}}
	qcfg := opqueue.DefaultQueueConfig()
	qcfg.FlushThreshold = 1
	qcfg.FlushInterval = 5 * time.Millisecond
	q := opqueue.NewOpQueue(b, qcfg)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	q.Start(ctx)

	m := New()
	m.config.Enabled = true
	m.bus = eventbus.New()
	m.InitEnforcer(q)
	ev := &banEvents{got: map[string]eventbus.Event{}}
	m.bus.Subscribe(eventbus.EventBan, func(e eventbus.Event) {
		ev.mu.Lock()
		ev.got[e.IP] = e
		ev.mu.Unlock()
	})
	return m, b, ev
}

func waitTTL(t *testing.T, b *ttlRecBackend, set, ip string) uint32 {
	t.Helper()
	for i := 0; i < 200; i++ {
		if v, ok := b.ttl(set, ip); ok {
			return v
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%s not added to %s", ip, set)
	return 0
}

func (ev *banEvents) get(ip string) (eventbus.Event, bool) {
	for i := 0; i < 100; i++ {
		ev.mu.Lock()
		e, ok := ev.got[ip]
		ev.mu.Unlock()
		if ok {
			return e, true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return eventbus.Event{}, false
}

func botscanSig(ip, action string, requestedTTL int64) *BatchSignal {
	return &BatchSignal{IP: ip, Score: 90, Action: action, RequestClass: "scanner", Reasons: []string{"404_flood"},
		RequestedTTLSec: requestedTTL}
}

// Grey: throttle only — grey set with GreyTTL, no ban event (the daemon would turn it into a blacklist ban).
func TestBotScanGreyAppliesThrottleWithoutBanEvent(t *testing.T) {
	m, b, ev := newEnabledBatchModule(t)
	const ip = "198.51.100.21"
	m.applyBatchSignal(botscanSig(ip, "grey", 900))
	if got := waitTTL(t, b, StateGrey.SetName(), ip); got != uint32(m.config.GreyTTL/time.Second) {
		t.Fatalf("grey set TTL = %d, want GreyTTL %d", got, uint32(m.config.GreyTTL/time.Second))
	}
	if e, ok := ev.get(ip); ok {
		t.Fatalf("grey published EventBan (would add a blacklist ban): %+v", e.Data)
	}
	if _, ok := b.ttl(StateBan.SetName(), ip); ok {
		t.Fatalf("grey also added %s to the ban set", ip)
	}
}

// Two ban decisions with different allowed durations → those durations in the ban set and in the event.
func TestBotScanBanDurationsFollowRequest(t *testing.T) {
	m, b, ev := newEnabledBatchModule(t)
	for _, c := range []struct {
		ip           string
		requested    int64
		wantSec      int64
		wantDuration string
	}{
		{"198.51.100.31", 7200, 7200, "7200s"},
		{"198.51.100.32", 14400, 14400, "14400s"},
		{"198.51.100.33", int64(m.config.BanTTL/time.Second) + 3600, int64(m.config.BanTTL / time.Second), ""},
		{"198.51.100.34", 0, int64(m.config.BanTTL / time.Second), ""},
		{"2001:db8::35", 5400, 5400, "5400s"},
	} {
		m.applyBatchSignal(botscanSig(c.ip, "ban", c.requested))
		set := StateBan.SetName()
		if c.ip[0] == '2' {
			set = StateBan.SetName6()
		}
		if got := waitTTL(t, b, set, c.ip); int64(got) != c.wantSec {
			t.Errorf("%s requested %ds: ban set TTL %d, want %d", c.ip, c.requested, got, c.wantSec)
		}
		e, ok := ev.get(c.ip)
		if !ok {
			t.Fatalf("%s: no ban event", c.ip)
		}
		want := c.wantDuration
		if want == "" {
			want = fmt.Sprintf("%ds", c.wantSec)
		}
		if d, _ := e.Data["duration"].(string); d != want {
			t.Errorf("%s: event duration %q, want %q", c.ip, d, want)
		}
		if parsed, err := time.ParseDuration(want); err != nil || int64(parsed/time.Second) != c.wantSec {
			t.Errorf("%s: duration %q is not parseable by the subscriber (time.ParseDuration)", c.ip, want)
		}
		if src, _ := e.Data["source"].(string); src != "clock3_batch" {
			t.Errorf("%s: event source %q, want clock3_batch", c.ip, src)
		}
	}
}
