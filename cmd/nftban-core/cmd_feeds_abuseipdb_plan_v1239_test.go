// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.239 AbuseIPDB plan: status rendering, request adaptation and the refresh wiring. In-memory
// unit test, reserved documentation IPs, no traffic/firewall change: a loopback TLS mock
// (httptest; no live AbuseIPDB call) serves the blacklist, records and config live in temp dirs.

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
)

func TestAbuseIPDBStatusLinesKnownPlan(t *testing.T) {
	seen := time.Date(2026, 11, 28, 9, 30, 0, 0, time.UTC)
	prov := &feeds.ProviderStats{CheckQuotaKnown: true, CheckQuotaLimit: 1000, CheckQuotaRemaining: 997,
		CheckQuotaResetAt: time.Date(2026, 11, 29, 0, 0, 0, 0, time.UTC), CheckQuotaSeenAt: seen}
	fc := FeedConfig{Name: "ABUSEIPDB", Format: FeedFormatAbuseIPDB, ConfidenceMinimum: 50, Limit: 50000}
	v := abuseIPDBStatusFor(fc, prov)
	var b bytes.Buffer
	printAbuseIPDBPlanLines(&b, v)
	s := b.String()
	t.Logf("known plan:\n%s", s)
	for _, want := range []string{
		"  Plan:                    Standard (detected from the key's daily limits: check endpoint 1000/day, as of 2026-11-28 09:30 UTC)\n",
		"  Lookup quota:            997 of 1000 left, resets 2026-11-29 00:00 UTC (as of 2026-11-28 09:30 UTC)\n",
		"  Effective request:       confidence >= 100, limit 10000 (plan maximum 10000); configured confidence >= 50, limit 50000\n",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q in:\n%s", want, s)
		}
	}
	if fc.ConfidenceMinimum != 50 || fc.Limit != 50000 {
		t.Fatal("the configured values must not change")
	}
	if !v.PlanKnown || v.EffectiveLimit != 10000 || v.EffectiveConfMin != 100 || v.ConfiguredLimit != 50000 || v.PlanBlacklistMax != 10000 {
		t.Fatalf("json view %+v", v)
	}
}

func TestAbuseIPDBStatusLinesUnknownPlan(t *testing.T) {
	fc := FeedConfig{Name: "ABUSEIPDB", Format: FeedFormatAbuseIPDB} // provider defaults
	var b bytes.Buffer
	printAbuseIPDBPlanLines(&b, abuseIPDBStatusFor(fc, nil))
	s := b.String()
	t.Logf("unknown plan:\n%s", s)
	for _, want := range []string{
		"  Plan:                    unknown (no daily limit seen yet)\n",
		"  Lookup quota:            unknown (no key test or lookup recorded yet)\n",
		"  Effective request:       confidence >= 100, limit 10000 (plan maximum unknown: the configured values are sent)\n",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q in:\n%s", want, s)
		}
	}
	// blacklist fallback, no lookup recorded
	prov := &feeds.ProviderStats{QuotaKnown: true, QuotaLimit: 100, QuotaRemaining: 99, QuotaSeenAt: time.Date(2026, 11, 27, 3, 22, 0, 0, time.UTC)}
	b.Reset()
	printAbuseIPDBPlanLines(&b, abuseIPDBStatusFor(FeedConfig{Format: FeedFormatAbuseIPDB, ConfidenceMinimum: 50, Limit: 200000}, prov))
	if s := b.String(); !strings.Contains(s, "Plan:                    Basic (detected from the key's daily limits: blacklist endpoint 100/day, as of 2026-11-27 03:22 UTC)") ||
		!strings.Contains(s, "Effective request:       confidence >= 50, limit 100000 (plan maximum 100000); configured confidence >= 50, limit 200000") {
		t.Fatalf("fallback:\n%s", s)
	}
}

