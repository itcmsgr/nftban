// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238 BUG-BANS-LOG-LABELS-BOTSCAN-ESCALATION-AS-DDOS (owner 2026-11-24): a BotScan ban must be written
// to bans.log as botscan and a real DDoS ban as ddos. Measured on v1.237.0 (lab2/lab4): a BotScan 404-flood
// signal was enforced correctly but logged with source "ddos".

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/banlog"
)

func TestBanSourceLabelBotScanVsDDoS(t *testing.T) {
	for _, c := range []struct {
		name, source, dataSource, want string
	}{
		// the two events the owner asked for
		{"BotScan signal enforced by the BotGuard module", "botguard", botscanBatchSource, banlog.SourceBotScan},
		{"real DDoS detection", "ddos", "", banlog.SourceDDoS},
		// guards against unintended change
		{"direct BotScan ban over IPC (was manual)", "botscan", "", banlog.SourceBotScan},
		{"realtime BotGuard ban keeps its previous label", "botguard", "", banlog.SourceDDoS},
		{"operator ban stays manual", "manual", "", banlog.SourceManual},
	} {
		if got, _ := banSourceLabel(c.source, c.dataSource); got != c.want {
			t.Errorf("%s: banSourceLabel(%q, %q) = %q, want %q", c.name, c.source, c.dataSource, got, c.want)
		}
	}
	// The BotGuard module tags batch bans with this exact value (internal/botguard/guard.go).
	if botscanBatchSource != "clock3_batch" {
		t.Fatalf("botscanBatchSource drifted from the producer tag: %q", botscanBatchSource)
	}
}
