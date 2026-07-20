// SPDX-License-Identifier: MPL-2.0
// meta:name="health_resource.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 HEALTH-OOM hotfix Lane 2 installer wiring: phaseConfigure reconciler for the profile-derived nftban-health.service memory drop-in. Renders the canonical safety policy (healthresource.Render/Validate), writes atomically via the Executor ONLY when bytes change (no-churn), daemon-reloads only on change, then VERIFIES effective systemd properties via `systemctl show` (not file presence), classifies protection state (healthresource.ClassifyEffective), and persists the structured HEALTH_RESOURCE_* result to install_state. Returns a healthresource.Verdict for the phaseValidate assertion — one policy path, one shared verification method. No RAM/CPU/size classifier here (consumes internal/safety)."
package services

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/safety"
)

const healthUnit = "nftban-health.service"

// ReconcileHealthResource generates + activates + verifies the health-service
// resource drop-in and returns a structured verdict. Called from phaseConfigure
// (install/upgrade/repair) before failed-unit/health validation. It never fails
// the phase itself — the phaseValidate assertion turns an unacceptable verdict
// into installer DEGRADED (medium/large fallback) per contract.
func ReconcileHealthResource(exec executor.Executor, sf *state.StateFile, log *logging.Logger, sourceVersion string) healthresource.Verdict {
	// Facts + tier + policy come from the canonical safety authority (reads
	// /proc). Split from reconcileWithProfile so tests inject a fixture tier.
	return reconcileWithProfile(exec, sf, log, sourceVersion, safety.HealthServiceMemoryLimits())
}

// reconcileWithProfile is the profile-parameterized core (unit-testable with a
// fixture HealthResourceProfile + a MockExecutor).
func reconcileWithProfile(exec executor.Executor, sf *state.StateFile, log *logging.Logger, sourceVersion string, p safety.HealthResourceProfile) healthresource.Verdict {
	v := healthresource.Verdict{
		Profile:        p,
		Authority:      "internal/safety",
		CalculatedHigh: p.MemoryHigh,
		CalculatedMax:  p.MemoryMax,
		DropInPath:     healthresource.DropinFile,
		SourceVersion:  sourceVersion,
	}

	// 1. Validate the calculated policy defensively.
	if err := healthresource.Validate(p); err != nil {
		v.GeneratedState = healthresource.StateInvalid
		v.EffectiveState = healthresource.StateActivationFailed
		v.ValidationError = "policy invalid: " + err.Error()
		finishHealthResource(exec, sf, log, &v)
		return v
	}

	// 2. Generate the drop-in only when its content changes (no-churn).
	desired := healthresource.Render(p, sourceVersion)
	existing, rerr := exec.ReadFile(healthresource.DropinFile)
	if rerr != nil {
		existing = nil // absent (or unreadable) → treat as absent, (re)write below
	}
	v.GeneratedState = healthresource.Classify(existing, desired)
	if v.GeneratedState != healthresource.StateActiveMatch {
		if err := exec.MkdirAll(healthresource.DropinDir, 0o755); err != nil {
			v.GeneratedState = healthresource.StateGenerationFailed
			v.EffectiveState = healthresource.StateActivationFailed
			v.ValidationError = "mkdir drop-in dir: " + err.Error()
			finishHealthResource(exec, sf, log, &v)
			return v
		}
		if err := exec.WriteFileAtomic(healthresource.DropinFile, desired, 0o644); err != nil {
			v.GeneratedState = healthresource.StateGenerationFailed
			v.EffectiveState = healthresource.StateActivationFailed
			v.ValidationError = "write drop-in: " + err.Error()
			finishHealthResource(exec, sf, log, &v)
			return v
		}
		v.Changed = true
		v.GeneratedState = healthresource.StateReadyGen
	}

	// 3. daemon-reload ONLY when the drop-in changed.
	if v.Changed {
		if err := exec.DaemonReload(); err != nil {
			v.EffectiveState = healthresource.StateActivationFailed
			v.ValidationError = "daemon-reload: " + err.Error()
			finishHealthResource(exec, sf, log, &v)
			return v
		}
		v.DaemonReloaded = true
	}

	// 4. Verify EFFECTIVE systemd properties — do not trust file presence alone.
	effHigh, effMax, effTasks, dropins, err := queryEffectiveHealth(exec)
	if err != nil {
		v.EffectiveState = healthresource.StateActivationFailed
		v.ValidationError = "systemctl show: " + err.Error()
		finishHealthResource(exec, sf, log, &v)
		return v
	}
	v.EffectiveHigh, v.EffectiveMax, v.EffectiveTasksMax = effHigh, effMax, effTasks
	v.LoadedDropIns = dropins
	v.DropInLoaded = containsPath(dropins, healthresource.DropinFile)

	// 4b. Infinity (systemd's "unset limit") is INVALID for this bounded hotfix:
	// an unlimited hard ceiling violates the design; NEVER read it as "safe
	// because larger than calculated". Effective values must MATCH the policy.
	if effHigh == healthresource.InfinityBytes || effMax == healthresource.InfinityBytes {
		v.EffectiveState = healthresource.StateActivationFailed
		v.ValidationError = "unbounded effective memory limit (infinity) violates bounded v1.222.1 policy"
		v.ProtectionActive = false
		finishHealthResource(exec, sf, log, &v)
		return v
	}

	// 5. Classify effective protection state, conflict-aware. Any loaded drop-in
	// that is not ours is an external/administrator override.
	otherDropins := 0
	for _, dp := range dropins {
		if dp != healthresource.DropinFile {
			otherDropins++
		}
	}
	v.EffectiveState = healthresource.ClassifyEffectiveDetailed(p, effHigh, effMax, v.DropInLoaded, otherDropins, true)
	if v.EffectiveState == healthresource.StateExternalConflict && v.ValidationError == "" {
		v.ValidationError = "external systemd drop-in overrides health-service memory limits: " + strings.Join(dropins, " ")
	}
	v.ProtectionActive = v.EffectiveState.ProtectionActive()
	finishHealthResource(exec, sf, log, &v)
	return v
}

