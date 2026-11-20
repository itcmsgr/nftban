// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238 feed prerequisites (in-memory/temp-dir unit tests; no network, no firewall change;
// feed entries use reserved documentation ranges):
//   - BUG-FEEDS-UPDATE-SINGLE-FEED-REFRESHES-ALL: a named update selects only that feed.
//   - SEC-FEED-STAGING-SNAPSHOTS-OWNED-BY-NFTBAN-ACCOUNT: the snapshot writer creates the
//     file 0640 with the configured owner AT CREATION, exclusively, and never writes through
//     a link pre-placed at the temp or final name.

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestSelectFeedsForUpdate(t *testing.T) {
	cfgs := []FeedConfig{
		{Name: "SPAMHAUS_DROP", Enabled: true},
		{Name: "FIREHOL_LEVEL1", Enabled: true},
		{Name: "BLOCKLIST_DE", Enabled: false},
	}
	all, err := selectFeedsForUpdate(cfgs, "")
	if err != nil || len(all) != 2 {
		t.Fatalf("no name: got %v, %v; want the 2 enabled feeds", all, err)
	}
	one, err := selectFeedsForUpdate(cfgs, "firehol_level1")
	if err != nil || len(one) != 1 || one[0].Name != "FIREHOL_LEVEL1" {
		t.Fatalf("named (case-insensitive): got %v, %v; want only FIREHOL_LEVEL1", one, err)
	}
	if _, err := selectFeedsForUpdate(cfgs, "BLOCKLIST_DE"); err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("disabled feed must be refused, got %v", err)
	}
	if _, err := selectFeedsForUpdate(cfgs, "NO_SUCH_FEED"); err == nil || !strings.Contains(err.Error(), "unknown feed") {
		t.Fatalf("unknown feed must be refused, got %v", err)
	}
}

// ownAsCaller makes the writer chown to the test's own uid/gid (unprivileged run).
func ownAsCaller(t *testing.T) {
	t.Helper()
	old := feedFileOwner
	feedFileOwner = func() (int, int, bool) { return os.Getuid(), os.Getgid(), true }
	t.Cleanup(func() { feedFileOwner = old })
}

func TestWriteFeedFileModeOwnerAndContent(t *testing.T) {
	ownAsCaller(t)
	old := syscall.Umask(0o077) // a restrictive umask must not change the declared 0640
	defer syscall.Umask(old)
	dir := t.TempDir()
	f := filepath.Join(dir, "feed.txt")
	if err := writeFeedFile(f, []string{"192.0.2.0/24", "2001:db8::/32"}); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Lstat(f)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o640 || !fi.Mode().IsRegular() {
		t.Fatalf("mode %v, want regular 0640", fi.Mode())
	}
	st := fi.Sys().(*syscall.Stat_t)
	if int(st.Uid) != os.Getuid() || int(st.Gid) != os.Getgid() {
		t.Fatalf("owner %d:%d, want %d:%d", st.Uid, st.Gid, os.Getuid(), os.Getgid())
	}
	b, _ := os.ReadFile(f)
	if string(b) != "192.0.2.0/24\n2001:db8::/32\n" {
		t.Fatalf("content %q", b)
	}
	if _, err := os.Lstat(f + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("temp file left behind: %v", err)
	}
}

func TestWriteFeedFileNeverFollowsPlacedLinks(t *testing.T) {
	ownAsCaller(t)
	dir := t.TempDir()
	victim := filepath.Join(dir, "victim")
	if err := os.WriteFile(victim, []byte("keep\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f := filepath.Join(dir, "feed.txt")
	// a link pre-placed at the temp name and one at the final name
	if err := os.Symlink(victim, f+".tmp"); err != nil {
		t.Fatal(err)
	}
	if err := writeFeedFile(f, []string{"198.51.100.7"}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(f); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, f); err != nil {
		t.Fatal(err)
	}
	if err := writeFeedFile(f, []string{"203.0.113.9"}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(victim); string(b) != "keep\n" {
		t.Fatalf("link target was written: %q", b)
	}
	fi, err := os.Lstat(f)
	if err != nil || fi.Mode()&os.ModeSymlink != 0 || !fi.Mode().IsRegular() {
		t.Fatalf("final snapshot must be a regular file replacing the link: %v %v", fi.Mode(), err)
	}
}

func TestWriteFeedFileOwnerFailureLeavesSnapshotUntouched(t *testing.T) {
	old := feedFileOwner
	feedFileOwner = func() (int, int, bool) { return 0, 0, true } // chown to root fails unprivileged
	defer func() { feedFileOwner = old }()
	if os.Getuid() == 0 {
		t.Skip("root can chown; the failure path is exercised unprivileged")
	}
	dir := t.TempDir()
	f := filepath.Join(dir, "feed.txt")
	if err := os.WriteFile(f, []byte("192.0.2.1\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := writeFeedFile(f, []string{"192.0.2.2"}); err == nil {
		t.Fatal("an ownership failure must fail the write")
	}
	if b, _ := os.ReadFile(f); string(b) != "192.0.2.1\n" {
		t.Fatalf("last-known-good snapshot changed: %q", b)
	}
	if _, err := os.Lstat(f + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("temp file left behind: %v", err)
	}
}
