// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="nftbackend_exemption_backend_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="The Backend side of the never-ban fail-closed / fail-safe contract, kept with Backend when the resolver moved to internal/exemption (v1.236): a nil Backend and a Backend without a resolver admit no prefix, and a nil Backend subtracts nothing."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package nftbackend

import "testing"

// No backend or no resolver refuses: a /24 drop without the never-ban authority is never safe.
func TestAdmitPrefixFailsClosed_Backend(t *testing.T) {
	var nilB *Backend
	if ok, _ := nilB.AdmitPrefix("45.33.32.0/24"); ok {
		t.Fatal("nil backend admitted a prefix")
	}
	if ok, _ := (&Backend{}).AdmitPrefix("45.33.32.0/24"); ok {
		t.Fatal("backend without a resolver admitted a prefix")
	}
}

// A nil backend never withholds a feed element (a resolver failure must never block a load).
func TestSubtractExemptFailSafe_NilBackend(t *testing.T) {
	in := []string{"185.199.108.153/32", "198.100.44.0/24"}
	var nilB *Backend
	if kept, removed, _ := nilB.SubtractExempt(in); removed != 0 || len(kept) != len(in) {
		t.Errorf("FAIL-SAFE BROKEN: nil backend subtracted %d element(s)", removed)
	}
}
