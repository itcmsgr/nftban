// =============================================================================
// NFTBan v1.148 - Restore disarm (A.6b, delta 2.1) unit test
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-restore-disarm-v148-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.148 restore A.6b disarm (mask daemon/socket/timers) unit test"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// A.6b extends the CSF-restore disarm: stopping nftband.service alone is
// insufficient because nftband.socket (Requires/After + Restart=on-failure)
// re-activates the daemon, which recreates ip/ip6 nftban tables. A.6b must also
// stop AND disable nftband.socket and the table-touching timers. This proves
// the code path; the runtime reboot-survival effect is an integration test.
// =============================================================================

package main

import (
	"context"
	"testing"
)

func TestCSFRestore_A6b_DisarmsSocketAndTableTimers_v148(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		nftbandActive:      true,
	})
	// Arm the re-activation vectors as active+enabled (default fixture leaves
	// them off, which is why the existing "exactly 1 stop" A.6 test still holds).
	mock.ServicesEnabled[nftbandUnit] = true // service enabled (boot vector #1)
	mock.Services[nftbandSocketUnit] = true
	mock.ServicesEnabled[nftbandSocketUnit] = true
	for _, tmr := range nftbanTableTouchingTimers {
		mock.Services[tmr] = true
		mock.ServicesEnabled[tmr] = true
	}

	// A.6b executes before the A.7 safety-net gate, so the disarm lands even if
	// A.7 subsequently refuses; ignore the overall result.
	_ = mutateToCSFTarget(context.Background(), dep)

	// Every daemon/timer activation unit must be MASKED — disable is insufficient
	// (nftband.service is RequiredBy the exporter + TriggeredBy the socket; the
	// maintenance timer is Always-Active self-healed). mask blocks all start paths.
	// SELECT_V148_RESTORE_MASK_DAEMON_UNITS + ..._MASK_TABLE_TIMERS = yes.
	maskExpected := append([]string{nftbandUnit, nftbandSocketUnit}, nftbanTableTouchingTimers...)
	for _, u := range maskExpected {
		if !mock.CommandCalled("systemctl", "mask", u) {
			t.Errorf("A.6b did not MASK %s (disable does not hold — dependency-pull / self-heal)", u)
		}
	}
	// The socket + timers (armed in this fixture) must also be stopped first.
	for _, u := range append([]string{nftbandSocketUnit}, nftbanTableTouchingTimers...) {
		if mock.Services[u] {
			t.Errorf("A.6b did not stop %s before masking", u)
		}
	}
}
