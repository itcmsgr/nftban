// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="exemption_split_limit_fixture_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Positive control of the P1S-A split-limit arm (internal/nftbackend/exemption_split_limit_v1235_test.go), kept next to the splitter when the resolver moved to internal/exemption (v1.236): the shared fixture (200 scattered IPv6 never-ban singletons inside one /64) really needs more than MaxSplitPerPrefix prefixes, so the Backend arm is not vacuous."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package exemption

import (
	"fmt"
	"net/netip"
	"testing"
)

func TestSplitLimit_FixtureExceedsTheLimit(t *testing.T) {
	const wide = "2606:4700:4700::/64"
	holes := make([]netip.Prefix, 0, 200)
	for i := 1; i <= 200; i++ {
		a := netip.MustParseAddr(fmt.Sprintf("2606:4700:4700:0:%x::1", i<<8))
		holes = append(holes, netip.PrefixFrom(a, a.BitLen()))
	}
	var out []netip.Prefix
	subtractPrefix(netip.MustParsePrefix(wide), holes, &out)
	if len(out) <= MaxSplitPerPrefix {
		t.Fatalf("INVALID_TEST: the split needs only %d prefixes (limit %d): the Backend omission arm would not be exercised", len(out), MaxSplitPerPrefix)
	}
}
