// =============================================================================
// NFTBan v1.0 - DDoS Module Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-12"
// meta:description="Unit tests for DDoS module typed Status.Extra (V110 R-12)"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing,reflect"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ddos

import (
	"reflect"
	"testing"

	"github.com/itcmsgr/nftban/internal/module"
)

// TestDDoSStatusExtra_ToExtraInfo asserts the typed-status struct marshals
// to the byte-exact module.ExtraInfo map[string]any contract. Backstops
// the V110 R-12 invariant that Module.Status() API and JSON wire keys
// remain unchanged after the typed-struct refactor.
func TestDDoSStatusExtra_ToExtraInfo(t *testing.T) {
	extra := DDoSStatusExtra{
		Mode:              "hybrid",
		SuricataAvailable: false,
	}
	want := module.ExtraInfo{
		"mode":               "hybrid",
		"suricata_available": false,
	}
	got := extra.ToExtraInfo()
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ToExtraInfo() = %v, want %v", got, want)
	}
	if len(got) != 2 {
		t.Errorf("ToExtraInfo() key count = %d, want 2", len(got))
	}
}
