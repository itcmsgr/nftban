// =============================================================================
// NFTBan v1.80 - Effective-axis state machine (Phase E)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: aggregate
// Purpose: Evaluate aggregation snapshots into Effective-axis health states.
//
// meta:name="loginmon_pipeline_aggregate_effective"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="aggregate"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Phase E: Effective-axis state machine for pipeline health"
//
// meta:inventory.files="effective.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package aggregate

import (
	"fmt"
	"time"
)

// Effective-axis thresholds.
//
// These are the numeric criteria that distinguish ACTIVE from DEGRADED from
// FAILING. Derived from real soak data:
//
//   srv2 dovecot 24h: 683 events / 43 bans = 6.3% → DEGRADED
//   srv3 dovecot 24h: 868 events / 132 bans = 15.2% → ACTIVE
//
// The thresholds are conservative: only flag DEGRADED when there is
// sufficient volume AND diversity AND weak enforcement. Low volume stays
// ACTIVE regardless of ratio (insufficient signal to judge).
const (
	MinEventsForDegraded = 50  // below this, insufficient signal
	MinIPsForDegraded    = 5   // below this, not distributed
	DegradedRatio        = 0.10 // bans/events under this = enforcement weak

	MinEventsForFailing = 200
	MinIPsForFailing    = 10
	FailingRatio        = 0.05
)

// EvaluateWindow computes the EffectiveSnapshot for a single (source, window).
//
// This is the state machine from the v1.80 design doc (Section D of
// GO_PIPELINE_DESIGN_v1.80.md). It takes a WindowSnapshot from the
// aggregator and produces an EffectiveSnapshot with one of three states.
func EvaluateWindow(ws WindowSnapshot, source string) EffectiveSnapshot {
	snap := EffectiveSnapshot{
		Source:          source,
		Window:          ws.Window,
		EvaluatedAt:     time.Now(),
		EventsInWindow:  ws.EventCount,
		BansInWindow:    ws.BanCount,
		UniqueAttackers: ws.UniqueIPs,
	}

	if ws.EventCount == 0 {
		snap.State = EffectiveActive
		snap.Reason = "no events in window"
		snap.Ratio = 1.0
		return snap
	}

	snap.Ratio = float64(ws.BanCount) / float64(ws.EventCount)

	// FAILING (most severe — check first)
	if ws.EventCount >= MinEventsForFailing &&
		ws.UniqueIPs >= MinIPsForFailing &&
		snap.Ratio < FailingRatio {
		snap.State = EffectiveFailing
		snap.Reason = fmt.Sprintf("heavy volume %d events from %d IPs, ratio %.1f%% (< %.0f%%)",
			ws.EventCount, ws.UniqueIPs, snap.Ratio*100, FailingRatio*100)
		return snap
	}

	// DEGRADED
	if ws.EventCount >= MinEventsForDegraded &&
		ws.UniqueIPs >= MinIPsForDegraded &&
		snap.Ratio < DegradedRatio {
		snap.State = EffectiveDegraded
		snap.Reason = fmt.Sprintf("real volume %d events from %d IPs, ratio %.1f%% (< %.0f%%)",
			ws.EventCount, ws.UniqueIPs, snap.Ratio*100, DegradedRatio*100)
		return snap
	}

	snap.State = EffectiveActive
	if ws.EventCount >= MinEventsForDegraded && snap.Ratio < 0.30 {
		snap.Reason = fmt.Sprintf("active (advisory: ratio %.1f%% in lower band)", snap.Ratio*100)
	} else {
		snap.Reason = "active"
	}
	return snap
}

// EvaluateHost computes the worst Effective state across all sources and
// windows in a Snapshot. This is the host-level summary that the CLI and
// validator will display.
func EvaluateHost(snap Snapshot) HostEffective {
	result := HostEffective{
		EvaluatedAt: time.Now(),
		Worst:       EffectiveActive,
	}

	for srcName, srcSnap := range snap.Sources {
		for _, ws := range srcSnap.Windows {
			es := EvaluateWindow(ws, srcName)
			result.Snapshots = append(result.Snapshots, es)
			if es.State > result.Worst {
				result.Worst = es.State
			}
		}
	}

	return result
}

// HostEffective is the host-level effective-axis summary.
type HostEffective struct {
	EvaluatedAt time.Time
	Worst       EffectiveState
	Snapshots   []EffectiveSnapshot
}
