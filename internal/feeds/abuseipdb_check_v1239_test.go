// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.239 AbuseIPDB reputation lookup (read-only): in-memory unit test, reserved documentation
// IPs, no traffic/firewall change. A loopback mock server (httptest TLS; no external network, no
// live AbuseIPDB call) answers; addresses use the reserved documentation ranges 192.0.2.0/24,
// 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32. Because ValidateLookupIP refuses documentation
// ranges by design, the HTTP path is exercised through CheckAbuseIPDBAddr. The fake key is the
// run-time fixture testKey (abuseipdb_v1238_test.go), never a real credential.

import (
	"context"
	"fmt"
	"net/http"
	"net/netip"
	"strings"
	"testing"
	"time"
)

const checkOKv4 = `{"data":{"ipAddress":"203.0.113.7","isPublic":true,"ipVersion":4,"isWhitelisted":false,
 "abuseConfidenceScore":87,"countryCode":"ZZ","usageType":"Data Center/Web Hosting/Transit",
 "isp":"Example Transit","domain":"example.net","hostnames":[],"isTor":false,"totalReports":12,
 "numDistinctUsers":5,"lastReportedAt":"2026-11-27T08:15:00+00:00"}}`

func checkMock(t *testing.T, h http.HandlerFunc) (string, *http.Client) {
	t.Helper()
	u, c := mock(t, h)
	return strings.TrimSuffix(u, "/blacklist") + "/check", c
}

func TestCheckOKv4(t *testing.T) {
	var gotQuery, gotPath string
	u, c := checkMock(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Key") != testKey || r.Header.Get("Accept") != "application/json" || r.Method != http.MethodGet {
			w.WriteHeader(401)
			return
		}
		gotQuery, gotPath = r.URL.RawQuery, r.URL.Path
		w.Header().Set("X-RateLimit-Limit", "1000")
		w.Header().Set("X-RateLimit-Remaining", "998")
		w.Header().Set("X-RateLimit-Reset", "1795132800")
		fmt.Fprint(w, checkOKv4)
	})
	before := time.Now().UTC().Add(-time.Second)
	res, err := CheckAbuseIPDBAddr(context.Background(), c, u, testKey, netip.MustParseAddr("203.0.113.7"), 0)
	if err != nil {
		t.Fatal(err)
	}
	if gotPath != "/api/v2/check" || gotQuery != "ipAddress=203.0.113.7&maxAgeInDays=30" || strings.Contains(gotQuery, testKey) {
		t.Fatalf("request path=%q query=%q", gotPath, gotQuery)
	}
	if res.IPAddress != "203.0.113.7" || res.IPVersion != 4 || res.AbuseConfidenceScore != 87 || res.TotalReports != 12 ||
		res.NumDistinctUsers != 5 || res.LastReportedAt != "2026-11-27T08:15:00+00:00" || res.CountryCode != "ZZ" ||
		res.ISP != "Example Transit" || res.UsageType != "Data Center/Web Hosting/Transit" || res.Domain != "example.net" ||
		res.IsWhitelisted == nil || *res.IsWhitelisted || res.MaxAgeInDays != 30 {
		t.Fatalf("parsed %+v", res)
	}
	if res.QueriedAt.Before(before) || res.QueriedAt.After(time.Now().UTC().Add(time.Second)) {
		t.Fatalf("query time %v", res.QueriedAt)
	}
	if !res.RateLimit.Known || res.RateLimit.Limit != 1000 || res.RateLimit.Remaining != 998 || res.RateLimit.ResetAt.Unix() != 1795132800 {
		t.Fatalf("rate limit %+v", res.RateLimit)
	}
}

