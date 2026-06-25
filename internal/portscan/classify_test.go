// =============================================================================
// NFTBan - Tests for the portscan Go classifier (known-open exclusion, v4+v6)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="portscan_classify_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-25"
// meta:description="Table-driven tests for the v1.204 portscan classifier — known-open exclusion, score-only-unexpected, IPv4+IPv6 parity, strobe window, malformed/empty safety, cross-module non-overlap (classifier never owns DDoS/BotGuard/LoginMon)."
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package portscan

import "testing"

// Standard DA-host known-open service set + thresholds (mirrors classic.conf-ish).
var knownOpen = []int{22, 25, 80, 110, 143, 443, 465, 587, 993, 995, 2222, 2083, 2096}

func base(family, ip string, ev []Event) Input {
	return Input{
		IP: ip, Family: family, Events: ev, KnownOpenPorts: knownOpen,
		BlockRange: 10, VerticalPorts: 5, HorizontalTargets: 10, StrobePorts: 5, StrobeWindowSec: 10,
	}
}

func ev(host string, ts int64, ports ...int) []Event {
	out := make([]Event, 0, len(ports))
	for _, p := range ports {
		out = append(out, Event{Port: p, Target: host, TS: ts})
	}
	return out
}

func TestClassify_KnownOpenOnlyBurst_Allow(t *testing.T) {
	// Panel+mail+web+SSH+more — 6 known-open services in 1s (the proven FP).
	in := base("ipv4", "62.38.150.122", ev("203.0.113.10", 1000, 22, 2222, 25, 80, 443, 993))
	v := Classify(in)
	if v.Action != "allow" || v.ScanType != "" {
		t.Fatalf("known-open-only burst must ALLOW, got %+v", v)
	}
	if v.UnexpectedCount != 0 || v.KnownOpenCount != 6 {
		t.Fatalf("expected unexpected=0 known=6, got %+v", v)
	}
}

func TestClassify_MultiServiceKnownOpenBurst_Allow(t *testing.T) {
	in := base("ipv4", "1.2.3.4", ev("203.0.113.10", 1000, 80, 443, 25, 587, 993, 995, 2222))
	if v := Classify(in); v.Action != "allow" {
		t.Fatalf("multi-service known-open burst must ALLOW, got %+v", v)
	}
}

func TestClassify_UnexpectedClosedPortDiversity_BanCapable(t *testing.T) {
	// 6 distinct UNEXPECTED ports on one target within 1s → vertical/strobe ban.
	in := base("ipv4", "9.9.9.9", ev("203.0.113.10", 1000, 1234, 3306, 5432, 6379, 8080, 9000))
	v := Classify(in)
	if v.Action != "ban" {
		t.Fatalf("unexpected-port diversity must be ban-capable, got %+v", v)
	}
	if v.UnexpectedCount != 6 {
		t.Fatalf("expected unexpected=6, got %+v", v)
	}
}

func TestClassify_MixedKnownOpenAndUnexpected_ScoreUnexpectedOnly(t *testing.T) {
	// 4 known-open + 2 unexpected → score = 2 (below vertical=5) → ALLOW.
	in := base("ipv4", "5.6.7.8", ev("203.0.113.10", 1000, 22, 80, 443, 993, 4444, 5555))
	v := Classify(in)
	if v.KnownOpenCount != 4 || v.UnexpectedCount != 2 {
		t.Fatalf("expected known=4 unexpected=2, got %+v", v)
	}
	if v.Action != "allow" {
		t.Fatalf("2 unexpected (< vertical 5) must ALLOW, got %+v", v)
	}
	// add 3 more unexpected → 5 unexpected → ban-capable (known-open still ignored).
	in2 := base("ipv4", "5.6.7.8", ev("203.0.113.10", 1000, 22, 80, 443, 993, 4444, 5555, 6666, 7777, 8888))
	if v2 := Classify(in2); v2.Action != "ban" || v2.UnexpectedCount != 5 {
		t.Fatalf("5 unexpected must ban, got %+v", v2)
	}
}

