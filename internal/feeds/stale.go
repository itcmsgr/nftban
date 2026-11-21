// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 part B3 (owner 2026-11-21): ONE per-feed stale policy for `nftban feeds status` and the
// nftban_feed_stale gauge. A fixed 48h gauge must not contradict a feed's configured interval.
//
// Stale = the snapshot is older than twice the feed's expected refresh interval: the daily feeds
// timer, or FEED_<NAME>_MIN_INTERVAL when that is longer. Stale is a warning only; it never
// changes enforcement (expiry comes only from an explicit MAX_AGE).
//
// internal/metrics cannot import this package (this package imports metrics), so the policy is
// registered with metrics at init. Every binary that sets the gauge (nftband, nftban-core)
// imports this package.

import (
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/metrics"
)

// RefreshTimerInterval is the period of nftban-core-feeds.timer: every feed's expected interval
// unless its MIN_INTERVAL is longer.
const RefreshTimerInterval = 24 * time.Hour

// StaleAfter returns the stale threshold for a feed with the given minimum interval (0 = none).
func StaleAfter(minInterval time.Duration) time.Duration {
	iv := RefreshTimerInterval
	if minInterval > iv {
		iv = minInterval
	}
	return 2 * iv
}

// StaleThresholds reads FEED_<NAME>_MIN_INTERVAL in the same config order as the CLI
// (feeds.conf -> feeds.conf.local -> nftban.conf.local) and returns the per-feed threshold.
// An unset, zero or invalid MIN_INTERVAL counts as none (the CLI refuses an invalid one).
func StaleThresholds(configDir string) func(feed string) time.Duration {
	mins := make(map[string]time.Duration)
	for name, raw := range feedProperty(configDir, "MIN_INTERVAL") {
		if d, err := time.ParseDuration(raw); err == nil && d > 0 {
			mins[strings.ToUpper(name)] = d
		}
	}
	return func(feed string) time.Duration { return StaleAfter(mins[strings.ToUpper(feed)]) }
}

func init() { metrics.SetFeedStalePolicy(StaleThresholds) }
