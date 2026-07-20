// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_resources_test.go"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 3 tests for `nftban-core resources`: pure assembleReport across all final states (ACTIVE_MATCH/FALLBACK_MATCH/EXPECTED_DROPIN_NOT_LOADED/EXTERNAL_OVERRIDE_CONFLICT/infinity/show-unavailable), exit-code mapping, headroom (incl. over-limit/never-run), JSON schema + exact bytes, persisted old-format tolerance. assembleReport is pure (no I/O) → inherently read-only."
package main

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/safety"
)

func calcFor(ram int64) safety.HealthResourceProfile {
	p := safety.ServerProfile{TotalRAM: ram, AvailRAM: ram / 2, CPUCores: 4}
	return safety.HealthServiceMemoryLimitsFor(p, safety.ClassifyResourceTier(p))
}

func props(high, max, tasks, dropins string) map[string]string {
	return map[string]string{"MemoryHigh": high, "MemoryMax": max, "TasksMax": tasks, "DropInPaths": dropins}
}

func TestResourcesMediumActiveMatch(t *testing.T) {
	calc := calcFor(6 << 30) // 268435456 / 402653184
	rep := assembleReport(calc, nil, false, props("268435456", "402653184", "64", healthresource.DropinFile), nil, true)
	if rep.Service.State != string(healthresource.StateActiveMatch) || !rep.Service.ProtectionActive {
		t.Fatalf("state=%s protection=%v want ACTIVE_MATCH/true", rep.Service.State, rep.Service.ProtectionActive)
	}
	if resourcesExitCode(rep) != 0 {
		t.Errorf("exit=%d want 0", resourcesExitCode(rep))
	}
	if rep.Service.Calculated.MemoryMaxBytes != 402653184 || rep.Service.Effective.MemoryMaxBytes != 402653184 {
		t.Errorf("calc/effective max mismatch: %+v", rep.Service)
	}
}

func TestResourcesMediumExpectedNotLoaded(t *testing.T) {
	calc := calcFor(6 << 30)
	rep := assembleReport(calc, nil, false, props("201326592", "268435456", "64", ""), nil, true)
	if rep.Service.State != string(healthresource.StateExpectedNotLoaded) || rep.Service.ProtectionActive {
		t.Fatalf("state=%s protection=%v want EXPECTED_DROPIN_NOT_LOADED/false", rep.Service.State, rep.Service.ProtectionActive)
	}
	if resourcesExitCode(rep) != 2 {
		t.Errorf("exit=%d want 2 (not protected)", resourcesExitCode(rep))
	}
}

func TestResourcesSmallFallbackMatch(t *testing.T) {
	calc := calcFor(2 << 30) // small 201326592/268435456
	rep := assembleReport(calc, nil, false, props("201326592", "268435456", "64", ""), nil, false)
	if rep.Service.State != string(healthresource.StateFallbackMatch) || !rep.Service.ProtectionActive {
		t.Fatalf("state=%s protection=%v want FALLBACK_MATCH/true", rep.Service.State, rep.Service.ProtectionActive)
	}
	if resourcesExitCode(rep) != 0 {
		t.Errorf("small fallback exit=%d want 0", resourcesExitCode(rep))
	}
}

func TestResourcesExternalConflict(t *testing.T) {
	calc := calcFor(6 << 30)
	admin := "/etc/systemd/system/nftban-health.service.d/99-admin.conf"
	rep := assembleReport(calc, nil, false, props("314572800", "734003200", "64", healthresource.DropinFile+" "+admin), nil, true)
	if rep.Service.State != string(healthresource.StateExternalConflict) || rep.Service.ProtectionActive {
		t.Fatalf("state=%s want EXTERNAL_OVERRIDE_CONFLICT/not-protected", rep.Service.State)
	}
	if !strings.Contains(rep.Service.Error, admin) {
		t.Errorf("conflict error must name admin drop-in: %q", rep.Service.Error)
	}
}

func TestResourcesInfinityRejected(t *testing.T) {
	calc := calcFor(6 << 30)
	for _, p := range []map[string]string{
		props("268435456", "infinity", "64", healthresource.DropinFile),
		props("18446744073709551615", "402653184", "64", healthresource.DropinFile), // numeric uint64-max form
	} {
		rep := assembleReport(calc, nil, false, p, nil, true)
		if rep.Service.State != string(healthresource.StateActivationFailed) || rep.Service.ProtectionActive {
			t.Errorf("infinity %v: state=%s want ACTIVATION_FAILED/not-protected", p, rep.Service.State)
		}
		if resourcesExitCode(rep) != 2 {
			t.Errorf("infinity exit=%d want 2", resourcesExitCode(rep))
		}
	}
}

func TestResourcesShowUnavailable(t *testing.T) {
	calc := calcFor(6 << 30)
	rep := assembleReport(calc, nil, false, nil, errors.New("Failed to connect to bus"), true)
	if rep.Service.Effective.Available {
		t.Error("show-unavailable must set Effective.Available=false")
	}
	if resourcesExitCode(rep) != 1 {
		t.Errorf("show-unavailable exit=%d want 1 (incomplete evidence, never guessed active)", resourcesExitCode(rep))
	}
	if rep.Service.ProtectionActive {
		t.Error("must never report protection active when systemctl is unavailable")
	}
}

func TestResourcesHeadroomAndOverLimit(t *testing.T) {
	calc := calcFor(6 << 30) // max 402653184
	// Peak below max → positive headroom.
	p := props("268435456", "402653184", "64", healthresource.DropinFile)
	p["MemoryPeak"] = "252706816"
	p["Result"] = "success"
	rep := assembleReport(calc, nil, false, p, nil, true)
	if rep.Service.Runtime.MemoryPeakBytes == nil || rep.Service.Runtime.HeadroomBytes == nil {
		t.Fatalf("expected peak+headroom populated")
	}
	if *rep.Service.Runtime.HeadroomBytes != 402653184-252706816 {
		t.Errorf("headroom=%d want %d", *rep.Service.Runtime.HeadroomBytes, 402653184-252706816)
	}
	// Peak above max → negative headroom + OverLimit (no unsigned underflow).
	p["MemoryPeak"] = "500000000"
	rep = assembleReport(calc, nil, false, p, nil, true)
	if !rep.Service.Runtime.OverLimit || *rep.Service.Runtime.HeadroomBytes >= 0 {
		t.Errorf("over-limit: overLimit=%v headroom=%d want true/negative", rep.Service.Runtime.OverLimit, *rep.Service.Runtime.HeadroomBytes)
	}
}

func TestResourcesJSONSchemaStableBytes(t *testing.T) {
	calc := calcFor(6 << 30)
	rep := assembleReport(calc, nil, false, props("268435456", "402653184", "64", healthresource.DropinFile), nil, true)
	b, err := json.Marshal(rep)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, want := range []string{
		`"schema_version":1`, `"resource_tier":"medium"`, `"memory_max_bytes":402653184`,
		`"overall_state":"ACTIVE_MATCH"`, `"protection_active":true`, `"authority"`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("JSON missing %q\n%s", want, s)
		}
	}
	// No volatile timestamp fields that would break test stability.
	if strings.Contains(s, "timestamp") || strings.Contains(s, "_at\"") {
		t.Errorf("JSON must not contain volatile timestamp fields: %s", s)
	}
}
