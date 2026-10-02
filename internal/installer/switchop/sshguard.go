// =============================================================================
// NFTBan v1.73 - Installer SSH Port Live Set Guard
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-sshguard"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Ensure SSH port is in live nft sets before rebuild"
// meta:inventory.files="internal/installer/switchop/sshguard.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// emergencyTable is the name of the last-resort SSH safety table.
const emergencyTable = "nftban_install_emergency"

// InjectEmergencySSH creates a minimal inet table that accepts the SSH port.
// This table acts as a last-resort safety net during install transitions.
// It MUST be removed only after nftban rules are proven in the kernel.
// Idempotent: deletes any existing emergency table before creating.
//
// Priority -1: evaluated before nftban chains (priority 0).
// Policy accept: fail-open — safety net, not security boundary.
func InjectEmergencySSH(exec executor.Executor, sshPort int, log *logging.Logger) error {
	// Clean up any pre-existing emergency table (idempotent)
	if exec.NftTableExists("inet", emergencyTable) {
		_ = exec.NftDeleteTable("inet", emergencyTable)
	}

	nftRules := fmt.Sprintf(`table inet %s {
    chain input {
        type filter hook input priority -1; policy accept;
        tcp dport %d accept
    }
}`, emergencyTable, sshPort)

	// Write rules to temp file and load with nft -f
	tmpPath := "/tmp/.nftban-emergency-ssh.nft"
	if err := exec.WriteFileAtomic(tmpPath, []byte(nftRules+"\n"), 0600); err != nil {
		return fmt.Errorf("write emergency SSH rules: %w", err)
	}
	defer func() { _ = exec.Remove(tmpPath) }()

	res := exec.Run("nft", "-f", tmpPath)
	if res.ExitCode != 0 {
		return fmt.Errorf("inject emergency SSH table: %s", strings.TrimSpace(res.Stderr))
	}

	log.Info("injected emergency SSH table (port %d, priority -1)", sshPort)
	return nil
}

// RemoveEmergencySSH removes the emergency SSH table.
// Call only after nftban rules are proven in the kernel with SSH port present.
// No-op if table doesn't exist.
func RemoveEmergencySSH(exec executor.Executor, log *logging.Logger) {
	if !exec.NftTableExists("inet", emergencyTable) {
		return
	}
	if err := exec.NftDeleteTable("inet", emergencyTable); err != nil {
		log.Warn("remove emergency SSH table: %v", err)
	} else {
		log.Info("removed emergency SSH table (nftban rules proven)")
	}
}

// AssertSSHInLiveSet verifies the SSH port exists in the live nft tcp_ports_in
// sets for both ip and ip6. If missing, adds it.
// Call after EnableNftables (nftban tables must exist) and before/after rebuild.
func AssertSSHInLiveSet(exec executor.Executor, sshPort int, log *logging.Logger) {
	portStr := strconv.Itoa(sshPort)

	for _, family := range []string{"ip", "ip6"} {
		if !exec.NftTableExists(family, "nftban") {
			continue
		}
		setData, err := exec.NftListSet(family, "nftban", "tcp_ports_in")
		if err != nil {
			log.Debug("cannot list %s nftban tcp_ports_in: %v", family, err)
			continue
		}
		if strings.Contains(setData, portStr) {
			log.Debug("SSH port %d already in %s nftban tcp_ports_in", sshPort, family)
			continue
		}
		// Port missing — add it
		if err := exec.NftAddElement(family, "nftban", "tcp_ports_in", portStr); err != nil {
			log.Warn("add SSH port %d to %s nftban tcp_ports_in: %v", sshPort, family, err)
		} else {
			log.Info("added SSH port %d to %s nftban tcp_ports_in (was missing)", sshPort, family)
		}
	}
}

// sshAcceptRulePrefix is the leading text of the rendered service-accept rule in the
// nftban input chain, as `nft list chain` prints it on a v1.233.x host:
//
//	tcp dport @tcp_ports_in ct state new counter name "input_service_tcp_accept" counter name "total_input_accept" accept
//
// Matching the PREFIX excludes the `tcp flags syn ct state new tcp dport @tcp_ports_in …`
// SYN-meter rules, which may also end in accept but are rate limiters, not the service
// accept.
const sshAcceptRulePrefix = "tcp dport @tcp_ports_in ct state new"

