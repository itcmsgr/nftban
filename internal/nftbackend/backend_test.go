// =============================================================================
// NFTBan v1.58.0 - nftbackend Package Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="backend_test"
// meta:type="test"
// meta:version="1.58.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Unit tests for nftbackend — pure logic only, no kernel/netlink"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbackend

import (
	"context"
	"testing"
)

// =============================================================================
// isManualSource — set routing logic (hash vs interval)
// =============================================================================

func TestIsManualSource_ManualSources(t *testing.T) {
	manualSources := []string{
		"manual", "cli", "login",
		"portscan", "portscan-classic", "portscan-suricata",
		"ddos", "ddos-classic", "ddos-suricata",
		"suricata", "persistent",
	}

	for _, src := range manualSources {
		if !isManualSource(src) {
			t.Errorf("isManualSource(%q) = false, want true", src)
		}
	}
}

func TestIsManualSource_FeedSources(t *testing.T) {
	feedSources := []string{
		"feeds", "geoban", "blocklist-de", "spamhaus",
		"", "unknown", "custom-feed",
	}

	for _, src := range feedSources {
		if isManualSource(src) {
			t.Errorf("isManualSource(%q) = true, want false", src)
		}
	}
}

// =============================================================================
// Ban/Unban input validation
// =============================================================================

func TestBan_InvalidIP_ReturnsError(t *testing.T) {
	b := &Backend{}

	_, err := b.Ban(context.Background(), BanRequest{
		IP:     "not-an-ip",
		Source: "manual",
	})

	if err == nil {
		t.Error("expected error for invalid IP, got nil")
	}
}

func TestUnban_InvalidIP_ReturnsError(t *testing.T) {
	b := &Backend{}

	var unbanErr error
	func() {
		defer func() { recover() }()
		_, unbanErr = b.Unban(context.Background(), UnbanRequest{
			IP: "not-an-ip",
		})
	}()

	if unbanErr == nil {
		t.Error("expected error for invalid IP, got nil")
	}
}

// =============================================================================
// Stats error tracking
// =============================================================================

func TestBackend_StatsErrorIncrement(t *testing.T) {
	b := &Backend{}

	func() {
		defer func() { recover() }()
		_, _ = b.Ban(context.Background(), BanRequest{IP: "garbage", Source: "manual"})
	}()

	if b.stats.Errors != 1 {
		t.Errorf("Errors = %d after invalid ban, want 1", b.stats.Errors)
	}
	if b.stats.LastError == "" {
		t.Error("LastError should be set after error")
	}
}
