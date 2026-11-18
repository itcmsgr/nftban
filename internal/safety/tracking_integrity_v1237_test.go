// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="safety_tracking_integrity_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 state boundary (owner 2026-11-15, C1+C2): cleanup loads the tracking state only when the file and every parent are owned by the required uid without group/other write AND the root-only trust marker is valid; establishing trust sanitizes the records written before the boundary ONCE (age_source cleared -> legacy ineligible; pending markers kept but unverified -> never finished; ip/added_at/reason/source/protected kept); records written after the marker keep their provenance; a planted or loosened marker is never trusted; the tracking file is written 0640. Tempdir only, RFC 5737 documentation addresses, no traffic, no firewall."
// meta:inventory.privileges="none"

package safety

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type trackFixture struct {
	t    *testing.T
	top  string
	path string
}

func newTrackFixture(t *testing.T) *trackFixture {
	t.Helper()
	top := t.TempDir()
	if err := os.Chmod(top, 0o750); err != nil {
		t.Fatal(err)
	}
	st := filepath.Join(top, "data", "state")
	if err := os.MkdirAll(st, 0o750); err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(filepath.Dir(st), 0o750)
	_ = os.Chmod(st, 0o750)
	f := &trackFixture{t: t, top: top, path: filepath.Join(st, "permanent_bans.json")}
	t.Cleanup(SetPermanentBansPathForTest(f.path))
	t.Cleanup(SetTrackingIntegrityForTest(os.Getuid(), top))
	return f
}

func (f *trackFixture) establish() {
	f.t.Helper()
	if _, err := EstablishTrackingTrust(); err != nil {
		f.t.Fatal(err)
	}
}

var added = time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)

func TestTrackingTrust_TrustedLayoutLoadsAfterEstablish(t *testing.T) {
	f := newTrackFixture(t)
	if _, err := LoadPermanentBansForCleanup(); !errors.Is(err, ErrTrackingUntrusted) {
		t.Fatalf("before the boundary is established cleanup must refuse, got %v", err)
	}
	f.establish()
	if err := SavePermanentBans(&PermanentBansState{Bans: map[string]*PermanentBan{}}); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(f.path); fi.Mode().Perm() != PermanentBansFileMode {
		t.Fatalf("tracking file mode %04o, want %04o", fi.Mode().Perm(), PermanentBansFileMode)
	}
	if fi, _ := os.Stat(f.path + PermanentBansTrustSuffix); fi.Mode().Perm() != 0o600 {
		t.Fatalf("trust marker mode %04o, want 0600", fi.Mode().Perm())
	}
	if _, err := LoadPermanentBansForCleanup(); err != nil {
		t.Fatalf("trusted layout refused: %v", err)
	}
}

func TestTrackingTrust_RefusesWritableFileParentTopAndSymlink(t *testing.T) {
	cases := map[string]func(f *trackFixture){
		"group-writable file":      func(f *trackFixture) { _ = os.Chmod(f.path, 0o660) },
		"other-writable file":      func(f *trackFixture) { _ = os.Chmod(f.path, 0o642) },
		"group-writable state dir": func(f *trackFixture) { _ = os.Chmod(filepath.Dir(f.path), 0o770) },
		"group-writable top":       func(f *trackFixture) { _ = os.Chmod(f.top, 0o770) },
		"symlinked file": func(f *trackFixture) {
			alt := filepath.Join(f.top, "elsewhere.json")
			_ = os.Rename(f.path, alt)
			_ = os.Symlink(alt, f.path)
		},
	}
	for name, mut := range cases {
		t.Run(name, func(t *testing.T) {
			f := newTrackFixture(t)
			f.establish()
			if err := SavePermanentBans(&PermanentBansState{Bans: map[string]*PermanentBan{}}); err != nil {
				t.Fatal(err)
			}
			mut(f)
			if _, err := LoadPermanentBansForCleanup(); !errors.Is(err, ErrTrackingUntrusted) {
				t.Fatalf("want ErrTrackingUntrusted, got %v", err)
			}
		})
	}
}

func TestTrackingTrust_RefusesForeignOwner(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root-owned files always pass the owner check; covered by the package acceptance")
	}
	f := newTrackFixture(t)
	f.establish()
	if err := SavePermanentBans(&PermanentBansState{Bans: map[string]*PermanentBan{}}); err != nil {
		t.Fatal(err)
	}
	restore := SetTrackingIntegrityForTest(os.Getuid()+1, f.top)
	defer restore()
	if _, err := LoadPermanentBansForCleanup(); !errors.Is(err, ErrTrackingUntrusted) {
		t.Fatalf("want ErrTrackingUntrusted for a foreign owner, got %v", err)
	}
}

