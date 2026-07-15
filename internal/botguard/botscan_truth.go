// =============================================================================
// NFTBan v1.219.0 PR-B - BotScan daemon-truth surfaces (handoff status + ban evidence)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: v1.219.0 PR-B — two durable, bounded artifacts written next to batch_signals.jsonl
//          (DataDir/botguard) so the SHELL operator surfaces can tell the truth about the
//          BotScan consumer without a daemon IPC:
//            botscan_consumer_status.json — hand-off/consumer counters (BatchHandoffErrors,
//              malformed, expired, stale-backlog). Lets `nftban health` render a BROKEN hand-off
//              as WARN/DEGRADED instead of healthy/protected. Atomic snapshot, written via defer
//              on EVERY consumer cycle so an error path is always surfaced.
//            botscan_ban_evidence.jsonl — a per-ban side-record (ts/ip/reason(s)/action/…) that
//              SURVIVES the batch_signals.jsonl consume/delete, so a support operator can still
//              explain WHY an IP was BotScan-banned after the hand-off file is gone.
//          Both are bounded (atomic status snapshot; tail-capped evidence log) and carry no
//          secrets. The matched raw URL/path is NOT in BatchSignal today (shell-producer
//          follow-up); sig.Reasons carries the pattern/why and is recorded verbatim.
//
// meta:name="botguard_botscan_truth"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-09"
// meta:description="v1.219.0 PR-B BotScan daemon-truth surfaces: botscan_consumer_status.json (hand-off counters for shell health) + botscan_ban_evidence.jsonl (durable per-ban side-record surviving batch_signals consume)"
// meta:inventory.files="botscan_truth.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
)

const (
	botscanConsumerStatusName = "botscan_consumer_status.json"
	botscanBanEvidenceName    = "botscan_ban_evidence.jsonl"
	botscanEvidenceMaxBytes   = 512 * 1024 // soft cap; tail-trim to ~half when exceeded (bounded growth)
)

// botscanTruthDir co-locates the truth artifacts with batch_signals.jsonl (DataDir/botguard).
func (m *Module) botscanTruthDir() string {
	if m.config.BatchSignalFile != "" {
		return filepath.Dir(m.config.BatchSignalFile)
	}
	return "/var/lib/nftban/botguard"
}

// writeBotscanConsumerStatus atomically snapshots the consumer/hand-off counters so the shell
// health check can read them cheaply (no daemon IPC). Call via defer on every consumer cycle,
// so a broken hand-off (BatchHandoffErrors) is always surfaced. Never fatal.
func (m *Module) writeBotscanConsumerStatus() {
	dir := m.botscanTruthDir()
	if dir == "" {
		return
	}
	m.mu.RLock()
	rec := map[string]any{
		"ts":                           time.Now().Unix(),
		"batch_consumer_runs":          m.stats.BatchConsumerRuns,
		"batch_signals_processed":      m.stats.BatchSignalsProcessed,
		"batch_signals_applied":        m.stats.BatchSignalsApplied,
		"batch_signals_expired":        m.stats.BatchSignalsExpired,
		"batch_signals_malformed":      m.stats.BatchSignalsMalformed,
		"batch_handoff_errors":         m.stats.BatchHandoffErrors,
		"batch_consumer_stale_backlog": m.stats.BatchConsumerStaleBacklog,
	}
	m.mu.RUnlock()
	b, err := json.Marshal(rec)
	if err != nil {
		return
	}
	b = append(b, '\n')
	// Durable atomic write via the project's fsync-before-rename safety writer (v1.176 idiom).
	_ = safety.SafeWriteFile(filepath.Join(dir, botscanConsumerStatusName), b, 0o600)
}

// appendBotscanEvidence appends a bounded durable evidence record for an ENFORCED BotScan ban.
// This SURVIVES the batch_signals.jsonl consume/delete (separate file), preserving the "why".
// Best-effort: any error is ignored (never blocks a ban). No secrets are recorded.
func (m *Module) appendBotscanEvidence(sig *BatchSignal, setName string, ttlSec uint32) {
	dir := m.botscanTruthDir()
	if dir == "" || sig == nil {
		return
	}
	rec := map[string]any{
		"ts":            time.Now().Unix(),
		"source":        botscanProvenanceSrc, // "botscan" — distinguishes from admin/feed manual bans
		"ip":            sig.IP,
		"action":        sig.Action,
		"family":        sig.ResolvedFamily(),
		"request_class": sig.NormalizedRequestClass(),
		"reasons":       sig.Reasons, // pattern/why: e.g. "wp_probe","404_flood","Matched patterns: …"
		"set":           setName,
		"ttl_sec":       ttlSec,
		"url":           "", // reserved: matched URL/path not in BatchSignal (shell-producer follow-up)
	}
	b, err := json.Marshal(rec)
	if err != nil {
		return
	}
	b = append(b, '\n')
	path := filepath.Join(dir, botscanBanEvidenceName)
	// Bounded growth: tail-trim before appending if the log has grown past the soft cap.
	if fi, serr := os.Stat(path); serr == nil && fi.Size() > botscanEvidenceMaxBytes {
		trimBotscanEvidence(path)
	}
	// Append-only bounded JSONL log; path is internally derived from the trusted config
	// (BatchSignalFile dir), never user input.
	f, err := os.OpenFile(filepath.Clean(path), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600) // #nosec G304 -- path from trusted config (DataDir/botguard)
	if err != nil {
		return
	}
	_, _ = f.Write(b)
	_ = f.Close()
}

// trimBotscanEvidence keeps the most-recent line-aligned tail of the evidence log. Best-effort.
func trimBotscanEvidence(path string) {
	data, err := os.ReadFile(filepath.Clean(path)) // #nosec G304 -- path from trusted config (DataDir/botguard)
	if err != nil {
		return
	}
	keep := botscanEvidenceMaxBytes / 2
	if len(data) <= keep {
		return
	}
	tail := data[len(data)-keep:]
	if i := bytes.IndexByte(tail, '\n'); i >= 0 && i+1 <= len(tail) {
		tail = tail[i+1:] // drop the partial first line so records stay whole
	}
	// Durable atomic replace via the project's fsync-before-rename safety writer (v1.176 idiom).
	_ = safety.SafeWriteFile(path, tail, 0o600)
}
