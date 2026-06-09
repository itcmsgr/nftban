// =============================================================================
// NFTBan v1.168 - CLI-BUG-2 whitelist TTL: remainingTimeout invariant guard
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="whitelist_timeout_v168_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-09"
// meta:description="v1.168 CLI-BUG-2 PRIMARY release-blocking acceptance (logic level): a timed whitelist entry's kernel timeout is anchored to its absolute expiry and is RECOMPUTED (refreshed, shrinking) on every sync — it must SURVIVE a FullSync re-run and never be clobbered to permanent; permanent (durable/trust) entries must stay permanent. Kernel-level end-to-end proof is the lab/real-host rebuild-survival gate."
// meta:input="None"
// meta:output="t.Fatal on TTL-survival invariant break"
// meta:depends="testing,time"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package setsync

import (
	"testing"
	"time"
)

// TestRemainingTimeout_PermanentWhenNoExpiry asserts durable/trust entries
// (no expiry recorded) resolve to permanent — timed=false, so the sync adds
// them via the plain batch path with no kernel timeout.
func TestRemainingTimeout_PermanentWhenNoExpiry(t *testing.T) {
	now := time.Date(2026, 6, 9, 12, 0, 0, 0, time.UTC)

	// nil map → permanent
	if d, timed := remainingTimeout(nil, "1.2.3.4", now); timed || d != 0 {
		t.Fatalf("nil expiry: got (%v, %v), want (0, false)", d, timed)
	}
	// ip absent from map → permanent
	expiry := map[string]time.Time{"9.9.9.9": now.Add(time.Hour)}
	if d, timed := remainingTimeout(expiry, "1.2.3.4", now); timed || d != 0 {
		t.Fatalf("absent ip: got (%v, %v), want (0, false)", d, timed)
	}
	// zero-time value → permanent (defensive: should not be inserted, but guard it)
	expiry["1.2.3.4"] = time.Time{}
	if d, timed := remainingTimeout(expiry, "1.2.3.4", now); timed || d != 0 {
		t.Fatalf("zero expiry: got (%v, %v), want (0, false)", d, timed)
	}
}

// TestRemainingTimeout_TimedFuture asserts a future expiry yields a positive
// remaining duration and timed=true (the element gets a kernel timeout).
func TestRemainingTimeout_TimedFuture(t *testing.T) {
	now := time.Date(2026, 6, 9, 12, 0, 0, 0, time.UTC)
	exp := now.Add(2 * time.Hour)
	expiry := map[string]time.Time{"1.2.3.4": exp}

	d, timed := remainingTimeout(expiry, "1.2.3.4", now)
	if !timed {
		t.Fatalf("future expiry: timed=false, want true")
	}
	if d != 2*time.Hour {
		t.Fatalf("future expiry: remaining=%v, want 2h", d)
	}
}

// TestRemainingTimeout_TTLSurvivesFullSync is the PRIMARY release-blocking
// invariant for CLI-BUG-2 (v1.168): the kernel timeout is anchored to the
// ABSOLUTE expiry instant, so re-running the sync at a later wall-clock time
// RECOMPUTES a smaller-but-still-positive remaining TTL. The entry must stay
// timed across every sync — it must NEVER resolve to permanent (the bug) and
// the remaining must shrink toward zero (refresh, not clobber).
func TestRemainingTimeout_TTLSurvivesFullSync(t *testing.T) {
	base := time.Date(2026, 6, 9, 12, 0, 0, 0, time.UTC)
	exp := base.Add(time.Hour) // absolute expiry, fixed in the durable conf
	expiry := map[string]time.Time{"1.2.3.4": exp}

	// Sync #1 (fresh add): full hour remaining.
	d1, timed1 := remainingTimeout(expiry, "1.2.3.4", base)
	if !timed1 {
		t.Fatalf("sync#1: timed=false — entry would be added PERMANENT (CLI-BUG-2 regression)")
	}
	if d1 != time.Hour {
		t.Fatalf("sync#1: remaining=%v, want 1h", d1)
	}

	// Sync #2, 20 min later (e.g. a firewall reload/rebuild re-adds the element).
	now2 := base.Add(20 * time.Minute)
	d2, timed2 := remainingTimeout(expiry, "1.2.3.4", now2)
	if !timed2 {
		t.Fatalf("sync#2: timed=false — TTL did NOT survive FullSync (clobbered to permanent)")
	}
	if d2 <= 0 {
		t.Fatalf("sync#2: remaining=%v, want > 0 (still active)", d2)
	}
	if d2 != 40*time.Minute {
		t.Fatalf("sync#2: remaining=%v, want 40m (refreshed from absolute expiry)", d2)
	}
	if d2 >= d1 {
		t.Fatalf("sync#2: remaining did not shrink (%v >= %v) — not anchored to absolute expiry", d2, d1)
	}

	// Sync #3, 59 min in: still a sliver of TTL, still timed (never permanent).
	now3 := base.Add(59 * time.Minute)
	d3, timed3 := remainingTimeout(expiry, "1.2.3.4", now3)
	if !timed3 || d3 != time.Minute {
		t.Fatalf("sync#3: got (%v, %v), want (1m, true)", d3, timed3)
	}
}

// TestRemainingTimeout_PastIsTimedNonPositive asserts an entry whose expiry has
// already passed (the load→sync race window) returns timed=true with a
// non-positive duration — the sync caller skips it rather than re-adding it
// permanent. It must NOT be misclassified as permanent.
func TestRemainingTimeout_PastIsTimedNonPositive(t *testing.T) {
	now := time.Date(2026, 6, 9, 12, 0, 0, 0, time.UTC)
	exp := now.Add(-time.Minute) // already past
	expiry := map[string]time.Time{"1.2.3.4": exp}

	d, timed := remainingTimeout(expiry, "1.2.3.4", now)
	if !timed {
		t.Fatalf("past expiry: timed=false — would be re-added PERMANENT, want timed=true skip-path")
	}
	if d > 0 {
		t.Fatalf("past expiry: remaining=%v, want <= 0", d)
	}
}
