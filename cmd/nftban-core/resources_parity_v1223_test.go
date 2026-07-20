// SPDX-License-Identifier: MPL-2.0
// meta:name="resources_parity_v1223_test.go"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: CLI/installer parity. For each (tier,state) prove the read-only CLI's resourcesExitCode + rep.Service.ProtectionActive agree with the SHARED healthresource.AcceptableFor predicate (INSTALLER_ACCEPTABLE == CLI_PROTECTION_ACTIVE), and that human vs JSON render the SAME semantic accept/reject result. Also the live-unreadable incomplete-evidence exit (exit 1) per resourcesExitCode."
// meta:inventory.files="cmd/nftban-core/resources_parity_v1223_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
)

func i64(v int64) string { return strconv.FormatInt(v, 10) }

// captureHuman renders printResourcesHuman to a string.
func captureHuman(t *testing.T, rep resourcesReport) string {
	t.Helper()
	orig := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	printResourcesHuman(rep)
	_ = w.Close()
	var buf bytes.Buffer
	_, _ = io.Copy(&buf, r)
	os.Stdout = orig
	return buf.String()
}

// TestResourcesTierStateParity is the (tier,state) → accept/exit truth table. Every
// readable row proves resourcesExitCode + ProtectionActive == AcceptableFor, and that
// the human "Protection active" line matches the JSON protection_active field.
func TestResourcesTierStateParity(t *testing.T) {
	const (
		smallHigh, smallMax   = int64(201326592), int64(268435456) // 192/256 MiB
		mediumHigh, mediumMax = int64(268435456), int64(402653184) // 256/384 MiB
		largeHigh, largeMax   = int64(402653184), int64(536870912) // 384/512 MiB
	)
	type row struct {
		name            string
		ram             int64
		effHigh, effMax int64
		dropins         string
		onDisk          bool
		wantState       healthresource.State
		wantExit        int
		wantAccept      bool
	}
	rows := []row{
		{"small/ACTIVE_MATCH", 2 << 30, smallHigh, smallMax, healthresource.DropinFile, true, healthresource.StateActiveMatch, 0, true},
		{"small/FALLBACK_MATCH", 2 << 30, smallHigh, smallMax, "", false, healthresource.StateFallbackMatch, 0, true},
		{"medium/ACTIVE_MATCH", 6 << 30, mediumHigh, mediumMax, healthresource.DropinFile, true, healthresource.StateActiveMatch, 0, true},
		{"medium/FALLBACK_MATCH", 6 << 30, mediumHigh, mediumMax, "", false, healthresource.StateFallbackMatch, 2, false},
		{"medium/FALLBACK_UNDERSIZED", 6 << 30, smallHigh, smallMax, "", false, healthresource.StateFallbackUnder, 2, false},
		{"large/ACTIVE_MATCH", 16 << 30, largeHigh, largeMax, healthresource.DropinFile, true, healthresource.StateActiveMatch, 0, true},
		{"large/FALLBACK_MATCH", 16 << 30, largeHigh, largeMax, "", false, healthresource.StateFallbackMatch, 2, false},
	}
	for _, r := range rows {
		t.Run(r.name, func(t *testing.T) {
			calc := calcFor(r.ram)
			rep := assembleReport(calc, nil, false, props(i64(r.effHigh), i64(r.effMax), "64", r.dropins), nil, r.onDisk)

			// 1. State classification.
			if rep.Service.State != string(r.wantState) {
				t.Fatalf("state=%s want %s", rep.Service.State, r.wantState)
			}
			// 2. CLI exit code.
			if got := resourcesExitCode(rep); got != r.wantExit {
				t.Errorf("resourcesExitCode=%d want %d", got, r.wantExit)
			}
			// 3. CLI ProtectionActive == the SHARED AcceptableFor predicate == expected.
			shared := healthresource.AcceptableFor(calc.Tier, r.wantState)
			if shared != r.wantAccept {
				t.Errorf("AcceptableFor(%s,%s)=%v want %v", calc.Tier, r.wantState, shared, r.wantAccept)
			}
			if rep.Service.ProtectionActive != shared {
				t.Errorf("CLI ProtectionActive=%v != shared AcceptableFor=%v (installer/CLI must agree)", rep.Service.ProtectionActive, shared)
			}

			// 4. human vs JSON give the same semantic accept/reject result.
			jb, err := json.Marshal(rep)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			var decoded struct {
				Service struct {
					ProtectionActive bool `json:"protection_active"`
				} `json:"services_health"`
			}
			if err := json.Unmarshal(jb, &decoded); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			human := captureHuman(t, rep)
			wantLine := "Protection active....... " + map[bool]string{true: "yes", false: "no"}[r.wantAccept]
			if !strings.Contains(human, wantLine) {
				t.Errorf("human output missing %q; semantic mismatch human vs verdict", wantLine)
			}
			if decoded.Service.ProtectionActive != r.wantAccept {
				t.Errorf("JSON protection_active=%v want %v", decoded.Service.ProtectionActive, r.wantAccept)
			}
			// human and JSON must agree with each other (same semantic result).
			humanYes := strings.Contains(human, "Protection active....... yes")
			if humanYes != decoded.Service.ProtectionActive {
				t.Errorf("human(yes=%v) and JSON(%v) disagree on the accept/reject verdict", humanYes, decoded.Service.ProtectionActive)
			}
		})
	}
}

// The live-unreadable path (systemctl show failed) is unverifiable. LOCKED v1.223.0
// policy: a protection-REQUIRED tier (medium/large) FAIL-CLOSES → exit 2 — the SAME
// stance as the installer's UNAVAILABLE→DEGRADED (CLI and installer agree). A
// non-required tier (small) is incomplete evidence → exit 1.
func TestResourcesLiveUnreadable_TierAware(t *testing.T) {
	medium := assembleReport(calcFor(6<<30), nil, false, nil, errors.New("systemctl show: unit not loaded"), false)
	if medium.Service.Effective.Available {
		t.Fatal("live read failed → Effective.Available must be false")
	}
	if got := resourcesExitCode(medium); got != 2 {
		t.Errorf("medium live-unreadable exit=%d want 2 (required-protection fail-closed)", got)
	}
	small := assembleReport(calcFor(2<<30), nil, false, nil, errors.New("systemctl show: unit not loaded"), false)
	if got := resourcesExitCode(small); got != 1 {
		t.Errorf("small live-unreadable exit=%d want 1 (incomplete evidence)", got)
	}
}
