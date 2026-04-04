// =============================================================================
// NFTBan v1.73 - Installer System nftables.conf Integration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-render-sysconf"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Integrate NFTBan include into system nftables.conf"
// meta:inventory.files="internal/installer/render/sysconf.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package render

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const includeDirective = `include "/etc/nftban/nftables.conf"`

// IntegrateSystemConf appends the NFTBan include directive to the system
// nftables.conf if not already present. Idempotent.
func IntegrateSystemConf(exec executor.Executor, nftConfPath string, log *logging.Logger) error {
	if nftConfPath == "" {
		return fmt.Errorf("system nftables.conf path is empty")
	}
	if !exec.FileExists(nftConfPath) {
		log.Warn("system nftables.conf not found at %s — skipping integration", nftConfPath)
		return nil
	}

	data, err := exec.ReadFile(nftConfPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", nftConfPath, err)
	}

	content := string(data)
	if strings.Contains(content, "/etc/nftban/nftables.conf") {
		log.Debug("system nftables.conf already includes NFTBan config")
		return nil
	}

	// Append include directive
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	content += "# NFTBan firewall configuration\n"
	content += includeDirective + "\n"

	if err := exec.WriteFileAtomic(nftConfPath, []byte(content), 0644); err != nil {
		return fmt.Errorf("write %s: %w", nftConfPath, err)
	}

	log.Info("added NFTBan config to %s", nftConfPath)
	return nil
}
