// =============================================================================
// NFTBan v1.80 - pipeline dedup tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: dedup
// Purpose: Tests for the bounded LRU dedup sieve.
//
// meta:name="loginmon_pipeline_dedup_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="dedup"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Tests for dedup.Sieve"
//
// meta:inventory.files="dedup_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package dedup

import (
	"net/netip"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

func mkEvent(reason event.Reason, ip, user string, ts time.Time) event.NormalizedEvent {
	addr, _ := netip.ParseAddr(ip)
	return event.NormalizedEvent{
		Reason:    reason,
		SrcIP:     addr,
		Username:  user,
		Timestamp: ts,
	}
}

func TestSieve_AdmitsNewEvent(t *testing.T) {
	s := NewSieve(SieveOptions{})
	e := mkEvent(event.ReasonDovecotAuthFail, "1.2.3.4", "info@x", time.Now())
	if !s.Admit(e) {
		t.Error("first Admit should return true")
	}
	if s.Len() != 1 {
		t.Errorf("Len: got %d, want 1", s.Len())
	}
}

func TestSieve_SuppressesDuplicate(t *testing.T) {
	s := NewSieve(SieveOptions{Window: 5 * time.Second})
	// Use a fixed timestamp anchored to a 5-second boundary so the two
	// event timestamps land in the same bucket regardless of wall-clock.
	// (Earlier version used time.Now() which produced 1-in-5 flake.)
	base := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)
	e1 := mkEvent(event.ReasonDovecotAuthFail, "1.2.3.4", "info@x", base)
	e2 := mkEvent(event.ReasonDovecotAuthFail, "1.2.3.4", "info@x", base.Add(1*time.Second))

	if !s.Admit(e1) {
		t.Error("first Admit: want true")
	}
	if s.Admit(e2) {
		t.Error("duplicate within window: want false")
	}
	if s.Len() != 1 {
		t.Errorf("Len: got %d, want 1", s.Len())
	}
}

func TestSieve_DifferentReasonNotDuplicate(t *testing.T) {
	s := NewSieve(SieveOptions{})
	now := time.Now()
	e1 := mkEvent(event.ReasonDovecotAuthFail, "1.2.3.4", "info@x", now)
	e2 := mkEvent(event.ReasonEximAuthFail, "1.2.3.4", "info@x", now)
	if !s.Admit(e1) || !s.Admit(e2) {
		t.Error("different reasons must both admit")
	}
}

func TestSieve_DifferentTimeBucketNotDuplicate(t *testing.T) {
	s := NewSieve(SieveOptions{Window: 5 * time.Second})
	base := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)
	e1 := mkEvent(event.ReasonDovecotAuthFail, "1.2.3.4", "x", base)
	e2 := mkEvent(event.ReasonDovecotAuthFail, "1.2.3.4", "x", base.Add(10*time.Second))
	if !s.Admit(e1) || !s.Admit(e2) {
		t.Error("different time buckets must both admit")
	}
}

func TestSieve_ExpiredEntriesEvicted(t *testing.T) {
	clock := time.Now()
	s := NewSieve(SieveOptions{
		Window: 1 * time.Second,
		Now:    func() time.Time { return clock },
	})
	e := mkEvent(event.ReasonDovecotAuthFail, "1.2.3.4", "x", clock)
	s.Admit(e)
	if s.Len() != 1 {
		t.Errorf("after first admit: %d", s.Len())
	}

	// Advance clock past window. Next Admit should evict the old entry.
	clock = clock.Add(10 * time.Second)
	e2 := mkEvent(event.ReasonEximAuthFail, "5.6.7.8", "y", clock)
	s.Admit(e2)
	if s.Len() != 1 {
		t.Errorf("after expiry + new admit: %d (want 1)", s.Len())
	}
}

func TestSieve_CapacityEviction(t *testing.T) {
	s := NewSieve(SieveOptions{
		Capacity: 3,
	})
	now := time.Now()
	for i := 0; i < 5; i++ {
		ip := "10.0.0." + string(rune('1'+i))
		e := mkEvent(event.ReasonDovecotAuthFail, ip, "x", now.Add(time.Duration(i)*time.Hour))
		s.Admit(e)
	}
	if s.Len() != 3 {
		t.Errorf("Len: got %d, want 3 (capacity)", s.Len())
	}
}

func TestSieve_DAOverlapClassicCase(t *testing.T) {
	// The exact case BUG-2 dedup is meant to handle: DA login.log and
	// security.log both record the same failed login. Two events with
	// identical (Reason, IP, User) and timestamps within 5 seconds.
	// Anchored to a fixed boundary-aligned timestamp to avoid wall-clock flake.
	s := NewSieve(SieveOptions{Window: 5 * time.Second})
	base := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	fromLogin := mkEvent(event.ReasonDirectAdminFail, "192.0.2.122", "admin", base)
	fromSecurity := mkEvent(event.ReasonDirectAdminFail, "192.0.2.122", "admin", base.Add(time.Second))

	if !s.Admit(fromLogin) {
		t.Error("login.log event must admit")
	}
	if s.Admit(fromSecurity) {
		t.Error("security.log mirror must NOT admit (dedup)")
	}
}
