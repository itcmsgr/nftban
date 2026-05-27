// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-timers-critical-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Unit test for v1.135 critical core timer classification"
// meta:inventory.files="internal/installer/services/timers_critical_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package services

import "testing"

func TestCriticalCoreTimers(t *testing.T) {
	got := CriticalCoreTimers()

	// must include the maintenance timer (scope §item-1)
	found := false
	for _, x := range got {
		if x == "nftban-maintenance.timer" {
			found = true
		}
	}
	if !found {
		t.Errorf("CriticalCoreTimers must include nftban-maintenance.timer, got %v", got)
	}

	// subset invariant: every critical timer is also a core timer
	core := map[string]bool{}
	for _, c := range coreTimers {
		core[c] = true
	}
	for _, x := range got {
		if !core[x] {
			t.Errorf("critical timer %q is not in coreTimers", x)
		}
	}

	// accessor returns a copy — mutating it must not affect the source
	if len(got) > 0 {
		got[0] = "mutated"
		if CriticalCoreTimers()[0] == "mutated" {
			t.Errorf("CriticalCoreTimers must return a defensive copy")
		}
	}
}
