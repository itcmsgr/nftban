// =============================================================================
// NFTBan v1.135.0 — Critical Core Timers Gather (host-side adapter)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-timers-gather"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Adapter that builds TimerValidationInputs from a live host"
// meta:inventory.files="internal/installer/validate/timers_gather.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_RECONCILE_CORE_TIMERS"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftban-maintenance.timer"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Pure validator + tests live in timers.go. This adapter pulls live host
// data: the critical-timer set + the NFTBAN_RECONCILE_CORE_TIMERS opt-out
// come from the services package (single source of truth, co-located with
// ReconcileTimers), and enabled/active come from executor.Executor.
//
// =============================================================================

package validate

import (
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/services"
)

// GatherTimerInputs builds TimerValidationInputs from the live host.
func GatherTimerInputs(exec executor.Executor, log *logging.Logger) TimerValidationInputs {
	in := TimerValidationInputs{
		ReconcileDisabled: !services.ShouldReconcile(exec),
		Critical:          services.CriticalCoreTimers(),
		States:            map[string]TimerState{},
	}
	if in.ReconcileDisabled {
		log.Debug("timer validation: NFTBAN_RECONCILE_CORE_TIMERS=false — intentional opt-out; critical-timer assertion passes (Skipped)")
		return in
	}
	for _, t := range in.Critical {
		in.States[t] = TimerState{
			Enabled:           exec.ServiceEnabled(t),
			ActiveOrScheduled: exec.ServiceActive(t),
		}
	}
	return in
}
