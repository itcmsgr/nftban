// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238 BUG-GEOIP-MAXMIND-LICENSE-KEY-IN-ERROR-OUTPUT: a failed MaxMind download must not print
// the licence key. Sentinel key only; the target is a closed local port and a local server, no
// external network.

import (
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

// A low-entropy sentinel built at run time: never a real key, and not a key-shaped literal.
var sentinelKey = "sentinel" + strings.Repeat("0", 24)

func maxmindURL(base string) string {
	return base + "/app/geoip_download?edition_id=GeoLite2-Country&license_key=" + sentinelKey + "&suffix=tar.gz"
}

func TestMaxMindTransportErrorDoesNotLeakKey(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close() // closed port: connection refused

	err = downloadMaxMindTarGz(maxmindURL("http://"+addr), filepath.Join(t.TempDir(), "db.mmdb"), sentinelKey)
	if err == nil {
		t.Fatal("expected a transport error")
	}
	if strings.Contains(err.Error(), sentinelKey) || strings.Contains(err.Error(), "license_key") {
		t.Fatalf("error leaks the key/URL: %q", err.Error())
	}
	if !strings.Contains(err.Error(), "download failed") {
		t.Fatalf("error lost its meaning: %q", err.Error())
	}
}

func TestMaxMindRedirectErrorDoesNotLeakKey(t *testing.T) {
	// A redirect loop yields a *url.Error naming the (key-carrying) URL.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, r.URL.String(), http.StatusFound)
	}))
	defer srv.Close()
	err := downloadMaxMindTarGz(maxmindURL(srv.URL), filepath.Join(t.TempDir(), "db.mmdb"), sentinelKey)
	if err == nil {
		t.Fatal("expected a redirect error")
	}
	if strings.Contains(err.Error(), sentinelKey) {
		t.Fatalf("error leaks the key: %q", err.Error())
	}
}

func TestMaxMindBadStatusDoesNotLeakKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "invalid license key "+r.URL.Query().Get("license_key"), http.StatusUnauthorized)
	}))
	defer srv.Close()
	err := downloadMaxMindTarGz(maxmindURL(srv.URL), filepath.Join(t.TempDir(), "db.mmdb"), sentinelKey)
	if err == nil || strings.Contains(err.Error(), sentinelKey) {
		t.Fatalf("bad status error = %v", err)
	}
}
