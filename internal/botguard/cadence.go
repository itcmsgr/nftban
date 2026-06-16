// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: BotScan cadence-lag visibility (read-only)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: v1.191 8B (config-knobs/cadence) — a bounded, READ-ONLY advisory of the
//          BotScan→BotGuard pipeline freshness, derived from the batch-signal file mtime.
//          Text/diagnostic only: it is NEVER a schema field, Prometheus metric, v1.191
//          counter, or install_state input. Three states: fresh / stale (lag suspected) /
//          unknown (unavailable). Recon: BotScan cadence is 10–77 min, so a generous default
//          window avoids false "stale" on quiet hosts.
//
// meta:name="botguard_cadence"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Read-only BotScan cadence-lag freshness advisory for BotGuard"
// meta:inventory.files="cadence.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"os"
	"path/filepath"
	"time"
)

// CadenceFreshness is the advisory BotScan-pipeline freshness state.
type CadenceFreshness int

const (
	CadenceUnknown CadenceFreshness = iota // freshness unavailable (no file / unreadable)
	CadenceFresh                           // touched within the advisory window
	CadenceStale                           // not touched within the window → lag suspected
)

func (f CadenceFreshness) String() string {
	switch f {
	case CadenceFresh:
		return "fresh"
	case CadenceStale:
		return "stale"
	default:
		return "unknown"
	}
}

// CadenceStatus is a bounded, read-only advisory snapshot. It is diagnostic text only and is
// never serialized into a schema/metric or used to compute install_state.
type CadenceStatus struct {
	State             CadenceFreshness
	AgeSeconds        int64 // -1 when unknown
	StaleAfterSeconds int64
	Note              string
}

// botScanCadenceStatus reports the BotScan pipeline freshness from the batch-signal file mtime.
// Read-only and side-effect-free. Unknown (file missing/unreadable/unconfigured) is a clean
// advisory state — it does NOT imply lag and must never escalate enforcement or install_state.
func (m *Module) botScanCadenceStatus(now time.Time) CadenceStatus {
	staleAfter := int64(45 * 60)
	if m.config != nil && m.config.CadenceStaleAfter > 0 {
		staleAfter = int64(m.config.CadenceStaleAfter / time.Second)
	}
	cs := CadenceStatus{
		State:             CadenceUnknown,
		AgeSeconds:        -1,
		StaleAfterSeconds: staleAfter,
		Note:              "BotScan batch-signal freshness unavailable (advisory only; durable nft-set checks remain authoritative)",
	}
	if m.config == nil || m.config.BatchSignalFile == "" {
		return cs
	}
	fi, err := os.Stat(filepath.Clean(m.config.BatchSignalFile))
	if err != nil {
		return cs // missing/unreadable → unknown (NOT stale, NOT degraded)
	}
	age := now.Sub(fi.ModTime())
	if age < 0 {
		age = 0
	}
	cs.AgeSeconds = int64(age / time.Second)
	if cs.AgeSeconds <= staleAfter {
		cs.State = CadenceFresh
		cs.Note = "BotScan pipeline fresh (advisory)"
	} else {
		cs.State = CadenceStale
		cs.Note = "BotScan cadence lag suspected; durable nft-set checks remain authoritative (advisory)"
	}
	return cs
}
