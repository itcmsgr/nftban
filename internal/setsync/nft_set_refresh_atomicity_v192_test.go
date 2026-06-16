// =============================================================================
// NFTBan - v1.192 set-refresh atomicity test (F-FEED / F-GEO)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft_set_refresh_atomicity_v192_test"
// meta:type="test"
// meta:version="1.192.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Asserts shared-set refresh emits flush+add as ONE nft -f transaction (no fail-open empty window)"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// V-NFT-SET-REFRESH-ATOMICITY (hermetic): the blacklist refresh path must
// replace a set's contents via a SINGLE `nft -f` transaction whose FIRST
// statement is `flush set` and whose remaining statements are `add element`.
// That ordering is what guarantees the shared blacklist_* set is never observed
// empty/partial between transactions (the F-FEED / F-GEO fail-open window where
// banned IPs were admitted during the daily feed / weekly geoban refresh).
//
// These tests assert the rendered script directly — no nft / root / kernel.

package setsync

import (
	"strings"
	"testing"
)

func scriptLines(t *testing.T, s string) []string {
	t.Helper()
	out := make([]string, 0, 8)
	for _, ln := range strings.Split(s, "\n") {
		if strings.TrimSpace(ln) != "" {
			out = append(out, ln)
		}
	}
	return out
}

func TestSetRefresh_FlushIsFirstStatement(t *testing.T) {
	script := renderSetReplaceScript("ip", "nftban", "blacklist_ipv4",
		[]string{"10.0.0.0/8", "192.168.0.0/16", "203.0.113.0/24"})
	lines := scriptLines(t, script)
	if len(lines) == 0 {
		t.Fatal("empty script")
	}
	// The FIRST non-blank statement MUST be the flush.
	if !strings.HasPrefix(lines[0], "flush set ip nftban blacklist_ipv4") {
		t.Fatalf("first statement is not the flush set: %q", lines[0])
	}
	// Exactly ONE flush — never a second flush that could re-empty mid-script.
	if n := strings.Count(script, "flush set "); n != 1 {
		t.Fatalf("expected exactly 1 flush set, got %d", n)
	}
	// Every other statement is an add element (no standalone delete/flush after).
	for _, ln := range lines[1:] {
		if !strings.HasPrefix(ln, "add element ip nftban blacklist_ipv4") {
			t.Fatalf("non-add statement after flush: %q", ln)
		}
	}
}

func TestSetRefresh_FlushPrecedesEveryAdd(t *testing.T) {
	script := renderSetReplaceScript("ip6", "nftban", "blacklist_ipv6",
		[]string{"2001:db8::/32", "2001:db8:1::/48"})
	flushIdx := strings.Index(script, "flush set ")
	addIdx := strings.Index(script, "add element ")
	if flushIdx < 0 {
		t.Fatal("no flush set in script")
	}
	if addIdx < 0 {
		t.Fatal("no add element in script")
	}
	if flushIdx > addIdx {
		t.Fatalf("flush set (idx %d) must precede the first add element (idx %d) so flush+add commit as one transaction", flushIdx, addIdx)
	}
}

func TestSetRefresh_EmptyElementsFlushOnly(t *testing.T) {
	// An empty replacement legitimately empties the set, but still in ONE flush
	// transaction (no separate add) — never an orphaned standalone flush call.
	script := renderSetReplaceScript("ip", "nftban", "blacklist_ipv4", nil)
	lines := scriptLines(t, script)
	if len(lines) != 1 || !strings.HasPrefix(lines[0], "flush set ip nftban blacklist_ipv4") {
		t.Fatalf("empty replace should be a single flush statement, got: %v", lines)
	}
	if strings.Contains(script, "add element") {
		t.Fatalf("empty replace must not emit add element: %q", script)
	}
}

func TestSetRefresh_LargeSetBatchesAllAfterSingleFlush(t *testing.T) {
	// > batchSize elements: still exactly one flush, first, then N add batches.
	elems := make([]string, 0, 25000)
	for i := 0; i < 25000; i++ {
		// vary octets to keep distinct, valid-looking CIDR strings
		elems = append(elems, formatTestCIDR(i))
	}
	script := renderSetReplaceScript("ip", "nftban", "blacklist_ipv4", elems)
	if n := strings.Count(script, "flush set "); n != 1 {
		t.Fatalf("large set: expected exactly 1 flush, got %d", n)
	}
	// 25000 / 10000 = 3 add-element batches.
	if n := strings.Count(script, "add element "); n != 3 {
		t.Fatalf("large set: expected 3 add-element batches, got %d", n)
	}
	if !strings.HasPrefix(strings.TrimSpace(script), "flush set ") {
		t.Fatalf("large set: flush must be first")
	}
}

func formatTestCIDR(i int) string {
	a := (i / 65536) % 256
	b := (i / 256) % 256
	c := i % 256
	return strings.NewReplacer(
		"A", itoa(a), "B", itoa(b), "C", itoa(c),
	).Replace("A.B.C.0/24")
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}
