// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 part B: refresh and full-sync records (temp dirs only; no network, no firewall change).

import (
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func recordSandbox(t *testing.T) string {
	t.Helper()
	old := FileOwner
	FileOwner = func() (int, int, bool) { return os.Getuid(), os.Getgid(), true }
	t.Cleanup(func() { FileOwner = old })
	return t.TempDir()
}

func TestRefreshFailureNeverAdvancesSuccess(t *testing.T) {
	dir := recordSandbox(t)
	t0 := time.Date(2026, 11, 20, 8, 0, 0, 0, time.UTC)
	if tr, err := RecordSuccess(dir, "ABUSEIPDB", 9000, "2026-11-20T07:59:00+00:00", &ProviderStats{Received: 9000, Accepted: 9000, MinScore: 100, MaxScore: 100}, t0); err != nil || tr != TransitionNone {
		t.Fatalf("first success: tr=%q err=%v", tr, err)
	}
	t1 := t0.Add(12 * time.Hour)
	nb := t0.Add(24 * time.Hour)
	tr, err := RecordFailure(dir, "abuseipdb", "abuseipdb: rate_limited (HTTP 429)", nb, RateLimitInfo{Known: true, Limit: 5, Remaining: 0}, t1)
	if err != nil || tr != TransitionFailure {
		t.Fatalf("first failure: tr=%q err=%v", tr, err)
	}
	tr, _ = RecordFailure(dir, "abuseipdb", "abuseipdb: transport", time.Time{}, RateLimitInfo{}, t1.Add(time.Hour))
	if tr != TransitionNone {
		t.Fatalf("a repeated failure is not a new transition: %q", tr)
	}
	r, ok, err := ReadRefresh(dir, "abuseipdb")
	if err != nil || !ok {
		t.Fatalf("read: ok=%v err=%v", ok, err)
	}
	if !r.LastSuccessAt.Equal(t0) || r.LastSuccessEntries != 9000 || r.ProviderGeneratedAt == "" {
		t.Fatalf("a failure must keep the success time, entries and provider time: %+v", r)
	}
	if r.Provider == nil || r.Provider.Received != 9000 || !r.Provider.QuotaKnown || r.Provider.QuotaRemaining != 0 || r.Provider.QuotaLimit != 5 {
		t.Fatalf("a failure keeps the last success's provider figures and records the stated quota: %+v", r.Provider)
	}
	if r.LastAttemptOK || r.ConsecutiveFailures != 2 || !r.FailingSince.Equal(t1) || !strings.Contains(r.LastAttemptReason, "transport") {
		t.Fatalf("failure not recorded: %+v", r)
	}
	tr, _ = RecordSuccess(dir, "abuseipdb", 9100, "", nil, t1.Add(20*time.Hour))
	if tr != TransitionRecovery {
		t.Fatalf("success after failures is a recovery: %q", tr)
	}
	r, _, _ = ReadRefresh(dir, "abuseipdb")
	if r.ConsecutiveFailures != 0 || !r.FailingSince.IsZero() || !r.NotBefore.IsZero() || !r.LastAttemptOK {
		t.Fatalf("recovery must clear the failure state: %+v", r)
	}
	fi, err := os.Stat(filepath.Join(dir, "abuseipdb.status"))
	if err != nil || fi.Mode().Perm() != 0o640 {
		t.Fatalf("record mode: %v %v", fi, err)
	}
}

func TestNextPermitted(t *testing.T) {
	now := time.Date(2026, 11, 20, 20, 0, 0, 0, time.UTC)
	if !NextPermitted(RefreshRecord{}, 6*time.Hour, now).IsZero() {
		t.Fatal("never refreshed: a request may go now")
	}
	r := RefreshRecord{LastSuccessAt: now.Add(-2 * time.Hour)}
	if got := NextPermitted(r, 6*time.Hour, now); !got.Equal(now.Add(4 * time.Hour)) {
		t.Fatalf("minimum interval: %v", got)
	}
	if !NextPermitted(r, 0, now).IsZero() {
		t.Fatal("no minimum interval, no back-off: now")
	}
	r.NotBefore = now.Add(12 * time.Hour)
	if got := NextPermitted(r, 6*time.Hour, now); !got.Equal(r.NotBefore) {
		t.Fatalf("the provider back-off wins when later: %v", got)
	}
	r.NotBefore = now.Add(-time.Minute)
	if got := NextPermitted(r, 0, now); !got.IsZero() {
		t.Fatalf("a past back-off no longer applies: %v", got)
	}
}

func TestSyncRecordKeepsLastOKAndLogsExpiryOnce(t *testing.T) {
	dir := recordSandbox(t)
	t0 := time.Date(2026, 11, 20, 3, 25, 0, 0, time.UTC)
	if _, err := WriteSync(dir, SyncRecord{At: t0, OK: true, Effect: "applied", Enforced: []string{"abuseipdb", "spamhaus_drop"}}); err != nil {
		t.Fatal(err)
	}
	newly, err := WriteSync(dir, SyncRecord{At: t0.Add(time.Hour), OK: false, Effect: "refused", Reason: "enforced feed unreadable", Expired: []string{"abuseipdb"}})
	if err != nil || strings.Join(newly, ",") != "abuseipdb" {
		t.Fatalf("newly expired: %v %v", newly, err)
	}
	s, ok, err := ReadSync(dir)
	if err != nil || !ok {
		t.Fatal(ok, err)
	}
	if s.OK || s.Reason == "" || !s.LastOKAt.Equal(t0) || strings.Join(s.LastOKFeeds, ",") != "abuseipdb,spamhaus_drop" {
		t.Fatalf("a failed sync must stay visible and keep the last OK sync: %+v", s)
	}
	newly, _ = WriteSync(dir, SyncRecord{At: t0.Add(2 * time.Hour), OK: true, Effect: "applied", Enforced: []string{"spamhaus_drop"}, Expired: []string{"abuseipdb"}})
	if len(newly) != 0 {
		t.Fatalf("expiry is a transition, logged once: %v", newly)
	}
	s, _, _ = ReadSync(dir)
	if !s.LastOKAt.Equal(t0.Add(2*time.Hour)) || strings.Join(s.LastOKFeeds, ",") != "spamhaus_drop" {
		t.Fatalf("OK sync must move the last OK fields: %+v", s)
	}
}

func TestWriteFeedDirFileStaysInDir(t *testing.T) {
	dir := recordSandbox(t)
	for _, bad := range []string{"", "../x.status", "a/b.status"} {
		if err := WriteFeedDirFile(dir, bad, []byte("x"), FileOwner); err == nil {
			t.Fatalf("name %q must be refused", bad)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "corrupt.status"), []byte("{not json"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ReadRefresh(dir, "corrupt"); err == nil {
		t.Fatal("a corrupt record is an error, never an empty record")
	}
	if tr, err := RecordFailure(dir, "corrupt", "x", time.Time{}, RateLimitInfo{}, time.Now()); err != nil || tr != TransitionFailure {
		t.Fatalf("a corrupt record is replaced by the next outcome: %q %v", tr, err)
	}
}

// v1.238 D-2 (owner GO 2026-11-23): in the setgid root:nftban feeds directory a file root creates
// already has the wanted group, so the writer needs no CAP_CHOWN (nftband has none and runs without
// supplementary groups); it still sets the mode 0640 itself. Runs against a directory prepared
// outside the test (NFTBAN_TEST_FEEDS_DIR, root:nftban, setgid), under nftband's capabilities, e.g.
//
//	systemd-run --wait --pipe -p CapabilityBoundingSet="CAP_NET_ADMIN CAP_DAC_OVERRIDE" \
//	  -E NFTBAN_TEST_FEEDS_DIR=/tmp/x feeds.test -test.run TestWriteFeedDirFileSetgid
//
// The same run against a non-setgid 0750 directory fails with EPERM (the defect).
func TestWriteFeedDirFileSetgidDirNeedsNoChown(t *testing.T) {
	dir := os.Getenv("NFTBAN_TEST_FEEDS_DIR")
	if dir == "" || os.Geteuid() != 0 {
		t.Skip("set NFTBAN_TEST_FEEDS_DIR to a root:nftban setgid directory (needs root privileges to prepare it)")
	}
	grp, err := user.LookupGroup("nftban")
	if err != nil {
		t.Skip("no nftban group on this host")
	}
	gid, _ := strconv.Atoi(grp.Gid)
	owner := func() (int, int, bool) { return 0, gid, true }
	if err := WriteFeedDirFile(dir, "full-sync.status", []byte("{}\n"), owner); err != nil {
		t.Fatalf("write in %s: %v", dir, err)
	}
	st, err := os.Stat(filepath.Join(dir, "full-sync.status"))
	if err != nil {
		t.Fatal(err)
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok || sys.Uid != 0 || int(sys.Gid) != gid || st.Mode().Perm() != 0o640 {
		t.Fatalf("want root:nftban 0640, got uid=%d gid=%d mode=%v", sys.Uid, sys.Gid, st.Mode().Perm())
	}
}