// EmergencyTablePresent reports whether the install-time emergency SSH table is loaded.
func EmergencyTablePresent(exec executor.Executor) bool {
	return exec.NftTableExists("inet", emergencyTable)
}

// SSHHandoffProven reports whether NFTBan's OWN rules demonstrably admit new SSH
// connections, which is the precondition for removing the emergency SSH table.
//
// ⛔ v1.234.0 BUG-INSTALL-EMERGENCY-SSH-TABLE-LEFT-AFTER-REINSTALL. The emergency table is
// the last-resort protection during a transition; deleting it is safe only when the
// protection has been HANDED OFF. Handoff is proven per family (ip AND ip6), from the
// kernel, never from the render:
//
//  1. table <fam> nftban exists;
//  2. EVERY detected sshd port is an element of <fam> nftban tcp_ports_in — exact kernel
//     membership via `nft get element`, never a substring of a set listing ("22" is a
//     substring of "2222");
//  3. the input chain carries the `tcp dport @tcp_ports_in ct state new … accept` rule.
//
// Any leg that cannot be observed is NOT proven: the caller keeps the table. Read-only.
func SSHHandoffProven(exec executor.Executor, sshPorts []int) (bool, string) {
	var ports []int
	for _, p := range sshPorts {
		if p > 0 && p <= 65535 {
			ports = append(ports, p)
		}
	}
	if len(ports) == 0 {
		return false, "no sshd port is known, so the handoff cannot be proven"
	}
	for _, fam := range []string{"ip", "ip6"} {
		if !exec.NftTableExists(fam, "nftban") {
			return false, fmt.Sprintf("table %s nftban is not loaded", fam)
		}
		for _, p := range ports {
			res := exec.Run("nft", "get", "element", fam, "nftban", "tcp_ports_in", fmt.Sprintf("{ %d }", p))
			if res.ExitCode != 0 {
				return false, fmt.Sprintf("sshd port %d is not an element of %s nftban tcp_ports_in", p, fam)
			}
		}
		chain := exec.Run("nft", "list", "chain", fam, "nftban", "input")
		if chain.ExitCode != 0 {
			return false, fmt.Sprintf("cannot list %s nftban input chain (exit %d)", fam, chain.ExitCode)
		}
		if !hasSSHAcceptRule(chain.Stdout) {
			return false, fmt.Sprintf("%s nftban input has no '%s ... accept' rule", fam, sshAcceptRulePrefix)
		}
	}
	return true, ""
}

// hasSSHAcceptRule looks for a rule line that starts with sshAcceptRulePrefix and whose
// verdict is accept (the last statement, optionally followed by a comment).
func hasSSHAcceptRule(chainListing string) bool {
	for _, line := range strings.Split(chainListing, "\n") {
		l := strings.TrimSpace(line)
		if !strings.HasPrefix(l, sshAcceptRulePrefix) {
			continue
		}
		if i := strings.Index(l, " comment "); i >= 0 {
			l = strings.TrimSpace(l[:i])
		}
		if strings.HasSuffix(l, " accept") {
			return true
		}
	}
	return false
}

// HandOffEmergencySSH removes the emergency SSH table ONLY after SSHHandoffProven.
// Returns true when the table is absent afterwards (removed, or never present).
// When the handoff is not proven the table is KEPT and the reason logged: an extra
// accept-only table is a hygiene defect, a missing SSH allowance is a lockout.
func HandOffEmergencySSH(exec executor.Executor, sshPorts []int, log *logging.Logger) bool {
	if !EmergencyTablePresent(exec) {
		return true
	}
	ok, why := SSHHandoffProven(exec, sshPorts)
	if !ok {
		log.Warn("emergency SSH table KEPT: NFTBan's own rules are not proven to admit SSH (%s)", why)
		return false
	}
	RemoveEmergencySSH(exec, log)
	return !EmergencyTablePresent(exec)
}
