// SPDX-License-Identifier: MPL-2.0
// meta:name="nftbackend/classguard_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="v1.220.2 F3: exemptAddRejection rejects absolute+non-public classes on enforcement sets even with a nil (fail-open) exemption resolver, allows public routable IPs, and never blocks non-enforcement sets (whitelist can hold loopback/private). Pure decision, no netlink/root."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// v1.220.2 F3: the enforcement-set add rejection must reject absolute non-bannable
// classes (loopback/unspecified/multicast) and non-public classes on ENFORCEMENT sets
// EVEN when the membership exemption resolver is nil (fail-open exemption must never make
// an absolute-non-bannable class bannable). Non-enforcement sets (e.g. whitelist) are
// unaffected — loopback is legitimately whitelistable. Pure decision, no netlink/root.
package nftbackend

import "testing"

func TestExemptAddRejectionClassGuard(t *testing.T) {
	b := &Backend{} // exempt == nil → membership exemption unavailable (fail-open)

	// pick an actual enforcement set name
	var enfSet string
	for s := range enforcementSets {
		enfSet = s
		break
	}
	if enfSet == "" {
		t.Fatal("no enforcement set registered")
	}

	// absolute + non-public classes: rejected on the enforcement set despite nil exempt.
	for _, ip := range []string{"127.0.0.1", "::1", "0.0.0.0", "::", "224.0.0.1", "ff02::1",
		"10.0.0.5", "fc00::1", "169.254.1.2", "100.64.0.1", "192.0.2.1", "2001:db8::1"} {
		reject, reason := b.exemptAddRejection(enfSet, ip)
		if !reject {
			t.Errorf("exemptAddRejection(%s, %q)=false, want reject (nil exempt must still block non-bannable class)", enfSet, ip)
		}
		if reason == "" {
			t.Errorf("exemptAddRejection(%s, %q) rejected with empty reason", enfSet, ip)
		}
	}

	// public routable: NOT rejected by class (would then hit membership exemption, nil here).
	for _, ip := range []string{"8.8.4.4", "46.225.150.67", "2a01:4f8:c014:5ee1::1"} {
		if reject, _ := b.exemptAddRejection(enfSet, ip); reject {
			t.Errorf("exemptAddRejection(%s, %q)=true, want public address allowed", enfSet, ip)
		}
	}

	// NON-enforcement set: loopback/private are legitimately addable (whitelist etc).
	for _, ip := range []string{"127.0.0.1", "::1", "10.0.0.5"} {
		if reject, _ := b.exemptAddRejection("whitelist_ipv4", ip); reject {
			t.Errorf("exemptAddRejection(whitelist_ipv4, %q)=true, want allowed on non-enforcement set", ip)
		}
	}
}
