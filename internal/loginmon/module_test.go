// =============================================================================
// NFTBan v1.0 - LoginMon Module Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-12"
// meta:description="Unit tests for LoginMon typed Status.Extra (V110 R-12)"
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

package loginmon

import (
	"reflect"
	"testing"

	"github.com/itcmsgr/nftban/internal/module"
)

// TestLoginMonStatusExtra_ToExtraInfo asserts the typed-status struct
// marshals to the byte-exact module.ExtraInfo map[string]any contract,
// covering all 18 keys (including string, bool, int64, []string, and
// map[string]int64 value types). Backstops the V110 R-12 invariant that
// Module.Status() API and JSON wire keys remain unchanged.
func TestLoginMonStatusExtra_ToExtraInfo(t *testing.T) {
	extra := LoginMonStatusExtra{
		Mode:                "auto",
		SuricataAvailable:   true,
		Services:            "ssh,ftp",
		Detectors:           []string{"SSHDetector", "FTPDetector"},
		TotalDetections:     100,
		TotalBans:           20,
		TotalEscalations:    3,
		TotalPermanent:      1,
		UniqueIPs:           17,
		DetectionsIPv4:      90,
		DetectionsIPv6:      10,
		BansIPv4:            18,
		BansIPv6:            2,
		TrackedIPs:          5,
		DetectionsByService: map[string]int64{"ssh": 80, "ftp": 20},
		BansByService:       map[string]int64{"ssh": 18, "ftp": 2},
		DetectionsByReason:  map[string]int64{"bruteforce": 95, "scan": 5},
		BansByReason:        map[string]int64{"bruteforce": 19, "scan": 1},
	}
	want := module.ExtraInfo{
		"mode":                  "auto",
		"suricata_available":    true,
		"services":              "ssh,ftp",
		"detectors":             []string{"SSHDetector", "FTPDetector"},
		"total_detections":      int64(100),
		"total_bans":            int64(20),
		"total_escalations":     int64(3),
		"total_permanent":       int64(1),
		"unique_ips":            int64(17),
		"detections_ipv4":       int64(90),
		"detections_ipv6":       int64(10),
		"bans_ipv4":             int64(18),
		"bans_ipv6":             int64(2),
		"tracked_ips":           5,
		"detections_by_service": map[string]int64{"ssh": 80, "ftp": 20},
		"bans_by_service":       map[string]int64{"ssh": 18, "ftp": 2},
		"detections_by_reason":  map[string]int64{"bruteforce": 95, "scan": 5},
		"bans_by_reason":        map[string]int64{"bruteforce": 19, "scan": 1},
	}
	got := extra.ToExtraInfo()
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ToExtraInfo() = %v, want %v", got, want)
	}
	if len(got) != 18 {
		t.Errorf("ToExtraInfo() key count = %d, want 18", len(got))
	}
}

// TestLoginMonStatusExtra_SubnetFields_ZeroOmitted asserts the v1.113
// subnet-aggregation fields are omitted from ToExtraInfo() when zero, so
// hosts where the feature is disabled produce byte-identical Status.Extra
// payloads compared to v1.112 (preserves the wire-format invariant from
// the R-12 typed status struct introduction).
func TestLoginMonStatusExtra_SubnetFields_ZeroOmitted(t *testing.T) {
	extra := LoginMonStatusExtra{
		Mode:                "auto",
		SuricataAvailable:   true,
		Services:            "ssh,ftp",
		Detectors:           []string{"SSHDetector"},
		TotalDetections:     1,
		TotalBans:           1,
		TotalEscalations:    0,
		TotalPermanent:      0,
		UniqueIPs:           1,
		DetectionsIPv4:      1,
		DetectionsIPv6:      0,
		BansIPv4:            1,
		BansIPv6:            0,
		TrackedIPs:          1,
		DetectionsByService: map[string]int64{},
		BansByService:       map[string]int64{},
		DetectionsByReason:  map[string]int64{},
		BansByReason:        map[string]int64{},
		// SubnetPressureCount, SubnetBansTotal, SubnetWatchActive all zero (default).
	}
	got := extra.ToExtraInfo()
	if _, present := got["subnet_pressure_count"]; present {
		t.Errorf("zero SubnetPressureCount should be omitted; got key present")
	}
	if _, present := got["subnet_bans_total"]; present {
		t.Errorf("zero SubnetBansTotal should be omitted; got key present")
	}
	if _, present := got["subnet_watch_active"]; present {
		t.Errorf("zero SubnetWatchActive should be omitted; got key present")
	}
	if len(got) != 18 {
		t.Errorf("ToExtraInfo() with zero subnet fields key count = %d, want 18", len(got))
	}
}

// TestLoginMonStatusExtra_SubnetFields_NonZeroEmitted asserts that when the
// v1.113 subnet-aggregation fields hold non-zero values, ToExtraInfo()
// emits them under stable JSON keys for portal + status consumers.
func TestLoginMonStatusExtra_SubnetFields_NonZeroEmitted(t *testing.T) {
	extra := LoginMonStatusExtra{
		Mode:                "auto",
		SuricataAvailable:   true,
		Services:            "exim",
		Detectors:           []string{"MailDetector"},
		TotalDetections:     50,
		TotalBans:           5,
		TotalEscalations:    0,
		TotalPermanent:      0,
		UniqueIPs:           11,
		DetectionsIPv4:      50,
		DetectionsIPv6:      0,
		BansIPv4:            5,
		BansIPv6:            0,
		TrackedIPs:          11,
		DetectionsByService: map[string]int64{"exim": 50},
		BansByService:       map[string]int64{"exim": 5},
		DetectionsByReason:  map[string]int64{"exim_auth_fail": 50},
		BansByReason:        map[string]int64{"exim_auth_fail_subnet": 1, "exim_auth_fail": 4},
		// v1.113 subnet fields populated:
		SubnetPressureCount: 7,
		SubnetBansTotal:     1,
		SubnetWatchActive:   3,
	}
	got := extra.ToExtraInfo()
	if got["subnet_pressure_count"] != int64(7) {
		t.Errorf("subnet_pressure_count = %v, want 7", got["subnet_pressure_count"])
	}
	if got["subnet_bans_total"] != int64(1) {
		t.Errorf("subnet_bans_total = %v, want 1", got["subnet_bans_total"])
	}
	if got["subnet_watch_active"] != int64(3) {
		t.Errorf("subnet_watch_active = %v, want 3", got["subnet_watch_active"])
	}
	if len(got) != 21 {
		t.Errorf("ToExtraInfo() with all 3 subnet fields populated key count = %d, want 21", len(got))
	}
}
