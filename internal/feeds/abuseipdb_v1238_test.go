// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 AbuseIPDB provider + credential file: unit tests against a loopback mock server
// (httptest TLS; no external network, no firewall change). Addresses in responses use the
// reserved documentation ranges 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32.
// The fake key is a low-entropy test token built at run time, never a real credential.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testKey is a low-entropy fixture built at run time (not a credential; keeps secret scanners quiet).
var testKey = strings.Repeat("f2fixture", 4)

func okParams() AbuseIPDBParams { return AbuseIPDBParams{ConfidenceMinimum: 90, Limit: 20000} }

// mock serves handler over TLS on loopback and returns its URL and a client that trusts it.
func mock(t *testing.T, h http.HandlerFunc) (string, *http.Client) {
	t.Helper()
	srv := httptest.NewTLSServer(h)
	t.Cleanup(srv.Close)
	return srv.URL + "/api/v2/blacklist", srv.Client()
}

func TestParamsValidate(t *testing.T) {
	for _, tc := range []struct {
		p  AbuseIPDBParams
		ok bool
	}{
		{AbuseIPDBParams{25, 1}, true}, {AbuseIPDBParams{100, AbuseIPDBMaxLimit}, true},
		{AbuseIPDBParams{24, 10}, false}, {AbuseIPDBParams{101, 10}, false},
		{AbuseIPDBParams{90, 0}, false}, {AbuseIPDBParams{90, AbuseIPDBMaxLimit + 1}, false},
	} {
		if err := tc.p.Validate(); (err == nil) != tc.ok {
			t.Fatalf("%+v: err=%v want ok=%v", tc.p, err, tc.ok)
		}
	}
}

func TestRequestCarriesKeyOnlyInHeader(t *testing.T) {
	req, err := BuildAbuseIPDBRequest(context.Background(), AbuseIPDBDefaultURL+"?key=leak", testKey, okParams())
	if err != nil {
		t.Fatal(err)
	}
	if req.Header.Get("Key") != testKey || req.Header.Get("Accept") != "application/json" {
		t.Fatalf("headers %v", req.Header)
	}
	if strings.Contains(req.URL.String(), testKey) || req.URL.Query().Has("key") {
		t.Fatalf("key reached the URL: %s", req.URL.Redacted())
	}
	if req.URL.Query().Get("confidenceMinimum") != "90" || req.URL.Query().Get("limit") != "20000" {
		t.Fatalf("requested parameters not sent as configured: %s", req.URL.RawQuery)
	}
	for _, bad := range []string{"http://api.abuseipdb.com/api/v2/blacklist", "https://user:pw@api.abuseipdb.com/x", "ftp://x/y", "not a url"} {
		if _, err := BuildAbuseIPDBRequest(context.Background(), bad, testKey, okParams()); err == nil {
			t.Fatalf("%q must be refused", bad)
		}
	}
	if _, err := BuildAbuseIPDBRequest(context.Background(), AbuseIPDBDefaultURL, "", okParams()); err == nil {
		t.Fatal("empty key must be refused")
	}
}

