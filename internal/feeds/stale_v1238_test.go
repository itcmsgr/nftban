// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 part B3 (owner 2026-11-21): one per-feed stale policy for the CLI and the
// nftban_feed_stale gauge. Temp dirs only; feed entries are documentation ranges.

import (
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/metrics"
	"github.com/prometheus/client_golang/prometheus"
)

func staleGauge(t *testing.T, feed string) float64 {
	t.Helper()
	mfs, err := prometheus.DefaultGatherer.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() != "nftban_feed_stale" {
			continue
		}
		for _, m := range mf.GetMetric() {
			for _, l := range m.GetLabel() {
				if l.GetValue() == feed {
					return m.GetGauge().GetValue()
				}
			}
		}
	}
	t.Fatalf("no nftban_feed_stale sample for %s", feed)
	return -1
}

func TestStalePolicySharedByCLIAndGauge(t *testing.T) {
	if StaleAfter(0) != metrics.DefaultFeedStaleThreshold || StaleAfter(6*time.Hour) != 48*time.Hour {
		t.Fatalf("default: %s / %s", StaleAfter(0), StaleAfter(6*time.Hour))
	}
	if StaleAfter(36*time.Hour) != 72*time.Hour {
		t.Fatalf("a longer MIN_INTERVAL must lengthen the threshold: %s", StaleAfter(36*time.Hour))
	}
	// feeds.conf sets SLOW 36h; nftban.conf.local (last wins) sets SLOWER 60h; an invalid
	// value counts as none.
	cfg, _ := expirySandbox(t, `FEED_SLOW_ENABLED="true"
FEED_SLOW_MIN_INTERVAL="36h"
FEED_BAD_MIN_INTERVAL="soon"
FEED_SLOWER_MIN_INTERVAL="6h"
`, `FEED_SLOWER_MIN_INTERVAL="60h"
`)
	want := map[string]time.Duration{"slow": 72 * time.Hour, "slower": 120 * time.Hour, "bad": 48 * time.Hour, "spamhaus_drop": 48 * time.Hour}
	viaMetrics := metrics.FeedStaleThresholds(cfg) // the policy registered at init
	viaFeeds := StaleThresholds(cfg)
	for f, w := range want {
		if viaFeeds(f) != w || viaMetrics(f) != w {
			t.Fatalf("%s: feeds %s metrics %s want %s", f, viaFeeds(f), viaMetrics(f), w)
		}
	}
	// The gauge follows the configured threshold: 50h old is fresh for SLOW (72h), stale for a
	// default feed (48h). A fixed 48h gauge would call SLOW stale while the CLI says fresh.
	mtime := time.Now().Add(-50 * time.Hour)
	metrics.UpdateFeedStaleness("slow", mtime, viaMetrics("slow"))
	metrics.UpdateFeedStaleness("stalepolicy_default", mtime, viaMetrics("stalepolicy_default"))
	if staleGauge(t, "slow") != 0 || staleGauge(t, "stalepolicy_default") != 1 {
		t.Fatalf("gauge: slow=%v default=%v", staleGauge(t, "slow"), staleGauge(t, "stalepolicy_default"))
	}
}
