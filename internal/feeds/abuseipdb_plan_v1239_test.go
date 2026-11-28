// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.239 AbuseIPDB plan detection and request adaptation: in-memory unit test, reserved
// documentation IPs, no traffic/firewall change. The key test runs against a loopback TLS mock
// (httptest; no external network, no live AbuseIPDB call) that states each documented daily
// limit; records are written to t.TempDir() only. The fake key is the run-time fixture testKey.

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPlanFromCheckLimitEachValueViaKeyTestMock(t *testing.T) {
	cases := []struct {
		hdr      string // X-RateLimit-Limit; "" = not sent
		label    string
		known    bool
		max      int
		fullConf bool
	}{
		{"1000", "Standard", true, 10000, true},
		{"3000", "Webmaster", true, 10000, true},
		{"5000", "Supporter", true, 10000, true},
		{"10000", "Basic", true, 100000, false},
		{"50000", "Premium", true, 500000, false},
		{"7", "unknown (limit 7)", false, 0, false},
		{"", "unknown (no limit stated)", false, 0, false},
	}
	for _, c := range cases {
		t.Run("limit="+c.hdr, func(t *testing.T) {
			u, cl := mock(t, func(w http.ResponseWriter, _ *http.Request) {
				if c.hdr != "" {
					w.Header().Set("X-RateLimit-Limit", c.hdr)
					w.Header().Set("X-RateLimit-Remaining", "1")
				}
				fmt.Fprint(w, `{"data":{"ipAddress":"127.0.0.1"}}`)
			})
			res, err := TestAbuseIPDBKey(context.Background(), cl, u, testKey)
			if err != nil {
				t.Fatal(err)
			}
			p := AbuseIPDBPlanFromCheckLimit(res.RateLimit)
			if p.Label != c.label || p.Known != c.known || p.BlacklistMax != c.max || p.FullConfidenceOnly != c.fullConf {
				t.Fatalf("plan %+v", p)
			}
		})
	}
}

func TestPlanFromBlacklistLimitFallback(t *testing.T) {
	for lim, label := range map[int]string{5: "Standard", 10: "Webmaster", 20: "Supporter", 100: "Basic", 500: "Premium", 42: "unknown (limit 42)"} {
		p := AbuseIPDBPlanFromBlacklistLimit(RateLimitInfo{Known: true, Limit: lim})
		if p.Label != label || p.Known != (lim != 42) {
			t.Fatalf("blacklist %d: %+v", lim, p)
		}
	}
	// the check table and the blacklist table never cross-match
	if AbuseIPDBPlanFromBlacklistLimit(RateLimitInfo{Known: true, Limit: 1000}).Known || AbuseIPDBPlanFromCheckLimit(RateLimitInfo{Known: true, Limit: 5}).Known {
		t.Fatal("a check limit must not identify a plan through the blacklist table, or the reverse")
	}
}

func TestEffectiveParamsAdaptAndNeverChangeConfigured(t *testing.T) {
	check := func(l int) AbuseIPDBPlan { return AbuseIPDBPlanFromCheckLimit(RateLimitInfo{Known: true, Limit: l}) }
	cases := []struct {
		name      string
		conf      AbuseIPDBParams
		plan      AbuseIPDBPlan
		wantConf  int
		wantLimit int
	}{
		{"standard caps limit and raises confidence", AbuseIPDBParams{50, 50000}, check(1000), 100, 10000},
		{"webmaster", AbuseIPDBParams{75, 10000}, check(3000), 100, 10000},
		{"supporter below cap keeps limit", AbuseIPDBParams{100, 5000}, check(5000), 100, 5000},
		{"basic keeps confidence, caps limit", AbuseIPDBParams{50, 200000}, check(10000), 50, 100000},
		{"basic under cap unchanged", AbuseIPDBParams{25, 50000}, check(10000), 25, 50000},
		{"premium at maximum", AbuseIPDBParams{25, 500000}, check(50000), 25, 500000},
		{"unknown value: configured", AbuseIPDBParams{50, 50000}, check(7), 50, 50000},
		{"no plan: configured", AbuseIPDBParams{50, 50000}, AbuseIPDBPlan{}, 50, 50000},
	}
	for _, c := range cases {
		before := c.conf
		eff := EffectiveAbuseIPDBParams(c.conf, c.plan)
		if eff.ConfidenceMinimum != c.wantConf || eff.Limit != c.wantLimit {
			t.Fatalf("%s: effective %+v, want %d/%d", c.name, eff, c.wantConf, c.wantLimit)
		}
		if c.conf != before {
			t.Fatalf("%s: configured values changed: %+v", c.name, c.conf)
		}
		if err := eff.Validate(); err != nil {
			t.Fatalf("%s: effective values invalid: %v", c.name, err)
		}
	}
}

