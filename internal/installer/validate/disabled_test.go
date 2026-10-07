// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package validate

import (
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/services"
)

// v1.235 row 486: the DISABLED invariants a disabled/bypassed install is
// validated on (instead of runtime health).

func newDisLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New(filepath.Join(t.TempDir(), "installer.log"), false)
}

const projPath = "/etc/nftban/generated/nftban-boot.nft"

func TestAssertProjectionInert(t *testing.T) {
	log := newDisLogger(t)
	m := executor.NewMockExecutor()
	m.Files[projPath] = []byte("#!/usr/sbin/nft -f\n# NFTBAN GENERATED BOOT PROJECTION\n" + BootProjectionInertMarker + "\n")
	if r := assertProjectionInert(m, log, projPath); !r.Passed {
		t.Fatalf("inert projection must pass: %+v", r)
	}
	m.Files[projPath] = []byte("#!/usr/sbin/nft -f\ntable ip nftban {\n}\n")
	if r := assertProjectionInert(m, log, projPath); r.Passed {
		t.Fatal("an ACTIVE projection must FAIL while disabled (NFTBan would load at boot)")
	}
	// marker only as a substring (commented differently) is not the marker
	m.Files[projPath] = []byte("#  # NFTBAN-PROJECTION-STATE: inert\n")
	if r := assertProjectionInert(m, log, projPath); r.Passed {
		t.Fatal("only the exact marker line counts")
	}
	delete(m.Files, projPath)
	if r := assertProjectionInert(m, log, projPath); r.Passed {
		t.Fatal("an unreadable projection must FAIL, never pass")
	}
}

func TestAssertNoNftbanUnitEnabled(t *testing.T) {
	log := newDisLogger(t)
	key := "systemctl:list-unit-files:--no-legend:--plain:nftban*:nftband*"

	m := executor.NewMockExecutor()
	m.RunResults[key] = executor.Result{ExitCode: 0, Stdout: "nftband.service disabled enabled\n" +
		"nftban-boot-bypass.service enabled enabled\nnftban-boot-normal.service enabled enabled\n" +
		"nftban-maintenance.timer disabled enabled\nnftban-alert@.service static -\n"}
	if r := assertNoNftbanUnitEnabled(m, log); !r.Passed {
		t.Fatalf("only boot guards enabled must pass: %+v", r)
	}

	m.RunResults[key] = executor.Result{ExitCode: 0, Stdout: "nftband.service enabled enabled\nnftban-watchdog.timer enabled enabled\n"}
	r := assertNoNftbanUnitEnabled(m, log)
	if r.Passed {
		t.Fatal("an enabled NFTBan unit while disabled must FAIL")
	}
	if r.Detail == "" {
		t.Fatal("the failure must name the enabled units")
	}

	m.RunResults[key] = executor.Result{ExitCode: 1, Stderr: "boom"}
	if r := assertNoNftbanUnitEnabled(m, log); r.Passed {
		t.Fatal("an unreadable unit list must FAIL, never pass")
	}
}

func TestAssertNoNftbanTablesUnderBypass(t *testing.T) {
	log := newDisLogger(t)
	m := executor.NewMockExecutor()
	if r := assertNoNftbanTablesUnderBypass(m, log); !r.Passed {
		t.Fatalf("no NFTBan table must pass: %+v", r)
	}
	m.NftTables["ip6:nftban"] = true
	if r := assertNoNftbanTablesUnderBypass(m, log); r.Passed {
		t.Fatal("a loaded NFTBan table during a bypass boot must FAIL")
	}
}

func TestAssertBootGuardsEnabled(t *testing.T) {
	log := newDisLogger(t)
	m := executor.NewMockExecutor()
	for _, u := range services.BootGuardUnits {
		m.Files["/usr/lib/systemd/system/"+u] = []byte("[Unit]\n")
		m.ServicesEnabled[u] = true
	}
	if r := assertBootGuardsEnabled(m, log); !r.Passed {
		t.Fatalf("all guards installed+enabled must pass: %+v", r)
	}
	m.ServicesEnabled["nftban-boot-bypass.service"] = false
	if r := assertBootGuardsEnabled(m, log); r.Passed {
		t.Fatal("a disabled bypass unit must FAIL (the emergency bypass would not act)")
	}
	delete(m.Files, "/usr/lib/systemd/system/nftban-boot-normal.service")
	m.ServicesEnabled["nftban-boot-bypass.service"] = true
	if r := assertBootGuardsEnabled(m, log); r.Passed {
		t.Fatal("a missing guard unit must FAIL")
	}
}

func TestRunDisabledAssertionsSelectsModeSet(t *testing.T) {
	log := newDisLogger(t)
	m := executor.NewMockExecutor()
	empty := SystemdPayloadInputs{}
	names := func(rs []AssertionResult) map[string]bool {
		out := map[string]bool{}
		for _, r := range rs {
			out[r.Name] = true
		}
		return out
	}
	opts := AssertionOpts{SystemdPayloadInputs: &empty}
	stored := names(RunDisabledAssertions(m, log, ModeStoredDisabled, projPath, opts))
	bypass := names(RunDisabledAssertions(m, log, ModeEmergencyBypass, projPath, opts))
	for _, want := range []string{"boot_guards_enabled", "boot_projection_inert"} {
		if !stored[want] || !bypass[want] {
			t.Errorf("%s must be asserted in both modes", want)
		}
	}
	if !stored["nftban_units_not_enabled_while_disabled"] || stored["no_nftban_tables_under_bypass"] {
		t.Error("stored-disabled mode must check unit enablement, not bypass tables")
	}
	if !bypass["no_nftban_tables_under_bypass"] || bypass["nftban_units_not_enabled_while_disabled"] {
		t.Error("bypass mode must check loaded tables, not unit enablement (the operator's units stay as chosen)")
	}
	for _, runtime := range []string{"nftban_table_ip", "daemon_active", "ssh_in_set"} {
		if stored[runtime] || bypass[runtime] {
			t.Errorf("runtime-health assertion %s must not run for a disabled/bypassed install", runtime)
		}
	}
}
