// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="safety_tracking_integrity_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 tracking-state integrity (owner 2026-11-15): cleanup loads the tracking file only when the file and every parent up to the chain top are owned by the required uid without group/other write and the file is a regular non-symlink; the legacy file is copied once, keeping ip/added_at/reason/source/protected/cleanup_pending and clearing age_source (migrated records stay ineligible), is left byte-identical and is never read again; the tracking file is written 0640. Tempdir only, RFC 5737 documentation addresses, no traffic, no firewall."
// meta:inventory.privileges="none"

package safety

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type trackFixture struct {
	t      *testing.T
	top    string
	path   string
	legacy string
}

func newTrackFixture(t *testing.T) *trackFixture {
	t.Helper()
	top := t.TempDir()
	if err := os.Chmod(top, 0o750); err != nil {
		t.Fatal(err)
	}
	data := filepath.Join(top, "data")
	if err := os.MkdirAll(filepath.Join(data, "state"), 0o750); err != nil {
		t.Fatal(err)
	}
	f := &trackFixture{t: t, top: top, path: filepath.Join(data, "permanent_bans.json"), legacy: filepath.Join(data, "state", "permanent_bans.json")}
	t.Cleanup(SetPermanentBansPathForTest(f.path))
	t.Cleanup(SetTrackingIntegrityForTest(f.legacy, os.Getuid(), top))
	return f
}

func (f *trackFixture) writeLegacy(st *PermanentBansState) []byte {
	f.t.Helper()
	b, _ := json.MarshalIndent(st, "", "  ")
	if err := os.WriteFile(f.legacy, b, 0o640); err != nil {
		f.t.Fatal(err)
	}
	return b
}

func TestTrackingIntegrity_TrustedLayoutLoads(t *testing.T) {
	f := newTrackFixture(t)
	if err := SavePermanentBans(&PermanentBansState{Bans: map[string]*PermanentBan{}}); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(f.path)
	if fi.Mode().Perm() != PermanentBansFileMode {
		t.Fatalf("tracking file mode %04o, want %04o", fi.Mode().Perm(), PermanentBansFileMode)
	}
	if _, err := LoadPermanentBansForCleanup(); err != nil {
		t.Fatalf("trusted layout refused: %v", err)
	}
}

func TestTrackingIntegrity_RefusesWritableFileParentAndSymlink(t *testing.T) {
	cases := map[string]func(f *trackFixture){
		"group-writable file":   func(f *trackFixture) { _ = os.Chmod(f.path, 0o660) },
		"other-writable file":   func(f *trackFixture) { _ = os.Chmod(f.path, 0o642) },
		"group-writable parent": func(f *trackFixture) { _ = os.Chmod(filepath.Dir(f.path), 0o770) },
		"group-writable top":    func(f *trackFixture) { _ = os.Chmod(f.top, 0o770) },
		"symlinked file": func(f *trackFixture) {
			alt := filepath.Join(f.top, "elsewhere.json")
			_ = os.Rename(f.path, alt)
			_ = os.Symlink(alt, f.path)
		},
	}
	for name, mut := range cases {
		t.Run(name, func(t *testing.T) {
			f := newTrackFixture(t)
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

func TestTrackingIntegrity_RefusesForeignOwner(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root-owned files always pass the owner check; covered by the package acceptance")
	}
	f := newTrackFixture(t)
	if err := SavePermanentBans(&PermanentBansState{Bans: map[string]*PermanentBan{}}); err != nil {
		t.Fatal(err)
	}
	restore := SetTrackingIntegrityForTest(f.legacy, os.Getuid()+1, f.top) // the file's owner is not the required uid
	defer restore()
	if _, err := LoadPermanentBansForCleanup(); !errors.Is(err, ErrTrackingUntrusted) {
		t.Fatalf("want ErrTrackingUntrusted for a foreign owner, got %v", err)
	}
}

func TestTrackingMigration_PreservesStateClearsAgeSourceLeavesLegacy(t *testing.T) {
	f := newTrackFixture(t)
	added := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	legacyBytes := f.writeLegacy(&PermanentBansState{Bans: map[string]*PermanentBan{
		"198.51.100.80": {IP: "198.51.100.80", AddedAt: added, Reason: "r1", Source: "login", Protected: true},
		"198.51.100.81": {IP: "198.51.100.81", AddedAt: added, Reason: "r2", Source: "portscan", CleanupPending: "portscan"},
		"198.51.100.82": {IP: "198.51.100.82", AddedAt: added, Reason: "r3", Source: "ddos", AgeSource: AgeSourceBanTime}, // forged marker
	}})
	st, err := LoadPermanentBans()
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Bans) != 3 {
		t.Fatalf("migrated %d records, want 3", len(st.Bans))
	}
	a, b, c := st.Bans["198.51.100.80"], st.Bans["198.51.100.81"], st.Bans["198.51.100.82"]
	if !a.Protected || !a.AddedAt.Equal(added) || a.Reason != "r1" || a.Source != "login" {
		t.Fatalf("protected record not preserved: %+v", a)
	}
	if b.CleanupPending != "portscan" {
		t.Fatalf("pending marker not preserved: %+v", b)
	}
	if c.AgeSource != "" || !c.AddedAt.Equal(added) {
		t.Fatalf("legacy age_source must be cleared (untrusted), age kept: %+v", c)
	}
	if _, err := os.Stat(f.path); err != nil {
		t.Fatalf("new tracking file not written: %v", err)
	}
	now, _ := os.ReadFile(f.legacy)
	if !bytes.Equal(now, legacyBytes) {
		t.Fatal("legacy file must be left byte-identical (copy, never move)")
	}
	// never read again: a later change to the legacy file has no effect
	f.writeLegacy(&PermanentBansState{Bans: map[string]*PermanentBan{"198.51.100.99": {IP: "198.51.100.99", AddedAt: added}}})
	st2, _ := LoadPermanentBans()
	if _, ok := st2.Bans["198.51.100.99"]; ok || len(st2.Bans) != 3 {
		t.Fatalf("legacy file was read again after migration: %d records", len(st2.Bans))
	}
	// migrated records stay ineligible under the approved rules
	reasons := map[string][]string{"198.51.100.82": {"ddos"}}
	decs := EvaluateCleanup(reasons, st2, added.AddDate(0, 0, BanAgeThresholdDays+30), BanAgeThresholdDays)
	found := false
	for _, d := range decs {
		if d.IP == "198.51.100.82" && d.Source == "ddos" {
			found = true
			if d.Eligible || d.Exclusion != ExclLegacyUnverified {
				t.Fatalf("migrated record must be legacy-age-unverified: %+v", d)
			}
		}
		if d.Eligible {
			t.Fatalf("no migrated record may be eligible: %+v", d)
		}
	}
	if !found {
		t.Fatalf("no decision for the migrated ddos reason: %+v", decs)
	}
}

func TestTrackingMigration_NoLegacyNoFileIsEmpty(t *testing.T) {
	f := newTrackFixture(t)
	st, err := LoadPermanentBans()
	if err != nil || len(st.Bans) != 0 {
		t.Fatalf("want empty state, got %v %v", st, err)
	}
	if _, err := os.Stat(f.path); !os.IsNotExist(err) {
		t.Fatal("nothing to migrate must not create a file")
	}
}
