// =============================================================================
// NFTBan v1.73 - Installer Post-Install Assertions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-assertions"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Post-install kernel + service + state assertions"
// meta:inventory.files="internal/installer/validate/assertions.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package validate

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/payload"
)

// AssertionResult holds the outcome of a single assertion.
type AssertionResult struct {
	Name   string
	Passed bool
	Detail string
}

// RunAssertions performs all post-install assertions and returns the results.
// None of these are individually fatal — the caller decides based on the aggregate.
func RunAssertions(exec executor.Executor, sshPort int, log *logging.Logger) []AssertionResult {
	var results []AssertionResult

	results = append(results, assertNftablesActive(exec, log))
	results = append(results, assertNftbanTable(exec, "ip", log))
	results = append(results, assertNftbanTable(exec, "ip6", log))
	results = append(results, assertNftbanChain(exec, log))
	results = append(results, assertSSHInSet(exec, sshPort, log))
	results = append(results, assertNoEmergencyTable(exec, log))
	results = append(results, assertDaemonActive(exec, log))
	results = append(results, assertInstallStateFile(exec, log))
	results = append(results, assertPayloadInventory(exec, log))
	results = append(results, assertConfigIntegrity(exec, log))

	// PR26.1: systemd-payload invariants. One gather call feeds four
	// assertions so we don't walk the unit dirs (or call systemctl)
	// four times. Inventory paths are derived from existing
	// payload.VerifyInventory's required-set; PAYLOAD-INVENTORY-001
	// fails closed when nothing is supplied (every nftban-owned
	// referenced path becomes "unknown"), so the gatherer SHOULD
	// pass a populated set in production.
	in, _ := GatherSystemdPayloadInputs(exec, log, defaultInventoryPaths())
	spr := ValidateInstalledSystemdPayload(in)
	results = append(results,
		assertSystemdExecStartPaths(spr, log),
		assertSystemdTimerPair(spr, log),
		assertSystemdPayloadInventory(spr, log),
		assertFailedUnitsPostInstall(spr, log),
	)

	passed := 0
	for _, r := range results {
		if r.Passed {
			passed++
		}
	}
	log.Info("assertions: %d/%d passed", passed, len(results))
	return results
}

// AllPassed returns true if all assertions passed.
func AllPassed(results []AssertionResult) bool {
	for _, r := range results {
		if !r.Passed {
			return false
		}
	}
	return true
}

// FailedNames returns the names of all failed assertions.
func FailedNames(results []AssertionResult) []string {
	var names []string
	for _, r := range results {
		if !r.Passed {
			names = append(names, r.Name)
		}
	}
	return names
}

func assertNftablesActive(exec executor.Executor, log *logging.Logger) AssertionResult {
	active := exec.ServiceActive("nftables")
	r := AssertionResult{Name: "nftables_active", Passed: active}
	if !active {
		r.Detail = "nftables.service not active"
		log.Warn("ASSERT nftables_active: FAIL")
	} else {
		log.Debug("ASSERT nftables_active: PASS")
	}
	return r
}

func assertNftbanTable(exec executor.Executor, family string, log *logging.Logger) AssertionResult {
	name := "nftban_table_" + family
	exists := exec.NftTableExists(family, "nftban")
	r := AssertionResult{Name: name, Passed: exists}
	if !exists {
		r.Detail = family + " nftban table missing from kernel"
		log.Warn("ASSERT %s: FAIL", name)
	} else {
		log.Debug("ASSERT %s: PASS", name)
	}
	return r
}

func assertNftbanChain(exec executor.Executor, log *logging.Logger) AssertionResult {
	// Check for input chain in ip nftban
	res := exec.Run("nft", "list", "chain", "ip", "nftban", "input")
	passed := res.ExitCode == 0
	r := AssertionResult{Name: "nftban_input_chain", Passed: passed}
	if !passed {
		r.Detail = "ip nftban input chain missing"
		log.Warn("ASSERT nftban_input_chain: FAIL")
	} else {
		log.Debug("ASSERT nftban_input_chain: PASS")
	}
	return r
}

func assertSSHInSet(exec executor.Executor, sshPort int, log *logging.Logger) AssertionResult {
	if sshPort <= 0 {
		return AssertionResult{Name: "ssh_in_set", Passed: true, Detail: "no SSH port configured"}
	}

	setData, err := exec.NftListSet("ip", "nftban", "tcp_ports_in")
	if err != nil {
		return AssertionResult{Name: "ssh_in_set", Passed: false, Detail: "cannot list tcp_ports_in: " + err.Error()}
	}

	portStr := fmt.Sprintf("%d", sshPort)
	passed := strings.Contains(setData, portStr)

	r := AssertionResult{Name: "ssh_in_set", Passed: passed}
	if !passed {
		r.Detail = "SSH port " + portStr + " not in ip nftban tcp_ports_in"
		log.Warn("ASSERT ssh_in_set: FAIL — port %d missing", sshPort)
	} else {
		log.Debug("ASSERT ssh_in_set: PASS — port %d present", sshPort)
	}
	return r
}

