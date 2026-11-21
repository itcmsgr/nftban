// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238 part B: refresh outcome, deferral, exit status and the status reader. Mock fetchers and
// temp dirs only (feed entries are documentation ranges; no network, no firewall change).

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
)

func partBSandbox(t *testing.T, conf string) (cfgDir, dataDir, feedsDir string) {
	t.Helper()
	oldF, oldO := feedFileOwner, feeds.FileOwner
	own := func() (int, int, bool) { return os.Getuid(), os.Getgid(), true }
	feedFileOwner, feeds.FileOwner = own, own
	oldP, oldA := fetchPlainFn, fetchAbuseIPDBFn
	t.Cleanup(func() {
		feedFileOwner, feeds.FileOwner = oldF, oldO
		fetchPlainFn, fetchAbuseIPDBFn = oldP, oldA
	})
	root := t.TempDir()
	cfgDir, dataDir = filepath.Join(root, "etc"), filepath.Join(root, "data")
	feedsDir = filepath.Join(dataDir, "feeds")
	for _, d := range []string{filepath.Join(cfgDir, "conf.d"), feedsDir, filepath.Join(dataDir, "state")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "conf.d", "feeds.conf"), []byte(conf), 0o644); err != nil {
		t.Fatal(err)
	}
	return cfgDir, dataDir, feedsDir
}

func setMtime(t *testing.T, path string, ts time.Time) {
	t.Helper()
	if err := os.Chtimes(path, ts, ts); err != nil {
		t.Fatal(err)
	}
}

