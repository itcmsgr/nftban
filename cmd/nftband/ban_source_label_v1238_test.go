// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238 BUG-BANS-LOG-LABELS-BOTSCAN-ESCALATION-AS-DDOS (owner 2026-11-24; audit KERNEL_WRITER_AUDIT_d016f838 §0).
// On both BotScan paths the same event is logged as botscan and keeps its class, duration and kernel set:
//   - signal path (production): event subscriber; class/duration come from the timeout and the set from the
//     backend, not from the label — so only the label may change;
//   - direct IPC ban: the handler derives the class from classSource, which must stay what it was (manual).
// Every other label must be exactly what it was before.

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/banlog"
)

func TestBotScanLabelBothPathsOthersUnchanged(t *testing.T) {
	// --- event subscriber (signal path, real DDoS, realtime BotGuard, all other sources) ---
	sub := []struct {
		name, source, dataSource, wantLabel, wantPersist string
	}{
		{"BotScan signal enforced by BotGuard", "botguard", botscanBatchSource, banlog.SourceBotScan, "persistent"},
		{"real DDoS (Go module)", "ddos", "", banlog.SourceDDoS, "ddos"},
		{"realtime BotGuard (unchanged)", "botguard", "", banlog.SourceDDoS, "persistent"},
		// previous behaviour, unchanged
		{"portscan", "portscan", "", banlog.SourcePortscan, "portscan"},
		{"loginmon", "loginmon", "", banlog.SourceLogin, "login"},
		{"feeds", "feeds", "", banlog.SourceFeeds, "persistent"},
		{"suricata", "suricata", "", banlog.SourceSuricata, "persistent"},
		{"unknown source", "something-else", "", banlog.SourceManual, "persistent"},
		{"clock3_batch on a non-botguard source does nothing", "ddos", botscanBatchSource, banlog.SourceDDoS, "ddos"},
	}
	for _, c := range sub {
		l, p := subscriberBanLabel(c.source, c.dataSource)
		if l != c.wantLabel || p != c.wantPersist {
			t.Errorf("subscriber %s: got (%q,%q) want (%q,%q)", c.name, l, p, c.wantLabel, c.wantPersist)
		}
	}

	// --- IPC handler (direct BotScan ban, real DDoS, all other sources) ---
	ipc := []struct {
		name, source, wantClassSource, wantLog string
	}{
		{"direct BotScan ban: class source stays manual, logged as botscan", "botscan", banlog.SourceManual, banlog.SourceBotScan},
		{"real DDoS over IPC", "ddos", banlog.SourceDDoS, banlog.SourceDDoS},
		// previous behaviour, unchanged (class source == log label)
		{"operator ban", "manual", banlog.SourceManual, banlog.SourceManual},
		{"cli", "cli", banlog.SourceManual, banlog.SourceManual},
		{"portscan", "portscan-classic", banlog.SourcePortscan, banlog.SourcePortscan},
		{"login", "login", banlog.SourceLogin, banlog.SourceLogin},
		{"feeds", "feed", banlog.SourceFeeds, banlog.SourceFeeds},
		{"suricata", "suricata", banlog.SourceSuricata, banlog.SourceSuricata},
		{"botguard over IPC (no caller in tree): unchanged manual", "botguard", banlog.SourceManual, banlog.SourceManual},
	}
	for _, c := range ipc {
		cs, ls := ipcBanLabels(c.source)
		if cs != c.wantClassSource || ls != c.wantLog {
			t.Errorf("ipc %s: got (class=%q, log=%q) want (class=%q, log=%q)", c.name, cs, ls, c.wantClassSource, c.wantLog)
		}
	}

	if botscanBatchSource != "clock3_batch" {
		t.Fatalf("botscanBatchSource drifted from the producer tag (internal/botguard/guard.go): %q", botscanBatchSource)
	}
}
