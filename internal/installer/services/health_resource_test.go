// SPDX-License-Identifier: MPL-2.0
// meta:name="health_resource_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 2 installer-wiring tests (MockExecutor): fresh install per tier, no-churn, medium/large FALLBACK_UNDERSIZED, small FALLBACK_MATCH, effective mismatch, malformed/failed systemctl show → ACTIVATION_FAILED, daemon-reload-only-on-change, and HEALTH_RESOURCE_* state persistence. Injects the profile so tiers are deterministic; no real systemd/disk."
package services

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/safety"
)

const (
	miB        = int64(1) << 20
	verFixture = "1.222.1"
)

func healthShowKey() string {
	return strings.Join([]string{
		"systemctl", "show", healthUnit,
		"-p", "MemoryHigh", "-p", "MemoryMax", "-p", "TasksMax", "-p", "DropInPaths", "-p", "FragmentPath",
	}, ":")
}

func showOut(high, max, tasks int64, dropins string) string {
	return fmt.Sprintf("MemoryHigh=%d\nMemoryMax=%d\nTasksMax=%d\nDropInPaths=%s\nFragmentPath=/usr/lib/systemd/system/nftban-health.service\n",
		high, max, tasks, dropins)
}

func profFor(totalRAM int64) safety.HealthResourceProfile {
	p := safety.ServerProfile{TotalRAM: totalRAM, AvailRAM: totalRAM / 2, CPUCores: 4}
	return safety.HealthServiceMemoryLimitsFor(p, safety.ClassifyResourceTier(p))
}

func reloadCount(m *executor.MockExecutor) int {
	n := 0
	for _, c := range m.Commands {
		if c.Name == "systemctl" && len(c.Args) == 1 && c.Args[0] == "daemon-reload" {
			n++
		}
	}
	return n
}

// 2/3/4. Fresh install medium → writes drop-in, reload, effective==calc → ACTIVE_MATCH.
func TestReconcileFreshMediumActiveMatch(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30) // medium: 256/384 MiB
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile)}
	sf := &state.StateFile{}
	v := reconcileWithProfile(m, sf, logging.New("/dev/null", false), verFixture, p)

	if v.Profile.Tier != safety.ResourceTierMedium {
		t.Fatalf("tier=%s want medium", v.Profile.Tier)
	}
	if !v.Changed || !v.DaemonReloaded {
		t.Errorf("fresh install: Changed=%v DaemonReloaded=%v want true/true", v.Changed, v.DaemonReloaded)
	}
	if _, ok := m.WrittenFiles[healthresource.DropinFile]; !ok {
		t.Error("drop-in not written")
	}
	if reloadCount(m) != 1 {
		t.Errorf("daemon-reload count=%d want 1", reloadCount(m))
	}
	if v.EffectiveState != healthresource.StateActiveMatch || !v.ProtectionActive || !v.Acceptable() {
		t.Errorf("state=%s protection=%v acceptable=%v want ACTIVE_MATCH/true/true", v.EffectiveState, v.ProtectionActive, v.Acceptable())
	}
	// State persisted.
	if sf.HealthResourceState != string(healthresource.StateActiveMatch) ||
		sf.HealthMemMaxCalculated != p.MemoryMax || sf.HealthMemMaxEffective != p.MemoryMax ||
		!sf.HealthResourceProtection || sf.HealthResourceError != "" {
		t.Errorf("state not persisted correctly: %+v", sf)
	}
}

// 14/19. No-churn: identical existing bytes → no write, no reload, ACTIVE_MATCH.
func TestReconcileNoChurn(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)
	m.Files[healthresource.DropinFile] = healthresource.Render(p, verFixture) // pre-seed identical
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile)}
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
	if v.Changed || v.DaemonReloaded {
		t.Errorf("no-churn: Changed=%v DaemonReloaded=%v want false/false", v.Changed, v.DaemonReloaded)
	}
	if len(m.WrittenFiles) != 0 {
		t.Errorf("no-churn wrote %d files, want 0", len(m.WrittenFiles))
	}
	if reloadCount(m) != 0 {
		t.Errorf("no-churn daemon-reload=%d want 0", reloadCount(m))
	}
	if v.EffectiveState != healthresource.StateActiveMatch {
		t.Errorf("no-churn state=%s want ACTIVE_MATCH", v.EffectiveState)
	}
}

