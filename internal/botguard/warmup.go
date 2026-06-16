// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Bounded decision-cache warm-up on restart
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: v1.191 8B (increment 7) — on daemon start, replay only the bounded RECENT TAIL of
//          the existing batch_signals.jsonl into the TEMPORARY decision cache, so a restart
//          does not lose in-flight classification. Bounded for 100–300-site shared hosts:
//          hard caps on bytes (tail-seek, never whole-file read), lines, age, accepted signals,
//          and a duration/context budget. Replay rebuilds CACHE context ONLY — it never
//          enforces (no ban/grey/whitelist/blacklist), never persists, adds no state writer,
//          and never blocks startup beyond the budget.
//
// meta:name="botguard_warmup"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Bounded batch_signals.jsonl tail-replay warm-up for the BotGuard decision cache"
// meta:inventory.files="warmup.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"time"
)

// warmupLimits bounds the restart replay. Defaults are conservative and safe for large shared
// hosts (a busy 300-site server can produce a large batch_signals.jsonl between flushes).
type warmupLimits struct {
	maxBytes    int64         // only the trailing maxBytes are read (tail-seek; never whole file)
	maxLines    int           // hard cap on scanned lines
	maxAccepted int           // hard cap on accepted (replayed) signals
	maxAge      time.Duration // signals older than this are skipped
	budget      time.Duration // wall-clock/context budget for the whole replay
	maxLineSize int           // per-line scanner buffer cap (malformed-huge-line guard)
	now         func() time.Time
}

func defaultWarmupLimits() warmupLimits {
	return warmupLimits{
		maxBytes:    4 << 20, // 4 MiB tail
		maxLines:    10000,
		maxAccepted: 10000,
		maxAge:      45 * time.Minute,
		budget:      400 * time.Millisecond,
		maxLineSize: 256 << 10, // 256 KiB
		now:         time.Now,
	}
}

// warmupLimitsFrom builds the replay bounds from operator config (v1.191 8B config-knobs).
// Config values are already validated/clamped at parse time and defaulted to the inc7 values;
// any field still <=0 falls back to the conservative default here (defence in depth — there is
// never a "read whole file" / "unbounded" mode).
func warmupLimitsFrom(cfg *Config) warmupLimits {
	d := defaultWarmupLimits()
	if cfg == nil {
		return d
	}
	lim := warmupLimits{
		maxBytes:    cfg.WarmupMaxBytes,
		maxLines:    cfg.WarmupMaxLines,
		maxAccepted: cfg.WarmupMaxAccepted,
		maxAge:      cfg.WarmupMaxAge,
		budget:      cfg.WarmupMaxDuration,
		maxLineSize: cfg.WarmupMaxLineSize,
		now:         time.Now,
	}
	if lim.maxBytes <= 0 {
		lim.maxBytes = d.maxBytes
	}
	if lim.maxLines <= 0 {
		lim.maxLines = d.maxLines
	}
	if lim.maxAccepted <= 0 {
		lim.maxAccepted = d.maxAccepted
	}
	if lim.maxAge <= 0 {
		lim.maxAge = d.maxAge
	}
	if lim.budget <= 0 {
		lim.budget = d.budget
	}
	if lim.maxLineSize <= 0 {
		lim.maxLineSize = d.maxLineSize
	}
	return lim
}

// WarmupStats is an internal, bounded view of a replay run (for later support/health; NOT
// wired to schema/metrics in this increment).
type WarmupStats struct {
	LinesScanned     int
	Accepted         int
	SkippedOld       int
	SkippedMalformed int
	BytesRead        int64
	TruncatedTail    bool   // file exceeded maxBytes → only the tail was read
	Stopped          string // "eof" | "max_lines" | "max_accepted" | "timeout" | "scan_error" | "noop"
}

// warmupFromBatchSignals replays the bounded recent tail of batch_signals.jsonl into the
// decision cache via the same cache-only transition path as live observation
// (recordDecisionTransition) — so it NEVER enforces and NEVER creates durable state. All
// failures degrade to a no-op without panicking; startup always continues.
func (m *Module) warmupFromBatchSignals(ctx context.Context, lim warmupLimits) WarmupStats {
	var st WarmupStats
	st.Stopped = "noop"

	if m.decisionCache == nil { // nil cache → no-op, no panic
		return st
	}
	signalFile := m.config.BatchSignalFile
	if signalFile == "" {
		return st
	}
	f, err := os.Open(filepath.Clean(signalFile)) // #nosec G304 -- path from trusted config
	if err != nil {
		return st // missing file → no-op, startup continues
	}
	defer func() { _ = f.Close() }()

	fi, err := f.Stat()
	if err != nil || fi.Size() == 0 {
		return st // unreadable / empty → no-op
	}
	size := fi.Size()

	// Bounded TAIL: seek to the last maxBytes. We never read the whole file into memory; on a
	// 300-site host with a multi-MiB signal file this caps both I/O and allocation.
	var start int64
	if lim.maxBytes > 0 && size > lim.maxBytes {
		start = size - lim.maxBytes
		st.TruncatedTail = true
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return st
	}
	reader := bufio.NewReader(f)
	if start > 0 {
		// We seeked into the middle of a line; drop the first partial line.
		if _, err := reader.ReadString('\n'); err != nil {
			return st // tail had no complete line
		}
	}

	// Effective deadline: the smaller of the caller's context and our own budget.
	runCtx := ctx
	if runCtx == nil {
		runCtx = context.Background()
	}
	if lim.budget > 0 {
		var cancel context.CancelFunc
		runCtx, cancel = context.WithTimeout(runCtx, lim.budget)
		defer cancel()
	}

	now := lim.now
	if now == nil {
		now = time.Now
	}
	var cutoff int64
	if lim.maxAge > 0 {
		cutoff = now().Add(-lim.maxAge).Unix()
	}

	scanner := bufio.NewScanner(reader)
	if lim.maxLineSize > 0 {
		scanner.Buffer(make([]byte, 0, 64<<10), lim.maxLineSize)
	}

	st.Stopped = "eof"
	for scanner.Scan() {
		if runCtx.Err() != nil {
			st.Stopped = "timeout"
			break
		}
		if lim.maxLines > 0 && st.LinesScanned >= lim.maxLines {
			st.Stopped = "max_lines"
			break
		}
		line := scanner.Bytes()
		st.LinesScanned++
		st.BytesRead += int64(len(line)) + 1
		if len(line) == 0 {
			continue
		}

		var sig BatchSignal
		if err := json.Unmarshal(line, &sig); err != nil || sig.IP == "" {
			st.SkippedMalformed++
			continue
		}
		if cutoff > 0 && sig.TS != 0 && sig.TS < cutoff {
			st.SkippedOld++ // too old → ignore (TTL no longer relevant)
			continue
		}
		ip, err := netip.ParseAddr(sig.IP)
		if err != nil {
			st.SkippedMalformed++
			continue
		}

		// Cache-only transition (same path as live observation). NEVER enforces, never durable.
		m.recordDecisionTransition(&sig, ip)
		st.Accepted++
		if lim.maxAccepted > 0 && st.Accepted >= lim.maxAccepted {
			st.Stopped = "max_accepted"
			break
		}
	}
	if err := scanner.Err(); err != nil && st.Stopped == "eof" {
		st.Stopped = "scan_error"
	}
	return st
}
