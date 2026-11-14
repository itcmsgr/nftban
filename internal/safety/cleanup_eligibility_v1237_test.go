// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="safety_cleanup_eligibility_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 cleanup repair: EvaluateCleanup selects only an old, tracked, unprotected automatic reason whose tracked source matches its file and whose age is not inside a bulk timestamp window; every other case is reported with its exclusion reason. Pure in-memory test with RFC 5737 documentation addresses."
// meta:inventory.privileges="none"

package safety

import (
	"fmt"
	"testing"
	"time"
)

func TestEvaluateCleanup_Exclusions(t *testing.T) {
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	old := now.AddDate(0, 0, -(BanAgeThresholdDays + 5))
	young := now.AddDate(0, 0, -1)
	st := &PermanentBansState{Bans: map[string]*PermanentBan{
		"198.51.100.1": {IP: "198.51.100.1", AddedAt: old, Source: "persistent"},                  // eligible
		"198.51.100.2": {IP: "198.51.100.2", AddedAt: old, Source: "persistent", Protected: true}, // protected
		"198.51.100.3": {IP: "198.51.100.3", AddedAt: young, Source: "login"},                     // too young
		"198.51.100.4": {IP: "198.51.100.4", AddedAt: old, Source: "manual"},                      // source mismatch
		"198.51.100.5": {IP: "198.51.100.5", AddedAt: old, Source: "persistent"},                  // also in manual
		"198.51.100.9": {IP: "198.51.100.9", AddedAt: old, Source: "persistent"},                  // no reason file
	}}
	reasons := map[string][]string{
		"198.51.100.1": {"persistent"},
		"198.51.100.2": {"persistent"},
		"198.51.100.3": {"login"},
		"198.51.100.4": {"persistent"},
		"198.51.100.5": {"manual", "persistent"},
		"198.51.100.6": {"portscan"}, // not tracked
		"198.51.100.7": {"manual"},   // manual only: no automatic decision at all
	}
	got := map[string]string{}
	for _, d := range EvaluateCleanup(reasons, st, now, BanAgeThresholdDays) {
		v := d.Exclusion
		if d.Eligible {
			v = "ELIGIBLE"
		}
		got[d.IP+"/"+d.Source] = v
	}
	want := map[string]string{
		"198.51.100.1/persistent": "ELIGIBLE",
		"198.51.100.2/persistent": ExclProtected,
		"198.51.100.3/login":      ExclTooYoung,
		"198.51.100.4/persistent": ExclSourceMismatch,
		"198.51.100.5/persistent": ExclManualReason,
		"198.51.100.6/portscan":   ExclNotTracked,
		"198.51.100.9/":           ExclNoReasonFile,
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("decisions:\n got %v\nwant %v", got, want)
	}
}

// The dns1 2026-10-17 shape: many entries stamped within one minute are persist times, not ages.
func TestEvaluateCleanup_BulkWindowIsUnreliableAge(t *testing.T) {
	now := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
	burst := time.Date(2026, 10, 17, 6, 50, 14, 0, time.UTC)
	st := &PermanentBansState{Bans: map[string]*PermanentBan{}}
	reasons := map[string][]string{}
	for i := 0; i < 30; i++ {
		ip := fmt.Sprintf("203.0.113.%d", i+1)
		st.Bans[ip] = &PermanentBan{IP: ip, AddedAt: burst.Add(time.Duration(i) * time.Second), Source: "login"}
		reasons[ip] = []string{"login"}
	}
	lone := "198.51.100.50"
	st.Bans[lone] = &PermanentBan{IP: lone, AddedAt: burst.AddDate(0, 0, -3), Source: "login"}
	reasons[lone] = []string{"login"}
	if w := DetectBulkWindows(st, BulkWindowMinEntries, BulkWindowSpan); len(w) != 1 {
		t.Fatalf("want one bulk window, got %v", w)
	}
	for _, d := range EvaluateCleanup(reasons, st, now, BanAgeThresholdDays) {
		if d.IP == lone {
			if !d.Eligible {
				t.Errorf("an isolated old entry outside the window must stay eligible, got %q", d.Exclusion)
			}
			continue
		}
		if d.Eligible || d.Exclusion != ExclBulkTimestamp {
			t.Errorf("%s inside the bulk window: eligible=%v exclusion=%q", d.IP, d.Eligible, d.Exclusion)
		}
	}
}

// One function, deterministic: the same inputs give identical decisions (dry-run == execute == stats).
func TestEvaluateCleanup_Deterministic(t *testing.T) {
	now := time.Date(2026, 11, 14, 0, 0, 0, 0, time.UTC)
	st := &PermanentBansState{Bans: map[string]*PermanentBan{
		"198.51.100.1": {IP: "198.51.100.1", AddedAt: now.AddDate(0, -3, 0), Source: "ddos"},
	}}
	r := map[string][]string{"198.51.100.1": {"ddos"}, "198.51.100.2": {"login"}}
	a, b := EvaluateCleanup(r, st, now, BanAgeThresholdDays), EvaluateCleanup(r, st, now, BanAgeThresholdDays)
	if fmt.Sprint(a) != fmt.Sprint(b) {
		t.Fatal("EvaluateCleanup is not deterministic")
	}
}
