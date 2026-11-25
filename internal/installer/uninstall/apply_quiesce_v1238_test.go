// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package uninstall

// v1.238 (audit KERNEL_WRITER_AUDIT_d016f838 V2): before the nftban tables are flushed/deleted,
// the uninstall stops and masks nftband.socket and the table-touching timers, so nothing
// re-activates the daemon or recreates the tables mid-release. Emergency SSH stays first/last.

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func cmdIndex(cmds []executor.RecordedCommand, name string, prefix ...string) int {
	for i, c := range cmds {
		if c.Name != name || len(c.Args) < len(prefix) {
			continue
		}
		match := true
		for j, p := range prefix {
			if c.Args[j] != p {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

func TestApplyQuiescesTableWritersBeforeFlush(t *testing.T) {
	m := executor.NewMockExecutor()
	seedAuthoritativeHost(m)
	for _, u := range TableWriterUnits {
		m.Services[u] = true
	}
	r := Apply(m, &ApplyConfig{SSHPort: 22}, newTestLogger())
	if r.State != "UNINSTALL_RELEASED" {
		t.Fatalf("State = %q (%s)", r.State, r.Reason)
	}
	flush := cmdIndex(m.Commands, "nft", "flush", "table", "ip", "nftban")
	if flush < 0 {
		t.Fatal("no flush of ip nftban recorded")
	}
	for _, u := range TableWriterUnits {
		stop := cmdIndex(m.Commands, "systemctl", "stop", u)
		mask := cmdIndex(m.Commands, "systemctl", "mask", u)
		if stop < 0 || mask < 0 {
			t.Errorf("%s: stop=%d mask=%d, want both recorded", u, stop, mask)
			continue
		}
		if !(stop < mask && mask < flush) {
			t.Errorf("%s: order stop=%d mask=%d flush=%d, want stop < mask < flush", u, stop, mask, flush)
		}
	}
	if svc := cmdIndex(m.Commands, "systemctl", "stop", "nftband.service"); svc < 0 || svc > flush {
		t.Errorf("nftband.service stop=%d not before flush=%d", svc, flush)
	}
	if r.Steps[0].Name != "inject_emergency_ssh" || r.Steps[len(r.Steps)-1].Name != "remove_emergency_ssh" {
		t.Errorf("emergency SSH must stay first/last: first=%s last=%s", r.Steps[0].Name, r.Steps[len(r.Steps)-1].Name)
	}
}

func TestApplyQuiesceInactiveUnitsMaskedNotStopped(t *testing.T) {
	m := executor.NewMockExecutor()
	seedAuthoritativeHost(m)
	r := Apply(m, &ApplyConfig{SSHPort: 22}, newTestLogger())
	flush := cmdIndex(m.Commands, "nft", "flush", "table", "ip", "nftban")
	for _, u := range TableWriterUnits {
		// (later artifact-removal steps may stop units; only the pre-flush quiesce is checked)
		if stop := cmdIndex(m.Commands, "systemctl", "stop", u); stop >= 0 && stop < flush {
			t.Errorf("%s: stopped before the flush although inactive", u)
		}
		if mask := cmdIndex(m.Commands, "systemctl", "mask", u); mask < 0 || mask > flush {
			t.Errorf("%s: not masked before the flush (mask=%d flush=%d)", u, mask, flush)
		}
	}
	for _, s := range r.Steps {
		if s.Name == "quiesce_table_writers" && !s.Success {
			t.Errorf("quiesce step failed: %s", s.Detail)
		}
	}
}

func TestTableWriterUnitsNamesSocketAndTimers(t *testing.T) {
	got := strings.Join(TableWriterUnits, ",")
	for _, want := range []string{"nftband.socket", "nftban-rebuild-recovery.timer", "nftban-maintenance.timer"} {
		if !strings.Contains(got, want) {
			t.Errorf("TableWriterUnits lacks %s: %s", want, got)
		}
	}
}