func TestRefreshOneFailureKeepsSnapshotAndSuccessTime(t *testing.T) {
	_, _, fd := partBSandbox(t, "")
	snap := filepath.Join(fd, "spamhaus_drop.txt")
	if err := os.WriteFile(snap, []byte("192.0.2.0/24\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-10 * time.Hour).Truncate(time.Second)
	setMtime(t, snap, old)
	feed := FeedConfig{Name: "SPAMHAUS_DROP", URL: "https://example.invalid/drop.txt", Enabled: true}

	fetchPlainFn = func(string) (*fetchResult, error) { return nil, errors.New("bad HTTP status: 503") }
	if r := refreshOne(feed, fd, "", time.Now()); r.outcome != refreshFailed {
		t.Fatalf("outcome %q", r.outcome)
	}
	if fi, _ := os.Stat(snap); !fi.ModTime().Equal(old) {
		t.Fatal("a failed download must not touch the snapshot (its age is the freshness)")
	}
	rec, ok, err := feeds.ReadRefresh(fd, "spamhaus_drop")
	if err != nil || !ok || rec.LastAttemptOK || !rec.LastSuccessAt.IsZero() || !strings.Contains(rec.LastAttemptReason, "503") {
		t.Fatalf("failure record: %+v ok=%v err=%v", rec, ok, err)
	}

	fetchPlainFn = func(string) (*fetchResult, error) {
		return &fetchResult{entries: []string{"198.51.100.0/24", "203.0.113.7"}}, nil
	}
	if r := refreshOne(feed, fd, "", time.Now()); r.outcome != refreshOK || r.entries != 2 {
		t.Fatalf("success: %+v", r)
	}
	if b, _ := os.ReadFile(snap); string(b) != "198.51.100.0/24\n203.0.113.7\n" {
		t.Fatalf("snapshot: %q", b)
	}
	rec, _, _ = feeds.ReadRefresh(fd, "spamhaus_drop")
	if !rec.LastAttemptOK || rec.LastSuccessAt.IsZero() || rec.LastSuccessEntries != 2 {
		t.Fatalf("success record: %+v", rec)
	}
}

func TestRefreshOneDefersWithoutTouchingTheRecord(t *testing.T) {
	_, _, fd := partBSandbox(t, "")
	feed := FeedConfig{Name: "ABUSEIPDB", Format: FeedFormatAbuseIPDB, Enabled: true}
	calls := 0
	nb := time.Now().Add(9 * time.Hour)
	fetchAbuseIPDBFn = func(FeedConfig, string) (*fetchResult, error) {
		calls++
		return nil, &feeds.ProviderError{Kind: feeds.ErrKindRateLimited, Status: 429, NotBefore: nb}
	}
	if r := refreshOne(feed, fd, "", time.Now()); r.outcome != refreshFailed || calls != 1 {
		t.Fatalf("429: %+v calls=%d", r, calls)
	}
	before, _ := os.ReadFile(filepath.Join(fd, "abuseipdb.status"))
	if r := refreshOne(feed, fd, "", time.Now()); r.outcome != refreshDeferred || calls != 1 {
		t.Fatalf("no request before the provider's back-off: %+v calls=%d", r, calls)
	}
	after, _ := os.ReadFile(filepath.Join(fd, "abuseipdb.status"))
	if !bytes.Equal(before, after) {
		t.Fatal("a deferral is not an attempt: the record must not change")
	}
	rec, _, _ := feeds.ReadRefresh(fd, "abuseipdb")
	if !rec.NotBefore.Equal(nb.UTC()) {
		t.Fatalf("back-off not recorded: %+v", rec)
	}

	// minimum interval after a success
	fetchAbuseIPDBFn = func(FeedConfig, string) (*fetchResult, error) {
		calls++
		return &fetchResult{entries: []string{"192.0.2.9"}, generatedAt: "2026-11-20T08:00:00+00:00"}, nil
	}
	if r := refreshOne(feed, fd, "", nb.Add(time.Minute)); r.outcome != refreshOK {
		t.Fatalf("after the back-off: %+v", r)
	}
	feed.MinInterval = 6 * time.Hour
	if r := refreshOne(feed, fd, "", time.Now().Add(time.Hour)); r.outcome != refreshDeferred {
		t.Fatalf("minimum interval: %+v", r)
	}
}

func TestUpdateOutcomeKeepsDownloadAndSyncSeparate(t *testing.T) {
	syncErr := errors.New("sync refused, nothing changed")
	cases := []struct {
		name     string
		feed     string
		failed   []string
		deferred []string
		sync     error
		wantErr  string
	}{
		{"all ok", "", nil, nil, nil, ""},
		{"download failed, sync ok", "", []string{"ABUSEIPDB"}, nil, nil, "download failed for ABUSEIPDB"},
		{"download ok, sync failed", "", nil, nil, syncErr, "full sync did not complete"},
		{"both failed", "", []string{"X"}, nil, syncErr, "full sync did not complete: sync refused"},
		{"scheduled run, deferred", "", nil, []string{"ABUSEIPDB"}, nil, ""},
		{"named feed, deferred", "ABUSEIPDB", nil, []string{"ABUSEIPDB"}, nil, "not refreshed: request deferred"},
	}
	for _, c := range cases {
		err := updateOutcome(c.feed, c.failed, c.deferred, c.sync)
		if c.wantErr == "" {
			if err != nil {
				t.Errorf("%s: want success, got %v", c.name, err)
			}
			continue
		}
		if err == nil || !strings.Contains(err.Error(), c.wantErr) {
			t.Errorf("%s: want %q, got %v", c.name, c.wantErr, err)
		}
	}
}

const partBConf = `FEED_ABUSEIPDB_URL="https://api.abuseipdb.com/api/v2/blacklist"
FEED_ABUSEIPDB_FORMAT="abuseipdb"
FEED_ABUSEIPDB_ENABLED="true"
FEED_ABUSEIPDB_MAX_AGE="72h"
FEED_ABUSEIPDB_MIN_INTERVAL="6h"
FEED_SPAMHAUS_DROP_URL="https://example.invalid/drop.txt"
FEED_SPAMHAUS_DROP_ENABLED="true"
FEED_TOR_EXITS_URL="https://example.invalid/tor.txt"
FEED_TOR_EXITS_ENABLED="false"
`

func TestFeedsStatusExpiryFailureAndSyncAreSeparate(t *testing.T) {
	cfg, data, fd := partBSandbox(t, partBConf)
	now := time.Now().UTC().Truncate(time.Second)
	for f, age := range map[string]time.Duration{"abuseipdb": 80 * time.Hour, "spamhaus_drop": time.Hour} {
		p := filepath.Join(fd, f+".txt")
		if err := os.WriteFile(p, []byte("192.0.2.1\n"), 0o640); err != nil {
			t.Fatal(err)
		}
		setMtime(t, p, now.Add(-age))
	}
	if _, err := feeds.RecordSuccess(fd, "abuseipdb", 9000, "2026-11-17T03:00:00+00:00", nil, now.Add(-80*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := feeds.RecordFailure(fd, "abuseipdb", "abuseipdb: rate_limited (HTTP 429)", now.Add(5*time.Hour), feeds.RateLimitInfo{}, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := feeds.WriteSync(fd, feeds.SyncRecord{At: now.Add(-2 * time.Hour), OK: true, Effect: "applied", Enforced: []string{"abuseipdb", "spamhaus_drop"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := feeds.WriteSync(fd, feeds.SyncRecord{At: now.Add(-time.Hour), OK: false, Effect: "refused", Reason: "daemon busy"}); err != nil {
		t.Fatal(err)
	}
	configs, err := parseFeedsConfig(filepath.Join(cfg, "conf.d", "feeds.conf"))
	if err != nil {
		t.Fatal(err)
	}
	rep, err := buildFeedsStatus(cfg, data, true, configs, now, "")
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]feedStatusView{}
	for _, v := range rep.Feeds {
		by[v.Feed] = v
	}
	a := by["abuseipdb"]
	if a.State != feedStateExpired || a.Enforcement != "pending_removal" ||
		!strings.Contains(a.EnforcementText, "until the next successful full sync") ||
		!strings.Contains(a.StateText, "excluded by the feed authority") {
		t.Fatalf("expired feed: %+v", a)
	}
	if a.LastAttempt == nil || a.LastAttempt.OK || a.ConsecutiveFailures != 1 || a.NextPermittedRetry == nil {
		t.Fatalf("failed attempt and back-off must show: %+v", a)
	}
	if a.LastSuccessAt == nil || !a.LastSuccessAt.Equal(now.Add(-80*time.Hour)) || a.ProviderGeneratedAt == "" {
		t.Fatalf("success time and provider time stay separate: %+v", a)
	}
	if s := by["spamhaus_drop"]; s.State != feedStateFresh || s.Enforcement != "enforced" || s.LastSuccessSource != "snapshot_mtime" {
		t.Fatalf("fresh feed without a record: %+v", s)
	}
	if tor := by["tor_exits"]; tor.State != feedStateDisabled || tor.Enforcement != "not_enforced" {
		t.Fatalf("disabled feed: %+v", tor)
	}
	if rep.LastFullSync.OK || !rep.LastFullSync.Recorded || rep.LastFullSync.LastOKAt == nil || rep.Worst != feedStateExpired {
		t.Fatalf("a failed sync must stay visible: %+v worst=%s", rep.LastFullSync, rep.Worst)
	}
	// B3: the attention list status/health print. Expiry, the failed download and the failed
	// sync are separate items; the fresh and the disabled feed contribute nothing.
	keys := map[string]string{}
	for _, it := range rep.Attention {
		keys[it.Key+"/"+it.Feed] = it.Text
	}
	if len(rep.Attention) != 4 {
		t.Fatalf("attention: %+v", rep.Attention)
	}
	if txt := keys["feed_expired/abuseipdb"]; !strings.Contains(txt, "excluded by the feed authority") ||
		!strings.Contains(txt, "until the next successful full sync") || strings.Contains(txt, "removed at 72") {
		t.Fatalf("expiry attention: %q", txt)
	}
	if txt := keys["feed_refresh_failed/abuseipdb"]; !strings.Contains(txt, "rate_limited") || !strings.Contains(txt, "snapshot retained") {
		t.Fatalf("download attention: %q", txt)
	}
	if txt := keys["feeds_sync_failed/"]; !strings.Contains(txt, "daemon busy") || !strings.Contains(txt, "last successful full sync") {
		t.Fatalf("sync attention: %q", txt)
	}
	if _, ok := keys["feed_credential/abuseipdb"]; !ok {
		t.Fatalf("an absent key on an enabled provider feed must be listed: %+v", rep.Attention)
	}
}

// B3: a non-root reader gets one "needs root" line, not one per feed; disabled feeds add nothing.
func TestFeedsAttentionCollapsesPermissionErrors(t *testing.T) {
	rep := feedsStatusReport{
		Feeds: []feedStatusView{
			{Feed: "a", Enabled: true, State: feedStateFresh, RecordError: recordNeedsRoot},
			{Feed: "b", Enabled: true, State: feedStateFresh, RecordError: recordNeedsRoot},
			{Feed: "c", Enabled: false, State: feedStateDisabled, RecordError: "refresh record c.status: corrupt"},
		},
		LastFullSync: syncView{Error: recordNeedsRoot},
	}
	got := feedsAttention(rep)
	if len(got) != 1 || got[0].Key != "feeds_records_need_root" {
		t.Fatalf("attention: %+v", got)
	}
	if a := feedsAttention(feedsStatusReport{}); a == nil || len(a) != 0 {
		t.Fatalf("nothing to report must be an empty list (JSON []), got %#v", a)
	}
}

func TestFeedExtrasValidated(t *testing.T) {
	_, _, _ = partBSandbox(t, "")
	for _, bad := range []map[string]string{
		{"X_FORMAT": "csv"},
		{"X_MIN_INTERVAL": "soon"},
		{"X_LIMIT": "-1"},
		{"X_CONFIDENCE_MINIMUM": "high"},
	} {
		fc := FeedConfig{Name: "X"}
		if err := applyFeedExtras(&fc, bad); err == nil {
			t.Fatalf("%v must be refused", bad)
		}
	}
	fc := FeedConfig{Name: "X"}
	if err := applyFeedExtras(&fc, map[string]string{"X_FORMAT": "AbuseIPDB", "X_MIN_INTERVAL": "6h", "X_LIMIT": "10000", "X_CONFIDENCE_MINIMUM": "100"}); err != nil ||
		fc.Format != FeedFormatAbuseIPDB || fc.MinInterval != 6*time.Hour || fc.Limit != 10000 || fc.ConfidenceMinimum != 100 {
		t.Fatalf("valid extras: %+v %v", fc, err)
	}
}
