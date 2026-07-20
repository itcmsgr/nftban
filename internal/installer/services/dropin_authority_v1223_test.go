// SPDX-License-Identifier: MPL-2.0
// meta:name="dropin_authority_v1223_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: drop-in authority adverse cases on verifyLiveWithProfile — DropInLoaded derives from systemd DropInPaths (systemctl show), NEVER from disk presence. file-present-but-not-in-DropInPaths→FALLBACK_MATCH (NOT ACTIVE_MATCH); file-absent-but-in-DropInPaths→EFFECTIVE_VALUES_MISMATCH; only-admin-sibling→EXTERNAL_OVERRIDE_CONFLICT; file-present+omitted+mismatch→EXPECTED_DROPIN_NOT_LOADED. Plus ResolveHealthResourceVerdict ResolvedFrom precedence markers (current/live/persisted/unavailable)."
// meta:inventory.files="internal/installer/services/dropin_authority_v1223_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package services

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/safety"
)

// file exists + DropInPaths omits expected + effective != calc → EXPECTED_DROPIN_NOT_LOADED.
func TestDropinAuthority_FileOnDisk_NotLoaded_Mismatch(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)
	m.Files[healthresource.DropinFile] = healthresource.Render(p, verFixture) // ON DISK
	setShow(m, 192*miB, 256*miB, 64, "")                                      // effective undersized, NO drop-in loaded
	v := verifyLiveWithProfile(m, &state.StateFile{}, nolog(), verFixture, p)
	if v.EffectiveState != healthresource.StateExpectedNotLoaded {
		t.Fatalf("state=%s want EXPECTED_DROPIN_NOT_LOADED", v.EffectiveState)
	}
	if v.DropInLoaded {
		t.Error("DropInLoaded must be FALSE (derived from DropInPaths, which omits our path) despite the file on disk")
	}
	if v.Acceptable() {
		t.Error("EXPECTED_DROPIN_NOT_LOADED must NOT be acceptable")
	}
}

// file ABSENT + DropInPaths INCLUDES expected + effective != calc → EFFECTIVE_VALUES_MISMATCH.
// Proves DropInLoaded is derived from systemctl-show DropInPaths, not disk presence.
func TestDropinAuthority_FileAbsent_LoadedFromShow_Mismatch(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)
	// NO m.Files[DropinFile] → absent on disk.
	setShow(m, 300*miB, 500*miB, 64, healthresource.DropinFile) // loaded per systemd, effective != calc
	v := verifyLiveWithProfile(m, &state.StateFile{}, nolog(), verFixture, p)
	if !v.DropInLoaded {
		t.Fatal("DropInLoaded must be TRUE — derived from DropInPaths (systemctl show), even though the file is ABSENT on disk")
	}
	if v.EffectiveState != healthresource.StateEffectiveMismatch {
		t.Fatalf("state=%s want EFFECTIVE_VALUES_MISMATCH", v.EffectiveState)
	}
	if v.Acceptable() {
		t.Error("EFFECTIVE_VALUES_MISMATCH must NOT be acceptable")
	}
}

// only an admin sibling drop-in loaded (effective != calc) → EXTERNAL_OVERRIDE_CONFLICT.
func TestDropinAuthority_AdminSiblingOnly_ExternalConflict(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)
	admin := "/etc/systemd/system/nftban-health.service.d/99-admin.conf"
	setShow(m, 300*miB, 700*miB, 64, admin) // only the admin drop-in loaded
	v := verifyLiveWithProfile(m, &state.StateFile{}, nolog(), verFixture, p)
	if v.EffectiveState != healthresource.StateExternalConflict {
		t.Fatalf("state=%s want EXTERNAL_OVERRIDE_CONFLICT", v.EffectiveState)
	}
	if !strings.Contains(v.ValidationError, admin) {
		t.Errorf("conflict must name the external drop-in; error=%q", v.ValidationError)
	}
	if v.Acceptable() {
		t.Error("EXTERNAL_OVERRIDE_CONFLICT must NOT be acceptable")
	}
}

