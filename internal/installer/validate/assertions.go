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
