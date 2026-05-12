// =============================================================================
// NFTBan v1.0 - BotGuard Module Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="guard_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-12"
// meta:description="Unit tests for BotGuard typed Status.Extra (V110 R-12)"
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

package botguard

import (
	"reflect"
	"testing"

	"github.com/itcmsgr/nftban/internal/module"
)

// TestBotGuardStatusExtra_ToExtraInfo asserts the typed-status struct
// marshals to the byte-exact module.ExtraInfo map[string]any contract,
// covering all 16 keys. Backstops the V110 R-12 invariant that
// Module.Status() API and JSON wire keys remain unchanged.
func TestBotGuardStatusExtra_ToExtraInfo(t *testing.T) {
	extra := BotGuardStatusExtra{
		LoopInterval:          "30s",
		PressureMode:          false,
		TrackedIPs:            128,
		TotalTicks:            1000,
		SuspectsFound:         42,
		Classified:            40,
		AllowCount:            30,
		GreyCount:             5,
		BanCount:              5,
		EmergencyCount:        0,
		LastTickDuration:      "120ms",
		VerifyEnqueued:        12,
		VerifyCompleted:       10,
		VerifyVerified:        8,
		VerifyFailed:          2,
		BatchSignalsProcessed: 250,
	}
	want := module.ExtraInfo{
		"loop_interval":           "30s",
		"pressure_mode":           false,
		"tracked_ips":             int64(128),
		"total_ticks":             int64(1000),
		"suspects_found":          int64(42),
		"classified":              int64(40),
		"allow_count":             int64(30),
		"grey_count":              int64(5),
		"ban_count":               int64(5),
		"emergency_count":         int64(0),
		"last_tick_duration":      "120ms",
		"verify_enqueued":         int64(12),
		"verify_completed":        int64(10),
		"verify_verified":         int64(8),
		"verify_failed":           int64(2),
		"batch_signals_processed": int64(250),
	}
	got := extra.ToExtraInfo()
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ToExtraInfo() = %v, want %v", got, want)
	}
	if len(got) != 16 {
		t.Errorf("ToExtraInfo() key count = %d, want 16", len(got))
	}
}