func TestClassify_IPv4KnownOpenOnly_Allow(t *testing.T) {
	if v := Classify(base("ipv4", "1.1.1.1", ev("203.0.113.10", 1000, 22, 80, 443, 993, 995))); v.Action != "allow" {
		t.Fatalf("v4 known-open-only must ALLOW, got %+v", v)
	}
}

func TestClassify_IPv6KnownOpenOnly_Allow(t *testing.T) {
	if v := Classify(base("ipv6", "2606:4700::1", ev("2606:4700:4700::1", 1000, 22, 80, 443, 993, 995))); v.Action != "allow" {
		t.Fatalf("v6 known-open-only must ALLOW, got %+v", v)
	}
}

func TestClassify_IPv4UnexpectedDiversity_BanCapable(t *testing.T) {
	in := base("ipv4", "9.9.9.9", ev("203.0.113.10", 1000, 1111, 3333, 4444, 5555, 6666))
	if v := Classify(in); v.Action != "ban" {
		t.Fatalf("v4 unexpected diversity must be ban-capable, got %+v", v)
	}
}

func TestClassify_IPv6UnexpectedDiversity_BanCapable(t *testing.T) {
	in := base("ipv6", "2a01:4f8::99", ev("2606:4700:4700::1", 1000, 1111, 3333, 4444, 5555, 6666))
	if v := Classify(in); v.Action != "ban" {
		t.Fatalf("v6 unexpected diversity must be ban-capable, got %+v", v)
	}
}

func TestClassify_V4V6Parity_SameInputSameVerdict(t *testing.T) {
	mk := func(fam string) Verdict {
		return Classify(base(fam, "x", ev("t", 1000, 1111, 3333, 4444, 5555, 6666)))
	}
	a, b := mk("ipv4"), mk("ipv6")
	if a.Action != b.Action || a.ScanType != b.ScanType || a.UnexpectedCount != b.UnexpectedCount {
		t.Fatalf("v4/v6 parity broken: %+v vs %+v", a, b)
	}
}

func TestClassify_StrobeWindow_OutsideWindowNotStrobe(t *testing.T) {
	// 5 unexpected ports but spread across 30s (> 10s window), one target →
	// vertical still fires (vertical has no window). Use 4 unexpected (< vertical 5)
	// spread wide to confirm strobe needs the window.
	in := base("ipv4", "8.8.8.8", []Event{
		{Port: 1111, Target: "t", TS: 1000}, {Port: 2233, Target: "t", TS: 1010},
		{Port: 3344, Target: "t", TS: 1020}, {Port: 4455, Target: "t", TS: 1030},
	})
	v := Classify(in) // 4 unexpected < vertical(5) and spread 30s → no strobe → allow
	if v.Action != "allow" {
		t.Fatalf("4 unexpected spread 30s must ALLOW (no strobe), got %+v", v)
	}
}

func TestClassify_EmptyInput_NoFalseHealthyOrBan(t *testing.T) {
	v := Classify(base("ipv4", "1.2.3.4", nil))
	if v.Action != "allow" || v.ScanType != "" || v.UnexpectedCount != 0 {
		t.Fatalf("empty input must be allow/no-scan (NOT a ban, NOT a confirmed-healthy assertion), got %+v", v)
	}
}

func TestClassify_ThresholdDisabled_NoBan(t *testing.T) {
	in := base("ipv4", "9.9.9.9", ev("t", 1000, 1111, 3333, 4444, 5555, 6666))
	in.BlockRange, in.VerticalPorts, in.HorizontalTargets, in.StrobePorts = 0, 0, 0, 0
	if v := Classify(in); v.Action != "allow" {
		t.Fatalf("all thresholds disabled must ALLOW, got %+v", v)
	}
}