func TestFetchOKReportsEffectiveResult(t *testing.T) {
	u, c := mock(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Key") != testKey {
			w.WriteHeader(401)
			return
		}
		w.Header().Set("X-RateLimit-Limit", "5")
		w.Header().Set("X-RateLimit-Remaining", "4")
		w.Header().Set("X-RateLimit-Reset", "1795132800")
		fmt.Fprint(w, `{"meta":{"generatedAt":"2026-11-20T10:00:00+00:00"},"data":[
		 {"ipAddress":"192.0.2.10","abuseConfidenceScore":100,"lastReportedAt":"x"},
		 {"ipAddress":"2001:db8::7","abuseConfidenceScore":97},
		 {"ipAddress":"192.0.2.10","abuseConfidenceScore":100},
		 {"ipAddress":"10.1.2.3","abuseConfidenceScore":100},
		 {"ipAddress":"not-an-ip","abuseConfidenceScore":100},
		 {"ipAddress":"::ffff:198.51.100.5","abuseConfidenceScore":93},
		 {"abuseConfidenceScore":99}]}`)
	})
	res, err := FetchAbuseIPDB(context.Background(), c, u, testKey, okParams(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(res.Entries, ",") != "192.0.2.10,2001:db8::7,198.51.100.5" {
		t.Fatalf("entries %v", res.Entries)
	}
	if res.Received != 7 || res.Accepted != 3 || res.Rejected != 4 {
		t.Fatalf("counts received=%d accepted=%d rejected=%d", res.Received, res.Accepted, res.Rejected)
	}
	if res.MinScore != 93 || res.MaxScore != 100 || res.GeneratedAt != "2026-11-20T10:00:00+00:00" {
		t.Fatalf("observed %d-%d generated %q", res.MinScore, res.MaxScore, res.GeneratedAt)
	}
	if res.Requested != okParams() {
		t.Fatalf("requested %+v must be reported as configured", res.Requested)
	}
	if !res.RateLimit.Known || res.RateLimit.Limit != 5 || res.RateLimit.Remaining != 4 || res.RateLimit.ResetAt.Unix() != 1795132800 {
		t.Fatalf("rate limit %+v", res.RateLimit)
	}
}

func TestFetchWithoutRateHeadersReportsUnknown(t *testing.T) {
	u, c := mock(t, func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, `{"meta":{},"data":[]}`) })
	res, err := FetchAbuseIPDB(context.Background(), c, u, testKey, okParams(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if res.RateLimit.Known || res.MinScore != -1 || res.Accepted != 0 {
		t.Fatalf("unknown must stay unknown, not 0: %+v", res)
	}
}

func kindOf(t *testing.T, err error) *ProviderError {
	t.Helper()
	var pe *ProviderError
	if !errors.As(err, &pe) {
		t.Fatalf("want *ProviderError, got %T %v", err, err)
	}
	if strings.Contains(pe.Error(), testKey) {
		t.Fatalf("error leaks the key: %s", pe.Error())
	}
	return pe
}

func TestFetchTypedFailures(t *testing.T) {
	cases := []struct {
		name   string
		status int
		hdr    map[string]string
		body   string
		kind   string
	}{
		{"auth", 401, nil, `{"errors":[{"detail":"Authentication failed. Your API key is either missing, incorrect, or revoked. key=` + testKey + `","status":401}]}`, ErrKindAuth},
		{"forbidden", 403, nil, `{"errors":[{"detail":"Forbidden"}]}`, ErrKindAuth},
		{"params", 422, nil, `{"errors":[{"detail":"The limit must be an integer.","status":422}]}`, ErrKindClient},
		{"server", 503, nil, `<html>down</html>`, ErrKindServer},
		{"redirect", 302, map[string]string{"Location": "https://elsewhere.invalid/"}, ``, ErrKindRedirect},
		{"html200", 200, nil, `<!DOCTYPE html><html>login</html>`, ErrKindMalformed},
		{"truncated", 200, nil, `{"meta":{"generatedAt":"x"},"data":[{"ipAddress":"192.0.2.1"`, ErrKindMalformed},
		{"nodata", 200, nil, `{"meta":{"generatedAt":"x"}}`, ErrKindMalformed},
		{"trailing", 200, nil, `{"data":[]} {"data":[]}`, ErrKindMalformed},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			u, c := mock(t, func(w http.ResponseWriter, _ *http.Request) {
				for k, v := range tc.hdr {
					w.Header().Set(k, v)
				}
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			})
			_, err := FetchAbuseIPDB(context.Background(), c, u, testKey, okParams(), 0)
			pe := kindOf(t, err)
			if pe.Kind != tc.kind || pe.Status != tc.status {
				t.Fatalf("kind=%s status=%d, want %s %d (%v)", pe.Kind, pe.Status, tc.kind, tc.status, pe)
			}
		})
	}
}

