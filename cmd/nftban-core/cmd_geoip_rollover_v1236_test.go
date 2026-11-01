// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="cmd_geoip_rollover_v1236_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.236 BUG-GEOIP-MONTH-ROLLOVER-404-FAILS-UNIT-AND-DEGRADES-INSTALL: when DB-IP has not published the current month (404), the previous month is fetched; when neither is published a valid existing database is kept (reported, not a failure); with no valid database, and for any other download error, the update still fails. A provider 404 is classified as not-published, other statuses are not. Month arithmetic is first-of-month."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_TEST_MMDB (optional: a real database to validate)"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="loopback httptest only"
// meta:inventory.privileges="none"

package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDbipMonths_FirstOfMonth(t *testing.T) {
	cases := map[string][2]string{
		"2026-03-31": {"2026-03", "2026-02"},
		"2026-01-15": {"2026-01", "2025-12"},
		"2026-11-01": {"2026-11", "2026-10"},
	}
	for day, want := range cases {
		now, _ := time.Parse("2006-01-02", day)
		got := dbipMonths(now)
		if got[0] != want[0] || got[1] != want[1] {
			t.Errorf("%s: got %v, want %v", day, got, want)
		}
	}
}

func TestFetchDBIP_CurrentNotPublished_PreviousInstalled(t *testing.T) {
	var tried []string
	month, err := fetchDBIP([]string{"2026-11", "2026-10"}, func(url string) error {
		tried = append(tried, url)
		if url == dbipURL("2026-11") {
			return errGeoipNotPublished
		}
		return nil
	})
	if err != nil || month != "2026-10" {
		t.Fatalf("got month=%q err=%v, want the previous month installed", month, err)
	}
	if len(tried) != 2 {
		t.Fatalf("tried %v", tried)
	}
}

func TestFetchDBIP_NeitherPublished(t *testing.T) {
	_, err := fetchDBIP([]string{"2026-11", "2026-10"}, func(string) error { return errGeoipNotPublished })
	if !errors.Is(err, errGeoipNotPublished) {
		t.Fatalf("err=%v, want not-published", err)
	}
}

func TestFetchDBIP_OtherErrorStopsWithoutFallback(t *testing.T) {
	calls := 0
	_, err := fetchDBIP([]string{"2026-11", "2026-10"}, func(string) error {
		calls++
		return errors.New("connection refused")
	})
	if err == nil || errors.Is(err, errGeoipNotPublished) || calls != 1 {
		t.Fatalf("err=%v calls=%d, want the network error after one attempt", err, calls)
	}
}

func TestKeepExistingWhenNotPublished(t *testing.T) {
	built := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	if !keepExistingWhenNotPublished(errGeoipNotPublished, built, true) {
		t.Error("not published + valid database: must keep it")
	}
	if keepExistingWhenNotPublished(errGeoipNotPublished, time.Time{}, false) {
		t.Error("not published + no valid database: must stay a failure")
	}
	if keepExistingWhenNotPublished(errors.New("timeout"), built, true) {
		t.Error("other download error: must stay a failure even with a valid database")
	}
}

func TestExistingGeoipBuild_InvalidOrMissing(t *testing.T) {
	dir := t.TempDir()
	junk := filepath.Join(dir, "x.mmdb")
	if err := os.WriteFile(junk, []byte("not a database"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := existingGeoipBuild(junk); ok {
		t.Error("a file that is not a database was accepted")
	}
	if _, ok := existingGeoipBuild(filepath.Join(dir, "missing.mmdb")); ok {
		t.Error("a missing database was accepted")
	}
}

// Optional: validate a real database (set NFTBAN_TEST_MMDB to its path).
func TestExistingGeoipBuild_RealDatabase(t *testing.T) {
	p := os.Getenv("NFTBAN_TEST_MMDB")
	if p == "" {
		t.Skip("NFTBAN_TEST_MMDB not set")
	}
	build, ok := existingGeoipBuild(p)
	if !ok || build.IsZero() {
		t.Fatalf("real database %s not accepted", p)
	}
	t.Logf("real database built %s", build.Format("2006-01-02"))
}

func TestDownloadGzip_404IsNotPublished_500IsNot(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/missing.mmdb.gz" {
			http.NotFound(w, r)
			return
		}
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()
	dest := filepath.Join(t.TempDir(), "db.mmdb")
	if err := downloadAndDecompressGzip(srv.URL+"/missing.mmdb.gz", dest); !errors.Is(err, errGeoipNotPublished) {
		t.Errorf("404: err=%v, want not-published", err)
	}
	if err := downloadAndDecompressGzip(srv.URL+"/broken.mmdb.gz", dest); err == nil || errors.Is(err, errGeoipNotPublished) {
		t.Errorf("500: err=%v, want a plain failure", err)
	}
}