func assertNoEmergencyTable(exec executor.Executor, log *logging.Logger) AssertionResult {
	exists := exec.NftTableExists("inet", "nftban_install_emergency")
	r := AssertionResult{Name: "no_emergency_table", Passed: !exists}
	if exists {
		r.Detail = "inet nftban_install_emergency table still present"
		log.Warn("ASSERT no_emergency_table: FAIL")
	} else {
		log.Debug("ASSERT no_emergency_table: PASS")
	}
	return r
}

func assertDaemonActive(exec executor.Executor, log *logging.Logger) AssertionResult {
	active := exec.ServiceActive("nftband.service")
	r := AssertionResult{Name: "daemon_active", Passed: active}
	if !active {
		r.Detail = "nftband.service not active"
		log.Warn("ASSERT daemon_active: FAIL")
	} else {
		log.Debug("ASSERT daemon_active: PASS")
	}
	return r
}

func assertInstallStateFile(exec executor.Executor, log *logging.Logger) AssertionResult {
	exists := exec.FileExists(fhs.StateDir + "/install_state")
	r := AssertionResult{Name: "state_file_exists", Passed: exists}
	if !exists {
		r.Detail = "install_state file missing"
		log.Warn("ASSERT state_file_exists: FAIL")
	} else {
		log.Debug("ASSERT state_file_exists: PASS")
	}
	return r
}

// assertPayloadInventory (v1.98.2 R-3, issue #463): material install
// completeness check. Every install (source OR package) must produce the
// canonical set of destinations defined in payload.VerifyInventory. Missing
// entries indicate either a broken payload stage or a tampered install —
// both must surface as a failed assertion rather than a clean COMMITTED.
func assertPayloadInventory(exec executor.Executor, log *logging.Logger) AssertionResult {
	ok, missing := payload.VerifyInventory(exec)
	r := AssertionResult{Name: "payload_inventory_ok", Passed: ok}
	if !ok {
		r.Detail = "missing required payload: " + strings.Join(missing, ", ")
		log.Warn("ASSERT payload_inventory_ok: FAIL — missing %d: %s",
			len(missing), strings.Join(missing, ", "))
	} else {
		log.Debug("ASSERT payload_inventory_ok: PASS")
	}
	return r
}

// assertConfigIntegrity (v1.100 PR-P2-6): minimum-sanity integrity check
// on the critical config files that the rest of the install depends on.
//
// Complements assertPayloadInventory:
//   - inventory checks presence — "the file exists"
//   - integrity checks minimum viability — "the file is not empty /
//     truncated and still carries its required header tokens"
//
// Scope lock (per PR-P2-6 contract): minimum-size + required-token only.
// No checksum, no signature, no semantic parse. The fixed two-file set
// (nftban.conf + nftables.conf) lives in payload.criticalConfigs; adding
// a file or a signal type requires an explicit contract update.
func assertConfigIntegrity(exec executor.Executor, log *logging.Logger) AssertionResult {
	ok, issues := payload.VerifyConfigIntegrity(exec)
	r := AssertionResult{Name: "config_integrity_ok", Passed: ok}
	if !ok {
		parts := make([]string, 0, len(issues))
		for _, i := range issues {
			parts = append(parts, i.Path+": "+i.Reason)
		}
		r.Detail = "config integrity issues: " + strings.Join(parts, "; ")
		log.Warn("ASSERT config_integrity_ok: FAIL — %d issue(s): %s",
			len(issues), strings.Join(parts, "; "))
	} else {
		log.Debug("ASSERT config_integrity_ok: PASS")
	}
	return r
}

// PR26.1 assertions ----------------------------------------------------------
//
// These four assertions implement, respectively:
//
//	SYSTEMD-EXECSTART-001         systemd_execstart_paths_ok
//	SYSTEMD-TIMER-PAIR-001        systemd_timer_pair_ok
//	PAYLOAD-INVENTORY-001         systemd_payload_inventory_ok
//	FAILED-UNIT-POSTINSTALL-001   failed_units_postinstall_ok
//
// All four are derived from a single SystemdPayloadValidationResult
// computed once per RunAssertions pass. Each contributes a distinct
// AssertionResult so FailedNames pinpoints which invariant fired.