// finishHealthResource persists the verdict to install_state and logs it.
func finishHealthResource(_ executor.Executor, sf *state.StateFile, log *logging.Logger, v *healthresource.Verdict) {
	v.ProtectionActive = v.EffectiveState.ProtectionActive()
	if sf != nil {
		sf.HealthResourceState = string(v.EffectiveState)
		sf.HealthResourceProfile = string(v.Profile.Tier)
		sf.HealthResourceAuthority = v.Authority
		sf.HealthResourceReason = v.Profile.Reason
		sf.HealthResourceProtection = v.ProtectionActive
		sf.HealthMemHighCalculated = v.CalculatedHigh
		sf.HealthMemMaxCalculated = v.CalculatedMax
		sf.HealthMemHighEffective = v.EffectiveHigh
		sf.HealthMemMaxEffective = v.EffectiveMax
		sf.HealthTasksMaxEffective = v.EffectiveTasksMax
		sf.HealthResourceDropin = v.DropInPath
		sf.HealthResourceDropinLoaded = v.DropInLoaded
		sf.HealthResourceLoadedDropins = strings.Join(v.LoadedDropIns, " ")
		sf.HealthResourceSourceVer = v.SourceVersion
		sf.HealthResourceGenerated = string(v.GeneratedState)
		sf.HealthResourceError = v.ValidationError // cleared ("") on success → no stale error retained
	}
	logHealthResource(log, v)
}

