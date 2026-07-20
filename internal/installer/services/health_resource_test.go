// meta:name="health_resource_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 2 installer-wiring tests (MockExecutor): fresh install per tier, no-churn, medium/large FALLBACK_UNDERSIZED, small FALLBACK_MATCH, effective mismatch, malformed/failed systemctl show → ACTIVATION_FAILED, daemon-reload-only-on-change, and HEALTH_RESOURCE_* state persistence. Injects the profile so tiers are deterministic; no real systemd/disk."
package services

import (
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

// 17. Medium under packaged fallback (effective 192/256) → FALLBACK_UNDERSIZED, not acceptable.
func TestReconcileMediumFallbackUndersized(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 << 30)
	// systemd shows the packaged fallback (drop-in not effective), no drop-in loaded.
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(192*miB, 256*miB, 64, "")}
	sf := &state.StateFile{}
	v := reconcileWithProfile(m, sf, logging.New("/dev/null", false), verFixture, p)
	if v.EffectiveState != healthresource.StateFallbackUnder || v.ProtectionActive || v.Acceptable() {
		t.Errorf("medium fallback: state=%s protection=%v acceptable=%v want FALLBACK_UNDERSIZED/false/false",
			v.EffectiveState, v.ProtectionActive, v.Acceptable())
	}
	if sf.HealthResourceProtection {
		t.Error("state must persist protection=false")
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