func assertSystemdExecStartPaths(spr SystemdPayloadValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "systemd_execstart_paths_ok", Passed: spr.ExecStartOK()}
	if r.Passed {
		log.Debug("ASSERT systemd_execstart_paths_ok: PASS")
		return r
	}
	parts := make([]string, 0, len(spr.MissingExecPaths))
	for _, m := range spr.MissingExecPaths {
		parts = append(parts, m.UnitFile+":"+m.Directive+"="+m.Path)
	}
	r.Detail = "missing ExecStart paths: " + strings.Join(parts, "; ")
	log.Warn("ASSERT systemd_execstart_paths_ok: FAIL — %d missing: %s",
		len(spr.MissingExecPaths), strings.Join(parts, "; "))
	return r
}

func assertSystemdTimerPair(spr SystemdPayloadValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "systemd_timer_pair_ok", Passed: spr.TimerPairOK()}
	if r.Passed {
		log.Debug("ASSERT systemd_timer_pair_ok: PASS")
		return r
	}
	parts := make([]string, 0, len(spr.MissingTimerTargets))
	for _, m := range spr.MissingTimerTargets {
		parts = append(parts, m.TimerUnit+"->"+m.TargetUnit)
	}
	r.Detail = "timers activate missing services: " + strings.Join(parts, "; ")
	log.Warn("ASSERT systemd_timer_pair_ok: FAIL — %d unpaired: %s",
		len(spr.MissingTimerTargets), strings.Join(parts, "; "))
	return r
}

func assertSystemdPayloadInventory(spr SystemdPayloadValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "systemd_payload_inventory_ok", Passed: spr.PayloadInventoryOK()}
	if r.Passed {
		log.Debug("ASSERT systemd_payload_inventory_ok: PASS")
		return r
	}
	parts := make([]string, 0, len(spr.UnknownPayloadRefs))
	for _, m := range spr.UnknownPayloadRefs {
		parts = append(parts, m.UnitFile+":"+m.Path)
	}
	r.Detail = "nftban-owned paths not in payload inventory: " + strings.Join(parts, "; ")
	log.Warn("ASSERT systemd_payload_inventory_ok: FAIL — %d unknown: %s",
		len(spr.UnknownPayloadRefs), strings.Join(parts, "; "))
	return r
}

func assertFailedUnitsPostInstall(spr SystemdPayloadValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "failed_units_postinstall_ok", Passed: spr.FailedUnitsOK()}
	if r.Passed {
		log.Debug("ASSERT failed_units_postinstall_ok: PASS")
		return r
	}
	// Fail-closed query error takes precedence — surfaces the
	// enumeration failure rather than misreporting "no failed units".
	if spr.FailedUnitQueryError != "" {
		r.Detail = "failed-unit enumeration error: " + spr.FailedUnitQueryError
		log.Warn("ASSERT failed_units_postinstall_ok: FAIL — %s", spr.FailedUnitQueryError)
		return r
	}
	parts := make([]string, 0, len(spr.FailedUnits))
	for _, f := range spr.FailedUnits {
		parts = append(parts, f.Unit+"("+f.Detail+")")
	}
	r.Detail = "nftban units in failed state: " + strings.Join(parts, "; ")
	log.Warn("ASSERT failed_units_postinstall_ok: FAIL — %d failed: %s",
		len(spr.FailedUnits), strings.Join(parts, "; "))
	return r
}

// defaultInventoryPaths returns the set of nftban-owned paths the
// staged install is known to populate. Mirrors payload.VerifyInventory's
// canonical required set, expressed as a set instead of a slice.
//
// Kept local to validate/ so the systemd-payload assertion does not
// import payload.buildEntries (which would couple validation against
// the full destination table). The set is intentionally narrow: a
// missing path here surfaces as a PAYLOAD-INVENTORY-001 finding with
// actionable detail (the unit file + path), prompting the operator
// to either expand this set or stop the unit from referencing the
// path. Either is a deliberate decision — not a silent pass.
func defaultInventoryPaths() map[string]bool {
	return map[string]bool{
		"/usr/sbin/nftban":                         true,
		"/usr/lib/nftban/bin/nftban-core":          true,
		"/usr/lib/nftban/bin/nftband":              true,
		"/usr/lib/nftban/bin/nftban-validate":      true,
		"/usr/lib/nftban/bin/nftban-installer":     true,
		"/usr/lib/nftban/sbin/nftban-apply":        true,
		"/usr/lib/nftban/sbin/nftban-confirm":      true,
		"/usr/lib/nftban/sbin/nftban-panelctl":     true,
		"/usr/lib/nftban/sbin/nftban-queue-processor":   true,
		"/usr/lib/nftban/sbin/nftban-rollback":     true,
		"/usr/lib/nftban/sbin/nftban-service-alert":     true,
		"/usr/lib/nftban/sbin/nftban-botscan-processor": true,
	}
}
