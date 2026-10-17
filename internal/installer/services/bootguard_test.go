// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package services

import (
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/internal/configloader"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// v1.235 row 486: installer boot guards + lifecycle-mode facts.

func newBGLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New(filepath.Join(t.TempDir(), "installer.log"), false)
}

func TestMasterSwitchState(t *testing.T) {
	cases := []struct {
		name      string
		main      string // "" = file absent
		local     string // "" = file absent
		want      configloader.SwitchState
		wantKnown bool
	}{
		{"both absent → enabled (default)", "", "", configloader.SwitchOn, true},
		{"main true", "NFTBAN_ENABLED=true\n", "", configloader.SwitchOn, true},
		{"main false", "NFTBAN_ENABLED=false\n", "", configloader.SwitchOff, true},
		{"local false overrides main true", "NFTBAN_ENABLED=true\n", "NFTBAN_ENABLED=\"false\"\n", configloader.SwitchOff, true},
		{"local true overrides main false", "NFTBAN_ENABLED=false\n", "NFTBAN_ENABLED='true'\n", configloader.SwitchOn, true},
		{"last value in a file wins", "NFTBAN_ENABLED=true\nNFTBAN_ENABLED=false\n", "", configloader.SwitchOff, true},
		{"other keys ignored", "NFTBAN_ENABLED_X=false\n# NFTBAN_ENABLED=false\n", "", configloader.SwitchOn, true},
		// v1.235 K2: one contract with the shell; a declared value that is neither on nor off is
		// INVALID (it was "on" here and "off"/"on" elsewhere before).
		{"K2 yes = on", "NFTBAN_ENABLED=yes\n", "", configloader.SwitchOn, true},
		{"K2 OFF = off", "NFTBAN_ENABLED=OFF\n", "", configloader.SwitchOff, true},
		{"K2 empty = invalid", "NFTBAN_ENABLED=\n", "", configloader.SwitchInvalid, true},
		{"K2 typo = invalid", "NFTBAN_ENABLED=flase\n", "", configloader.SwitchInvalid, true},
		{"K2 local invalid overrides main true", "NFTBAN_ENABLED=true\n", "NFTBAN_ENABLED=maybe\n", configloader.SwitchInvalid, true},
		// K2-c: present but unreadable = UNKNOWN, and it wins over a readable "true".
		{"K2-c local unreadable = unknown (not on)", "NFTBAN_ENABLED=true\n", "<UNREADABLE>", configloader.SwitchUnknown, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := executor.NewMockExecutor()
			if c.main != "" {
				m.Files["/etc/nftban/conf.d/services.conf"] = []byte(c.main)
			}
			if c.local == "<UNREADABLE>" {
				m.Dirs["/etc/nftban/conf.d/services.conf.local"] = true // exists; ReadFile fails
			} else if c.local != "" {
				m.Files["/etc/nftban/conf.d/services.conf.local"] = []byte(c.local)
			}
			st, _, _, known := MasterSwitchState(m, "/etc/nftban")
			if st != c.want || known != c.wantKnown {
				t.Fatalf("MasterSwitchState = (%v,%v), want (%v,%v)", st, known, c.want, c.wantKnown)
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
