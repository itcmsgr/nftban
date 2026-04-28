// =============================================================================
// NFTBan v1.73 - Installer SSH Port Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-ssh"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="4-source SSH port detection chain for installer"
// meta:inventory.files="internal/installer/detect/ssh.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/ssh/sshd_config"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package detect

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// SSHPort detects the active SSH port using a 4-source priority chain.
// Returns the port number (1-65535) or an error if no source yields a valid port.
//
// Priority:
//  1. ss listener (most authoritative — reflects actual running sshd)
//  2. sshd_config + drop-in dirs (config-declared)
//  3. State file from previous install (/var/lib/nftban/state/ssh_port_active.state)
//  4. nftban.conf.local override (/etc/nftban/nftban.conf.local SSH_PORT=)
func SSHPort(exec executor.Executor, log *logging.Logger) (int, error) {
	// Source 1: ss listener
	if port := sshFromListener(exec); port > 0 {
		log.Detect("ssh", "source", "ss-listener")
		log.Detect("ssh", "port", strconv.Itoa(port))
		return port, nil
	}

	// Source 2: sshd_config
	if port := sshFromConfig(exec); port > 0 {
		log.Detect("ssh", "source", "sshd_config")
		log.Detect("ssh", "port", strconv.Itoa(port))
		return port, nil
	}

	// Source 3: state file
	if port := sshFromStateFile(exec); port > 0 {
		log.Detect("ssh", "source", "state-file")
		log.Detect("ssh", "port", strconv.Itoa(port))
		return port, nil
	}

	// Source 4: nftban.conf.local
	if port := sshFromConfLocal(exec); port > 0 {
		log.Detect("ssh", "source", "conf.local")
		log.Detect("ssh", "port", strconv.Itoa(port))
		return port, nil
	}

	return 0, fmt.Errorf("cannot determine SSH port from any source (ss, sshd_config, state file, conf.local)")
}

// SSHPortWithSource returns the resolved SSH port AND a short string
// identifying which source yielded it: "ss" / "sshd_config" /
// "state" / "config" — matching the schema enum required by the
// PR-26-code-D restore evidence record (§39.1 / §48.6 lock).
//
// Same priority chain as SSHPort. Read-only typed introspection;
// no mutation. Per §51.5-A2 invariant, this is OUTSIDE the bounded
// mutation surface cap. Added in PR-26-code-D.
func SSHPortWithSource(exec executor.Executor, log *logging.Logger) (port int, source string, err error) {
	if p := sshFromListener(exec); p > 0 {
		log.Detect("ssh", "source", "ss-listener")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return p, "ss", nil
	}
	if p := sshFromConfig(exec); p > 0 {
		log.Detect("ssh", "source", "sshd_config")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return p, "sshd_config", nil
	}
	if p := sshFromStateFile(exec); p > 0 {
		log.Detect("ssh", "source", "state-file")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return p, "state", nil
	}
	if p := sshFromConfLocal(exec); p > 0 {
		log.Detect("ssh", "source", "conf.local")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return p, "config", nil
	}
	return 0, "", fmt.Errorf("cannot determine SSH port from any source (ss, sshd_config, state file, conf.local)")
}

// portRe matches a trailing port number after a colon.
var portRe = regexp.MustCompile(`:(\d+)\s*$`)

// sshFromListener checks ss -tlnp for sshd listening port.
func sshFromListener(exec executor.Executor) int {
	res := exec.Run("ss", "-tlnp")
	if res.ExitCode != 0 {
		return 0
	}
	for _, line := range strings.Split(res.Stdout, "\n") {
		if !strings.Contains(line, "sshd") {
			continue
		}
		// Extract port from LISTEN address column (e.g., *:22 or 0.0.0.0:55000)
		m := portRe.FindStringSubmatch(safeField(line, 3))
		if m != nil {
			return validatePort(m[1])
		}
	}
	return 0
}

// sshFromConfig reads /etc/ssh/sshd_config and drop-in dirs.
func sshFromConfig(exec executor.Executor) int {
	// Main config
	if port := parseSSHConfig(exec, "/etc/ssh/sshd_config"); port > 0 {
		return port
	}
	// Drop-in directory
	res := exec.Run("ls", "/etc/ssh/sshd_config.d/")
	if res.ExitCode == 0 {
		for _, name := range strings.Fields(res.Stdout) {
			if !strings.HasSuffix(name, ".conf") {
				continue
			}
			path := filepath.Join("/etc/ssh/sshd_config.d", name)
			if port := parseSSHConfig(exec, path); port > 0 {
				return port
			}
		}
	}
	return 0
}

// portLineRe matches "Port NNN" lines in sshd_config.
var portLineRe = regexp.MustCompile(`(?i)^\s*Port\s+(\d+)`)

func parseSSHConfig(exec executor.Executor, path string) int {
	data, err := exec.ReadFile(path)
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		m := portLineRe.FindStringSubmatch(line)
		if m != nil {
			return validatePort(m[1])
		}
	}
	return 0
}

// sshFromStateFile reads /var/lib/nftban/state/ssh_port_active.state.
func sshFromStateFile(exec executor.Executor) int {
	data, err := exec.ReadFile("/var/lib/nftban/state/ssh_port_active.state")
	if err != nil {
		return 0
	}
	return validatePort(strings.TrimSpace(string(data)))
}

// sshFromConfLocal reads SSH_PORT= from /etc/nftban/nftban.conf.local.
func sshFromConfLocal(exec executor.Executor) int {
	data, err := exec.ReadFile("/etc/nftban/nftban.conf.local")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "SSH_PORT=") {
			val := strings.TrimPrefix(line, "SSH_PORT=")
			return validatePort(strings.TrimSpace(val))
		}
	}
	return 0
}

// validatePort returns the port if it's a valid number in 1-65535, else 0.
func validatePort(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 || n > 65535 {
		return 0
	}
	return n
}

// safeField returns the nth whitespace-separated field, or empty string.
func safeField(line string, n int) string {
	fields := strings.Fields(line)
	if n < len(fields) {
		return fields[n]
	}
	return ""
}