// 17/14. Medium: reconciler wrote the drop-in but systemd shows the packaged
// fallback with our drop-in NOT loaded → EXPECTED_DROPIN_NOT_LOADED (precise
// activation diagnosis), not protected, not acceptable → medium DEGRADES.
func TestReconcileMediumDropinNotLoaded(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(192*miB, 256*miB, 64, "")}
	sf := &state.StateFile{}
	v := reconcileWithProfile(m, sf, logging.New("/dev/null", false), verFixture, p)
	if v.EffectiveState != healthresource.StateExpectedNotLoaded || v.ProtectionActive || v.Acceptable() {
		t.Errorf("medium not-loaded: state=%s protection=%v acceptable=%v want EXPECTED_DROPIN_NOT_LOADED/false/false",
			v.EffectiveState, v.ProtectionActive, v.Acceptable())
	}
	if sf.HealthResourceProtection {
		t.Error("state must persist protection=false")
	}
}

// External administrator drop-in overrides effective values → EXTERNAL_OVERRIDE_CONFLICT,
// never silently accepted, DEGRADES, and records the conflicting paths.
func TestReconcileExternalOverrideConflict(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30) // medium calc 256/384
	external := "/etc/systemd/system/nftban-health.service.d/99-admin.conf"
	// Our drop-in + an admin drop-in both loaded; effective differs from calc (admin wins).
	m.RunResults[healthShowKey()] = executor.Result{
		Stdout: showOut(300*miB, 700*miB, 64, healthresource.DropinFile+" "+external)}
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
	if v.EffectiveState != healthresource.StateExternalConflict || v.ProtectionActive || v.Acceptable() {
		t.Errorf("external conflict: state=%s protection=%v acceptable=%v want EXTERNAL_OVERRIDE_CONFLICT/false/false",
			v.EffectiveState, v.ProtectionActive, v.Acceptable())
	}
	if !strings.Contains(v.ValidationError, external) {
		t.Errorf("conflict must name the external drop-in; error=%q", v.ValidationError)
	}
}

// 16. Small under packaged fallback (effective == small calc) → FALLBACK_MATCH, acceptable.
func TestReconcileSmallFallbackMatch(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(2 << 30) // small: 192/256
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, "")}
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
	if v.Profile.Tier != safety.ResourceTierSmall {
		t.Fatalf("tier=%s want small", v.Profile.Tier)
	}
	if v.EffectiveState != healthresource.StateFallbackMatch || !v.ProtectionActive || !v.Acceptable() {
		t.Errorf("small fallback: state=%s protection=%v acceptable=%v want FALLBACK_MATCH/true/true",
			v.EffectiveState, v.ProtectionActive, v.Acceptable())
	}
}

// 10/11. Malformed systemctl show output → ACTIVATION_FAILED.
func TestReconcileMalformedShow(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)
	m.RunResults[healthShowKey()] = executor.Result{Stdout: "garbage-without-memory-keys\n"}
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
	if v.EffectiveState != healthresource.StateActivationFailed || v.Acceptable() {
		t.Errorf("malformed show: state=%s acceptable=%v want ACTIVATION_FAILED/false", v.EffectiveState, v.Acceptable())
	}
	if v.ValidationError == "" {
		t.Error("malformed show must record a ValidationError")
	}
}

// systemctl show exit != 0 → ACTIVATION_FAILED.
func TestReconcileShowExecFailure(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(16 << 30)
	m.RunResults[healthShowKey()] = executor.Result{ExitCode: 1, Stderr: "unit not loaded"}
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
	if v.EffectiveState != healthresource.StateActivationFailed || v.Acceptable() {
		t.Errorf("show exec fail: state=%s acceptable=%v want ACTIVATION_FAILED/false", v.EffectiveState, v.Acceptable())
	}
}