func TestFetchRateLimitedSetsNotBefore(t *testing.T) {
	reset := time.Now().Add(6 * time.Hour).Unix()
	u, c := mock(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "3600")
		w.Header().Set("X-RateLimit-Limit", "5")
		w.Header().Set("X-RateLimit-Remaining", "0")
		w.Header().Set("X-RateLimit-Reset", fmt.Sprint(reset))
		w.WriteHeader(429)
		fmt.Fprint(w, `{"errors":[{"detail":"Daily rate limit of 5 requests exceeded for this endpoint. See headers for additional details.","status":429}]}`)
	})
	_, err := FetchAbuseIPDB(context.Background(), c, u, testKey, okParams(), 0)
	pe := kindOf(t, err)
	if pe.Kind != ErrKindRateLimited || pe.NotBefore.Unix() != reset || pe.RateLimit.Remaining != 0 {
		t.Fatalf("429: %+v (want NotBefore = the later reset %d)", pe, reset)
	}
	if !strings.Contains(pe.Detail, "Daily rate limit") {
		t.Fatalf("provider detail not reported: %q", pe.Detail)
	}
	// Retry-After later than the reset wins
	h := http.Header{}
	h.Set("Retry-After", "7200")
	now := time.Unix(1_000_000, 0)
	if got := notBefore(h, RateLimitInfo{ResetAt: now.Add(time.Hour)}, now); !got.Equal(now.Add(2 * time.Hour)) {
		t.Fatalf("notBefore %v", got)
	}
}

func TestFetchOversizeRefused(t *testing.T) {
	u, c := mock(t, func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"data":[`+strings.Repeat(`{"ipAddress":"192.0.2.1"},`, 100)+`{"ipAddress":"192.0.2.2"}]}`)
	})
	_, err := FetchAbuseIPDB(context.Background(), c, u, testKey, okParams(), 512)
	if pe := kindOf(t, err); pe.Kind != ErrKindOversize {
		t.Fatalf("want oversize, got %v", pe)
	}
}

func TestFetchTransportErrorIsKeyFree(t *testing.T) {
	_, err := FetchAbuseIPDB(context.Background(), &http.Client{Timeout: 2 * time.Second}, "https://127.0.0.1:1/api/v2/blacklist", testKey, okParams(), 0)
	if pe := kindOf(t, err); pe.Kind != ErrKindTransport {
		t.Fatalf("want transport, got %v", pe)
	}
}

// ---- credential file ----

func asOwner(t *testing.T) {
	t.Helper()
	old := credentialOwnerUID
	credentialOwnerUID = os.Getuid()
	t.Cleanup(func() { credentialOwnerUID = old })
}

func TestCredentialFile(t *testing.T) {
	asOwner(t)
	dir := t.TempDir()
	p := filepath.Join(dir, "abuseipdb.key")
	if _, err := ReadCredentialFile(p); !errors.Is(err, ErrCredentialMissing) || CredentialStatus(p) != "absent" {
		t.Fatalf("missing: %v / %s", err, CredentialStatus(p))
	}
	if err := os.WriteFile(p, []byte("  "+testKey+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	k, err := ReadCredentialFile(p)
	if err != nil || k != testKey || CredentialStatus(p) != "ok" {
		t.Fatalf("valid file: %q %v %s", k, err, CredentialStatus(p))
	}
	if err := os.Chmod(p, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadCredentialFile(p); !errors.Is(err, ErrCredentialUnsafe) || !strings.HasPrefix(CredentialStatus(p), "unsafe: mode 0640") {
		t.Fatalf("group-readable must be refused: %v / %s", err, CredentialStatus(p))
	}
	_ = os.Chmod(p, 0o600)
	link := filepath.Join(dir, "link.key")
	if err := os.Symlink(p, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadCredentialFile(link); !errors.Is(err, ErrCredentialUnsafe) {
		t.Fatalf("symlink must be refused: %v", err)
	}
	for name, content := range map[string]string{"short": "abc", "two tokens": testKey + " " + testKey, "bad char": testKey + "$", "huge": strings.Repeat("a", 2000)} {
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := ReadCredentialFile(p)
		if !errors.Is(err, ErrCredentialInvalid) {
			t.Fatalf("%s: want invalid, got %v", name, err)
		}
		if strings.Contains(err.Error(), content) && content != "" {
			t.Fatalf("%s: error echoes the content: %v", name, err)
		}
	}
	credentialOwnerUID = os.Getuid() + 1
	_ = os.WriteFile(p, []byte(testKey), 0o600)
	if _, err := ReadCredentialFile(p); !errors.Is(err, ErrCredentialUnsafe) {
		t.Fatalf("wrong owner must be refused: %v", err)
	}
}