// file exists + effective values MATCH via the MAIN unit but our drop-in NOT in
// DropInPaths → FALLBACK_MATCH (NOT ACTIVE_MATCH). Proves DropInLoaded is FALSE
// (from DropInPaths) even though the file IS present on disk; medium is NOT protected.
func TestDropinAuthority_MatchButNotLoaded_FallbackNotActive(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)                                                     // medium (protection-required)
	m.Files[healthresource.DropinFile] = healthresource.Render(p, verFixture) // ON DISK
	setShow(m, p.MemoryHigh, p.MemoryMax, 64, "")                             // effective == calc, but no drop-in loaded
	v := verifyLiveWithProfile(m, &state.StateFile{}, nolog(), verFixture, p)
	if v.EffectiveState != healthresource.StateFallbackMatch {
		t.Fatalf("state=%s want FALLBACK_MATCH (NOT ACTIVE_MATCH — drop-in not in DropInPaths)", v.EffectiveState)
	}
	if v.DropInLoaded {
		t.Error("DropInLoaded must be FALSE (DropInPaths omits our path) even though the file is on disk")
	}
	if v.Acceptable() {
		t.Error("medium FALLBACK_MATCH must NOT be acceptable (protection required, drop-in not effective)")
	}
}

// ResolveHealthResourceVerdict ResolvedFrom precedence markers.
func TestResolvedFromMarkers(t *testing.T) {
	p := profFor(6 << 30)

	// current: a non-zero reconciliation verdict is reused → "current", no live probe.
	t.Run("current", func(t *testing.T) {
		m := executor.NewMockExecutor()
		cur := healthresource.Verdict{Profile: p, EffectiveState: healthresource.StateActiveMatch, CalculatedMax: p.MemoryMax}
		got := resolveWithProfile(m, &state.StateFile{}, nolog(), cur, verFixture, p)
		if got.ResolvedFrom != "current" {
			t.Fatalf("ResolvedFrom=%q want current", got.ResolvedFrom)
		}
	})
	// live: zero current + a valid systemctl show → "live".
	t.Run("live", func(t *testing.T) {
		m := executor.NewMockExecutor()
		setShow(m, p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile)
		m.Files[healthresource.DropinFile] = healthresource.Render(p, verFixture)
		got := resolveWithProfile(m, &state.StateFile{}, nolog(), healthresource.Verdict{}, verFixture, p)
		if got.ResolvedFrom != "live" {
			t.Fatalf("ResolvedFrom=%q want live", got.ResolvedFrom)
		}
	})
	// persisted: live unreadable + persisted evidence → "persisted".
	t.Run("persisted", func(t *testing.T) {
		m := executor.NewMockExecutor()
		m.RunResults[healthShowKey()] = executor.Result{ExitCode: 1, Stderr: "boom"}
		sf := &state.StateFile{
			HealthResourceState:   string(healthresource.StateActiveMatch),
			HealthResourceProfile: string(safety.ResourceTierMedium),
			HealthMemMaxEffective: 402653184,
		}
		got := resolveWithProfile(m, sf, nolog(), healthresource.Verdict{}, verFixture, p)
		if got.ResolvedFrom != "persisted" {
			t.Fatalf("ResolvedFrom=%q want persisted", got.ResolvedFrom)
		}
	})
	// unavailable: live unreadable + NO persisted → "unavailable" (never a silent zero).
	t.Run("unavailable", func(t *testing.T) {
		m := executor.NewMockExecutor()
		m.RunResults[healthShowKey()] = executor.Result{ExitCode: 1, Stderr: "boom"}
		got := resolveWithProfile(m, &state.StateFile{}, nolog(), healthresource.Verdict{}, verFixture, p)
		if got.ResolvedFrom != "unavailable" {
			t.Fatalf("ResolvedFrom=%q want unavailable", got.ResolvedFrom)
		}
		if got.IsZero() {
			t.Error("unavailable verdict must be MARKED, not a silent zero")
		}
	})
}
