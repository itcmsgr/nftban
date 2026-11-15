// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="safety_cleanup_eligibility_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 cleanup repair: EvaluateCleanup makes eligible ONLY an old, unprotected automatic reason whose tracking entry carries the ban-time age marker and a matching source, outside every bulk window and not a documented rollout rewrite. Legacy (unmarked) entries, the dns1 rollout rewrite, bulk windows, manual reasons, protection and missing tracking are excluded with their reason; trust is never inferred from the bulk heuristic. TrackPermanentBan never overwrites a stored reason/source/age; TrackDurableUnknownAge never invents an age. Pure in-memory/tempdir test with RFC 5737 documentation addresses."
// meta:inventory.privileges="none"

package safety

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func TestEvaluateCleanup_Exclusions(t *testing.T) {
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	old := now.AddDate(0, 0, -(BanAgeThresholdDays + 5))
	young := now.AddDate(0, 0, -1)
	bt := AgeSourceBanTime
	st := &PermanentBansState{Bans: map[string]*PermanentBan{
		"198.51.100.1":  {IP: "198.51.100.1", AddedAt: old, Source: "persistent", AgeSource: bt},                  // eligible
		"198.51.100.2":  {IP: "198.51.100.2", AddedAt: old, Source: "persistent", AgeSource: bt, Protected: true}, // protected
		"198.51.100.3":  {IP: "198.51.100.3", AddedAt: young, Source: "login", AgeSource: bt},                     // too young
		"198.51.100.4":  {IP: "198.51.100.4", AddedAt: old, Source: "manual", AgeSource: bt},                      // source mismatch
		"198.51.100.5":  {IP: "198.51.100.5", AddedAt: old, Source: "persistent", AgeSource: bt},                  // also in manual
		"198.51.100.8":  {IP: "198.51.100.8", AddedAt: old, Source: "persistent"},                                 // legacy: no marker
		"198.51.100.9":  {IP: "198.51.100.9", AddedAt: old, Source: "persistent", AgeSource: bt},                  // no reason file
		"198.51.100.10": {IP: "198.51.100.10", AddedAt: old, Source: "login", AgeSource: bt, Reason: "v1235.1-rollout-preserve login|x"},
		"198.51.100.11": {IP: "198.51.100.11", AddedAt: old, Source: "ddos", AgeSource: bt, CleanupPending: "ddos"}, // interrupted
	}}
	reasons := map[string][]string{
		"198.51.100.1":  {"persistent"},
		"198.51.100.2":  {"persistent"},
		"198.51.100.3":  {"login"},
		"198.51.100.4":  {"persistent"},
		"198.51.100.5":  {"manual", "persistent"},
		"198.51.100.6":  {"portscan"}, // not tracked
		"198.51.100.7":  {"manual"},   // manual only: no automatic decision
		"198.51.100.8":  {"persistent"},
		"198.51.100.10": {"login"},
	}
	got := map[string]string{}
	for _, d := range EvaluateCleanup(reasons, st, now, BanAgeThresholdDays) {
		v := d.Exclusion
		if d.Eligible {
			v = "ELIGIBLE"
		}
		if d.FinishPending {
			v += "+FINISH"
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
		"198.51.100.8/persistent": ExclLegacyUnverified,
		"198.51.100.9/":           ExclNoReasonFile,
		"198.51.100.10/login":     ExclRolloutRewrite,
		"198.51.100.11/ddos":      ExclNoReasonFile + "+FINISH",
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("decisions:\n got %v\nwant %v", got, want)
	}
}

// Bulk detection only EXCLUDES: even entries carrying the ban-time marker are excluded inside a bulk
// window, and an entry outside the window is eligible only because of its own marker, never because
// the heuristic "cleared" it.
func TestEvaluateCleanup_BulkWindowExcludesOnly(t *testing.T) {
	now := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
	burst := time.Date(2026, 10, 17, 6, 50, 14, 0, time.UTC)
	st := &PermanentBansState{Bans: map[string]*PermanentBan{}}
	reasons := map[string][]string{}
	for i := 0; i < 30; i++ {
		ip := fmt.Sprintf("203.0.113.%d", i+1)
		st.Bans[ip] = &PermanentBan{IP: ip, AddedAt: burst.Add(time.Duration(i) * time.Second), Source: "login", AgeSource: AgeSourceBanTime}
		reasons[ip] = []string{"login"}
	}
	marked, unmarked := "198.51.100.50", "198.51.100.51"
	st.Bans[marked] = &PermanentBan{IP: marked, AddedAt: burst.AddDate(0, 0, -3), Source: "login", AgeSource: AgeSourceBanTime}
	st.Bans[unmarked] = &PermanentBan{IP: unmarked, AddedAt: burst.AddDate(0, 0, -3), Source: "login"}
	reasons[marked], reasons[unmarked] = []string{"login"}, []string{"login"}
	for _, d := range EvaluateCleanup(reasons, st, now, BanAgeThresholdDays) {
		switch d.IP {
		case marked:
			if !d.Eligible {
				t.Errorf("marked old entry outside the window: want eligible, got %q", d.Exclusion)
			}
		case unmarked:
			if d.Eligible || d.Exclusion != ExclLegacyUnverified {
				t.Errorf("unmarked entry outside the window must stay ineligible (legacy), got eligible=%v %q", d.Eligible, d.Exclusion)
			}
		default:
			if d.Eligible || d.Exclusion != ExclBulkTimestamp {
				t.Errorf("%s inside the bulk window: eligible=%v exclusion=%q", d.IP, d.Eligible, d.Exclusion)
			}
		}
	}
}

func TestTracking_NeverOverwritesProvenanceOrInventsAge(t *testing.T) {
	t.Cleanup(SetPermanentBansPathForTest(filepath.Join(t.TempDir(), "permanent_bans.json")))

	if err := TrackDurableUnknownAge("198.51.100.60", "persistent", false); err != nil {
		t.Fatal(err)
	}
	if err := TrackPermanentBan("198.51.100.61", "v1235.1-rollout-preserve login|x", "manual", false); err != nil {
		t.Fatal(err)
	}
	// a later ban / re-persist of the same IPs must not rewrite stored fields or mark the unknown age
	if err := TrackPermanentBan("198.51.100.60", "later", "login", false); err != nil {
		t.Fatal(err)
	}
	if err := TrackPermanentBan("198.51.100.61", "later", "login", false); err != nil {
		t.Fatal(err)
	}
	st, err := LoadPermanentBans()
	if err != nil {
		t.Fatal(err)
	}
	a, b := st.Bans["198.51.100.60"], st.Bans["198.51.100.61"]
	if !a.AddedAt.IsZero() || a.AgeSource != "" || a.Source != "persistent" {
		t.Errorf("unknown-age entry changed: %+v", a)
	}
	if b.Source != "manual" || b.Reason != "v1235.1-rollout-preserve login|x" || b.AgeSource != AgeSourceBanTime {
		t.Errorf("existing entry's stored provenance was rewritten: %+v", b)
	}
}

func TestEvaluateCleanup_Deterministic(t *testing.T) {
	now := time.Date(2026, 11, 14, 0, 0, 0, 0, time.UTC)
	st := &PermanentBansState{Bans: map[string]*PermanentBan{
		"198.51.100.1": {IP: "198.51.100.1", AddedAt: now.AddDate(0, -3, 0), Source: "ddos", AgeSource: AgeSourceBanTime},
	}}
	r := map[string][]string{"198.51.100.1": {"ddos"}, "198.51.100.2": {"login"}}
	a, b := EvaluateCleanup(r, st, now, BanAgeThresholdDays), EvaluateCleanup(r, st, now, BanAgeThresholdDays)
	if fmt.Sprint(a) != fmt.Sprint(b) {
		t.Fatal("EvaluateCleanup is not deterministic")
	}
}
