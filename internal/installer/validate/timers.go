// =============================================================================
// NFTBan v1.135.0 — Reusable Install Validation: Critical Core Timers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-timers"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Pure validator for critical core systemd timers (enabled + active/scheduled)"
// meta:inventory.files="internal/installer/validate/timers.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_RECONCILE_CORE_TIMERS"
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-maintenance.timer"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// CORE-TIMER-ENABLED-001  every CRITICAL core timer (e.g. nftban-maintenance.timer,
//                         which backs maintenance/trend/auto-heal/lockout-prevention)
//                         must be enabled AND active-or-scheduled after install. A
//                         critical timer that silently failed to enable/start must
//                         DEGRADE the install (D-MAINTENANCE-TIMER-SILENT-ENABLE),
//                         not land COMMITTED.
//
// Intentional opt-out: when NFTBAN_RECONCILE_CORE_TIMERS=false the operator has
// chosen not to reconcile timers — that is recorded as Skipped and is NOT a
// failure. Optional/non-critical timers are never in scope here.
//
// Generic + pure: no I/O. The host-side adapter that feeds this lives in
// timers_gather.go; tests pass synthetic inputs directly.
//
// =============================================================================

package validate

import (
	"sort"
)

// TimerState is the observed runtime state of one timer unit.
type TimerState struct {
	Enabled           bool // systemctl is-enabled (will start on boot)
	ActiveOrScheduled bool // .timer unit active (scheduled to fire)
}

// TimerValidationInputs is the synthetic input set for ValidateCriticalTimers.
type TimerValidationInputs struct {
	// ReconcileDisabled is true when NFTBAN_RECONCILE_CORE_TIMERS=false — an
	// intentional operator opt-out; validation passes (Skipped), not DEGRADED.
	ReconcileDisabled bool
	// Critical is the set of critical core timer unit names to check.
	Critical []string
	// States maps a critical timer unit -> observed state.
	States map[string]TimerState
}

// TimerValidationResult is the verdict consumed by assertCriticalTimersEnabled.
type TimerValidationResult struct {
	OK      bool     // all critical timers enabled + active/scheduled (or Skipped)
	Skipped bool     // reconcile intentionally disabled
	Missing []string // critical timers not enabled+active (sorted)
}

// ValidateCriticalTimers checks that every critical core timer is enabled AND
// active-or-scheduled. Pure (no I/O). NFTBAN_RECONCILE_CORE_TIMERS=false →
// Skipped+OK (intentional). Optional timers are never inspected.
func ValidateCriticalTimers(in TimerValidationInputs) TimerValidationResult {
	if in.ReconcileDisabled {
		return TimerValidationResult{OK: true, Skipped: true}
	}
	var missing []string
	for _, t := range in.Critical {
		st := in.States[t]
		if !st.Enabled || !st.ActiveOrScheduled {
			missing = append(missing, t)
		}
	}
	sort.Strings(missing)
	return TimerValidationResult{OK: len(missing) == 0, Missing: missing}
}
