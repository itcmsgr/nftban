// =============================================================================
// NFTBan v1.73 - Installer Authority File Write
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-authority"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Write /var/lib/nftban/state/authority and .firewall_authority"
// meta:inventory.files="internal/installer/validate/authority.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package validate

import (
	"github.com/itcmsgr/nftban/internal/installer/authority"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// WriteAuthorityFiles records the authority decision to state files.
// Two locations for compatibility:
//   - /var/lib/nftban/state/authority         (primary, read by Go daemon)
//   - /etc/nftban/.firewall_authority         (legacy, read by CLI scripts)
func WriteAuthorityFiles(exec executor.Executor, decision authority.Decision, log *logging.Logger) {
	content := []byte(string(decision) + "\n")

	// Primary authority file
	if err := exec.WriteFileAtomic(fhs.AuthorityFile, content, 0644); err != nil {
		log.Warn("write authority file %s: %v", fhs.AuthorityFile, err)
	} else {
		log.Debug("wrote authority=%s to %s", decision, fhs.AuthorityFile)
	}

	// Legacy authority file
	const legacyPath = "/etc/nftban/.firewall_authority"
	legacyContent := []byte("nftban\n")
	if err := exec.WriteFileAtomic(legacyPath, legacyContent, 0644); err != nil {
		log.Warn("write legacy authority %s: %v", legacyPath, err)
	} else {
		log.Debug("wrote firewall_authority=nftban to %s", legacyPath)
	}
}
