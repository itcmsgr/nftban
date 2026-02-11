// =============================================================================
// NFTBan v1.0 - Shared State Snapshot Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="snapshot_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-24"
// meta:description="Tests for shared state snapshot"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package state

import (
	"testing"
	"time"
)

func TestUpdate(t *testing.T) {
	snap := BasicSnapshot{
		BannedIPv4:    100,
		BannedIPv6:    50,
		WhitelistIPv4: 10,
		WhitelistIPv6: 5,
		RulesTotal:    200,
		FeedsActive:   12,
		FeedsIPs:      50000,
	}

	Update(snap)

	got := Get()
	if got.BannedIPv4 != 100 {
		t.Errorf("BannedIPv4 = %d, want 100", got.BannedIPv4)
	}
	if got.BannedIPv6 != 50 {
		t.Errorf("BannedIPv6 = %d, want 50", got.BannedIPv6)
	}
	if got.UpdatedAt.IsZero() {
		t.Error("UpdatedAt should not be zero")
	}
}

func TestGetBannedTotal(t *testing.T) {
	Update(BasicSnapshot{
		BannedIPv4: 100,
		BannedIPv6: 50,
	})

	total := GetBannedTotal()
	if total != 150 {
		t.Errorf("GetBannedTotal() = %d, want 150", total)
	}
}

func TestGetWhitelistTotal(t *testing.T) {
	Update(BasicSnapshot{
		WhitelistIPv4: 10,
		WhitelistIPv6: 5,
	})

	total := GetWhitelistTotal()
	if total != 15 {
		t.Errorf("GetWhitelistTotal() = %d, want 15", total)
	}
}

func TestIsStale(t *testing.T) {
	Update(BasicSnapshot{BannedIPv4: 1})

	// Should not be stale immediately
	if IsStale(time.Second) {
		t.Error("Snapshot should not be stale immediately after update")
	}

	// Wait and check again
	time.Sleep(10 * time.Millisecond)
	if !IsStale(time.Millisecond) {
		t.Error("Snapshot should be stale after 10ms with 1ms threshold")
	}
}

func TestIsInitialized(t *testing.T) {
	// Reset state
	mu.Lock()
	current = BasicSnapshot{}
	mu.Unlock()

	if IsInitialized() {
		t.Error("Should not be initialized with zero UpdatedAt")
	}

	Update(BasicSnapshot{BannedIPv4: 1})

	if !IsInitialized() {
		t.Error("Should be initialized after Update")
	}
}

func TestConcurrentAccess(t *testing.T) {
	// Test concurrent reads and writes don't panic
	done := make(chan bool)

	// Writer
	go func() {
		for i := 0; i < 100; i++ {
			Update(BasicSnapshot{BannedIPv4: int64(i)})
		}
		done <- true
	}()

	// Readers
	for i := 0; i < 10; i++ {
		go func() {
			for j := 0; j < 100; j++ {
				_ = Get()
				_ = GetBannedTotal()
				_ = GetWhitelistTotal()
				_ = GetAge()
			}
			done <- true
		}()
	}

	// Wait for all goroutines
	for i := 0; i < 11; i++ {
		<-done
	}
}

func TestUpdateFeeds(t *testing.T) {
	// First do a full update to initialize
	Update(BasicSnapshot{
		BannedIPv4: 100,
		BannedIPv6: 50,
	})

	// Now update just feeds
	UpdateFeeds(12, 50000)

	got := Get()
	if got.FeedsActive != 12 {
		t.Errorf("FeedsActive = %d, want 12", got.FeedsActive)
	}
	if got.FeedsIPs != 50000 {
		t.Errorf("FeedsIPs = %d, want 50000", got.FeedsIPs)
	}
	// Verify other fields unchanged
	if got.BannedIPv4 != 100 {
		t.Errorf("BannedIPv4 changed unexpectedly: %d", got.BannedIPv4)
	}
}
