// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package nftbackend

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
)

// Campaign prefix admission refuses while the latest refresh could not read a required
// source (here: a dangling-symlink whitelist.conf, which the loader reports as "unknown, not
// absent" even for root). The per-IP and feed answers keep their fail-safe meanwhile.
func TestAdmitPrefixSourceCompleteness(t *testing.T) {
	if _, err := safety.DetectSystemIPs(); err != nil {
		t.Skipf("system-IP detection unavailable in this environment (%v): admission is refused by design here", err)
	}
	cfg := t.TempDir()
	if err := os.MkdirAll(filepath.Join(cfg, "whitelist.d"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg, "whitelist.d", "99-manual.conf"), []byte("185.220.101.7\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mainConf := filepath.Join(cfg, "whitelist.conf")
	breakSource := func() {
		t.Helper()
		if err := os.Symlink(filepath.Join(cfg, "nonexistent"), mainConf); err != nil {
			t.Fatal(err)
		}
	}
	healSource := func() {
		t.Helper()
		if err := os.Remove(mainConf); err != nil {
			t.Fatal(err)
		}
	}
	r := newExemptResolver(cfg, "")
	r.ttl = time.Hour // refreshes below are explicit

	// 1. Initial failure: never admitted.
	breakSource()
	r.Refresh()
	if ok, why := r.AdmitPrefix("45.33.32.0/24"); ok || !strings.HasPrefix(why, "exemption-incomplete") {
		t.Fatalf("initial failure: admit=%v (%s), want refused as incomplete", ok, why)
	}

	// 2. Recovery: a complete refresh clears the failure.
	healSource()
	r.Refresh()
	if ok, why := r.AdmitPrefix("45.33.32.0/24"); !ok {
		t.Fatalf("after recovery: refused (%s)", why)
	}
	if ok, _ := r.IsExempt("185.220.101.7"); !ok {
		t.Fatal("positive control: whitelist.d entry not exempt after a complete refresh")
	}

	// 3. Failure after a successful refresh: refused although older entries remain usable.
	breakSource()
	r.Refresh()
	if ok, why := r.AdmitPrefix("45.33.32.0/24"); ok || !strings.HasPrefix(why, "exemption-incomplete") {
		t.Fatalf("failure after success: admit=%v (%s), want refused as incomplete", ok, why)
	}

	// 4. Per-IP and feed answers unchanged by the failure status (their fail-safe).
	sys, _ := safety.DetectSystemIPs()
	if sys != nil && len(sys.ServerIPs) > 0 {
		ip := sys.ServerIPs[0].String()
		if ok, _ := r.IsExempt(ip); !ok {
			t.Fatalf("IsExempt(%s) changed by the source failure", ip)
		}
		if kept, removed, _ := r.SubtractExempt([]string{ip + "/32"}); removed != 1 || len(kept) != 0 {
			t.Fatalf("SubtractExempt changed by the source failure: removed=%d kept=%v", removed, kept)
		}
	}
	healSource()
	r.Refresh()

	// 5. A valid empty source is complete: no whitelist.conf, no whitelist.d at all.
	empty := newExemptResolver(t.TempDir(), "")
	empty.ttl = time.Hour
	empty.Refresh()
	if ok, why := empty.AdmitPrefix("45.33.32.0/24"); !ok {
		t.Fatalf("valid empty whitelist refused (%s): absence is not a failure", why)
	}
}
