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
// meta:description="NEGATIVE CONTROL for OPEN_DUPLICATE_AUTHORITY_LOCKOUT_P1S child P1S-A. The feed/geoban/blacklist.d unified replace (cmd/nftband/daemon_handlers_sync.go) converts every feed single IP to <ip>/32 and hands the union to nft.AddCIDRElementsWithStats; before v1.231.0 no never-ban authority was consulted on that path. IsExempt is single-IP-only by contract (internal/nftbackend/backend.go), so the prefix question needed a prefix-shaped answer: exemptResolver.SubtractExempt. Every subject arm here is paired with a PRE-FIX INVERSION arm that reproduces the defect in the same run, so no row can pass vacuously."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// ⚠️ TEST-SUBJECT ADAPTATION — RECORDED, NOT HIDDEN.
//
// As first authored (git tag rescue/lane1c-p1sa-f5299b6a) both controls probed the
// defect through r.IsExempt(<CIDR>), because at the time no prefix-aware authority
// existed to probe. That expression could only ever be satisfied by making IsExempt
// itself answer true for a CIDR — which the P1S-A acceptance contract forbids, and
// for a load-bearing reason: IsExempt is also the input to Backend.Ban and to
// exemptAddRejection, where "true" REFUSES the whole operation. A feed prefix
// containing one admin IP would then be refused entirely, i.e. the exemption would
// become the denial of service it exists to prevent, and the legitimate "add a CIDR
// to an enforcement set" path would silently regress.
//
// The ASSERTIONS are therefore preserved and the SUBJECT is re-pointed at the
// authority the fix creates. Nothing was relaxed: each original assertion still has
// to hold, its positive control still runs first, and each arm now additionally
// carries the pre-fix inversion it used to rely on the tree to supply.
//
// Recorded pre-fix run (lab4, go1.25.13, tree at 0c7ad204 + original test file):
//   --- FAIL: TestP1SA_NC1_NoExemptAuthorityForFeedShapedElements (0.00s)
//   --- FAIL: TestP1SA_NC2_ExemptIPSurvivesTheUnifiedReplaceFilterChain (0.00s)
// with both positive controls passing (no INVALID_TEST fatal).

package nftbackend