func TestCheckOKv6NeverReportedAndMaxAge(t *testing.T) {
	var gotQuery string
	u, c := checkMock(t, func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		fmt.Fprint(w, `{"data":{"ipAddress":"2001:db8::7","ipVersion":6,"isWhitelisted":null,"abuseConfidenceScore":0,
		 "countryCode":null,"totalReports":0,"numDistinctUsers":0,"lastReportedAt":null}}`)
	})
	res, err := CheckAbuseIPDBAddr(context.Background(), c, u, testKey, netip.MustParseAddr("2001:DB8:0::7"), 90)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(gotQuery, "ipAddress=2001%3Adb8%3A%3A7") || !strings.Contains(gotQuery, "maxAgeInDays=90") {
		t.Fatalf("query %q", gotQuery)
	}
	if res.IPVersion != 6 || res.IPAddress != "2001:db8::7" || res.LastReportedAt != "" || res.IsWhitelisted != nil ||
		res.CountryCode != "" || res.TotalReports != 0 || res.MaxAgeInDays != 90 || res.RateLimit.Known {
		t.Fatalf("null/absent fields must stay empty/unknown: %+v", res)
	}
}

func TestCheckTypedFailures(t *testing.T) {
	cases := []struct {
		name   string
		status int
		hdr    map[string]string
		body   string
		kind   string
	}{
		{"auth", 401, nil, `{"errors":[{"detail":"Authentication failed. key=` + testKey + `","status":401}]}`, ErrKindAuth},
		{"forbidden", 403, nil, `{"errors":[{"detail":"Forbidden ` + testKey + `"}]}`, ErrKindAuth},
		{"unprocessable", 422, nil, `{"errors":[{"detail":"The max age in days must be between 1 and 365.","status":422}]}`, ErrKindClient},
		{"server", 503, nil, `<html>down</html>`, ErrKindServer},
		{"redirect", 302, map[string]string{"Location": "https://elsewhere.invalid/"}, ``, ErrKindRedirect},
		{"html200", 200, nil, `<!DOCTYPE html><html>login</html>`, ErrKindMalformed},
		{"truncated", 200, nil, `{"data":{"ipAddress":"203.0.113.7","abuseConfidenceScore":87`, ErrKindMalformed},
		{"nodata", 200, nil, `{"meta":{}}`, ErrKindMalformed},
		{"trailing", 200, nil, checkOKv4 + ` {}`, ErrKindMalformed},
		{"otheraddress", 200, nil, strings.Replace(checkOKv4, "203.0.113.7", "203.0.113.8", 1), ErrKindMalformed},
		{"noscore", 200, nil, `{"data":{"ipAddress":"203.0.113.7","totalReports":1,"numDistinctUsers":1}}`, ErrKindMalformed},
		{"scorerange", 200, nil, strings.Replace(checkOKv4, `"abuseConfidenceScore":87`, `"abuseConfidenceScore":101`, 1), ErrKindMalformed},
		{"noreports", 200, nil, `{"data":{"ipAddress":"203.0.113.7","abuseConfidenceScore":5}}`, ErrKindMalformed},
		{"wrongtype", 200, nil, strings.Replace(checkOKv4, `"totalReports":12`, `"totalReports":"12"`, 1), ErrKindMalformed},
		{"oversize", 200, nil, `{"data":{"ipAddress":"203.0.113.7","isp":"` + strings.Repeat("x", abuseIPDBCheckMaxBytes) + `"}}`, ErrKindOversize},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			u, c := checkMock(t, func(w http.ResponseWriter, _ *http.Request) {
				for k, v := range tc.hdr {
					w.Header().Set(k, v)
				}
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			})
			_, err := CheckAbuseIPDBAddr(context.Background(), c, u, testKey, netip.MustParseAddr("203.0.113.7"), 0)
			pe := kindOf(t, err) // also asserts the key is not in the error
			if pe.Kind != tc.kind || pe.Status != tc.status {
				t.Fatalf("kind=%s status=%d, want %s %d (%v)", pe.Kind, pe.Status, tc.kind, tc.status, pe)
			}
		})
	}
}

