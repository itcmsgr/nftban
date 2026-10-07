// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package services

import (
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// v1.235 row 486: installer boot guards + lifecycle-mode facts.

func newBGLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New(filepath.Join(t.TempDir(), "installer.log"), false)
}

func TestMasterSwitchOn(t *testing.T) {
	cases := []struct {
		name      string
		main      string // "" = file absent
		local     string // "" = file absent
		wantOn    bool
		wantKnown bool
	}{
		{"both absent → enabled (default)", "", "", true, true},
		{"main true", "NFTBAN_ENABLED=true\n", "", true, true},
		{"main false", "NFTBAN_ENABLED=false\n", "", false, true},
		{"local false overrides main true", "NFTBAN_ENABLED=true\n", "NFTBAN_ENABLED=\"false\"\n", false, true},
		{"local true overrides main false", "NFTBAN_ENABLED=false\n", "NFTBAN_ENABLED='true'\n", true, true},
		{"last value in a file wins", "NFTBAN_ENABLED=true\nNFTBAN_ENABLED=false\n", "", false, true},
		{"other keys ignored", "NFTBAN_ENABLED_X=false\n# NFTBAN_ENABLED=false\n", "", true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := executor.NewMockExecutor()
			if c.main != "" {
				m.Files["/etc/nftban/conf.d/services.conf"] = []byte(c.main)
			}
			if c.local != "" {
				m.Files["/etc/nftban/conf.d/services.conf.local"] = []byte(c.local)
			}
			on, known := MasterSwitchOn(m, "/etc/nftban")
			if on != c.wantOn || known != c.wantKnown {
				t.Fatalf("MasterSwitchOn = (%v,%v), want (%v,%v)", on, known, c.wantOn, c.wantKnown)
			}
		})
	}
}

func TestEmergencyBypassActive(t *testing.T) {
	cases := []struct {
		name    string
		cmdline string // "" = unreadable
		want    bool
	}{
		{"exact word", "BOOT_IMAGE=/vmlinuz root=/dev/vda1 nftban=disabled quiet\n", true},
		{"absent", "BOOT_IMAGE=/vmlinuz root=/dev/vda1 quiet\n", false},
		{"substring is not the word", "xnftban=disabled nftban=disabledx\n", false},
		{"other value", "nftban=enabled\n", false},
		{"unreadable → no bypass claimed", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := executor.NewMockExecutor()
			if c.cmdline != "" {
				m.Files[ProcCmdlinePath] = []byte(c.cmdline)
			}
			if got := EmergencyBypassActive(m); got != c.want {
				t.Fatalf("EmergencyBypassActive = %v, want %v", got, c.want)
			}
		})
	}
}

func TestEnableBootGuards(t *testing.T) {
	m := executor.NewMockExecutor()
	m.Files["/usr/lib/systemd/system/nftban-boot-bypass.service"] = []byte("[Unit]\n")
	m.Files["/lib/systemd/system/nftban-boot-normal.service"] = []byte("[Unit]\n")
	// nftban-boot-bypass-guard.service deliberately NOT installed.
	EnableBootGuards(m, newBGLogger(t))

	if !m.ServicesEnabled["nftban-boot-bypass.service"] || !m.ServicesEnabled["nftban-boot-normal.service"] {
		t.Fatalf("installed boot guards must be enabled: %v", m.ServicesEnabled)
	}
	if m.ServicesEnabled["nftban-boot-bypass-guard.service"] {
		t.Fatal("a boot guard that is not installed must not be enabled")
	}
	for _, u := range BootGuardUnits {
		if m.Services[u] {
			t.Fatalf("boot guard %s was STARTED; the installer must never start them", u)
		}
	}
}

func TestRestartWedgedTimersSkipsRollbackUnits(t *testing.T) {
	for _, u := range []string{"nftban-rollback.timer", "nftban-commit-rollback-20261006T120000Z-4242.timer", "nftban-commit-rollback@abc123.timer", "nftban-commit-rollback@x.service"} {
		if !isRollbackTimer(u) {
			t.Errorf("isRollbackTimer(%q) = false; the installer must never restart it", u)
		}
	}
	for _, u := range []string{"nftban-watchdog.timer", "nftban-maintenance.timer"} {
		if isRollbackTimer(u) {
			t.Errorf("isRollbackTimer(%q) = true; only rollback units are skipped", u)
		}
	}
}