func TestFetchSendsEffectiveValuesForThePlan(t *testing.T) {
	var got []string
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.URL.Query().Get("confidenceMinimum")+"/"+r.URL.Query().Get("limit"))
		fmt.Fprint(w, `{"meta":{"generatedAt":"2026-11-28T10:00:00+00:00"},"data":[{"ipAddress":"192.0.2.10","abuseConfidenceScore":100}]}`)
	}))
	t.Cleanup(srv.Close)
	key := strings.Repeat("f2planfx", 4)
	base := FeedConfig{Name: "ABUSEIPDB", Format: FeedFormatAbuseIPDB, URL: srv.URL + "/api/v2/blacklist", ConfidenceMinimum: 50, Limit: 50000}
	for _, c := range []struct {
		checkLimit int
		want       string
	}{{1000, "100/10000"}, {3000, "100/10000"}, {5000, "100/10000"}, {10000, "50/50000"}, {50000, "50/50000"}, {7, "50/50000"}, {0, "50/50000"}} {
		feed := base
		feed.ProviderPlan = feeds.AbuseIPDBPlanFromCheckLimit(feeds.RateLimitInfo{Known: c.checkLimit > 0, Limit: c.checkLimit})
		got = nil
		res, err := fetchAbuseIPDBWithKey(feed, key, srv.Client())
		if err != nil {
			t.Fatalf("limit %d: %v", c.checkLimit, err)
		}
		if len(got) != 1 || got[0] != c.want {
			t.Fatalf("check limit %d: sent %v, want %s", c.checkLimit, got, c.want)
		}
		if fmt.Sprintf("%d/%d", res.prov.RequestedConfidence, res.prov.RequestedLimit) != c.want {
			t.Fatalf("check limit %d: recorded %d/%d, want %s", c.checkLimit, res.prov.RequestedConfidence, res.prov.RequestedLimit, c.want)
		}
		if feed.ConfidenceMinimum != 50 || feed.Limit != 50000 {
			t.Fatal("the configured values must not change")
		}
	}
}

func TestRefreshOneUsesTheRecordedPlanAndLeavesConfigAlone(t *testing.T) {
	conf := "FEED_ABUSEIPDB_ENABLED=true\nFEED_ABUSEIPDB_FORMAT=abuseipdb\nFEED_ABUSEIPDB_CONFIDENCE_MINIMUM=50\nFEED_ABUSEIPDB_LIMIT=50000\n"
	cfgDir, _, fd := partBSandbox(t, conf)
	confPath := filepath.Join(cfgDir, "conf.d", "feeds.conf")
	confBefore, _ := os.ReadFile(confPath)
	if err := feeds.RecordCheckQuota(fd, "ABUSEIPDB", feeds.RateLimitInfo{Known: true, Limit: 1000, Remaining: 999}, time.Now()); err != nil {
		t.Fatal(err)
	}
	var seen feeds.AbuseIPDBPlan
	fetchAbuseIPDBFn = func(f FeedConfig, _ string) (*fetchResult, error) {
		seen = f.ProviderPlan
		eff := feeds.EffectiveAbuseIPDBParams(abuseIPDBConfiguredParams(f), f.ProviderPlan)
		return &fetchResult{entries: []string{"192.0.2.9"}, prov: &feeds.ProviderStats{RequestedConfidence: eff.ConfidenceMinimum, RequestedLimit: eff.Limit, Received: 1, Accepted: 1}}, nil
	}
	feed := FeedConfig{Name: "ABUSEIPDB", Format: FeedFormatAbuseIPDB, Enabled: true, ConfidenceMinimum: 50, Limit: 50000}
	if r := refreshOne(feed, fd, cfgDir, time.Now()); r.outcome != refreshOK {
		t.Fatalf("refresh: %+v", r)
	}
	if seen.Label != "Standard" {
		t.Fatalf("refreshOne must hand the recorded plan to the fetcher: %+v", seen)
	}
	rec, _, _ := feeds.ReadRefresh(fd, "abuseipdb")
	if rec.Provider == nil || rec.Provider.RequestedConfidence != 100 || rec.Provider.RequestedLimit != 10000 || !rec.Provider.CheckQuotaKnown {
		t.Fatalf("record after download: %+v", rec.Provider)
	}
	if confAfter, _ := os.ReadFile(confPath); !bytes.Equal(confBefore, confAfter) {
		t.Fatal("the configuration file must never be modified")
	}
}
