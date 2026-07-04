// =============================================================================
// NFTBan v1.212.0 - BotScan lost-ban-signal hand-off (flock-guarded rename-then-consume) tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Prove the v1.212 fix for OPEN_BOTSCAN_LOST_BAN_SIGNAL — the consumer no longer
//          truncates a LIVE file (which destroyed any signal appended in the read->truncate
//          window). Instead it flock-guards an ATOMIC rename of the live signal file to a private
//          `.consuming` hand-off, processes that OUTSIDE the lock, and removes it on success. An
//          append is therefore either in the renamed file (processed now) or in a fresh file
//          (processed next cycle) — never lost. A crashed hand-off (stale `.consuming`) is
//          recovered + counted; lock/rename/remove failures increment BatchHandoffErrors so health
//          can WARN/DEGRADE instead of a false PROTECTED. Bounded-tail/age quarantine, malformed
//          handling and idempotent apply are unchanged.
//
// meta:name="botguard_guard_lost_signal_v212_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-01"
// meta:description="Tests for the v1.212 flock-guarded rename-then-consume BotScan signal hand-off (zero-loss + stale-recovery + hand-off counters)"
// meta:inventory.files="guard_lost_signal_v212_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// freshBanLine builds one BotScan ban JSONL line with a current timestamp (passes the age cutoff).
func freshBanLine(ip string) string {
	return fmt.Sprintf(`{"ip":%q,"score":80,"action":"ban","request_class":"scanner","family":"ipv4","ts":%d,"reasons":["scanner"]}`+"\n",
		ip, time.Now().Unix())
}

// appendLine appends a raw line to a file (models the shell producer's O_APPEND write).
func appendLine(t *testing.T, path, line string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatalf("append open %s: %v", path, err)
	}
	if _, err := f.WriteString(line); err != nil {
		t.Fatalf("append write %s: %v", path, err)
	}
	_ = f.Close()
}

// newDisabledConsumer wires an enforcing module in the BotGuard-DISABLED consumer mode and points
// BatchSignalFile at a fresh temp path.
func newDisabledConsumer(t *testing.T) (*Module, *recBackend, string) {
	t.Helper()
	m, b := newEnforcingModule(t)
	m.config.Enabled = false
	qf := filepath.Join(t.TempDir(), "batch_signals.jsonl")
	m.config.BatchSignalFile = qf
	return m, b, qf
}

// TestV212_APPEND_BEFORE_RENAME_PROCESSED — a signal appended before the hand-off is captured in the
// renamed file and applied (the ordinary path).
func TestV212_APPEND_BEFORE_RENAME_PROCESSED(t *testing.T) {
	m, b, qf := newDisabledConsumer(t)
	const ip = "45.140.17.10"
	appendLine(t, qf, freshBanLine(ip))

	m.processBatchSignals()

	if !waitBanned(b, "blacklist_manual_ipv4", ip) {
		t.Fatalf("signal appended before rename must be applied; sets=%v", b.adds)
	}
	// live file renamed+consumed → neither the live nor the .consuming file should remain.
	if _, err := os.Stat(qf); !os.IsNotExist(err) {
		t.Fatalf("live signal file must not remain after consume (err=%v)", err)
	}
	if _, err := os.Stat(qf + ".consuming"); !os.IsNotExist(err) {
		t.Fatalf(".consuming must be removed after a successful drain (err=%v)", err)
	}
}

// TestV212_FORCED_INTERLEAVE_ZERO_LOSS — the core proof: a producer that appends BETWEEN the
// consumer's rename and its processing writes into a FRESH file and is applied next cycle; the
// signal captured by the rename is applied now. Nothing is lost. (Pre-v1.212 the truncate of the
// live file destroyed the interleaved append.)
func TestV212_FORCED_INTERLEAVE_ZERO_LOSS(t *testing.T) {
	m, b, qf := newDisabledConsumer(t)
	const ipEarly = "45.140.17.21" // appended before the rename → captured in .consuming
	const ipRace = "45.140.17.22"  // appended AFTER the rename, before processing → fresh file

	appendLine(t, qf, freshBanLine(ipEarly))

	// Step A — take the hand-off exactly as the consumer does (flock + atomic rename).
	consuming := qf + ".consuming"
	renamed, err := m.renameSignalForConsume(qf, consuming)
	if err != nil || !renamed {
		t.Fatalf("rename hand-off should succeed: renamed=%v err=%v", renamed, err)
	}

	// Step B — INTERLEAVE: a producer appends AFTER the rename. It lands in a brand-new live file,
	// NOT in the renamed .consuming the consumer is about to read.
	appendLine(t, qf, freshBanLine(ipRace))

	// Step C — consume the captured file (outside the lock). Only ipEarly is here.
	if perr := m.consumeSignalFile(consuming); perr != nil {
		t.Fatalf("consume captured file: %v", perr)
	}
	if !waitBanned(b, "blacklist_manual_ipv4", ipEarly) {
		t.Fatalf("early signal must be applied from the captured file; sets=%v", b.adds)
	}

	// Step D — the interleaved signal survives in the fresh file and is applied next cycle.
	m.processBatchSignals()
	if !waitBanned(b, "blacklist_manual_ipv4", ipRace) {
		t.Fatalf("ZERO-LOSS VIOLATED: signal appended after the rename was lost; sets=%v", b.adds)
	}
}

