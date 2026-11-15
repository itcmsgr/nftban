// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="persistence_cleanup_reasons_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 cleanup repair: ReasonsForAll / ReasonsForIP report every reason file holding an IP; RemoveIPFromSourceLocked removes the IP from exactly one reason file and keeps every other reason; LockAllReasons holds the PersistBan sibling lock of every reason file (a concurrent writer waits) and releases them all; removeIPFromFile uses the same sibling lock. In-memory/tempdir test with RFC 5737 documentation addresses written directly into fixture files; no traffic, no firewall."
// meta:inventory.privileges="none"

package persistence

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
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
	if r, _ := ReasonsForIP(d, "192.0.2.10"); !reflect.DeepEqual(r, []string{"manual", "persistent"}) {
		t.Fatalf("ReasonsForIP = %v", r)
	}
}

func TestRemoveIPFromSourceLocked_OnlyThatReason(t *testing.T) {
	d := t.TempDir()
	man := writeReasonFile(t, d, "manual", "192.0.2.10  # operator")
	per := writeReasonFile(t, d, "persistent", "192.0.2.10  # escalated", "198.51.100.20")
	unlock, err := LockAllReasons(d)
	if err != nil {
		t.Fatal(err)
	}
	removed, err := RemoveIPFromSourceLocked(d, "192.0.2.10", "persistent")
	unlock()
	if err != nil || !removed {
		t.Fatalf("removed=%v err=%v", removed, err)
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

func TestRemoveIPFromSourceLocked_UnknownSourceNotGuessed(t *testing.T) {
	if _, err := RemoveIPFromSourceLocked(t.TempDir(), "198.51.100.20", "feeds"); err == nil {
		t.Fatal("an unknown source must be an error, never mapped to the manual file")
	}
}

// LockAllReasons holds the PersistBan sibling lock of every reason file: a writer on ANY of them waits.
func TestLockAllReasons_ExcludesWritersOnEveryReasonFile(t *testing.T) {
	d := t.TempDir()
	unlock, err := LockAllReasons(d)
	if err != nil {
		t.Fatal(err)
	}
	for _, src := range KnownSources() {
		name, _ := FileForSource(src)
		got := make(chan struct{})
		go func(p string) {
			u, err := lockSibling(p) // the same lockfile PersistBan / removeIPFromFile take
			if err == nil {
				u()
			}
			close(got)
		}(filepath.Join(d, "blacklist.d", name))
		select {
		case <-got:
			t.Fatalf("%s: a writer got the lock while LockAllReasons held it", name)
		case <-time.After(150 * time.Millisecond):
		}
		_ = got
	}
	unlock()
	// after release every lock is obtainable again
	for _, src := range KnownSources() {
		name, _ := FileForSource(src)
		u, err := lockSibling(filepath.Join(d, "blacklist.d", name))
		if err != nil {
			t.Fatalf("%s: lock not released: %v", name, err)
		}
		u()
	}
}

// removeIPFromFile (UnpersistBan) now waits for the PersistBan sibling lock.
func TestRemoveIPFromFile_UsesSiblingLock(t *testing.T) {
	d := t.TempDir()
	per := writeReasonFile(t, d, "persistent", "198.51.100.20")
	u, err := lockSibling(per)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _, _ = removeIPFromFile(per, "198.51.100.20"); close(done) }()
	select {
	case <-done:
		t.Fatal("removeIPFromFile proceeded while the sibling lock was held")
	case <-time.After(300 * time.Millisecond):
	}
	u()
	<-done
	if b, _ := os.ReadFile(per); strings.Contains(string(b), "198.51.100.20") {
		t.Errorf("removal did not complete after the lock was released")
	}
}
