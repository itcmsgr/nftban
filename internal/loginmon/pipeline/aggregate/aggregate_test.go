// =============================================================================
// NFTBan v1.80 - pipeline aggregate tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: aggregate
// Purpose: Tests for the Aggregator (per-IP / per-account counters + windows).
//
// meta:name="loginmon_pipeline_aggregate_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="aggregate"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Tests for aggregate.Aggregator"
//
// meta:inventory.files="aggregate_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package aggregate

import (
	"net/netip"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

func mkEvent(source, ip, user string, ts time.Time) event.NormalizedEvent {
	addr, _ := netip.ParseAddr(ip)
	return event.NormalizedEvent{
		Source:    source,
		Reason:    event.ReasonDovecotAuthFail,
		SrcIP:     addr,
		Username:  user,
		Timestamp: ts,
	}
}

func TestAggregator_BasicIngest(t *testing.T) {
	clock := time.Now()
	a := NewAggregator(AggregatorOptions{
		Windows: []time.Duration{5 * time.Minute},
		Now:     func() time.Time { return clock },
	})

	a.Ingest(mkEvent("dovecot", "1.2.3.4", "info@x.gr", clock))
	a.Ingest(mkEvent("dovecot", "1.2.3.4", "admin@x.gr", clock))
	a.Ingest(mkEvent("dovecot", "5.6.7.8", "info@x.gr", clock))

	snap := a.Snapshot()
	src, ok := snap.Sources["dovecot"]
	if !ok {
		t.Fatal("dovecot source missing from snapshot")
	}
	w, ok := src.Windows[5*time.Minute]
	if !ok {
		t.Fatal("5m window missing")
	}

	if w.EventCount != 3 {
		t.Errorf("EventCount: got %d, want 3", w.EventCount)
	}
	if w.UniqueIPs != 2 {
		t.Errorf("UniqueIPs: got %d, want 2", w.UniqueIPs)
	}
	if w.UniqueAccounts != 2 {
		t.Errorf("UniqueAccounts: got %d, want 2", w.UniqueAccounts)
	}
	if w.MaxIPsPerAccount != 2 {
		t.Errorf("MaxIPsPerAccount: got %d, want 2 (info@x.gr hit by 2 IPs)", w.MaxIPsPerAccount)
	}
	if w.MaxAccountsPerIP != 2 {
		t.Errorf("MaxAccountsPerIP: got %d, want 2 (1.2.3.4 hit 2 accounts)", w.MaxAccountsPerIP)
	}
}

func TestAggregator_RatioComputation(t *testing.T) {
	clock := time.Now()
	a := NewAggregator(AggregatorOptions{
		Windows: []time.Duration{1 * time.Hour},
		Now:     func() time.Time { return clock },
	})

	// 100 events, 5 bans → ratio = 0.05
	for i := 0; i < 100; i++ {
		a.Ingest(mkEvent("dovecot", "1.2.3.4", "x", clock))
	}
	for i := 0; i < 5; i++ {
		a.RecordBan("dovecot", clock)
	}

	snap := a.Snapshot()
	w := snap.Sources["dovecot"].Windows[1*time.Hour]
	if w.EventCount != 100 || w.BanCount != 5 {
		t.Errorf("counts: events=%d bans=%d", w.EventCount, w.BanCount)
	}
	if w.Ratio != 0.05 {
		t.Errorf("Ratio: got %v, want 0.05", w.Ratio)
	}
}

func TestAggregator_EmptyEventCountRatioOne(t *testing.T) {
	a := NewAggregator(AggregatorOptions{})
	a.RecordBan("ssh", time.Now())
	snap := a.Snapshot()
	for _, w := range snap.Sources["ssh"].Windows {
		if w.EventCount != 0 {
			continue
		}
		if w.Ratio != 1.0 {
			t.Errorf("Ratio with no events: got %v, want 1.0", w.Ratio)
		}
	}
}

func TestAggregator_DistributedSpraySignature(t *testing.T) {
	// Simulate the BUG-1 scenario: many distinct IPs hitting one account.
	clock := time.Now()
	a := NewAggregator(AggregatorOptions{
		Windows: []time.Duration{5 * time.Minute},
		Now:     func() time.Time { return clock },
	})

	target := "info@victim.gr"
	for i := 0; i < 12; i++ {
		ip := "92.118.39." + intToStr(220+i)
		a.Ingest(mkEvent("dovecot", ip, target, clock))
	}

	w := a.Snapshot().Sources["dovecot"].Windows[5*time.Minute]
	if w.EventCount != 12 {
		t.Errorf("EventCount: got %d, want 12", w.EventCount)
	}
	if w.UniqueIPs != 12 {
		t.Errorf("UniqueIPs: got %d, want 12", w.UniqueIPs)
	}
	if w.MaxIPsPerAccount != 12 {
		t.Errorf("MaxIPsPerAccount: got %d, want 12 (distributed spray signal)", w.MaxIPsPerAccount)
	}
}

func TestAggregator_WindowRollover(t *testing.T) {
	clock := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)
	a := NewAggregator(AggregatorOptions{
		Windows: []time.Duration{5 * time.Minute},
		Now:     func() time.Time { return clock },
	})

	a.Ingest(mkEvent("dovecot", "1.1.1.1", "x", clock))
	if a.Snapshot().Sources["dovecot"].Windows[5*time.Minute].EventCount != 1 {
		t.Fatal("first event")
	}

	// Advance past the window. The next ingest should reset the bucket.
	clock = clock.Add(10 * time.Minute)
	a.Ingest(mkEvent("dovecot", "2.2.2.2", "y", clock))

	w := a.Snapshot().Sources["dovecot"].Windows[5*time.Minute]
	if w.EventCount != 1 {
		t.Errorf("after rollover: EventCount=%d, want 1", w.EventCount)
	}
	if w.UniqueIPs != 1 {
		t.Errorf("after rollover: UniqueIPs=%d, want 1", w.UniqueIPs)
	}
}

func TestEffectiveState_String(t *testing.T) {
	cases := map[EffectiveState]string{
		EffectiveActive:   "ACTIVE",
		EffectiveDegraded: "DEGRADED",
		EffectiveFailing:  "FAILING",
	}
	for in, want := range cases {
		if in.String() != want {
			t.Errorf("EffectiveState(%d).String: got %q", in, in.String())
		}
	}
}

// intToStr converts a small int to a decimal string without using fmt.
// Local helper to keep this test file dependency-free.
func intToStr(n int) string {
	if n == 0 {
		return "0"
	}
	negative := n < 0
	if negative {
		n = -n
	}
	var buf [16]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if negative {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