func TestCheckRateLimitedSetsNotBefore(t *testing.T) {
	reset := time.Now().Add(5 * time.Hour).Unix()
	calls := 0
	u, c := checkMock(t, func(w http.ResponseWriter, _ *http.Request) {
		calls++
		w.Header().Set("Retry-After", "60")
		w.Header().Set("X-RateLimit-Limit", "1000")
		w.Header().Set("X-RateLimit-Remaining", "0")
		w.Header().Set("X-RateLimit-Reset", fmt.Sprint(reset))
		w.WriteHeader(429)
		fmt.Fprint(w, `{"errors":[{"detail":"Daily rate limit of 1000 requests exceeded for this endpoint. See headers for additional details.","status":429}]}`)
	})
	_, err := CheckAbuseIPDBAddr(context.Background(), c, u, testKey, netip.MustParseAddr("198.51.100.20"), 0)
	pe := kindOf(t, err)
	if pe.Kind != ErrKindRateLimited || pe.NotBefore.Unix() != reset || pe.RateLimit.Remaining != 0 || pe.RateLimit.Limit != 1000 {
		t.Fatalf("429: %+v (want NotBefore = the later X-RateLimit-Reset %d)", pe, reset)
	}
	if !strings.Contains(pe.Error(), "retry not before") || !strings.Contains(pe.Detail, "Daily rate limit") {
		t.Fatalf("429 must state the provider detail and the next allowed time: %s", pe.Error())
	}
	if calls != 1 {
		t.Fatalf("a rate-limited lookup must not retry: %d calls", calls)
	}
	// Retry-After only (no reset header)
	u2, c2 := checkMock(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "120")
		w.WriteHeader(429)
	})
	start := time.Now()
	_, err = CheckAbuseIPDBAddr(context.Background(), c2, u2, testKey, netip.MustParseAddr("2001:db8::9"), 0)
	pe = kindOf(t, err)
	if pe.NotBefore.Before(start.Add(119*time.Second)) || pe.NotBefore.After(time.Now().Add(121*time.Second)) || pe.RateLimit.Known {
		t.Fatalf("Retry-After 120: NotBefore %v, rate %+v", pe.NotBefore, pe.RateLimit)
	}
}

func TestCheckTransportErrorIsKeyFree(t *testing.T) {
	_, err := CheckAbuseIPDBAddr(context.Background(), &http.Client{Timeout: 2 * time.Second}, "https://127.0.0.1:1/api/v2/check", testKey, netip.MustParseAddr("192.0.2.1"), 0)
	if pe := kindOf(t, err); pe.Kind != ErrKindTransport {
		t.Fatalf("want transport, got %v", pe)
	}
}

func TestCheckRequestRefusals(t *testing.T) {
	a := netip.MustParseAddr("192.0.2.1")
	for name, fn := range map[string]func() error{
		"no key": func() error {
			_, err := CheckAbuseIPDBAddr(context.Background(), nil, "", "", a, 0)
			return err
		},
		"http endpoint": func() error {
			_, err := CheckAbuseIPDBAddr(context.Background(), nil, "http://api.abuseipdb.com/api/v2/check", testKey, a, 0)
			return err
		},
		"credentials in endpoint": func() error {
			_, err := CheckAbuseIPDBAddr(context.Background(), nil, "https://u:p@api.abuseipdb.com/api/v2/check", testKey, a, 0)
			return err
		},
		"max age 0 is default, 366 refused": func() error {
			_, err := CheckAbuseIPDBAddr(context.Background(), nil, "", testKey, a, 366)
			return err
		},
		"max age negative": func() error {
			_, err := CheckAbuseIPDBAddr(context.Background(), nil, "", testKey, a, -1)
			return err
		},
		"invalid addr": func() error {
			_, err := CheckAbuseIPDBAddr(context.Background(), nil, "", testKey, netip.Addr{}, 0)
			return err
		},
	} {
		err := fn()
		if err == nil {
			t.Fatalf("%s: must be refused before any request", name)
		}
		if strings.Contains(err.Error(), testKey) {
			t.Fatalf("%s: error leaks the key", name)
		}
	}
}

