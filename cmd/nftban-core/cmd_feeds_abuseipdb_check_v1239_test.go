// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.239 AbuseIPDB reputation lookup CLI (read-only): in-memory unit test, reserved documentation
// IPs, no traffic/firewall change. A loopback TLS mock (httptest; no external network, no live
// AbuseIPDB call) answers for 203.0.113.7 / 2001:db8::7; the HTTP path is driven through
// runAbuseIPDBCheck because the production validator refuses documentation ranges by design. The
// fake key is a low-entropy run-time fixture, never a real credential.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

var checkCLIKey = strings.Repeat("f2clifix", 4)

func checkCLIMock(t *testing.T, h http.HandlerFunc) (string, *http.Client) {
	t.Helper()
	srv := httptest.NewTLSServer(h)
	t.Cleanup(srv.Close)
	return srv.URL + "/api/v2/check", srv.Client()
}

func TestAbuseIPDBCheckArgs(t *testing.T) {
	ip, age, js, err := parseAbuseIPDBCheckArgs([]string{"--json", "203.0.113.7", "--max-age-days", "90"})
	if err != nil || ip != "203.0.113.7" || age != 90 || !js {
		t.Fatalf("parse: %q %d %v %v", ip, age, js, err)
	}
	if _, age, _, err = parseAbuseIPDBCheckArgs([]string{"2001:db8::7"}); err != nil || age != 30 {
		t.Fatalf("default max age: %d %v", age, err)
	}
	for _, bad := range [][]string{nil, {"--json"}, {"203.0.113.7", "203.0.113.8"}, {"203.0.113.7", "--max-age-days"},
		{"203.0.113.7", "--max-age-days", "0"}, {"203.0.113.7", "--max-age-days", "366"}, {"203.0.113.7", "--max-age-days", "x"},
		{"203.0.113.7", "--yes"}} {
		if _, _, _, err := parseAbuseIPDBCheckArgs(bad); err == nil {
			t.Fatalf("%v must be refused", bad)
		}
	}
}

func TestAbuseIPDBCheckTextOutput(t *testing.T) {
	u, c := checkCLIMock(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Key") != checkCLIKey {
			w.WriteHeader(401)
			return
		}
		w.Header().Set("X-RateLimit-Limit", "1000")
		w.Header().Set("X-RateLimit-Remaining", "998")
		w.Header().Set("X-RateLimit-Reset", "1795132800")
		fmt.Fprint(w, `{"data":{"ipAddress":"203.0.113.7","isWhitelisted":false,"abuseConfidenceScore":87,"countryCode":"ZZ",
		 "usageType":"Data Center/Web Hosting/Transit","isp":"Example Transit","domain":"example.net","totalReports":12,
		 "numDistinctUsers":5,"lastReportedAt":"2026-11-27T08:15:00+00:00"}}`)
	})
	rep := runAbuseIPDBCheck(context.Background(), c, u, checkCLIKey, netip.MustParseAddr("203.0.113.7"), 30)
	var out bytes.Buffer
	if err := finishAbuseIPDBCheck(&out, rep, false); err != nil {
		t.Fatalf("%v\n%s", err, out.String())
	}
	s := out.String()
	t.Logf("mock text output:\n%s", s)
	for _, want := range []string{
		"AbuseIPDB reputation lookup (information only)", "Address:        203.0.113.7",
		"Source:         AbuseIPDB (API v2 check endpoint)", "Queried at:     20",
		"Confidence:     87 of 100", "Reports:        12 from 5 distinct users in the last 30 days",
		"Last reported:  2026-11-27T08:15:00+00:00 (provider time)", "AbuseIPDB whitelist: no (AbuseIPDB's own list; not the NFTBan whitelist)",
		"Check-endpoint quota: 998 of 1000 left", "never bans, unbans or whitelists", "writes no kernel state",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("text output lacks %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, checkCLIKey) {
		t.Fatal("output leaks the key")
	}
}

