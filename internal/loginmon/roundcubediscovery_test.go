// =============================================================================
// NFTBan v1.186.0 - Roundcube discovery tests (DA-only hard-stops #9/#10)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loginmon_roundcubediscovery_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-14"
// meta:description="Pins v1.186 hard stops: DA-only discovery (returns nil unless directadmin detected) and NO cPanel/Plesk path globbed (no coverage claim)."
// meta:inventory.files="roundcubediscovery_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package loginmon

import (
	"strings"
	"testing"
)

// HARD STOP #9/#10: discovery must be DirectAdmin-only — nil unless DA detected,
// so the source is never even attempted on cPanel/Plesk hosts.
func TestRoundcubeDiscovery_DAOnly(t *testing.T) {
	m := &Module{detectedServices: map[string]bool{}}
	if got := m.discoverRoundcubeLogs(); got != nil {
		t.Errorf("non-DA host: discoverRoundcubeLogs = %v, want nil (DA-only claim)", got)
	}
	if m.roundcubeDetected() {
		t.Error("non-DA host: roundcubeDetected = true, want false")
	}
	// cPanel + Plesk detected but NOT DirectAdmin → still nil (not claimed).
	m2 := &Module{detectedServices: map[string]bool{"cpanel": true, "plesk": true}}
	if got := m2.discoverRoundcubeLogs(); got != nil {
		t.Errorf("cPanel/Plesk host: discoverRoundcubeLogs = %v, want nil (deferred, not claimed)", got)
	}
}

// HARD STOP #10: the DA glob set must NOT include any cPanel or Plesk path.
func TestRoundcubeGlobs_NoCPanelNoPlesk(t *testing.T) {
	m := &Module{detectedServices: map[string]bool{"directadmin": true}}
	for _, g := range m.roundcubeLogGlobs() {
		if strings.Contains(g, "cpanel") || strings.Contains(g, "domlogs") ||
			strings.Contains(g, "plesk-roundcube") || strings.Contains(g, "vhosts") ||
			strings.Contains(g, "$HOME") || strings.Contains(g, "/home/") {
			t.Errorf("glob %q references a cPanel/Plesk/per-user path — v1.186 is DA-only", g)
		}
	}
}
