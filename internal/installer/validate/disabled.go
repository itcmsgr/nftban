// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package validate

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/services"
)

// v1.235 row 486 (owner U1 / R-DEC / D4). When NFTBan is DISABLED (stored
// choice) or the per-boot EMERGENCY BYPASS is active, the installer loads no
// rules and starts no NFTBan unit, so the runtime-health assertions (nftban
// tables, SSH in set, daemon active, timers) do not apply: a correctly disabled
// host would otherwise be reported DEGRADED. RunDisabledAssertions checks the
// invariants of THAT state instead, plus the static payload assertions that
// hold in every mode. It never mutates anything.

// BootProjectionInertMarker is the exact body line of an inert projection
// (cli/lib/nftban/lib/boot_projection.sh NFTBAN_BOOT_PROJECTION_INERT_MARKER).
const BootProjectionInertMarker = "# NFTBAN-PROJECTION-STATE: inert"

// DisabledMode selects which invariant set applies.
type DisabledMode int

const (
	// ModeStoredDisabled — NFTBAN_ENABLED=false (stored choice), no bypass.
	ModeStoredDisabled DisabledMode = iota
	// ModeEmergencyBypass — kernel parameter nftban=disabled for this boot.
	ModeEmergencyBypass
)

// RunDisabledAssertions returns the assertion set for a disabled/bypassed run.
// projectionPath is the boot projection the distro include points at.
func RunDisabledAssertions(exec executor.Executor, log *logging.Logger, mode DisabledMode, projectionPath string, opts AssertionOpts) []AssertionResult {
	var results []AssertionResult
	results = append(results, assertInstallStateFile(exec, log))
	results = append(results, assertPayloadInventory(exec, log))
	results = append(results, assertConfigIntegrity(exec, log))

	var in SystemdPayloadInputs
	if opts.SystemdPayloadInputs != nil {
		in = *opts.SystemdPayloadInputs
	} else {
		in, _ = GatherSystemdPayloadInputs(exec, log, defaultInventoryPaths())
	}
	spr := ValidateInstalledSystemdPayload(in)
	results = append(results,
		assertSystemdExecStartPaths(spr, log),
		assertSystemdTimerPair(spr, log),
		assertSystemdPayloadInventory(spr, log),
	)

	results = append(results, assertBootGuardsEnabled(exec, log))
	results = append(results, assertProjectionInert(exec, log, projectionPath))
	switch mode {
	case ModeStoredDisabled:
		results = append(results, assertNoNftbanUnitEnabled(exec, log))
	case ModeEmergencyBypass:
		results = append(results, assertNoNftbanTablesUnderBypass(exec, log))
	}
	return results
}

// assertBootGuardsEnabled — every INSTALLED boot guard unit is enabled. A
// missing unit file is reported (the guarantee is not armed) and fails.
func assertBootGuardsEnabled(exec executor.Executor, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "boot_guards_enabled", Passed: true}
	var bad []string
	for _, u := range services.BootGuardUnits {
		installed := exec.FileExists("/etc/systemd/system/"+u) ||
			exec.FileExists("/usr/lib/systemd/system/"+u) ||
			exec.FileExists("/lib/systemd/system/"+u)
		switch {
		case !installed:
			bad = append(bad, u+" (not installed)")
		case !exec.ServiceEnabled(u):
			bad = append(bad, u+" (not enabled)")
		}
	}
	if len(bad) > 0 {
		r.Passed = false
		r.Detail = strings.Join(bad, ", ")
		log.Warn("ASSERT boot_guards_enabled: FAIL — %s", r.Detail)
	}
	return r
}

// assertProjectionInert — the boot projection carries the exact inert marker,
// so no NFTBan rule loads at the next boot (stored-disabled) or at this boot
// (bypass: the projection path is bind-mounted inert).
func assertProjectionInert(exec executor.Executor, log *logging.Logger, path string) AssertionResult {
	r := AssertionResult{Name: "boot_projection_inert"}
	data, err := exec.ReadFile(path)
	if err != nil {
		r.Detail = "projection unreadable: " + err.Error()
		log.Warn("ASSERT boot_projection_inert: FAIL — %s", r.Detail)
		return r
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimRight(line, "\r") == BootProjectionInertMarker {
			r.Passed = true
			return r
		}
	}
	r.Detail = "projection " + path + " is not inert (a disabled NFTBan would load at boot)"
	log.Warn("ASSERT boot_projection_inert: FAIL — %s", r.Detail)
	return r
}

// assertNoNftbanUnitEnabled — stored-disabled: no NFTBan unit is enabled except
// the boot guards (static/indirect/generated units are not "enabled").
// An unreadable unit list is a FAIL (never a silent pass).
func assertNoNftbanUnitEnabled(exec executor.Executor, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "nftban_units_not_enabled_while_disabled"}
	res := exec.Run("systemctl", "list-unit-files", "--no-legend", "--plain", "nftban*", "nftband*")
	if res.ExitCode != 0 {
		r.Detail = "systemctl list-unit-files failed: " + strings.TrimSpace(res.Stderr)
		log.Warn("ASSERT %s: FAIL — %s", r.Name, r.Detail)
		return r
	}
	guard := map[string]bool{}
	for _, u := range services.BootGuardUnits {
		guard[u] = true
	}
	var enabled []string
	for _, line := range strings.Split(res.Stdout, "\n") {
		f := strings.Fields(line)
		if len(f) < 2 || guard[f[0]] {
			continue
		}
		if f[1] == "enabled" || f[1] == "enabled-runtime" {
			enabled = append(enabled, f[0])
		}
	}
	if len(enabled) > 0 {
		r.Detail = "NFTBan is disabled but these units are enabled: " + strings.Join(enabled, ", ")
		log.Warn("ASSERT %s: FAIL — %s", r.Name, r.Detail)
		return r
	}
	r.Passed = true
	return r
}

// assertNoNftbanTablesUnderBypass — during an emergency-bypass boot no NFTBan
// table may be loaded.
func assertNoNftbanTablesUnderBypass(exec executor.Executor, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "no_nftban_tables_under_bypass", Passed: true}
	var present []string
	for _, fam := range []string{"ip", "ip6"} {
		if exec.NftTableExists(fam, "nftban") {
			present = append(present, fam+" nftban")
		}
	}
	if len(present) > 0 {
		r.Passed = false
		r.Detail = "EMERGENCY BYPASS ACTIVE but NFTBan tables are loaded: " + strings.Join(present, ", ")
		log.Warn("ASSERT %s: FAIL — %s", r.Name, r.Detail)
	}
	return r
}
