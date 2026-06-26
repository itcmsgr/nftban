// =============================================================================
// NFTBan v1.209.0 - BotScan batch-signal consumer un-gate (Option A) tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Prove the v1.209 fix — when BotGuard classification is DISABLED, BotScan (Clock-3)
//          ban signals are still consumed and routed to the DURABLE, drop-enforced
//          blacklist_manual_{v4,v6} sets (NOT http_bot_ban, which is unenforced when BotGuard
//          is off), with a MANDATORY stale-backlog quarantine (age-cutoff + bounded drain) so a
//          multi-day backlog cannot flood-apply. Browser-like classes stay suppressed; IPv4/IPv6
//          parity; malformed/stale signals are safely discarded.
//
// meta:name="botguard_guard_botscan_consumer_ungate_v209_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-27"
// meta:description="Tests for BotScan batch-signal consumer un-gate routing to blacklist_manual + stale quarantine (v1.209 Option A)"
// meta:inventory.files="guard_botscan_consumer_ungate_v209_test.go"
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
	"testing"
	"time"
)

// freshSig builds a BotScan ban signal with a current timestamp (passes the age cutoff).
func freshSig(ip, class, action string) *BatchSignal {
	s := mkSig(ip, class, action, class)
	s.TS = time.Now().Unix()
	s.Family = ""
	return s
}

// TestBOTSCAN_BAN_ROUTES_TO_BLACKLIST_MANUAL_V4 — a fresh scanner ban (BotGuard disabled) lands
// in blacklist_manual_ipv4 (drop-enforced), NOT http_bot_ban.
func TestBOTSCAN_BAN_ROUTES_TO_BLACKLIST_MANUAL_V4(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.config.Enabled = false
	const ip = "45.140.17.9"
	if !m.applyBotscanBanSignal(freshSig(ip, "scanner", "ban")) {
		t.Fatalf("applyBotscanBanSignal should return true (enqueued) for a scanner ban")
	}
	if !waitBanned(b, "blacklist_manual_ipv4", ip) {
		t.Fatalf("%s must be banned in blacklist_manual_ipv4; sets=%v", ip, b.adds)
	}
	if b.has("http_bot_ban", ip) {
		t.Fatalf("%s must NOT be in http_bot_ban (unenforced when BotGuard disabled)", ip)
	}
}

// TestBOTSCAN_BAN_ROUTES_TO_BLACKLIST_MANUAL_V6 — IPv6 parity.
func TestBOTSCAN_BAN_ROUTES_TO_BLACKLIST_MANUAL_V6(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.config.Enabled = false
	const ip = "2001:db8::dead:beef"
	if !m.applyBotscanBanSignal(freshSig(ip, "scanner", "ban")) {
		t.Fatalf("applyBotscanBanSignal should enqueue an IPv6 scanner ban")
	}
	if !waitBanned(b, "blacklist_manual_ipv6", ip) {
		t.Fatalf("%s must be banned in blacklist_manual_ipv6; sets=%v", ip, b.adds)
	}
}

// TestBOTSCAN_BROWSER_LIKE_SUPPRESSED — a browser/static class ban is suppressed (never enqueued).
func TestBOTSCAN_BROWSER_LIKE_SUPPRESSED(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.config.Enabled = false
	const ip = "203.0.113.77"
	if m.applyBotscanBanSignal(freshSig(ip, "static", "ban")) {
		t.Fatalf("browser-like (static) ban must be suppressed, not enqueued")
	}
	assertNotBanned(t, b, "blacklist_manual_ipv4", ip)
}

// TestBOTSCAN_CONSUMER_STALE_QUARANTINE — processBatchSignals applies only FRESH signals and
// quarantines (expires, never applies) stale ones, even with a mixed queue.
func TestBOTSCAN_CONSUMER_STALE_QUARANTINE(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.config.Enabled = false

	dir := t.TempDir()
	qf := filepath.Join(dir, "batch_signals.jsonl")
	m.config.BatchSignalFile = qf

	const freshIP = "45.141.84.10"
	const staleIP = "45.141.84.20"
	now := time.Now().Unix()
	staleTS := time.Now().Add(-10 * 24 * time.Hour).Unix() // 10 days old → far past the 45m cutoff

	lines := fmt.Sprintf(
		`{"ip":%q,"score":80,"action":"ban","request_class":"scanner","family":"ipv4","ts":%d,"reasons":["scanner"]}`+"\n"+
			`{"ip":%q,"score":80,"action":"ban","request_class":"scanner","family":"ipv4","ts":%d,"reasons":["scanner"]}`+"\n"+
			`this is a malformed line`+"\n",
		freshIP, now, staleIP, staleTS)
	if err := os.WriteFile(qf, []byte(lines), 0o600); err != nil {
		t.Fatalf("write queue: %v", err)
	}

	m.processBatchSignals()

	if !waitBanned(b, "blacklist_manual_ipv4", freshIP) {
		t.Fatalf("fresh signal %s must be applied to blacklist_manual_ipv4; sets=%v", freshIP, b.adds)
	}
	if b.has("blacklist_manual_ipv4", staleIP) {
		t.Fatalf("STALE signal %s must be QUARANTINED, never applied; sets=%v", staleIP, b.adds)
	}
	if m.stats.BatchSignalsExpired < 1 {
		t.Fatalf("expected >=1 expired (stale quarantined), got %d", m.stats.BatchSignalsExpired)
	}
	if m.stats.BatchSignalsMalformed < 1 {
		t.Fatalf("expected >=1 malformed counted, got %d", m.stats.BatchSignalsMalformed)
	}
	if m.stats.BatchConsumerRuns < 1 {
		t.Fatalf("expected consumer-run counted")
	}
	// The queue file must be truncated after a successful drain.
	if fi, err := os.Stat(qf); err == nil && fi.Size() != 0 {
		t.Fatalf("queue file must be truncated after drain, size=%d", fi.Size())
	}
}

// TestBOTSCAN_CONSUMER_EMPTY_AND_MISSING_SAFE — empty/missing queue is a no-op, no panic.
func TestBOTSCAN_CONSUMER_EMPTY_AND_MISSING_SAFE(t *testing.T) {
	m, _ := newEnforcingModule(t)
	m.config.Enabled = false
	m.config.BatchSignalFile = filepath.Join(t.TempDir(), "absent.jsonl")
	m.processBatchSignals() // missing → no-op
	empty := filepath.Join(t.TempDir(), "empty.jsonl")
	_ = os.WriteFile(empty, nil, 0o600)
	m.config.BatchSignalFile = empty
	m.processBatchSignals() // empty → no-op
}
