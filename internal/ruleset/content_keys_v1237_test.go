// =============================================================================
// NFTBan v1.237 - ruleset Result.Keys (hermetic: temp config dirs, fake kernel)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ruleset_content_keys_v1237_test"
// meta:type="test"
// meta:description="v1.237: Render exposes the rendered keys per family/set, consistent with Counts; with an empty kernel reader only durable content is present (the validator's boot-content restoration check relies on this)."
// =============================================================================

package ruleset

import (
	"sort"
	"testing"
)

func TestRenderKeysMatchCountsAndDurableOnlyWithEmptyReader(t *testing.T) {
	opts := fixture(t)
	res, err := Render(opts, reader(nil), fakeExempt{})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Keys) != len(res.Counts) {
		t.Fatalf("Keys has %d sets, Counts %d", len(res.Keys), len(res.Counts))
	}
	for set, n := range res.Counts {
		if len(res.Keys[set]) != n {
			t.Errorf("%s: %d keys, count %d", set, len(res.Keys[set]), n)
		}
	}
	got := append([]string(nil), res.Keys["ip/blacklist_manual_ipv4"]...)
	sort.Strings(got)
	if len(got) != 2 || got[0] != "23.129.97.10" || got[1] != "23.129.97.11" {
		t.Fatalf("durable blacklist.d singles expected, got %v", got)
	}
	if res.Carried != 0 {
		t.Fatalf("empty reader must carry nothing, carried=%d", res.Carried)
	}
	// The durable union (blacklist.d CIDR + enabled feed) is in blacklist_ipv4.
	u := map[string]bool{}
	for _, k := range res.Keys["ip/blacklist_ipv4"] {
		u[k] = true
	}
	if !u["185.220.100.0/24"] || !u["45.155.205.0/24"] {
		t.Fatalf("blacklist_ipv4 keys missing the durable union: %v", res.Keys["ip/blacklist_ipv4"])
	}
}
