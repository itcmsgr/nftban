// =============================================================================
// NFTBan - installer boot guards + lifecycle mode (v1.235 row 486)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="bootguard"
// meta:type="package"
// meta:version="1.235.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-06"
// meta:description="Installer side of the v1.235 row-486 contract (CLI_AUDIT_V1235/ROW486_BEHAVIOUR_CONTRACT_V1235.md). EnableBootGuards enables the three early-boot safety units on every install/upgrade/repair, regardless of the master switch or the emergency bypass (they only act at boot). MasterSwitchOn reads the STORED choice (NFTBAN_ENABLED in conf.d/services.conf then services.conf.local, last value wins) exactly like the shell nftban_master_switch_on. EmergencyBypassActive reports the per-boot bypass (exact word nftban=disabled on the kernel command line). The installer uses these to never load rules, start units or enable nftables.service while NFTBan is disabled or bypassed (owner decisions U1, R-DEC, D4)."
// meta:input="/etc/nftban/conf.d/services.conf(.local), /proc/cmdline"
// meta:output="unit enablement of nftban-boot-*.service; lifecycle mode facts"
// meta:depends="executor"
// meta:inventory.files="/etc/nftban/conf.d/services.conf,/etc/nftban/conf.d/services.conf.local,/proc/cmdline"
// meta:inventory.binaries="systemctl"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/services.conf"
// meta:inventory.systemd_units="nftban-boot-bypass.service,nftban-boot-bypass-guard.service,nftban-boot-normal.service,nftban-commit-confirm-boot.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package services

import (
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// BootGuardUnits are the early-boot safety units. They are enabled on every
// install path and never started by the installer (they act only at boot).
var BootGuardUnits = []string{
	"nftban-boot-bypass.service",
	"nftban-boot-bypass-guard.service",
	"nftban-boot-normal.service",
	// v1.235 section 4.5: decides a pending commit-confirm apply at boot, before nftband.
	"nftban-commit-confirm-boot.service",
}

// ProcCmdlinePath is the kernel command line; a variable so tests can point it
// at a fixture through the mock executor's file map.
var ProcCmdlinePath = "/proc/cmdline"

// EmergencyBypassWord is the exact kernel-command-line word of the per-boot bypass.
const EmergencyBypassWord = "nftban=disabled"

// unitInstalled reports whether a unit file is present in any systemd unit dir.
func unitInstalled(exec executor.Executor, unit string) bool {
	return exec.FileExists("/etc/systemd/system/"+unit) ||
		exec.FileExists("/usr/lib/systemd/system/"+unit) ||
		exec.FileExists("/lib/systemd/system/"+unit)
}

// EnableBootGuards enables the early-boot safety units. ALWAYS called, even
// when NFTBan is disabled or the emergency bypass is active: the bypass must be
// able to act on the next boot, and the normal-boot guard keeps a disabled
// NFTBan from loading at boot. Never starts them. Non-fatal: failures are logged.
func EnableBootGuards(exec executor.Executor, log *logging.Logger) {
	for _, u := range BootGuardUnits {
		if !unitInstalled(exec, u) {
			log.Warn("boot guard %s not installed — skipping (the emergency bypass/disabled-at-boot guarantee is NOT armed on this host)", u)
			continue
		}
		if err := exec.ServiceEnable(u); err != nil {
			log.Warn("enable boot guard %s: %v (non-fatal)", u, err)
			continue
		}
		log.Debug("boot guard %s enabled", u)
	}
}

// MasterSwitchOn returns the STORED choice NFTBAN_ENABLED.
//
//	on    true unless the last NFTBAN_ENABLED value is "false"
//	known false when an existing config file could not be read (the caller must
//	      not treat an unreadable choice as "enabled" for a lifecycle decision)
//
// Files: <configDir>/conf.d/services.conf then <configDir>/conf.d/services.conf.local
// (the same pair, in the same order, as the shell _nftban_load_services_config).
// A missing file is not an error; the absent key defaults to enabled.
func MasterSwitchOn(exec executor.Executor, configDir string) (on bool, known bool) {
	on, known = true, true
	for _, name := range []string{"services.conf", "services.conf.local"} {
		p := filepath.Join(configDir, "conf.d", name)
		if !exec.FileExists(p) {
			continue
		}
		data, err := exec.ReadFile(p)
		if err != nil {
			known = false
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "NFTBAN_ENABLED=") {
				continue
			}
			v := strings.TrimPrefix(line, "NFTBAN_ENABLED=")
			v = strings.Trim(v, `"'`)
			on = v != "false"
		}
	}
	return on, known
}

// EmergencyBypassActive reports whether the kernel command line carries the
// exact word nftban=disabled (the per-boot emergency bypass, owner R-DEC).
// An unreadable command line reports false (no bypass claimed without evidence).
func EmergencyBypassActive(exec executor.Executor) bool {
	data, err := exec.ReadFile(ProcCmdlinePath)
	if err != nil {
		return false
	}
	for _, w := range strings.Fields(string(data)) {
		if w == EmergencyBypassWord {
			return true
		}
	}
	return false
}
