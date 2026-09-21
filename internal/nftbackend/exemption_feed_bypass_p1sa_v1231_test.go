// =============================================================================
// NFTBan - P1S-A NEGATIVE CONTROL: feed/geoban unified-replace never-ban bypass
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="nftbackend_exemption_feed_bypass_p1sa"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-14"
// meta:description="NEGATIVE CONTROL for OPEN_DUPLICATE_AUTHORITY_LOCKOUT_P1S child P1S-A. The feed/geoban/blacklist.d unified replace (cmd/nftband/daemon_handlers_sync.go:319,467-481) converts every feed single IP to <ip>/32 and hands the union to nft.AddCIDRElementsWithStats WITHOUT consulting the never-ban exemption authority. IsExempt is single-IP-only by contract (internal/nftbackend/backend.go:614), so no exemption authority can answer 'does this CIDR cover an exempt IP'. These tests MUST FAIL on the current tree; they pass only once an exempt-aware CIDR filter exists on the unified replace input."
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
	"testing"
	"time"

	nftsync "github.com/itcmsgr/nftban/internal/setsync"
)

// exemptFixtureIP is a PUBLIC ROUTABLE address. It must not be RFC1918/CGNAT/
// documentation: netutil.EnforcementClassReject rejects those classes outright and
// setsync.BogonPrefixes filters them from feed input, which would mask the defect with
// an unrelated control (see feedback_lab_ban_fixtures_must_be_bannable).
const (
	exemptFixtureIP    = "185.199.108.153"
	exemptFixtureSlash = exemptFixtureIP + "/32"
	exemptFixtureNet   = "185.199.108.0/24"
	hostileFixtureNet  = "198.100.44.0/24" // public, not exempt — instrument positive control
)

func p1saLoadedResolver(t *testing.T, exact ...string) *exemptResolver {
	t.Helper()
	r := &exemptResolver{ttl: time.Hour, loaded: true, loadedAt: time.Now(), exact: map[string]struct{}{}}
	for _, ip := range exact {
		r.exact[ip] = struct{}{}
	}
	return r
}

// TestP1SA_NC1_NoExemptAuthorityForFeedShapedElements is the AUTHORITY-level negative
// control. The feed path never produces a bare IP — daemon_handlers_sync.go:319 emits
// "<ip>/32" — so the ONLY question the unified replace could ask is "does this CIDR
// cover an exempt IP". The current tree has no such authority.
//
// Positive control runs FIRST: the resolver must recognise the bare exempt IP. If that
// fails the measurement is INVALID_TEST (product verdict NONE), not a product result.
func TestP1SA_NC1_NoExemptAuthorityForFeedShapedElements(t *testing.T) {
	r := p1saLoadedResolver(t, exemptFixtureIP)

	// POSITIVE CONTROL — instrument validation before any verdict.
	if ok, why := r.IsExempt(exemptFixtureIP); !ok {
		t.Fatalf("INVALID_TEST: positive control failed — resolver does not recognise bare exempt IP %s (reason=%q); product verdict NONE", exemptFixtureIP, why)
	}

	// SUBJECT — the exact element shapes the feed/geoban unified replace feeds to
	// nft.AddCIDRElementsWithStats.
	for _, elem := range []string{exemptFixtureSlash, exemptFixtureNet} {
		if ok, _ := r.IsExempt(elem); !ok {
			t.Errorf("P1S-A BYPASS: element %q covers never-ban-exempt %s but no exemption authority recognises it — cmd/nftband/daemon_handlers_sync.go:467-481 writes it to blacklist_ipv4 unguarded (LOCKOUT)", elem, exemptFixtureIP)
		}
	}
}

// TestP1SA_NC2_ExemptIPSurvivesTheUnifiedReplaceFilterChain is the ELEMENT-level
// negative control. It reproduces the SHIPPED conversion (single IP -> /32, line 318)
// and runs the SHIPPED filter chain (setsync.MergeCIDRsSafe, the only filter between the
// unified list and replaceSetElementsViaFile). The exempt IP must not survive.
func TestP1SA_NC2_ExemptIPSurvivesTheUnifiedReplaceFilterChain(t *testing.T) {
	// Mirrors daemon_handlers_sync.go:319 — feeds.LoadAllFeeds single IPs become /32.
	unified := []string{exemptFixtureSlash, hostileFixtureNet}

	kept, _, filterStats, err := nftsync.MergeCIDRsSafe(unified)
	if err != nil {
		t.Fatalf("INVALID_TEST: MergeCIDRsSafe errored (%v); product verdict NONE", err)
	}

	// POSITIVE CONTROL — a plainly hostile public CIDR must survive the shipped filter.
	// If it does not, the filter (not the exemption gap) is the subject and any verdict
	// about the exempt IP would be unattributable.
	if !coversAny(kept, hostileFixtureNet) {
		t.Fatalf("INVALID_TEST: positive control failed — hostile public CIDR %s did not survive MergeCIDRsSafe (filtered=%d bogon=%d oversized=%d); product verdict NONE",
			hostileFixtureNet, filterStats.Filtered, filterStats.Bogon, filterStats.TooLarge)
	}

	// SUBJECT — the exempt IP must NOT reach replaceSetElementsViaFile.
	if coversAny(kept, exemptFixtureSlash) {
		t.Errorf("P1S-A BYPASS: never-ban-exempt %s survived the ENTIRE unified-replace pipeline as %s and would be written to blacklist_ipv4 (nftables.conf.tpl:426 drops it BEFORE the ct-state-established accept at :436 — live admin SSH session is cut)",
			exemptFixtureIP, exemptFixtureSlash)
	}
}

func coversAny(kept []string, want string) bool {
	for _, k := range kept {
		if k == want {
			return true
		}
	}
	return false
}