import (
	"net/netip"
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
// control. The feed path never produces a bare IP — the sync handler emits "<ip>/32" —
// so the ONLY question the unified replace can ask is "does this element cover an
// exempt IP". Some authority must answer it.
//
// Positive control runs FIRST: the resolver must recognise the bare exempt IP. If that
// fails the measurement is INVALID_TEST (product verdict NONE), not a product result.
func TestP1SA_NC1_NoExemptAuthorityForFeedShapedElements(t *testing.T) {
	r := p1saLoadedResolver(t, exemptFixtureIP)

	// POSITIVE CONTROL — instrument validation before any verdict.
	if ok, why := r.IsExempt(exemptFixtureIP); !ok {
		t.Fatalf("INVALID_TEST: positive control failed — resolver does not recognise bare exempt IP %s (reason=%q); product verdict NONE", exemptFixtureIP, why)
	}

	feedShaped := []string{exemptFixtureSlash, exemptFixtureNet}

	// PRE-FIX INVERSION — this is the gap the defect was made of, and it must STAY
	// this way: IsExempt is address-shaped and answers false for every feed element.
	// If this ever flips, IsExempt has been made prefix-aware and Ban/AddElement have
	// silently acquired a refuse-the-whole-prefix behaviour.
	for _, elem := range feedShaped {
		if ok, _ := r.IsExempt(elem); ok {
			t.Fatalf("INVALID_TEST: IsExempt(%q) answered true — IsExempt must stay single-IP-only (Backend.Ban and exemptAddRejection REFUSE on true, which would drop a whole feed prefix because one admin IP sits inside it); product verdict NONE", elem)
		}
	}

	// SUBJECT — the prefix-shaped authority must recognise every element shape the
	// unified replace feeds to nft.AddCIDRElementsWithStats.
	for _, elem := range feedShaped {
		kept, removed := r.SubtractExempt([]string{elem})
		if removed != 1 {
			t.Errorf("P1S-A BYPASS: element %q covers never-ban-exempt %s but the exemption authority did not recognise it (removed=%d) — it would be written to blacklist_ipv4 unguarded (LOCKOUT)", elem, exemptFixtureIP, removed)
			continue
		}
		if keptCovers(t, kept, exemptFixtureIP) {
			t.Errorf("P1S-A BYPASS: element %q was recognised but %s still survives in the output %v", elem, exemptFixtureIP, kept)
		}
	}
}

// TestP1SA_NC2_ExemptIPSurvivesTheUnifiedReplaceFilterChain is the ELEMENT-level
// negative control. It reproduces the SHIPPED conversion (single IP -> /32) and runs
// the SHIPPED filter chain. The exempt IP must not survive.
//
// Arm A is the PRE-FIX chain (MergeCIDRsSafe alone, which is what the unified replace
// used to be) and must LEAK — that is the defect, reproduced in this run. Arm B is the
// SHIPPED chain (SubtractExempt then MergeCIDRsSafe) and must not.
func TestP1SA_NC2_ExemptIPSurvivesTheUnifiedReplaceFilterChain(t *testing.T) {
	// Mirrors the sync handler — feeds.LoadAllFeeds single IPs become /32.
	unified := []string{exemptFixtureSlash, hostileFixtureNet}

	// ---- ARM A: PRE-FIX INVERSION -------------------------------------------
	preKept, _, filterStats, err := nftsync.MergeCIDRsSafe(unified)
	if err != nil {
		t.Fatalf("INVALID_TEST: MergeCIDRsSafe errored (%v); product verdict NONE", err)
	}
	// POSITIVE CONTROL — a plainly hostile public CIDR must survive the shipped filter.
	// If it does not, the filter (not the exemption gap) is the subject and any verdict
	// about the exempt IP would be unattributable.
	if !keptCovers(t, preKept, "198.100.44.7") {
		t.Fatalf("INVALID_TEST: positive control failed — hostile public CIDR %s did not survive MergeCIDRsSafe (filtered=%d bogon=%d oversized=%d); product verdict NONE",
			hostileFixtureNet, filterStats.Filtered, filterStats.Bogon, filterStats.TooLarge)
	}
	if !keptCovers(t, preKept, exemptFixtureIP) {
		t.Fatalf("INVALID_TEST: the pre-fix chain did NOT leak %s, so this fixture cannot demonstrate the defect and arm B would pass vacuously (kept=%v); product verdict NONE", exemptFixtureIP, preKept)
	}

	// ---- ARM B: SHIPPED CHAIN ------------------------------------------------
	r := p1saLoadedResolver(t, exemptFixtureIP)
	subtracted, removed := r.SubtractExempt(unified)
	if removed == 0 {
		t.Fatalf("P1S-A BYPASS: the unified list contains %s yet the exemption authority subtracted nothing", exemptFixtureSlash)
	}
	kept, _, _, err := nftsync.MergeCIDRsSafe(subtracted)
	if err != nil {
		t.Fatalf("INVALID_TEST: MergeCIDRsSafe errored on the subtracted list (%v); product verdict NONE", err)
	}
	if !keptCovers(t, kept, "198.100.44.7") {
		t.Errorf("DoS-BY-EXEMPTION: the hostile public CIDR %s was lost from the shipped chain (kept=%v) — the guard must remove exempt coverage, not enforcement", hostileFixtureNet, kept)
	}
	if keptCovers(t, kept, exemptFixtureIP) {
		t.Errorf("P1S-A BYPASS: never-ban-exempt %s survived the ENTIRE unified-replace pipeline and would be written to blacklist_ipv4 (nftables.conf.tpl drops @blacklist_ipv4 BEFORE the ct-state-established accept — the live admin SSH session is cut). kept=%v",
			exemptFixtureIP, kept)
	}
}

// TestP1SA_NC3_SplitNotDropped proves the remedy is SUBTRACTION. Dropping a whole
// prefix because one exempt address sits inside it would disable that prefix's
// protection — a denial of service caused by the exemption itself.
func TestP1SA_NC3_SplitNotDropped(t *testing.T) {
	r := p1saLoadedResolver(t, exemptFixtureIP)

	kept, removed := r.SubtractExempt([]string{exemptFixtureNet})
	if removed != 1 {
		t.Fatalf("INVALID_TEST: %s was not recognised as covering %s (removed=%d); product verdict NONE", exemptFixtureNet, exemptFixtureIP, removed)
	}
	if len(kept) == 0 {
		t.Fatalf("DoS-BY-EXEMPTION: the whole %s was dropped because one exempt address sits inside it", exemptFixtureNet)
	}
	if keptCovers(t, kept, exemptFixtureIP) {
		t.Errorf("P1S-A BYPASS: %s still covered after subtraction: %v", exemptFixtureIP, kept)
	}
	// Every OTHER address in the /24 must still be enforced.
	for _, still := range []string{"185.199.108.0", "185.199.108.152", "185.199.108.154", "185.199.108.255"} {
		if !keptCovers(t, kept, still) {
			t.Errorf("DoS-BY-EXEMPTION: %s lost enforcement after subtracting %s from %s (kept=%v)", still, exemptFixtureIP, exemptFixtureNet, kept)
		}
	}

	// An element that is EXACTLY the exempt address is removed, not split.
	kept, removed = r.SubtractExempt([]string{exemptFixtureSlash})
	if removed != 1 || len(kept) != 0 {
		t.Errorf("exempt /32 must be removed outright: kept=%v removed=%d", kept, removed)
	}
}

// TestP1SA_NC4_FailSafeSnapshot locks the contract that a resolver problem must NEVER
// block a legitimate feed load. An unloaded or empty snapshot subtracts NOTHING.
func TestP1SA_NC4_FailSafeSnapshot(t *testing.T) {
	in := []string{exemptFixtureSlash, hostileFixtureNet}

	// Never loaded: refresh is attempted, finds no sources in this hermetic context,
	// and the load must not withhold anything.
	unloaded := &exemptResolver{ttl: time.Hour}
	kept, removed := unloaded.SubtractExempt(in)
	if removed != 0 || len(kept) != len(in) {
		t.Errorf("FAIL-SAFE BROKEN: an unloaded snapshot subtracted %d element(s) (kept=%v); a resolver failure must never block a feed load", removed, kept)
	}

	// Loaded but empty.
	empty := p1saLoadedResolver(t)
	kept, removed = empty.SubtractExempt(in)
	if removed != 0 || len(kept) != len(in) {
		t.Errorf("FAIL-SAFE BROKEN: an empty snapshot subtracted %d element(s) (kept=%v)", removed, kept)
	}

	// Nil resolver and nil backend.
	var nilR *exemptResolver
	if kept, removed = nilR.SubtractExempt(in); removed != 0 || len(kept) != len(in) {
		t.Errorf("FAIL-SAFE BROKEN: nil resolver subtracted %d element(s)", removed)
	}
	var nilB *Backend
	if kept, removed = nilB.SubtractExempt(in); removed != 0 || len(kept) != len(in) {
		t.Errorf("FAIL-SAFE BROKEN: nil backend subtracted %d element(s)", removed)
	}

	// Unparseable input is passed through, not silently eaten.
	junk := []string{"not-an-ip", ""}
	if kept, removed = p1saLoadedResolver(t, exemptFixtureIP).SubtractExempt(junk); removed != 0 || len(kept) != 2 {
		t.Errorf("unparseable input must pass through untouched: kept=%v removed=%d", kept, removed)
	}
}

// TestP1SA_NC5_FamilyParity locks v4+v6 parity and IPv4-mapped-IPv6 canonicalisation.
// A mapped element is routed to the IPv6 set by the caller, so a split of it must be
// re-emitted in mapped form — rewriting its family there would corrupt the element.
func TestP1SA_NC5_FamilyParity(t *testing.T) {
	const v6IP = "2606:4700:4700::1111"

	r := p1saLoadedResolver(t, v6IP)
	if ok, _ := r.IsExempt(v6IP); !ok {
		t.Fatalf("INVALID_TEST: positive control failed — resolver does not recognise exempt IPv6 %s; product verdict NONE", v6IP)
	}

	kept, removed := r.SubtractExempt([]string{"2606:4700:4700::/64"})
	if removed != 1 {
		t.Fatalf("IPv6 BYPASS: the /64 covering exempt %s was not recognised (removed=%d)", v6IP, removed)
	}
	if keptCovers(t, kept, v6IP) {
		t.Errorf("IPv6 BYPASS: %s still covered after subtraction", v6IP)
	}
	if !keptCovers(t, kept, "2606:4700:4700::2222") {
		t.Errorf("DoS-BY-EXEMPTION: the rest of the IPv6 /64 lost enforcement (kept=%v)", kept)
	}

	// IPv4-mapped-IPv6: the snapshot stores the unmapped form (canonPrefix), and a
	// mapped element must still be recognised through it.
	rm := p1saLoadedResolver(t, exemptFixtureIP)
	kept, removed = rm.SubtractExempt([]string{"::ffff:185.199.108.153/128"})
	if removed != 1 || len(kept) != 0 {
		t.Errorf("IPv4-MAPPED BYPASS: mapped exempt /128 not removed (kept=%v removed=%d)", kept, removed)
	}
	kept, removed = rm.SubtractExempt([]string{"::ffff:185.199.108.0/120"})
	if removed != 1 {
		t.Fatalf("IPv4-MAPPED BYPASS: mapped /120 covering %s not recognised", exemptFixtureIP)
	}
	for _, k := range kept {
		p, err := netip.ParsePrefix(k)
		if err != nil {
			t.Fatalf("subtraction emitted an unparseable element %q", k)
		}
		if !p.Addr().Is4In6() {
			t.Errorf("FAMILY CORRUPTION: a mapped IPv6 input was re-emitted as %q — the caller routed it to the IPv6 set", k)
		}
	}
}

// keptCovers reports whether any element of kept covers ip.
func keptCovers(t *testing.T, kept []string, ip string) bool {
	t.Helper()
	a, err := netip.ParseAddr(ip)
	if err != nil {
		t.Fatalf("INVALID_TEST: bad fixture address %q: %v", ip, err)
	}
	a = a.Unmap()
	for _, k := range kept {
		p, wasMapped, ok := parseElementPrefix(k)
		_ = wasMapped
		if !ok {
			continue
		}
		if p.Contains(a) {
			return true
		}
	}
	return false
}
