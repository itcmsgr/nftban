// =============================================================================
// NFTBan v1.168 - CLI-BUG-2 whitelist TTL: EXPIRES_AT carry into typed loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="expiresat_carry_v168_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-09"
// meta:description="v1.168 CLI-BUG-2: the typed loader must CARRY the absolute EXPIRES_AT timestamp on WhitelistEntry.ExpiresAt for future markers (not skip-only), leave it zero for non-expiring entries, and still skip past/malformed markers. parseExpiresAt is the shared contract; shouldSkipDueToExpiresAt stays a compatible boolean wrapper."
// meta:input="None"
// meta:output="t.Fatal on EXPIRES_AT carry drift"
// meta:depends="testing,time"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package whitelist

import (
	"testing"
	"time"
)

// TestParseExpiresAt_FutureCarriesTimestamp asserts a still-future marker
// returns the parsed absolute timestamp and skip=false (so the daemon can
// apply a kernel timeout anchored to it).
func TestParseExpiresAt_FutureCarriesTimestamp(t *testing.T) {
	line := `10.0.0.1  # EXPIRES_AT=2100-01-01T00:00:00Z  REASON=test  ADDED_BY=test`
	ts, skip := parseExpiresAt(line)
	if skip {
		t.Fatalf("future marker: skip=true, want false")
	}
	want, _ := time.Parse(time.RFC3339, "2100-01-01T00:00:00Z")
	if !ts.Equal(want) {
		t.Fatalf("future marker: ts=%v, want %v", ts, want)
	}
}

// TestParseExpiresAt_NoMarkerZeroNoSkip asserts a line with no marker is a
// permanent (durable/trust) entry: zero timestamp, skip=false.
func TestParseExpiresAt_NoMarkerZeroNoSkip(t *testing.T) {
	ts, skip := parseExpiresAt(`10.0.0.4`)
	if skip {
		t.Fatalf("no marker: skip=true, want false")
	}
	if !ts.IsZero() {
		t.Fatalf("no marker: ts=%v, want zero", ts)
	}
}

// TestParseExpiresAt_PastAndMalformedSkip asserts past and malformed markers
// are still dropped (skip=true) with a zero timestamp — and that the legacy
// boolean wrapper shouldSkipDueToExpiresAt agrees.
func TestParseExpiresAt_PastAndMalformedSkip(t *testing.T) {
	cases := []string{
		`10.0.0.6  # EXPIRES_AT=2000-01-01T00:00:00Z`,
		`10.0.0.3  # EXPIRES_AT=not-a-timestamp`,
		`10.0.0.9  # EXPIRES_AT=`,
	}
	for _, line := range cases {
		ts, skip := parseExpiresAt(line)
		if !skip {
			t.Fatalf("line %q: skip=false, want true", line)
		}
		if !ts.IsZero() {
			t.Fatalf("line %q: ts=%v, want zero on skip", line, ts)
		}
		if !shouldSkipDueToExpiresAt(line) {
			t.Fatalf("line %q: wrapper shouldSkipDueToExpiresAt disagrees (got false)", line)
		}
	}
}

// TestLoadAllWhitelistsTyped_CarriesExpiresAt asserts the typed loader sets
// WhitelistEntry.ExpiresAt for a future session entry and leaves it zero for a
// non-expiring manual entry — the load-bearing change behind the daemon
// timeout sync (CLI-BUG-2).
func TestLoadAllWhitelistsTyped_CarriesExpiresAt(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "00-session.conf", `10.0.0.1  # EXPIRES_AT=2100-01-01T00:00:00Z  REASON=keep  ADDED_BY=test
`)
	writeWhitelistFile(t, dir, "99-manual.conf", `10.0.0.4
`)

	ipv4, _, err := LoadAllWhitelistsTyped(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	timed, ok := ipv4["10.0.0.1"]
	if !ok {
		t.Fatalf("expected timed entry 10.0.0.1 loaded, ipv4=%v", ipv4)
	}
	if timed.ExpiresAt.IsZero() {
		t.Fatalf("timed entry 10.0.0.1: ExpiresAt is zero, want the future timestamp carried")
	}
	want, _ := time.Parse(time.RFC3339, "2100-01-01T00:00:00Z")
	if !timed.ExpiresAt.Equal(want) {
		t.Fatalf("timed entry 10.0.0.1: ExpiresAt=%v, want %v", timed.ExpiresAt, want)
	}

	perm, ok := ipv4["10.0.0.4"]
	if !ok {
		t.Fatalf("expected permanent entry 10.0.0.4 loaded, ipv4=%v", ipv4)
	}
	if !perm.ExpiresAt.IsZero() {
		t.Fatalf("permanent entry 10.0.0.4: ExpiresAt=%v, want zero", perm.ExpiresAt)
	}
}
