// SPDX-License-Identifier: MPL-2.0
// meta:name="botscan_truth_v219_test"
// meta:type="test"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-09"
// meta:description="v1.219.0 PR-B BotScan daemon-truth: (1) writeBotscanConsumerStatus surfaces the in-memory hand-off counters (BatchHandoffErrors, stale-backlog) to a cheap-read status file so a broken hand-off can render WARN/DEGRADED instead of healthy; (2) appendBotscanEvidence writes a durable per-ban side-record that SURVIVES the batch_signals.jsonl consume/delete, carrying source=botscan + ip + reason(s); (3) the two surfaces stay wired into processBatchSignals (defer) and applyBotscanBanSignal."
// meta:inventory.files="botscan_truth_v219_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""

package botguard

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBotscanConsumerStatus_SurfacesBrokenHandoff(t *testing.T) {
	dir := t.TempDir()
	bdir := filepath.Join(dir, "botguard")
	if err := os.MkdirAll(bdir, 0o755); err != nil {
		t.Fatal(err)
	}
	m := &Module{config: &Config{BatchSignalFile: filepath.Join(bdir, "batch_signals.jsonl")}}
	m.stats.BatchHandoffErrors = 3
	m.stats.BatchConsumerStaleBacklog = true
	m.stats.BatchSignalsMalformed = 1

	m.writeBotscanConsumerStatus()

	b, err := os.ReadFile(filepath.Join(bdir, "botscan_consumer_status.json"))
	if err != nil {
		t.Fatalf("consumer status not written: %v", err)
	}
	var s map[string]any
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatalf("consumer status not valid JSON: %v", err)
	}
	if s["batch_handoff_errors"].(float64) != 3 {
		t.Fatalf("broken hand-off NOT surfaced to shell truth: %v", s)
	}
	if s["batch_consumer_stale_backlog"] != true {
		t.Fatalf("stale backlog NOT surfaced: %v", s)
	}
}

func TestBotscanEvidence_SurvivesConsume(t *testing.T) {
	dir := t.TempDir()
	bdir := filepath.Join(dir, "botguard")
	if err := os.MkdirAll(bdir, 0o755); err != nil {
		t.Fatal(err)
	}
	m := &Module{config: &Config{BatchSignalFile: filepath.Join(bdir, "batch_signals.jsonl")}}

	// A hand-off file exists, then is consumed (removed) — the evidence must outlive it.
	sigFile := m.config.BatchSignalFile
	if err := os.WriteFile(sigFile, []byte(`{"ip":"203.0.113.9","action":"ban","reasons":["wp_probe"]}`+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	sig := &BatchSignal{IP: "203.0.113.9", Action: "ban", Reasons: []string{"wp_probe", "Matched patterns: EXP_WPREST"}}
	m.appendBotscanEvidence(sig, "blacklist_manual_ipv4", 86400)

	// consume: the batch_signals hand-off file is removed
	if err := os.Remove(sigFile); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(sigFile); !os.IsNotExist(err) {
		t.Fatal("test setup: batch_signals not consumed")
	}

	// evidence must still be there, carrying the WHY
	ev := filepath.Join(bdir, "botscan_ban_evidence.jsonl")
	b, err := os.ReadFile(ev)
	if err != nil {
		t.Fatalf("ban evidence gone after consume: %v", err)
	}
	s := string(b)
	for _, want := range []string{"203.0.113.9", "wp_probe", `"source":"botscan"`, "blacklist_manual_ipv4"} {
		if !strings.Contains(s, want) {
			t.Fatalf("evidence missing %q: %s", want, s)
		}
	}
}

func TestBotscanEvidence_Bounded(t *testing.T) {
	dir := t.TempDir()
	bdir := filepath.Join(dir, "botguard")
	_ = os.MkdirAll(bdir, 0o755)
	m := &Module{config: &Config{BatchSignalFile: filepath.Join(bdir, "batch_signals.jsonl")}}
	ev := filepath.Join(bdir, botscanBanEvidenceName)
	// Pre-seed the evidence log past the soft cap, then append — it must trim (bounded growth).
	big := strings.Repeat(`{"ts":0,"ip":"1.2.3.4"}`+"\n", (botscanEvidenceMaxBytes/24)+100)
	if err := os.WriteFile(ev, []byte(big), 0o640); err != nil {
		t.Fatal(err)
	}
	sig := &BatchSignal{IP: "203.0.113.9", Action: "ban", Reasons: []string{"latest"}}
	m.appendBotscanEvidence(sig, "blacklist_manual_ipv4", 86400)
	fi, err := os.Stat(ev)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Size() > botscanEvidenceMaxBytes {
		t.Fatalf("evidence log unbounded: %d bytes > cap %d", fi.Size(), botscanEvidenceMaxBytes)
	}
	b, _ := os.ReadFile(ev)
	if !strings.Contains(string(b), "203.0.113.9") {
		t.Fatal("newest record lost after trim")
	}
}

func TestBotscanTruth_StaysWired(t *testing.T) {
	src, err := os.ReadFile("guard.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	if !strings.Contains(s, "defer m.writeBotscanConsumerStatus()") {
		t.Fatal("REGRESSION: processBatchSignals no longer publishes consumer hand-off truth")
	}
	if !strings.Contains(s, "m.appendBotscanEvidence(sig") {
		t.Fatal("REGRESSION: applyBotscanBanSignal no longer records durable ban evidence")
	}
}