func TestDetectedPlanFromRecord(t *testing.T) {
	seenC, seenB := time.Unix(1795000000, 0).UTC(), time.Unix(1794000000, 0).UTC()
	if p, src, _ := DetectedAbuseIPDBPlan(nil); p.Known || src != "" || p.Label != "unknown (no daily limit seen yet)" {
		t.Fatalf("no record: %+v %q", p, src)
	}
	both := &ProviderStats{CheckQuotaKnown: true, CheckQuotaLimit: 10000, CheckQuotaSeenAt: seenC, QuotaKnown: true, QuotaLimit: 5, QuotaSeenAt: seenB}
	if p, src, at := DetectedAbuseIPDBPlan(both); p.Label != "Basic" || src != PlanSourceCheck || !at.Equal(seenC) {
		t.Fatalf("the check limit wins: %+v %q %v", p, src, at)
	}
	fb := &ProviderStats{CheckQuotaKnown: true, CheckQuotaLimit: 7, CheckQuotaSeenAt: seenC, QuotaKnown: true, QuotaLimit: 10, QuotaSeenAt: seenB}
	if p, src, at := DetectedAbuseIPDBPlan(fb); p.Label != "Webmaster" || src != PlanSourceBlacklist || !at.Equal(seenB) {
		t.Fatalf("blacklist fallback: %+v %q %v", p, src, at)
	}
	onlyB := &ProviderStats{QuotaKnown: true, QuotaLimit: 500, QuotaSeenAt: seenB}
	if p, src, _ := DetectedAbuseIPDBPlan(onlyB); p.Label != "Premium" || src != PlanSourceBlacklist {
		t.Fatalf("blacklist only: %+v %q", p, src)
	}
	neither := &ProviderStats{CheckQuotaKnown: true, CheckQuotaLimit: 7, CheckQuotaSeenAt: seenC, QuotaKnown: true, QuotaLimit: 42}
	if p, src, _ := DetectedAbuseIPDBPlan(neither); p.Known || p.Label != "unknown (limit 7)" || src != PlanSourceCheck {
		t.Fatalf("both unknown: %+v %q", p, src)
	}
}

func TestRecordCheckQuotaTouchesOnlyCheckFields(t *testing.T) {
	old := FileOwner
	FileOwner = func() (int, int, bool) { return os.Getuid(), os.Getgid(), true }
	t.Cleanup(func() { FileOwner = old })
	dir := t.TempDir()
	now := time.Unix(1795100000, 0).UTC()

	// nothing stated: nothing written
	if err := RecordCheckQuota(dir, "ABUSEIPDB", RateLimitInfo{}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "abuseipdb.status")); !os.IsNotExist(err) {
		t.Fatalf("no quota stated must write nothing: %v", err)
	}

	prov := &ProviderStats{RequestedConfidence: 100, RequestedLimit: 10000, Received: 3, Accepted: 3, MinScore: 100, MaxScore: 100}
	prov.SetQuota(RateLimitInfo{Known: true, Limit: 5, Remaining: 4}, now)
	if _, err := RecordSuccess(dir, "ABUSEIPDB", 3, "2026-11-20T10:00:00+00:00", prov, now); err != nil {
		t.Fatal(err)
	}
	if _, err := RecordFailure(dir, "ABUSEIPDB", "abuseipdb: rate_limited (HTTP 429)", now.Add(6*time.Hour), RateLimitInfo{}, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	before, _, _ := ReadRefresh(dir, "abuseipdb")
	reset := now.Add(24 * time.Hour)
	if err := RecordCheckQuota(dir, "ABUSEIPDB", RateLimitInfo{Known: true, Limit: 1000, Remaining: 997, ResetAt: reset}, now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	after, _, _ := ReadRefresh(dir, "abuseipdb")
	if !after.LastSuccessAt.Equal(before.LastSuccessAt) || after.LastAttemptOK != before.LastAttemptOK || !after.LastAttemptAt.Equal(before.LastAttemptAt) ||
		after.LastAttemptReason != before.LastAttemptReason || !after.NotBefore.Equal(before.NotBefore) || after.ConsecutiveFailures != before.ConsecutiveFailures ||
		after.LastSuccessEntries != before.LastSuccessEntries {
		t.Fatalf("a lookup/test must not change the download facts:\nbefore %+v\nafter  %+v", before, after)
	}
	p := after.Provider
	if p == nil || !p.CheckQuotaKnown || p.CheckQuotaLimit != 1000 || p.CheckQuotaRemaining != 997 || !p.CheckQuotaResetAt.Equal(reset) ||
		p.QuotaLimit != 5 || p.Received != 3 || p.RequestedLimit != 10000 {
		t.Fatalf("provider stats: %+v", p)
	}
	// a later download keeps the lookup quota (it cannot see it)
	prov2 := &ProviderStats{RequestedConfidence: 100, RequestedLimit: 10000, Received: 1, Accepted: 1}
	if _, err := RecordSuccess(dir, "ABUSEIPDB", 1, "", prov2, now.Add(7*time.Hour)); err != nil {
		t.Fatal(err)
	}
	r3, _, _ := ReadRefresh(dir, "abuseipdb")
	if r3.Provider == nil || !r3.Provider.CheckQuotaKnown || r3.Provider.CheckQuotaLimit != 1000 {
		t.Fatalf("check quota lost on download: %+v", r3.Provider)
	}
	if pl, _, _ := DetectedAbuseIPDBPlan(r3.Provider); pl.Label != "Standard" {
		t.Fatalf("plan from the record: %+v", pl)
	}
	// a corrupt record is left alone
	if err := os.WriteFile(filepath.Join(dir, "abuseipdb.status"), []byte("{corrupt"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := RecordCheckQuota(dir, "ABUSEIPDB", RateLimitInfo{Known: true, Limit: 1000}, now); err == nil {
		t.Fatal("a corrupt record must not be overwritten by a lookup")
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "abuseipdb.status")); string(b) != "{corrupt" {
		t.Fatalf("corrupt record changed: %q", b)
	}
}