// 12/13. Large: effective MemoryMax below calculated (mismatch) → not ACTIVE_MATCH.
func TestReconcileLargeEffectiveMismatch(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(16 << 30) // large: 384/512
	// drop-in "loaded" but effective max stale/below calc → not ACTIVE_MATCH.
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(384*miB, 256*miB, 64, healthresource.DropinFile)}
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
	if v.Acceptable() {
		t.Errorf("large mismatch must not be acceptable, got state=%s", v.EffectiveState)
	}
}

// Profile transition (e.g. small→medium after a RAM change): stale drop-in bytes
// differ from desired → exactly one rewrite + one daemon-reload.
func TestReconcileProfileTransitionRewritesOnce(t *testing.T) {
	m := executor.NewMockExecutor()
	small := profFor(2 << 30)
	medium := profFor(6 << 30)
	m.Files[healthresource.DropinFile] = healthresource.Render(small, verFixture) // stale small drop-in
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(medium.MemoryHigh, medium.MemoryMax, 64, healthresource.DropinFile)}
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, medium)
	if !v.Changed || reloadCount(m) != 1 {
		t.Errorf("transition: Changed=%v reloads=%d want true/1", v.Changed, reloadCount(m))
	}
	if v.EffectiveState != healthresource.StateActiveMatch {
		t.Errorf("transition end state=%s want ACTIVE_MATCH", v.EffectiveState)
	}
}

// Rollback/uninstall removal primitive: present → removed + daemon-reload;
// absent → idempotent no-op; administrator sibling drop-ins untouched.
func TestRemoveHealthResourceDropin(t *testing.T) {
	m := executor.NewMockExecutor()
	m.Files[healthresource.DropinFile] = []byte("[Service]\nMemoryMax=402653184\n")
	admin := "/etc/systemd/system/nftban-health.service.d/99-admin.conf"
	m.Files[admin] = []byte("[Service]\nCPUQuota=50%\n")
	changed, err := RemoveHealthResourceDropin(m, logging.New("/dev/null", false))
	if err != nil || !changed {
		t.Fatalf("remove present: changed=%v err=%v want true/nil", changed, err)
	}
	if _, ok := m.Files[healthresource.DropinFile]; ok {
		t.Error("drop-in not removed")
	}
	if _, ok := m.Files[admin]; !ok {
		t.Error("administrator sibling drop-in must NOT be removed")
	}
	if reloadCount(m) != 1 {
		t.Errorf("remove reloads=%d want 1", reloadCount(m))
	}
	// Idempotent second removal.
	changed, err = RemoveHealthResourceDropin(m, logging.New("/dev/null", false))
	if err != nil || changed {
		t.Errorf("remove absent: changed=%v err=%v want false/nil", changed, err)
	}
}

// Step 1: mkdir failure → GENERATION_FAILED, no drop-in written, exact op+path.
func TestReconcileMkdirFailure(t *testing.T) {
	m := executor.NewMockExecutor()
	m.MkdirAllErr = errors.New("permission denied")
	p := profFor(6 << 30)
	sf := &state.StateFile{}
	v := reconcileWithProfile(m, sf, logging.New("/dev/null", false), verFixture, p)
	if v.GeneratedState != healthresource.StateGenerationFailed || v.ProtectionActive {
		t.Errorf("mkdir fail: generated=%s protection=%v want GENERATION_FAILED/false", v.GeneratedState, v.ProtectionActive)
	}
	if len(m.WrittenFiles) != 0 {
		t.Error("mkdir fail must leave no partial drop-in")
	}
	if !strings.Contains(v.ValidationError, "mkdir") || sf.HealthResourceError == "" {
		t.Errorf("must record mkdir op+path; error=%q state.err=%q", v.ValidationError, sf.HealthResourceError)
	}
}

