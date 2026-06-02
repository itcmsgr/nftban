// =============================================================================
// NFTBan v1.73 - Installer Config Persistence
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-render-config"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Persist SSH port and config values to conf.local and state"
// meta:inventory.files="internal/installer/render/config.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf.local"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package render

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const (
	confLocal    = "/etc/nftban/nftban.conf.local"
	sshStateFile = "/var/lib/nftban/state/ssh_port_active.state"
	// portsDSSHFile is the durable SSH-port whitelist consumed by the ports
	// loader and by the shell reload/rebuild union fallback.
	portsDSSHFile = "/etc/nftban/ports.d/00-ssh.conf"
)

// PersistSSHPortsUnion writes EVERY detected SSH listener port to the durable
// ports.d SSH file, so reload/rebuild and the ports loader keep all listeners
// whitelisted (lockout-safe) — not just the primary. Without this, a multi-port
// host's durable port intent collapses to the shipped default (22 only), and a
// shell render/reload could drop a secondary SSH management port. Idempotent
// overwrite; format PORT/PROTOCOL/DIRECTION (T=TCP, I=Input).
func PersistSSHPortsUnion(exec executor.Executor, ports []int, log *logging.Logger) {
	if len(ports) == 0 {
		return
	}
	var b strings.Builder
	b.WriteString("# NFTBan SSH port whitelist (machine-generated — full detected union)\n")
	b.WriteString("# Keeps every detected SSH listener port allowed so reload/rebuild\n")
	b.WriteString("# cannot collapse a multi-port host to primary-only (lockout-safe).\n")
	b.WriteString("# Format: PORT/PROTOCOL/DIRECTION (T=TCP, I=Input)\n")
	seen := make(map[int]bool, len(ports))
	count := 0
	for _, p := range ports {
		if p < 1 || p > 65535 || seen[p] {
			continue
		}
		seen[p] = true
		b.WriteString(strconv.Itoa(p) + "/T/I\n")
		count++
	}
	if err := exec.WriteFileAtomic(portsDSSHFile, []byte(b.String()), 0644); err != nil {
		log.Warn("persist SSH union to %s: %v", portsDSSHFile, err)
		return
	}
	log.Info("persisted SSH port union (%d ports) to %s", count, portsDSSHFile)
}

// PersistSSHPort writes the detected SSH port to conf.local and state file.
// Also ensures TCP_PORTS_IN includes the SSH port (lockout prevention).
func PersistSSHPort(exec executor.Executor, sshPort int, log *logging.Logger) {
	portStr := strconv.Itoa(sshPort)

	// Write to state file (simple, always overwrite)
	if err := exec.WriteFileAtomic(sshStateFile, []byte(portStr+"\n"), 0640); err != nil {
		log.Warn("write ssh state file: %v", err)
	} else {
		log.Debug("persisted SSH port %d to %s", sshPort, sshStateFile)
	}

	// Update conf.local: SSH_PORT=
	updateConfLocal(exec, "SSH_PORT", portStr, log)

	// Ensure TCP_PORTS_IN includes the SSH port (G2 parity with shell postinst).
	// Without this, a non-22 SSH port could be excluded after `nftban config reload`.
	ensureTCPPortsIncludes(exec, sshPort, log)
}

// ensureTCPPortsIncludes checks if the SSH port is in TCP_PORTS_IN and adds it if missing.
func ensureTCPPortsIncludes(exec executor.Executor, sshPort int, log *logging.Logger) {
	portStr := strconv.Itoa(sshPort)

	// Read current conf.local (may not exist yet)
	data, err := exec.ReadFile(confLocal)
	if err != nil {
		// No conf.local yet — updateConfLocal will create it
		// The SSH port is already in the rendered nftables.conf template,
		// but add TCP_PORTS_IN to conf.local for belt-and-suspenders
		updateConfLocal(exec, "TCP_PORTS_IN", portStr, log)
		log.Debug("added TCP_PORTS_IN=%s to conf.local (new file)", portStr)
		return
	}

	// Check if TCP_PORTS_IN already contains the SSH port
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "TCP_PORTS_IN=") {
			val := strings.TrimPrefix(line, "TCP_PORTS_IN=")
			val = strings.Trim(val, "\"")
			// Check if port is already listed (could be "22,80,443" or "22 80 443")
			for _, p := range strings.FieldsFunc(val, func(r rune) bool { return r == ',' || r == ' ' }) {
				if strings.TrimSpace(p) == portStr {
					log.Debug("SSH port %d already in TCP_PORTS_IN", sshPort)
					return
				}
			}
			// Port not found — append it
			var newVal string
			if strings.Contains(val, ",") {
				newVal = val + "," + portStr
			} else if val == "" {
				newVal = portStr
			} else {
				newVal = val + "," + portStr
			}
			updateConfLocal(exec, "TCP_PORTS_IN", newVal, log)
			log.Info("added SSH port %d to TCP_PORTS_IN in conf.local", sshPort)
			return
		}
	}

	// No TCP_PORTS_IN line exists — read from main conf to get current value
	mainData, err := exec.ReadFile("/etc/nftban/nftban.conf")
	if err != nil {
		// Can't read main conf — just set TCP_PORTS_IN to include SSH port
		updateConfLocal(exec, "TCP_PORTS_IN", portStr, log)
		return
	}

	for _, line := range strings.Split(string(mainData), "\n") {
		if strings.HasPrefix(line, "TCP_PORTS_IN=") {
			val := strings.TrimPrefix(line, "TCP_PORTS_IN=")
			val = strings.Trim(val, "\"")
			for _, p := range strings.FieldsFunc(val, func(r rune) bool { return r == ',' || r == ' ' }) {
				if strings.TrimSpace(p) == portStr {
					// Already in main conf — no override needed
					return
				}
			}
			// Not in main conf — add override
			var newVal string
			if val == "" {
				newVal = portStr
			} else {
				newVal = val + "," + portStr
			}
			updateConfLocal(exec, "TCP_PORTS_IN", newVal, log)
			log.Info("added SSH port %d to TCP_PORTS_IN override", sshPort)
			return
		}
	}
}

// updateConfLocal creates or updates a key=value in nftban.conf.local.
func updateConfLocal(exec executor.Executor, key, value string, log *logging.Logger) {
	prefix := key + "="
	data, err := exec.ReadFile(confLocal)
	if err != nil {
		// File doesn't exist — create with just this key
		content := fmt.Sprintf("# NFTBan local overrides (machine-generated entries)\n%s%s\n", prefix, value)
		if err := exec.WriteFileAtomic(confLocal, []byte(content), 0640); err != nil {
			log.Warn("create %s: %v", confLocal, err)
		}
		return
	}

	// File exists — update or append
	lines := strings.Split(string(data), "\n")
	found := false
	for i, line := range lines {
		if strings.HasPrefix(line, prefix) {
			lines[i] = prefix + value
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, prefix+value)
	}

	content := strings.Join(lines, "\n")
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	if err := exec.WriteFileAtomic(confLocal, []byte(content), 0640); err != nil {
		log.Warn("update %s: %v", confLocal, err)
	}
}
