// =============================================================================
// NFTBan v1.234.0 - BotScan requested vs effective ban duration (visibility) tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// Package: botguard
// Purpose: The standalone BotScan consumer KEEPS its established grey/ban mapping
//          (3600 s / 86400 s) and makes the rule's requested duration (signal field
//          requested_ttl_sec) visible beside the effective one: decoded, rendered for the
//          ban log line, and written to the per-ban evidence record.
//
// meta:name="botguard_botscan_signal_ttl_v1234_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-30"
// meta:description="BotScan batch-signal requested_ttl_sec is decoded and recorded beside the unchanged effective TTL (grey 3600 / ban 86400) end to end: decode -> applyBotscanBanSignal -> OpQueue SetElement.TTL + evidence record"
// meta:inventory.files="botscan_signal_ttl_v1234_test.go"
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
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/opqueue"
)

// The established mapping is preserved whatever the producer requests.
func TestBotscanSignalTTL_MappingPreserved(t *testing.T) {
	cases := []struct {
		action    string
		requested int64
		want      uint32
	}{
		{"grey", 1800, 3600},
		{"grey", 0, 3600},
		{"ban", 3600, 86400},
		{"ban", 7200, 86400},
		{"ban", 0, 86400},
	}
	for _, c := range cases {
		got := botscanSignalTTL(&BatchSignal{IP: "45.33.32.1", Action: c.action, RequestedTTLSec: c.requested})
		if got != c.want {
			t.Errorf("action=%s requested=%d: effective %d, want %d (mapping must not change)", c.action, c.requested, got, c.want)
		}
	}
	if got := botscanSignalTTL(nil); got != botscanManualBanTTLSec {
		t.Errorf("nil signal: got %d, want %d", got, botscanManualBanTTLSec)
	}
}

func TestBotscanRequestedTTLText(t *testing.T) {
	if got := botscanRequestedTTLText(&BatchSignal{RequestedTTLSec: 1800}); got != "1800s" {
		t.Errorf("requested 1800: got %q", got)
	}
	if got := botscanRequestedTTLText(&BatchSignal{}); got != "unknown" {
		t.Errorf("older producer: got %q, want unknown (never a fabricated value)", got)
	}
	if got := botscanRequestedTTLText(nil); got != "unknown" {
		t.Errorf("nil: got %q", got)
	}
}

// The exact line shape nftban_botscan_write_signal emits must decode requested_ttl_sec.
func TestBotscanSignalTTL_DecodesShellLine(t *testing.T) {
	line := `{"ip":"45.33.32.61","score":50,"reasons":["botscan","Matched patterns:  EXP_WPREST (hits: 6)"],"action":"grey","ts":1790762400,"family":"ipv4","request_class":"scanner","requested_ttl_sec":1800}`
	var s BatchSignal
	if err := json.Unmarshal([]byte(line), &s); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if s.RequestedTTLSec != 1800 {
		t.Fatalf("requested_ttl_sec not decoded: %d", s.RequestedTTLSec)
	}
	old := `{"ip":"45.33.32.61","score":50,"reasons":["botscan"],"action":"grey","ts":1790762400}`
	var o BatchSignal
	if err := json.Unmarshal([]byte(old), &o); err != nil {
		t.Fatalf("decode legacy: %v", err)
	}
	if o.RequestedTTLSec != 0 || botscanSignalTTL(&o) != botscanManualGreyTTLSec {
		t.Fatalf("legacy line: requested=%d effective=%d", o.RequestedTTLSec, botscanSignalTTL(&o))
	}
}

// ttlBackend records the TTL of every element the OpQueue applies.
type ttlBackend struct {
	mu  sync.Mutex
	ttl map[string]uint32 // set|ip -> TTL
}

func (b *ttlBackend) FlushSet(string, string) error { return nil }
func (b *ttlBackend) AddElements(_ string, set string, els []opqueue.SetElement) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, e := range els {
		b.ttl[set+"|"+e.Value] = e.TTL
	}
	return len(els), nil
}
func (b *ttlBackend) DeleteElements(string, string, []opqueue.SetElement) error { return nil }
func (b *ttlBackend) GetSetElements(string, string) ([]string, error)           { return nil, nil }
func (b *ttlBackend) ReplaceSet(string, string, []opqueue.SetElement) error     { return nil }
func (b *ttlBackend) get(set, ip string) (uint32, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	v, ok := b.ttl[set+"|"+ip]
	return v, ok
}

// End to end on the reached path: applyBotscanBanSignal -> OpQueue -> backend SetElement.TTL
// (effective = the unchanged mapping) and the evidence record (requested beside effective).
func TestBotscanSignalTTL_EffectiveAndRequestedRecorded(t *testing.T) {
	b := &ttlBackend{ttl: map[string]uint32{}}
	qcfg := opqueue.DefaultQueueConfig()
	qcfg.FlushThreshold = 1
	qcfg.FlushInterval = 5 * time.Millisecond
	q := opqueue.NewOpQueue(b, qcfg)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	q.Start(ctx)
	m := New()
	m.bus = eventbus.New()
	m.InitEnforcer(q)
	m.config.Enabled = false
	dir := t.TempDir()
	m.config.BatchSignalFile = filepath.Join(dir, "batch_signals.jsonl")

	cases := []struct {
		ip, action string
		requested  int64
		want       uint32
	}{
		{"45.33.32.61", "grey", 1800, 3600},
		{"45.33.32.62", "ban", 3600, 86400},
		{"45.33.32.63", "grey", 0, 3600},
	}
	for _, c := range cases {
		s := freshSig(c.ip, "scanner", c.action)
		s.RequestedTTLSec = c.requested
		if !m.applyBotscanBanSignal(s) {
			t.Fatalf("%s: signal not enqueued", c.ip)
		}
	}
	deadline := time.Now().Add(2 * time.Second)
	for _, c := range cases {
		var got uint32
		var ok bool
		for time.Now().Before(deadline) {
			if got, ok = b.get("blacklist_manual_ipv4", c.ip); ok {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if !ok {
			t.Fatalf("%s: never applied to blacklist_manual_ipv4", c.ip)
		}
		if got != c.want {
			t.Errorf("%s: enforced TTL %d, want %d (mapping must not change)", c.ip, got, c.want)
		}
	}

	f, err := os.Open(filepath.Join(dir, botscanBanEvidenceName))
	if err != nil {
		t.Fatalf("evidence record not written: %v", err)
	}
	defer f.Close()
	seen := map[string][2]int64{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var r struct {
			IP        string `json:"ip"`
			TTL       int64  `json:"ttl_sec"`
			Requested int64  `json:"requested_ttl_sec"`
		}
		if json.Unmarshal(sc.Bytes(), &r) == nil {
			seen[r.IP] = [2]int64{r.Requested, r.TTL}
		}
	}
	for _, c := range cases {
		got, ok := seen[c.ip]
		if !ok {
			t.Fatalf("%s: no evidence record", c.ip)
		}
		if got[0] != c.requested || got[1] != int64(c.want) {
			t.Errorf("%s: evidence requested=%d effective=%d, want requested=%d effective=%d", c.ip, got[0], got[1], c.requested, c.want)
		}
	}
}
