// =============================================================================
// NFTBan v1.154.0 - Installer Post-Install Timer Wedge Recovery
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-timers-post-install"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-06"
// meta:description="D-INSTALL-TIMER-RELOAD: conditional daemon-reload + restart of wedged nftban timers at end of phaseValidate"
// meta:inventory.files="internal/installer/services/timers_post_install.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-*.timer"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package services

import (
	"context"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// RestartWedgedTimers performs the D-INSTALL-TIMER-RELOAD post-install
// hardening pass: a defensive, CONDITIONAL daemon-reload + timer-restart for
// any nftban timer left in the "wedged" state after install.
//
// Background (fleet finding, V1_142_0_FLEET_ROLLOUT_RECORD §3.3): on one of ten
// hosts (dns2), nftban-unified-exporter.timer ended up:
//
//	Active:  active (elapsed)   ← active but NOT "waiting"
//	Trigger: n/a                ← never scheduled
//	0 runs in 24h               ← never fired
//
// The manual fix that resolved it was exactly:
//
//	systemctl daemon-reload && systemctl restart nftban-unified-exporter.timer
//
// after which the timer returned to `active (waiting), Trigger in Xs`.
//
// This function reproduces that fix defensively at the END of phaseValidate.
// It is CONDITIONAL (audit-bot 2026-06-01): only timers that are actually
// wedged are restarted — healthy and inactive timers are left untouched, so the
// blast radius is "restart only the wedged ones" rather than "restart all
// timers on every install".
//
// Failure policy is WARN-ONLY / non-fatal (operator-locked), matching the
// existing installer daemon-reload at phases.go (phaseSwitch step 6). Any error
// from daemon-reload, the wedge probe, or a restart is logged at Warn and
// iteration continues; the install state machine is never affected.
//
// installedTimers is the canonical full timer set to consider (pass
// services.KnownTimers()); timers whose unit file is not installed on this host
// are skipped.
func RestartWedgedTimers(ctx context.Context, exec executor.Executor, log *logging.Logger, installedTimers []string) {
	log.Info("D-INSTALL-TIMER-RELOAD hardening: probing %d nftban timers for wedged state", len(installedTimers))

	// Defensive daemon-reload first — half of the documented manual fix, and a
	// prerequisite for systemd to recompute next-elapse times. Non-fatal.
	if err := exec.DaemonReload(); err != nil {
		log.Warn("timer hardening daemon-reload: %v (non-fatal)", err)
	}

	restarted := 0
	for _, timer := range installedTimers {
		// Skip timers not installed on this host (pro-/panel-/feature-gated
		// units that this install did not deploy).
		if !timerUnitInstalled(exec, timer) {
			log.Debug("timer hardening: %s not installed — skipping", timer)
			continue
		}

		if !timerIsWedged(ctx, exec, timer) {
			log.Debug("timer hardening: %s healthy (or inactive) — skipping", timer)
			continue
		}

		// A wedged timer is already "active", so ServiceStart would be a no-op;
		// only a restart re-arms it (this is exactly the documented manual fix).
		log.Warn("timer hardening: %s is wedged (active but no next trigger) — restarting", timer)
		if res := exec.RunContext(ctx, "systemctl", "restart", timer); res.ExitCode != 0 {
			log.Warn("timer hardening restart %s: exit %d %s (non-fatal)", timer, res.ExitCode, strings.TrimSpace(res.Stderr))
			continue
		}
		restarted++
	}

	if restarted == 0 {
		log.Info("D-INSTALL-TIMER-RELOAD hardening: no wedged timers found")
	} else {
		log.Info("D-INSTALL-TIMER-RELOAD hardening: restarted %d wedged timer(s)", restarted)
	}
}

// timerUnitInstalled reports whether the timer unit file is present on this
// host (either the admin-override location or the package location). Mirrors
// the optional-timer presence check in ReconcileTimers.
func timerUnitInstalled(exec executor.Executor, timer string) bool {
	return exec.FileExists("/etc/systemd/system/"+timer) ||
		exec.FileExists("/usr/lib/systemd/system/"+timer) ||
		exec.FileExists("/lib/systemd/system/"+timer)
}

// timerIsWedged reports whether a timer is in the dns2-class wedged state:
// ACTIVE but with NO scheduled next trigger. Detection uses
//
//	systemctl show <timer> -p ActiveState -p NextElapseUSecRealtime --value
//
// A timer is considered wedged when ActiveState=="active" AND the next-elapse
// value is absent / "0" / "n/a" / "infinity". Inactive timers (disabled or
// stopped) legitimately have no next trigger and are NOT treated as wedged —
// re-arming them would be an out-of-scope policy change.
//
// On any probe error (non-zero exit, unparseable output) the timer is treated
// as NOT wedged: warn-only means we never restart on uncertain evidence, which
// keeps false positives at zero (a healthy timer is never needlessly bounced).
func timerIsWedged(ctx context.Context, exec executor.Executor, timer string) bool {
	res := exec.RunContext(ctx, "systemctl", "show", timer,
		"-p", "ActiveState", "-p", "NextElapseUSecRealtime", "--value")
	if res.ExitCode != 0 {
		return false
	}

	// With multiple -p properties and --value, systemctl prints one value per
	// line in the order requested: ActiveState, then NextElapseUSecRealtime.
	lines := strings.Split(strings.TrimSpace(res.Stdout), "\n")
	if len(lines) < 2 {
		return false
	}
	activeState := strings.TrimSpace(lines[0])
	nextElapse := strings.TrimSpace(lines[1])

	if activeState != "active" {
		return false
	}
	switch nextElapse {
	case "", "0", "n/a", "infinity":
		return true
	}
	return false
}