// TestV212_STALE_CONSUMING_RECOVERED — a `.consuming` left by a prior crash (rename done, processing
// not) is processed FIRST and counted, never orphaned.
func TestV212_STALE_CONSUMING_RECOVERED(t *testing.T) {
	m, b, qf := newDisabledConsumer(t)
	const ip = "45.140.17.33"
	// Simulate crash residue: a populated .consuming with NO live signal file.
	consuming := qf + ".consuming"
	if err := os.WriteFile(consuming, []byte(freshBanLine(ip)), 0o600); err != nil {
		t.Fatalf("seed stale .consuming: %v", err)
	}

	m.processBatchSignals()

	if !waitBanned(b, "blacklist_manual_ipv4", ip) {
		t.Fatalf("stale .consuming signal must be recovered+applied; sets=%v", b.adds)
	}
	if m.stats.BatchStaleConsumingRecovered != 1 {
		t.Fatalf("BatchStaleConsumingRecovered = %d, want 1", m.stats.BatchStaleConsumingRecovered)
	}
	if _, err := os.Stat(consuming); !os.IsNotExist(err) {
		t.Fatalf("stale .consuming must be removed after recovery (err=%v)", err)
	}
	if m.stats.BatchHandoffErrors != 0 {
		t.Fatalf("clean recovery must not count a hand-off error, got %d", m.stats.BatchHandoffErrors)
	}
}

// TestV212_HANDOFF_ERROR_COUNTED_AND_DEGRADABLE — a lock/rename failure increments BatchHandoffErrors
// (so health can WARN/DEGRADE) and does NOT consume/destroy the live file. Forced by making the
// sibling lockfile path un-openable (a directory sits where the lockfile must be created).
func TestV212_HANDOFF_ERROR_COUNTED_AND_DEGRADABLE(t *testing.T) {
	m, _, qf := newDisabledConsumer(t)
	const ip = "45.140.17.44"
	appendLine(t, qf, freshBanLine(ip))

	// Make signalFile+".lock" un-openable: create a DIRECTORY at that exact path.
	if err := os.Mkdir(qf+".lock", 0o755); err != nil {
		t.Fatalf("seed lock-path directory: %v", err)
	}

	m.processBatchSignals()

	if m.stats.BatchHandoffErrors != 1 {
		t.Fatalf("BatchHandoffErrors = %d, want 1 (lock/rename failure must be visible to health)",
			m.stats.BatchHandoffErrors)
	}
	// The live signal must NOT be destroyed by a broken hand-off — it stays for a later cycle.
	if _, err := os.Stat(qf); err != nil {
		t.Fatalf("live signal file must survive a broken hand-off, got err=%v", err)
	}
	// Health-degradability contract: a nonzero counter is surfaced in the typed status Extra.
	ex := BotGuardStatusExtra{BatchHandoffErrors: m.stats.BatchHandoffErrors}.ToExtraInfo()
	if v, ok := ex["batch_handoff_errors"].(int64); !ok || v != 1 {
		t.Fatalf("batch_handoff_errors not surfaced in status Extra: %v", ex["batch_handoff_errors"])
	}
}