// docAsPublic lets the documentation ranges pass the class check (and nothing else), so the
// accepting path is tested without any non-documentation address.
func docAsPublic(t *testing.T) {
	t.Helper()
	old := lookupClassReject
	doc := []netip.Prefix{netip.MustParsePrefix("192.0.2.0/24"), netip.MustParsePrefix("198.51.100.0/24"),
		netip.MustParsePrefix("203.0.113.0/24"), netip.MustParsePrefix("2001:db8::/32")}
	lookupClassReject = func(s string) (bool, string) {
		if a, err := netip.ParseAddr(s); err == nil {
			for _, p := range doc {
				if p.Contains(a) {
					return false, ""
				}
			}
		}
		return old(s)
	}
	t.Cleanup(func() { lookupClassReject = old })
}

func TestValidateLookupIPAcceptsOneAddress(t *testing.T) {
	docAsPublic(t)
	for in, want := range map[string]string{"203.0.113.7": "203.0.113.7", " 2001:DB8:0::7 ": "2001:db8::7", "::ffff:198.51.100.5": "198.51.100.5"} {
		a, err := ValidateLookupIP(in)
		if err != nil || a.String() != want {
			t.Fatalf("%q: %v %v", in, a, err)
		}
	}
	for in, cause := range map[string]string{"203.0.113.0/24": "CIDR range", "10.1.2.3": "private", "127.0.0.1": "loopback"} {
		if _, err := ValidateLookupIP(in); err == nil || !strings.Contains(err.Error(), cause) {
			t.Fatalf("%q with the seam: want %q, got %v", in, cause, err)
		}
	}
	// the public entry point: validate, then one request
	u, c := checkMock(t, func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, checkOKv4) })
	res, err := CheckAbuseIPDB(context.Background(), c, u, testKey, "::ffff:203.0.113.7", 7)
	if err != nil || res.IPAddress != "203.0.113.7" || res.MaxAgeInDays != 7 {
		t.Fatalf("CheckAbuseIPDB: %+v %v", res, err)
	}
}

func TestValidateLookupIPRefusals(t *testing.T) {
	for in, cause := range map[string]string{
		"":                "no address given",
		"203.0.113.0/24":  "CIDR range",
		"2001:db8::/48":   "CIDR range",
		"not-an-ip":       "not an IPv4 or IPv6 address",
		"192.0.2.300":     "not an IPv4 or IPv6 address",
		"fe80::1%eth0":    "interface zone",
		"127.0.0.1":       "loopback",
		"::1":             "loopback",
		"0.0.0.0":         "unspecified",
		"224.0.0.1":       "multicast",
		"169.254.1.1":     "link-local",
		"fe80::1":         "link-local",
		"10.1.2.3":        "private (RFC 1918)",
		"192.168.1.1":     "private (RFC 1918)",
		"fd00::1":         "unique-local",
		"100.64.0.1":      "CGNAT",
		"192.0.2.1":       "documentation",
		"198.51.100.20":   "documentation",
		"203.0.113.7":     "documentation",
		"2001:db8::7":     "documentation",
		"::ffff:10.0.0.1": "private (RFC 1918)",
	} {
		_, err := ValidateLookupIP(in)
		if err == nil || !strings.Contains(err.Error(), cause) {
			t.Fatalf("%q: want refusal naming %q, got %v", in, cause, err)
		}
	}
	// the public entry point refuses before any request: no server exists at this URL
	if _, err := CheckAbuseIPDB(context.Background(), nil, "https://127.0.0.1:1/api/v2/check", testKey, "203.0.113.7", 0); err == nil ||
		!strings.Contains(err.Error(), "nothing was sent") {
		t.Fatalf("documentation address must be refused before the request: %v", err)
	}
}