// Step 1: durable write failure → GENERATION_FAILED, atomic (no partial file).
func TestReconcileWriteFailure(t *testing.T) {
	m := executor.NewMockExecutor()
	m.WriteFileAtomicErr = errors.New("no space left on device")
	p := profFor(6 << 30)
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
	if v.GeneratedState != healthresource.StateGenerationFailed || v.Acceptable() {
		t.Errorf("write fail: generated=%s acceptable=%v want GENERATION_FAILED/false", v.GeneratedState, v.Acceptable())
	}
	if _, ok := m.WrittenFiles[healthresource.DropinFile]; ok {
		t.Error("write fail must not record a partial final drop-in")
	}
	if !strings.Contains(v.ValidationError, "write") {
		t.Errorf("must record write op; error=%q", v.ValidationError)
	}
}

// Step 2: daemon-reload failure after a changed write → ACTIVATION_FAILED.
func TestReconcileDaemonReloadFailure(t *testing.T) {
	m := executor.NewMockExecutor()
	m.DaemonReloadErr = errors.New("failed to reload")
	p := profFor(6 << 30)
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile)}
	v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
	if v.EffectiveState != healthresource.StateActivationFailed || v.ProtectionActive {
		t.Errorf("reload fail: state=%s protection=%v want ACTIVATION_FAILED/false", v.EffectiveState, v.ProtectionActive)
	}
	if !strings.Contains(v.ValidationError, "daemon-reload") {
		t.Errorf("must record daemon-reload failure; error=%q", v.ValidationError)
	}
}

// Step 2/3: MemoryMax=infinity → ACTIVATION_FAILED (INVALID, not "safe").
func TestReconcileInfinityRejected(t *testing.T) {
	for _, tc := range []struct {
		name      string
		high, max string
	}{
		{"max-infinity", "268435456", "infinity"},
		{"high-infinity", "infinity", "402653184"},
		{"both-infinity", "infinity", "infinity"},
	} {
		m := executor.NewMockExecutor()
		p := profFor(6 << 30)
		m.RunResults[healthShowKey()] = executor.Result{
			Stdout: fmt.Sprintf("MemoryHigh=%s\nMemoryMax=%s\nTasksMax=64\nDropInPaths=%s\n", tc.high, tc.max, healthresource.DropinFile)}
		v := reconcileWithProfile(m, &state.StateFile{}, logging.New("/dev/null", false), verFixture, p)
		if v.EffectiveState != healthresource.StateActivationFailed || v.Acceptable() {
			t.Errorf("%s: state=%s acceptable=%v want ACTIVATION_FAILED/false", tc.name, v.EffectiveState, v.Acceptable())
		}
		if !strings.Contains(v.ValidationError, "infinity") {
			t.Errorf("%s: must reject infinity; error=%q", tc.name, v.ValidationError)
		}
	}
}

// Step 6: a failed run persists the error; a later successful repair clears it,
// restores ACTIVE_MATCH, and does not double-write.
func TestReconcileRetryClearsStaleError(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile)}
	sf := &state.StateFile{}

	// Run 1: write fails → GENERATION_FAILED, error persisted.
	m.WriteFileAtomicErr = errors.New("transient EIO")
	v1 := reconcileWithProfile(m, sf, logging.New("/dev/null", false), verFixture, p)
	if v1.GeneratedState != healthresource.StateGenerationFailed || sf.HealthResourceError == "" {
		t.Fatalf("run1: generated=%s persisted-err=%q want GENERATION_FAILED/non-empty", v1.GeneratedState, sf.HealthResourceError)
	}

	// Run 2: failure cleared → succeeds, stale error cleared, ACTIVE_MATCH.
	m.WriteFileAtomicErr = nil
	v2 := reconcileWithProfile(m, sf, logging.New("/dev/null", false), verFixture, p)
	if v2.EffectiveState != healthresource.StateActiveMatch || !v2.ProtectionActive {
		t.Errorf("run2: state=%s protection=%v want ACTIVE_MATCH/true", v2.EffectiveState, v2.ProtectionActive)
	}
	if sf.HealthResourceError != "" {
		t.Errorf("run2 must clear stale error, got %q", sf.HealthResourceError)
	}
}