// TestV212_MALFORMED_AND_EXPIRED_UNCHANGED — malformed lines are counted+skipped and stale (past the
// age cutoff) signals are quarantined (counted, never applied), exactly as before.
func TestV212_MALFORMED_AND_EXPIRED_UNCHANGED(t *testing.T) {
	m, b, qf := newDisabledConsumer(t)
	const freshIP = "45.141.84.11"
	const staleIP = "45.141.84.21"
	staleTS := time.Now().Add(-10 * 24 * time.Hour).Unix() // 10 days old → well past the 45m cutoff

	lines := freshBanLine(freshIP) +
		fmt.Sprintf(`{"ip":%q,"score":80,"action":"ban","request_class":"scanner","family":"ipv4","ts":%d,"reasons":["scanner"]}`+"\n", staleIP, staleTS) +
		"this is a malformed line\n"
	if err := os.WriteFile(qf, []byte(lines), 0o600); err != nil {
		t.Fatalf("write queue: %v", err)
	}

	m.processBatchSignals()

	if !waitBanned(b, "blacklist_manual_ipv4", freshIP) {
		t.Fatalf("fresh signal must be applied; sets=%v", b.adds)
	}
	if b.has("blacklist_manual_ipv4", staleIP) {
		t.Fatalf("stale signal must be quarantined, never applied; sets=%v", b.adds)
	}
	if m.stats.BatchSignalsExpired < 1 {
		t.Fatalf("expected >=1 expired, got %d", m.stats.BatchSignalsExpired)
	}
	if m.stats.BatchSignalsMalformed < 1 {
		t.Fatalf("expected >=1 malformed, got %d", m.stats.BatchSignalsMalformed)
	}
}

// TestV212_DUPLICATE_IDEMPOTENT — the same IP delivered across two cycles stays banned (idempotent
// apply, same blacklist_manual element; no error/panic).
func TestV212_DUPLICATE_IDEMPOTENT(t *testing.T) {
	m, b, qf := newDisabledConsumer(t)
	const ip = "45.141.84.55"

	appendLine(t, qf, freshBanLine(ip))
	m.processBatchSignals()
	if !waitBanned(b, "blacklist_manual_ipv4", ip) {
		t.Fatalf("first cycle must ban %s; sets=%v", ip, b.adds)
	}

	appendLine(t, qf, freshBanLine(ip)) // same IP again next cycle
	m.processBatchSignals()
	if !b.has("blacklist_manual_ipv4", ip) {
		t.Fatalf("duplicate apply must keep %s banned; sets=%v", ip, b.adds)
	}
}

// TestV212_BOUNDED_TAIL_PRESERVED — a signal file larger than WarmupMaxBytes reads only the bounded
// TAIL; the stale head beyond the window is quarantined (flagged), and the file does not grow
// unbounded (it is consumed away each cycle).
func TestV212_BOUNDED_TAIL_PRESERVED(t *testing.T) {
	m, b, qf := newDisabledConsumer(t)
	m.config.WarmupMaxBytes = 512 // tiny window forces a bounded tail read

	var sb strings.Builder
	// Head: many fresh-but-old-position lines that overflow the window (must be quarantined as head).
	for i := 0; i < 200; i++ {
		sb.WriteString(freshBanLine(fmt.Sprintf("203.0.113.%d", i%254+1)))
	}
	const tailIP = "45.141.84.99"
	sb.WriteString(freshBanLine(tailIP)) // newest line at the very end → inside the tail window
	if err := os.WriteFile(qf, []byte(sb.String()), 0o600); err != nil {
		t.Fatalf("write big queue: %v", err)
	}
	sizeBefore, _ := os.Stat(qf)

	m.processBatchSignals()

	if !waitBanned(b, "blacklist_manual_ipv4", tailIP) {
		t.Fatalf("newest (tail) signal must be applied; sets=%v", b.adds)
	}
	if !m.stats.BatchConsumerStaleBacklog {
		t.Fatalf("head beyond the tail window must flag BatchConsumerStaleBacklog")
	}
	// No unbounded growth: the live file is renamed+removed, never left to accumulate.
	if _, err := os.Stat(qf); !os.IsNotExist(err) {
		t.Fatalf("consumed live file must not remain (no unbounded growth); sizeBefore=%v", sizeBefore)
	}
}

// TestV212_NO_LIVE_FILE_TRUNCATE_IN_SOURCE — regression guard: the consumer path must NOT reintroduce
// the truncate-of-a-live-file (os.WriteFile(signalFile, nil, ...)) and MUST hand off via os.Rename.
func TestV212_NO_LIVE_FILE_TRUNCATE_IN_SOURCE(t *testing.T) {
	src, err := os.ReadFile("guard.go")
	if err != nil {
		t.Fatalf("read guard.go: %v", err)
	}
	s := string(src)
	if strings.Contains(s, "os.WriteFile(signalFile, nil") {
		t.Fatal("REGRESSION: os.WriteFile(signalFile, nil ...) truncate-of-live-file reintroduced in the batch consumer path")
	}
	if !strings.Contains(s, "os.Rename(signalFile, consumingFile)") {
		t.Fatal("consumer must hand off via os.Rename(signalFile, consumingFile)")
	}
	if !strings.Contains(s, "syscall.Flock(") {
		t.Fatal("consumer hand-off must be flock-guarded (syscall.Flock)")
	}
}