func TestAbuseIPDBCheckJSONNeverReportedV6(t *testing.T) {
	u, c := checkCLIMock(t, func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"data":{"ipAddress":"2001:db8::7","abuseConfidenceScore":0,"totalReports":0,"numDistinctUsers":0,"lastReportedAt":null}}`)
	})
	rep := runAbuseIPDBCheck(context.Background(), c, u, checkCLIKey, netip.MustParseAddr("2001:db8::7"), 7)
	var out bytes.Buffer
	if err := finishAbuseIPDBCheck(&out, rep, true); err != nil {
		t.Fatal(err)
	}
	t.Logf("mock json output: %s", out.String())
	var m map[string]any
	if err := json.Unmarshal(out.Bytes(), &m); err != nil {
		t.Fatal(err)
	}
	if m["ok"] != true || m["information_only"] != true || m["ip"] != "2001:db8::7" || m["ip_version"] != float64(6) ||
		m["abuse_confidence_score"] != float64(0) || m["total_reports"] != float64(0) || m["max_age_in_days"] != float64(7) ||
		m["queried_at"] == nil || m["check_quota"] != "unknown (the provider did not state it)" {
		t.Fatalf("json %v", m)
	}
	if _, has := m["last_reported_at"]; has {
		t.Fatalf("a null lastReportedAt must not be reported as a time: %v", m)
	}
	var txt bytes.Buffer
	_ = finishAbuseIPDBCheck(&txt, rep, false)
	if !strings.Contains(txt.String(), "Last reported:  no report in the last 7 days") || !strings.Contains(txt.String(), "AbuseIPDB whitelist: not stated") {
		t.Fatalf("text:\n%s", txt.String())
	}
}

func TestAbuseIPDBCheckRateLimitedPrintsNextAllowed(t *testing.T) {
	calls := 0
	u, c := checkCLIMock(t, func(w http.ResponseWriter, _ *http.Request) {
		calls++
		w.Header().Set("X-RateLimit-Limit", "1000")
		w.Header().Set("X-RateLimit-Remaining", "0")
		w.Header().Set("X-RateLimit-Reset", "1795132800")
		w.WriteHeader(429)
		fmt.Fprint(w, `{"errors":[{"detail":"Daily rate limit of 1000 requests exceeded for this endpoint. key=`+checkCLIKey+`","status":429}]}`)
	})
	rep := runAbuseIPDBCheck(context.Background(), c, u, checkCLIKey, netip.MustParseAddr("198.51.100.20"), 30)
	var out bytes.Buffer
	if err := finishAbuseIPDBCheck(&out, rep, false); err == nil {
		t.Fatal("a rate-limited lookup must fail")
	}
	s := out.String()
	t.Logf("mock 429 output:\n%s", s)
	if calls != 1 || rep.ErrorKind != "rate_limited" || rep.Status != 429 ||
		!strings.Contains(s, "Next lookup allowed: not before 2026-11-20T00:00:00Z") || !strings.Contains(s, "0 of 1000 left") {
		t.Fatalf("calls=%d rep=%+v\n%s", calls, rep, s)
	}
	if strings.Contains(s, checkCLIKey) || strings.Contains(rep.Error, checkCLIKey) {
		t.Fatal("output leaks the key")
	}
}

func TestAbuseIPDBCheckAuthFailureIsKeyFree(t *testing.T) {
	u, c := checkCLIMock(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(401)
		fmt.Fprint(w, `{"errors":[{"detail":"Authentication failed for `+checkCLIKey+`","status":401}]}`)
	})
	rep := runAbuseIPDBCheck(context.Background(), c, u, checkCLIKey, netip.MustParseAddr("192.0.2.44"), 30)
	var out bytes.Buffer
	_ = finishAbuseIPDBCheck(&out, rep, true)
	if rep.OK || rep.ErrorKind != "auth" || strings.Contains(out.String(), checkCLIKey) {
		t.Fatalf("auth: %+v\n%s", rep, out.String())
	}
}
