// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 D5-1 opt-in per-feed expiry (temp dirs only; feed entries are documentation ranges).

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func expirySandbox(t *testing.T, conf string, local string) (cfgDir, dataDir string) {
	t.Helper()
	root := t.TempDir()
	cfgDir, dataDir = filepath.Join(root, "etc"), filepath.Join(root, "data")
	for _, d := range []string{filepath.Join(cfgDir, "conf.d"), filepath.Join(dataDir, "feeds"), filepath.Join(dataDir, "state")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "conf.d", "feeds.conf"), []byte(conf), 0o644); err != nil {
		t.Fatal(err)
	}
	if local != "" {
		if err := os.WriteFile(filepath.Join(cfgDir, "nftban.conf.local"), []byte(local), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"abuseipdb", "spamhaus_drop"} {
		if err := os.WriteFile(filepath.Join(dataDir, "feeds", f+".txt"), []byte("192.0.2.1\n"), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	return cfgDir, dataDir
}

func age(t *testing.T, dataDir, feed string, d time.Duration, now time.Time) {
	t.Helper()
	ts := now.Add(-d)
	if err := os.Chtimes(filepath.Join(dataDir, "feeds", feed+".txt"), ts, ts); err != nil {
		t.Fatal(err)
	}
}

const twoFeeds = `FEED_ABUSEIPDB_ENABLED="true"
FEED_ABUSEIPDB_MAX_AGE="72h"   # opt-in expiry
FEED_SPAMHAUS_DROP_ENABLED="true"
`

func TestExpiryOptInPerFeed(t *testing.T) {
	now := time.Now()
	cfg, data := expirySandbox(t, twoFeeds, "")
	age(t, data, "abuseipdb", 71*time.Hour, now)
	age(t, data, "spamhaus_drop", 30*24*time.Hour, now) // old, but no MAX_AGE: unchanged behaviour
	d := evaluateAt(cfg, data, true, "", []string{"abuseipdb", "spamhaus_drop"}, now)
	if strings.Join(d.Enforced, ",") != "abuseipdb,spamhaus_drop" || len(d.Expired) != 0 {
		t.Fatalf("fresh: enforced=%v expired=%v", d.Enforced, d.Expired)
	}
	age(t, data, "abuseipdb", 73*time.Hour, now)
	d = evaluateAt(cfg, data, true, "", []string{"abuseipdb", "spamhaus_drop"}, now)
	if strings.Join(d.Enforced, ",") != "spamhaus_drop" || strings.Join(d.Expired, ",") != "abuseipdb" {
		t.Fatalf("expired: enforced=%v expired=%v", d.Enforced, d.Expired)
	}
	if !strings.Contains(strings.Join(d.Texts, "|"), "feed abuseipdb expired") || !strings.Contains(strings.Join(d.Reasons, ","), ReasonFeedExpired) {
		t.Fatalf("expiry not reported: %v %v", d.Reasons, d.Texts)
	}
	if _, err := os.Stat(filepath.Join(data, "feeds", "abuseipdb.txt")); err != nil {
		t.Fatal("expired snapshot must stay on disk")
	}
}

func TestExpiryAgeNotResetByPermissionRepair(t *testing.T) {
	now := time.Now()
	cfg, data := expirySandbox(t, twoFeeds, "")
	age(t, data, "abuseipdb", 100*time.Hour, now)
	f := filepath.Join(data, "feeds", "abuseipdb.txt")
	// a permission repair: chmod/chown change ctime, never mtime
	if err := os.Chmod(f, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(f, 0o640); err != nil {
		t.Fatal(err)
	}
	_ = os.Chown(f, os.Getuid(), os.Getgid())
	d := evaluateAt(cfg, data, true, "", []string{"abuseipdb", "spamhaus_drop"}, now)
	if strings.Join(d.Expired, ",") != "abuseipdb" {
		t.Fatalf("a permission repair must not refresh the age: expired=%v", d.Expired)
	}
}

func TestExpiryOnlyForEnforcedFeeds(t *testing.T) {
	now := time.Now()
	cfg, data := expirySandbox(t, `FEED_ABUSEIPDB_ENABLED="false"
FEED_ABUSEIPDB_MAX_AGE="1h"
`, "")
	age(t, data, "abuseipdb", 10*time.Hour, now)
	d := evaluateAt(cfg, data, true, "", []string{"abuseipdb"}, now)
	if len(d.Expired) != 0 || len(d.Enforced) != 0 || strings.Join(d.NotEnabled, ",") != "abuseipdb" {
		t.Fatalf("a disabled feed stays not-enabled (not expired): %+v", d)
	}
}

func TestExpiryLocalOverrideAndInvalid(t *testing.T) {
	now := time.Now()
	// central override sets a shorter age (last wins), and an invalid value elsewhere
	cfg, data := expirySandbox(t, twoFeeds+`FEED_SPAMHAUS_DROP_MAX_AGE="soon"
`, `FEED_ABUSEIPDB_MAX_AGE="2h"
`)
	age(t, data, "abuseipdb", 3*time.Hour, now)
	age(t, data, "spamhaus_drop", 1000*time.Hour, now)
	d := evaluateAt(cfg, data, true, "", []string{"abuseipdb", "spamhaus_drop"}, now)
	if strings.Join(d.Expired, ",") != "abuseipdb" || strings.Join(d.Enforced, ",") != "spamhaus_drop" {
		t.Fatalf("override/invalid: enforced=%v expired=%v", d.Enforced, d.Expired)
	}
	if !strings.Contains(strings.Join(d.Reasons, ","), ReasonFeedMaxAgeInvalid) {
		t.Fatalf("invalid MAX_AGE must be reported: %v", d.Reasons)
	}
	for _, zero := range []string{`""`, `"0"`} {
		cfg, data := expirySandbox(t, `FEED_ABUSEIPDB_ENABLED="true"
FEED_ABUSEIPDB_MAX_AGE=`+zero+"\n", "")
		age(t, data, "abuseipdb", 1000*time.Hour, now)
		if d := evaluateAt(cfg, data, true, "", []string{"abuseipdb"}, now); len(d.Expired) != 0 {
			t.Fatalf("MAX_AGE=%s means no expiry: %v", zero, d.Expired)
		}
	}
}
