// =============================================================================
// NFTBan v1.154.0 - Installer Post-Install Timer Wedge Recovery
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
		// v1.235 row 486 / commit-confirm: the rollback timers are armed only by an
		// apply and must NEVER be (re)started by the installer. Restarting an armed
		// monotonic-only rollback timer would reset or fire it outside its apply.
		if isRollbackTimer(timer) {
			log.Debug("timer hardening: %s is a commit-confirm rollback unit — never restarted by the installer", timer)
			continue
		}
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

// timerIsWedged reports whether a timer is ACTIVE but has NO scheduled next
// trigger for any of the trigger kinds it actually has.
//
// v1.235 T1 (BUG-INTERVAL-TIMERS-UNSCHEDULED-AFTER-FRESH-START-ON-LONG-UPTIME).
// The v1.154 probe ran `systemctl show <t> -p ActiveState -p
// NextElapseUSecRealtime --value` and read the lines positionally as
// [ActiveState, NextElapse]. systemd prints properties in ITS order, not the
// requested one (measured on systemd 252, 255 and 257: the Timer properties come
// before ActiveState), and --value drops the names. A wedged interval timer
// therefore printed "\nactive\n" (one line after trimming: "not wedged") and a
// healthy calendar timer "<date>\nactive\n" (ActiveState read as a date: "not
// wedged"). The probe could never fire. It also only looked at the realtime
// field, which is always empty for an interval-only timer, healthy or not.
//
// Now: one key=value read (order-independent), then
//   - not active                                      -> not wedged (policy, not a wedge)
//   - calendar triggers   (TimersCalendar present)    -> NextElapseUSecRealtime must be set
//   - interval triggers   (TimersMonotonic present)   -> NextElapseUSecMonotonic must be set
//   - any applicable next elapse set                  -> not wedged
//   - neither trigger kind visible                    -> not wedged (cannot classify)
//   - triggered service active/activating/reloading   -> not wedged: a run in progress
//     or deactivating                                    legitimately has no next elapse
//
// Any probe error is still "not wedged": warn-only, never restart on uncertain
// evidence.
func timerIsWedged(ctx context.Context, exec executor.Executor, timer string) bool {
	res := exec.RunContext(ctx, "systemctl", "show", timer,
		"-p", "ActiveState", "-p", "Unit",
		"-p", "TimersCalendar", "-p", "TimersMonotonic",
		"-p", "NextElapseUSecRealtime", "-p", "NextElapseUSecMonotonic")
	if res.ExitCode != 0 {
		return false
	}
	p := parseShowProperties(res.Stdout)

	if p.first("ActiveState") != "active" {
		return false
	}
	hasCalendar := p.nonEmpty("TimersCalendar")
	hasMonotonic := p.nonEmpty("TimersMonotonic")
	if !hasCalendar && !hasMonotonic {
		return false
	}
	if hasCalendar && nextElapseSet(p.first("NextElapseUSecRealtime")) {
		return false
	}
	if hasMonotonic && nextElapseSet(p.first("NextElapseUSecMonotonic")) {
		return false
	}

	unit := p.first("Unit")
	if unit == "" {
		return false
	}
	svc := exec.RunContext(ctx, "systemctl", "show", unit, "-p", "ActiveState")
	if svc.ExitCode != 0 {
		return false
	}
	switch parseShowProperties(svc.Stdout).first("ActiveState") {
	case "inactive", "failed":
		return true
	}
	// active / activating / reloading / deactivating, or anything unrecognised:
	// not a wedge we can act on.
	return false
}

// showProperties is `systemctl show` output keyed by property name. A name can
// repeat (TimersMonotonic prints one line per trigger), so values are lists.
type showProperties map[string][]string

func parseShowProperties(out string) showProperties {
	p := showProperties{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		k, v, ok := strings.Cut(line, "=")
		if !ok || k == "" {
			continue
		}
		p[k] = append(p[k], strings.TrimSpace(v))
	}
	return p
}

func (p showProperties) first(k string) string {
	if v := p[k]; len(v) > 0 {
		return v[0]
	}
	return ""
}

func (p showProperties) nonEmpty(k string) bool {
	for _, v := range p[k] {
		if v != "" {
			return true
		}
	}
	return false
}

// nextElapseSet reports whether a NextElapseUSec* value names a scheduled time.
// systemd prints "" (realtime, none), "0" (monotonic on a calendar timer),
// "infinity" (monotonic, none), or "n/a" depending on version.
func nextElapseSet(v string) bool {
	switch strings.TrimSpace(v) {
	case "", "0", "n/a", "infinity":
		return false
	}
	return true
}

// isRollbackTimer reports the commit-confirm rollback units the installer must
// never restart: the legacy nftban-rollback.timer and any transient
// nftban-commit-rollback-<applyID> unit (systemd-run --unit name; v1.235 row 486).
func isRollbackTimer(unit string) bool {
	return unit == "nftban-rollback.timer" || strings.HasPrefix(unit, "nftban-commit-rollback")
}
