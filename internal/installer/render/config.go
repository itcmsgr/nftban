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
)

// PersistSSHPort writes the detected SSH port to conf.local and state file.
func PersistSSHPort(exec executor.Executor, sshPort int, log *logging.Logger) {
	portStr := strconv.Itoa(sshPort)

	// Write to state file (simple, always overwrite)
	if err := exec.WriteFileAtomic(sshStateFile, []byte(portStr+"\n"), 0640); err != nil {
		log.Warn("write ssh state file: %v", err)
	} else {
		log.Debug("persisted SSH port %d to %s", sshPort, sshStateFile)
	}

	// Update conf.local (create or update SSH_PORT= line)
	updateConfLocal(exec, "SSH_PORT", portStr, log)
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
