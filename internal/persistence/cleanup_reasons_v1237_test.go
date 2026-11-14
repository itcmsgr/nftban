// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="persistence_cleanup_reasons_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 cleanup repair: ReasonsForAll reports every reason file holding an IP; RemoveIPFromSourceIf removes the IP from exactly one reason file, keeps every other reason, honours a re-check that refuses under the lock, and uses the PersistBan sibling lock (removal and persist exclude each other). Addresses are RFC 5737 documentation ranges written directly into fixture files (in-memory/tempdir test; no traffic, no firewall)."
// meta:inventory.privileges="none"

package persistence

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func writeReasonFile(t *testing.T, dir, source string, lines ...string) string {
	t.Helper()
	name, ok := FileForSource(source)
	if !ok {
		t.Fatalf("unknown source %s", source)
	}
	p := filepath.Join(dir, "blacklist.d", name)
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("# header\n"+strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestReasonsForAll_EveryReasonFile(t *testing.T) {
	d := t.TempDir()
	writeReasonFile(t, d, "manual", "192.0.2.10  # operator")
	writeReasonFile(t, d, "persistent", "192.0.2.10  # escalated", "198.51.100.20")
	writeReasonFile(t, d, "login", "203.0.113.30")
	got, err := ReasonsForAll(d)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{
		"192.0.2.10":    {"manual", "persistent"},
		"198.51.100.20": {"persistent"},
		"203.0.113.30":  {"login"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("reasons = %v, want %v", got, want)
	}
}

func TestRemoveIPFromSourceIf_OnlyThatReason(t *testing.T) {
	d := t.TempDir()
	man := writeReasonFile(t, d, "manual", "192.0.2.10  # operator")
	per := writeReasonFile(t, d, "persistent", "192.0.2.10  # escalated", "198.51.100.20")
	removed, skip, err := RemoveIPFromSourceIf(d, "192.0.2.10", "persistent", func() (bool, string) { return true, "" })
	if err != nil || !removed || skip != "" {
		t.Fatalf("removed=%v skip=%q err=%v", removed, skip, err)
	}
	pb, _ := os.ReadFile(per)
	mb, _ := os.ReadFile(man)
	if strings.Contains(string(pb), "192.0.2.10") || !strings.Contains(string(pb), "198.51.100.20") {
		t.Errorf("persistent file wrong after removal:\n%s", pb)
	}
	if !strings.Contains(string(mb), "192.0.2.10") {
		t.Errorf("the independent manual reason must be kept:\n%s", mb)
	}
}

func TestRemoveIPFromSourceIf_RecheckRefusesUnderLock(t *testing.T) {
	d := t.TempDir()
	per := writeReasonFile(t, d, "persistent", "198.51.100.20")
	removed, skip, err := RemoveIPFromSourceIf(d, "198.51.100.20", "persistent", func() (bool, string) { return false, "protected" })
	if err != nil || removed || skip != "protected" {
		t.Fatalf("removed=%v skip=%q err=%v", removed, skip, err)
	}
	if b, _ := os.ReadFile(per); !strings.Contains(string(b), "198.51.100.20") {
		t.Errorf("a refused re-check must leave the reason in place")
	}
}

func TestRemoveIPFromSourceIf_UnknownSourceNotGuessed(t *testing.T) {
	if _, _, err := RemoveIPFromSourceIf(t.TempDir(), "198.51.100.20", "feeds", nil); err == nil {
		t.Fatal("an unknown source must be an error, never mapped to the manual file")
	}
}

// Removal holds the same sibling lock as PersistBan: while another holder has it, removal waits.
func TestRemoveIPFromSourceIf_UsesPersistBanSiblingLock(t *testing.T) {
	d := t.TempDir()
	per := writeReasonFile(t, d, "persistent", "198.51.100.20")
	lf, err := os.OpenFile(per+".lock", os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lf.Close()
	if err := syscall.Flock(int(lf.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	done := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _, _ = RemoveIPFromSourceIf(d, "198.51.100.20", "persistent", nil)
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("removal proceeded while the PersistBan sibling lock was held")
	case <-time.After(300 * time.Millisecond):
	}
	_ = syscall.Flock(int(lf.Fd()), syscall.LOCK_UN)
	wg.Wait()
	if b, _ := os.ReadFile(per); strings.Contains(string(b), "198.51.100.20") {
		t.Errorf("removal did not complete after the lock was released")
	}
}
