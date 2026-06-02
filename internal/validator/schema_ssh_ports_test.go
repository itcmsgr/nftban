// =============================================================================
// NFTBan v1.145 - PR-G ssh_ports required-set invariant (Go)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="schema_ssh_ports_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Locks ssh_ports as a REQUIRED managed set on both IPv4 and IPv6 so a missing ssh_ports is a schema/health failure, never a silent pass."
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package validator

import "testing"

// TestSSHPortsIsRequiredBothFamilies asserts the v1.145 invariant that
// ssh_ports is a REQUIRED managed nftban set on BOTH families. The set-driven
// SSH brute-force rule (`tcp dport @ssh_ports ct count`) cannot load without
// the set, so a host missing ssh_ports must be flagged by the validator /
// watchdog as a required-set failure — never treated as healthy. If a future
// change drops ssh_ports from the generated required-set inventory (e.g. an
// accidental schema regen), this test fails in CI.
func TestSSHPortsIsRequiredBothFamilies(t *testing.T) {
	contains := func(list []string, want string) bool {
		for _, s := range list {
			if s == want {
				return true
			}
		}
		return false
	}

	if !contains(GeneratedRequiredSetsIPv4, "ssh_ports") {
		t.Errorf("ssh_ports missing from GeneratedRequiredSetsIPv4 — a missing ssh_ports would not fail validation (lockout/rate-limit regression risk)")
	}
	if !contains(GeneratedRequiredSetsIPv6, "ssh_ports") {
		t.Errorf("ssh_ports missing from GeneratedRequiredSetsIPv6 — IPv6 SSH brute-force protection would not be required")
	}

	// ssh_ports must also be in the all-sets inventory for both families
	// (membership consistency: every required set is a known set).
	if !contains(GeneratedAllSetsIPv4, "ssh_ports") {
		t.Errorf("ssh_ports missing from GeneratedAllSetsIPv4")
	}
	if !contains(GeneratedAllSetsIPv6, "ssh_ports") {
		t.Errorf("ssh_ports missing from GeneratedAllSetsIPv6")
	}
}