func logHealthResource(log *logging.Logger, v *healthresource.Verdict) {
	if log == nil {
		return
	}
	if v.Acceptable() {
		log.Info("health-resource: profile=%s authority=%s expected_high=%d expected_max=%d generated=%s effective_high=%d effective_max=%d protection_active=%t changed=%t daemon_reload=%t",
			v.Profile.Tier, v.Authority, v.CalculatedHigh, v.CalculatedMax, v.GeneratedState,
			v.EffectiveHigh, v.EffectiveMax, v.ProtectionActive, v.Changed, v.DaemonReloaded)
		return
	}
	log.Warn("health-resource: profile=%s NOT PROTECTED — expected_high=%d expected_max=%d effective_high=%d effective_max=%d generated=%s effective=%s dropins=%s error=%q",
		v.Profile.Tier, v.CalculatedHigh, v.CalculatedMax, v.EffectiveHigh, v.EffectiveMax,
		v.GeneratedState, v.EffectiveState, strings.Join(v.LoadedDropIns, ","), v.ValidationError)
}

// queryEffectiveHealth reads machine-readable systemd properties (never
// human-formatted `systemctl status`). Returns MemoryHigh, MemoryMax, TasksMax
// (bytes; infinity → math.MaxInt64) and all loaded DropInPaths.
func queryEffectiveHealth(exec executor.Executor) (high, max, tasks int64, dropins []string, err error) {
	res := exec.Run("systemctl", "show", healthUnit,
		"-p", "MemoryHigh", "-p", "MemoryMax", "-p", "TasksMax", "-p", "DropInPaths", "-p", "FragmentPath")
	if res.ExitCode != 0 {
		return 0, 0, 0, nil, fmt.Errorf("exit %d: %s", res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	props := healthresource.ShowProps(res.Stdout)
	hs, hok := props["MemoryHigh"]
	ms, mok := props["MemoryMax"]
	if !hok || !mok {
		return 0, 0, 0, nil, fmt.Errorf("missing MemoryHigh/MemoryMax in systemctl show output")
	}
	var okh, okm bool
	high, _, okh = healthresource.ParseMemBytes(hs)
	max, _, okm = healthresource.ParseMemBytes(ms)
	if !okh || !okm {
		return 0, 0, 0, nil, fmt.Errorf("unparseable MemoryHigh=%q / MemoryMax=%q", hs, ms)
	}
	if ts, ok := props["TasksMax"]; ok {
		tasks, _, _ = healthresource.ParseMemBytes(ts) // infinity/blank tolerated
	}
	if dp, ok := props["DropInPaths"]; ok && strings.TrimSpace(dp) != "" {
		dropins = strings.Fields(dp)
	}
	return high, max, tasks, dropins, nil
}

// RemoveHealthResourceDropin removes the NFTBan-generated health-resource drop-in
// (rollback to a release that does not own it, and uninstall/purge). It is the
// GENERATED_DROPIN_OWNER cleanup path — Executor-based so DEB/RPM removal
// scriptlets and the installer uninstall mode share one implementation. It NEVER
// touches administrator-owned sibling drop-ins (only the exact NFTBan path).
// Idempotent: absent → (false, nil). changed=true means daemon-reload happened.
func RemoveHealthResourceDropin(exec executor.Executor, log *logging.Logger) (changed bool, err error) {
	if !exec.FileExists(healthresource.DropinFile) {
		if log != nil {
			log.Debug("health-resource: drop-in already absent (%s) — nothing to remove", healthresource.DropinFile)
		}
		return false, nil
	}
	if err := exec.Remove(healthresource.DropinFile); err != nil {
		return false, fmt.Errorf("remove health-resource drop-in %s: %w", healthresource.DropinFile, err)
	}
	// Best-effort remove the drop-in dir if it is now empty (ignore ENOTEMPTY:
	// an administrator sibling drop-in must survive).
	_ = exec.Remove(healthresource.DropinDir)
	if err := exec.DaemonReload(); err != nil {
		// Removal succeeded; a failed reload is reported but the file is gone.
		return true, fmt.Errorf("health-resource drop-in removed but daemon-reload failed: %w", err)
	}
	if log != nil {
		log.Info("health-resource: removed generated drop-in %s + daemon-reload (rollback/uninstall)", healthresource.DropinFile)
	}
	return true, nil
}

func containsPath(paths []string, want string) bool {
	for _, p := range paths {
		if p == want {
			return true
		}
	}
	return false
}
