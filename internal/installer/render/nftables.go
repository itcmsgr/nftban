// =============================================================================
// NFTBan v1.73 - Installer nftables.conf Rendering
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-render-nftables"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Template rendering + nft syntax validation for nftables.conf"
// meta:inventory.files="internal/installer/render/nftables.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftables.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package render

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const nftbanConf = "/etc/nftban/nftables.conf"

// placeholders that must be rendered before nft validation.
var placeholders = []string{
	"__SSH_PORT__",
	"__CT_LIMIT_SSH__",
	"__CT_LIMIT_HTTP__",
	"__CT_LIMIT_MAIL__",
}

// RenderNftablesConf reads the nftables.conf template, substitutes placeholders,
// validates syntax, and writes back atomically.
func RenderNftablesConf(exec executor.Executor, sshPort int, ct detect.CTLimits, log *logging.Logger) error {
	data, err := exec.ReadFile(nftbanConf)
	if err != nil {
		return fmt.Errorf("read %s: %w", nftbanConf, err)
	}

	content := string(data)
	original := content

	// Substitute placeholders
	content = strings.ReplaceAll(content, "__SSH_PORT__", strconv.Itoa(sshPort))
	content = strings.ReplaceAll(content, "__CT_LIMIT_SSH__", strconv.Itoa(ct.SSH))
	content = strings.ReplaceAll(content, "__CT_LIMIT_HTTP__", strconv.Itoa(ct.HTTP))
	content = strings.ReplaceAll(content, "__CT_LIMIT_MAIL__", strconv.Itoa(ct.Mail))

	// Check for unrendered placeholders
	for _, ph := range placeholders {
		if strings.Contains(content, ph) {
			return fmt.Errorf("unrendered placeholder %s in %s", ph, nftbanConf)
		}
	}

	// Check SSH port appears in tcp_ports_in set
	portStr := strconv.Itoa(sshPort)
	if !strings.Contains(content, portStr) {
		log.Warn("SSH port %d not found in rendered nftables.conf — may need manual tcp_ports_in entry", sshPort)
	}

	// Skip write if content unchanged
	if content == original {
		log.Debug("nftables.conf unchanged after render (already rendered)")
		return nil
	}

	// Validate syntax with nft -c -f
	if err := exec.NftCheck(content); err != nil {
		return fmt.Errorf("nft syntax validation failed: %w", err)
	}

	// Atomic write
	if err := exec.WriteFileAtomic(nftbanConf, []byte(content), 0640); err != nil {
		return fmt.Errorf("write %s: %w", nftbanConf, err)
	}

	log.Info("rendered nftables.conf (SSH=%d, CT: ssh=%d http=%d mail=%d)", sshPort, ct.SSH, ct.HTTP, ct.Mail)
	return nil
}
