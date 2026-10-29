// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package nftbackend

import (
	"context"
	"testing"
)

// F2: Backend.Ban admits a CIDR whole or refuses it whole (AdmitPrefix); single addresses
// keep the IsExempt answer. Refusals go through Ban (they return before any netlink work,
// so the test is hermetic, as the L3a tests). Admissions are asserted on the exact decision
// Ban consults, because an admitted ban proceeds to netlink, which needs root.
func TestBanPrefixAdmission_F2(t *testing.T) {
	b := &Backend{}
	b.exempt = snapshot([]string{"185.220.101.7"}, []string{"23.129.97.128/26"})

	refusedByBan := func(ip string) bool {
		t.Helper()
		res, _ := b.Ban(context.Background(), BanRequest{IP: ip, Timeout: 600, Source: "login"})
		return res != nil && res.Exempt
	}

	for _, c := range []struct {
		ip, why string
	}{
		{"185.220.101.0/24", "covers an exempt address"},
		{"23.129.97.0/24", "an exempt range inside it"},
		{"23.129.97.160/27", "inside an exempt range (.160-.191 within .128/26)"},
		{"185.220.101.7", "exempt single address (unchanged)"},
	} {
		if !refusedByBan(c.ip) {
			t.Errorf("%s (%s) was admitted into a drop set", c.ip, c.why)
		}
	}

	// Admissions: the gate's own decision (a clean prefix, a non-exempt address).
	if ok, why := b.exempt.AdmitPrefix("45.33.32.0/24"); !ok {
		t.Errorf("a clean /24 would be refused by the prefix gate (%s)", why)
	}
	if ok, _ := b.exempt.IsExempt("45.33.32.61"); ok {
		t.Error("a non-exempt single address would be refused")
	}

	// Incomplete protection data: CIDRs refused (fail closed); single addresses unaffected.
	b.exempt.sourceErr = "whitelist: unreadable"
	if !refusedByBan("45.33.32.0/24") {
		t.Error("a CIDR was admitted while protection data is incomplete")
	}
	if ok, _ := b.exempt.IsExempt("45.33.32.61"); ok {
		t.Error("the incomplete-data status changed a single-address decision")
	}
}
