// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 part B2: credential writer/remover and the key test, against temp dirs and a loopback TLS
// mock (no real provider, no firewall change; the key is a run-time test fixture).

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func credentialAsMe(t *testing.T) {
	t.Helper()
	ou, og := credentialOwnerUID, credentialOwnerGID
	credentialOwnerUID, credentialOwnerGID = os.Getuid(), os.Getgid()
	t.Cleanup(func() { credentialOwnerUID, credentialOwnerGID = ou, og })
}

func TestCredentialWriteReadRemove(t *testing.T) {
	credentialAsMe(t)
	dir := t.TempDir()
	p := filepath.Join(dir, "abuseipdb.key")
	if err := WriteCredentialFile(p, "  "+testKey+"\n"); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Lstat(p)
	if err != nil || fi.Mode().Perm() != 0o600 || !fi.Mode().IsRegular() {
		t.Fatalf("written file: %v %v", fi, err)
	}
	if got, err := ReadCredentialFile(p); err != nil || got != testKey {
		t.Fatalf("read back: err=%v match=%v", err, got == testKey)
	}
	// rotation replaces a link at the target, never writes through it
	other := filepath.Join(dir, "other")
	if err := os.WriteFile(other, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, p); err != nil {
		t.Fatal(err)
	}
	if err := WriteCredentialFile(p, strings.Repeat("rotated", 4)); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(other); string(b) != "keep" {
		t.Fatal("the writer followed a link at the target")
	}
	for _, bad := range []string{"short", "has space inside the key", strings.Repeat("x", 300)} {
		err := WriteCredentialFile(p, bad)
		if !errors.Is(err, ErrCredentialInvalid) || strings.Contains(err.Error(), bad) {
			t.Fatalf("invalid key %q: %v (must be refused, without echoing it)", bad, err)
		}
	}
	if err := RemoveCredentialFile(p); err != nil {
		t.Fatal(err)
	}
	if CredentialStatus(p) != "absent" {
		t.Fatal("removed key must report absent")
	}
	if err := RemoveCredentialFile(p); !errors.Is(err, ErrCredentialMissing) {
		t.Fatalf("second remove: %v", err)
	}
}

func TestKeyTestOutcomes(t *testing.T) {
	cases := []struct {
		name   string
		status int
		hdr    map[string]string
		kind   string
	}{
		{"accepted", 200, map[string]string{"X-RateLimit-Limit": "1000", "X-RateLimit-Remaining": "998"}, ""},
		{"auth", 401, nil, ErrKindAuth},
		{"rate", 429, map[string]string{"Retry-After": "60"}, ErrKindRateLimited},
		{"redirect", 302, map[string]string{"Location": "https://elsewhere.invalid/"}, ErrKindRedirect},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u, cl := mock(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Key") != testKey || r.URL.Query().Get("ipAddress") != "127.0.0.1" || r.URL.Query().Has("key") {
					w.WriteHeader(400)
					return
				}
				for k, v := range c.hdr {
					w.Header().Set(k, v)
				}
				w.WriteHeader(c.status)
				_, _ = w.Write([]byte(`{"errors":[{"detail":"x ` + testKey + `"}]}`))
			})
			res, err := TestAbuseIPDBKey(context.Background(), cl, u, testKey)
			if c.kind == "" {
				if err != nil || res.Status != 200 || !res.RateLimit.Known || res.RateLimit.Remaining != 998 {
					t.Fatalf("accepted: %+v %v", res, err)
				}
				return
			}
			var pe *ProviderError
			if !errors.As(err, &pe) || pe.Kind != c.kind {
				t.Fatalf("want %s, got %v", c.kind, err)
			}
			if strings.Contains(err.Error(), testKey) {
				t.Fatal("the key leaked into the error")
			}
			if c.kind == ErrKindRateLimited && pe.NotBefore.IsZero() {
				t.Fatal("429 must carry the retry time")
			}
		})
	}
	if _, err := TestAbuseIPDBKey(context.Background(), nil, "http://127.0.0.1/", testKey); err == nil {
		t.Fatal("plain http must be refused")
	}
}