// Records written while state/ was service-account writable: kept, never trusted.
func TestTrackingTrust_SanitizesPreBoundaryRecordsOnceKeepsLaterProvenance(t *testing.T) {
	_ = newTrackFixture(t)
	pre := &PermanentBansState{Bans: map[string]*PermanentBan{
		"198.51.100.80": {IP: "198.51.100.80", AddedAt: added, Reason: "r1", Source: "login", Protected: true},
		"198.51.100.81": {IP: "198.51.100.81", AddedAt: added, Reason: "r2", Source: "portscan", CleanupPending: "portscan"},
		"198.51.100.82": {IP: "198.51.100.82", AddedAt: added, Reason: "r3", Source: "ddos", AgeSource: AgeSourceBanTime}, // forged
	}}
	if err := SavePermanentBans(pre); err != nil {
		t.Fatal(err)
	}
	n, err := EstablishTrackingTrust()
	if err != nil || n != 3 {
		t.Fatalf("establish kept %d records, err %v", n, err)
	}
	st, err := LoadPermanentBansForCleanup()
	if err != nil {
		t.Fatal(err)
	}
	a, b, c := st.Bans["198.51.100.80"], st.Bans["198.51.100.81"], st.Bans["198.51.100.82"]
	if !a.Protected || !a.AddedAt.Equal(added) || a.Reason != "r1" || a.Source != "login" {
		t.Fatalf("protection/age/provenance not kept: %+v", a)
	}
	if b.CleanupPending != "portscan" || !b.CleanupPendingUnverified {
		t.Fatalf("pending marker must be kept and flagged unverified: %+v", b)
	}
	if c.AgeSource != "" || !c.AddedAt.Equal(added) || c.Source != "ddos" {
		t.Fatalf("pre-boundary age_source must be cleared, age/source kept: %+v", c)
	}
	// a record written after the boundary keeps its ban-time provenance; a second establish is a no-op
	if err := TrackPermanentBan("198.51.100.83", "r4", "login", false); err != nil {
		t.Fatal(err)
	}
	if n, err := EstablishTrackingTrust(); err != nil || n != 0 {
		t.Fatalf("second establish must be a no-op, got %d %v", n, err)
	}
	st, _ = LoadPermanentBansForCleanup()
	if st.Bans["198.51.100.83"].AgeSource != AgeSourceBanTime {
		t.Fatalf("post-boundary provenance lost: %+v", st.Bans["198.51.100.83"])
	}
	// legacy stays ineligible; the unverified pending marker is reported, never finished
	now := added.AddDate(0, 0, BanAgeThresholdDays+30)
	decs := EvaluateCleanup(map[string][]string{"198.51.100.82": {"ddos"}}, st, now, BanAgeThresholdDays)
	for _, d := range decs {
		if d.Eligible {
			t.Fatalf("a pre-boundary record became eligible: %+v", d)
		}
		if d.IP == "198.51.100.82" && d.Exclusion != ExclLegacyUnverified {
			t.Fatalf("pre-boundary record must be legacy-age-unverified: %+v", d)
		}
		if d.IP == "198.51.100.81" && (d.FinishPending || d.Exclusion != ExclPendingUnverified) {
			t.Fatalf("pre-boundary pending marker must be reported, not finished: %+v", d)
		}
	}
	// a NEW marker written by root under the boundary clears the flag
	if err := SetCleanupPending("198.51.100.81", "portscan"); err != nil {
		t.Fatal(err)
	}
	st, _ = LoadPermanentBansForCleanup()
	if st.Bans["198.51.100.81"].CleanupPendingUnverified {
		t.Fatal("a marker written under the boundary must not stay unverified")
	}
}

// A marker that is loosened, rewritten or planted is never trusted: the records are sanitized again.
func TestTrackingTrust_InvalidMarkerIsReplacedNotTrusted(t *testing.T) {
	cases := map[string]func(m string){
		"group-readable":  func(m string) { _ = os.Chmod(m, 0o640) },
		"wrong content":   func(m string) { _ = os.WriteFile(m, []byte("x\n"), 0o600) },
		"symlink planted": func(m string) { _ = os.Remove(m); _ = os.Symlink("/dev/null", m) },
	}
	for name, mut := range cases {
		t.Run(name, func(t *testing.T) {
			f := newTrackFixture(t)
			f.establish()
			if err := SavePermanentBans(&PermanentBansState{Bans: map[string]*PermanentBan{
				"198.51.100.84": {IP: "198.51.100.84", AddedAt: added, Source: "login", AgeSource: AgeSourceBanTime},
			}}); err != nil {
				t.Fatal(err)
			}
			mut(f.path + PermanentBansTrustSuffix)
			if _, err := LoadPermanentBansForCleanup(); !errors.Is(err, ErrTrackingUntrusted) {
				t.Fatalf("an invalid marker must make cleanup refuse, got %v", err)
			}
			f.establish()
			st, err := LoadPermanentBansForCleanup()
			if err != nil {
				t.Fatal(err)
			}
			if st.Bans["198.51.100.84"].AgeSource != "" {
				t.Fatal("records under an invalid marker must be sanitized again")
			}
		})
	}
}
