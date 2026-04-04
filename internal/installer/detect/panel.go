// =============================================================================
// NFTBan v1.75.1 - Installer Panel Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-panel"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Control panel detection by directory existence"
// meta:inventory.files="internal/installer/detect/panel.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package detect

import (
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// PanelType identifies a hosting control panel.
type PanelType string

const (
	PanelNone        PanelType = ""
	PanelDirectAdmin PanelType = "directadmin"
	PanelCPanel      PanelType = "cpanel"
	PanelPlesk       PanelType = "plesk"
	PanelCyberPanel  PanelType = "cyberpanel"
	PanelHestia      PanelType = "hestia"
	PanelVesta       PanelType = "vesta"
	PanelCWP         PanelType = "cwp"
	PanelInterWorx   PanelType = "interworx"
)

// Panel directory paths (exported for use by switchop and services packages).
const (
	PathDirectAdmin = "/usr/local/directadmin"
	PathCPanel      = "/usr/local/cpanel"
	PathPlesk       = "/usr/local/psa"
	PathCyberPanel  = "/usr/local/CyberCP"
	PathHestia      = "/usr/local/hestia"
	PathVesta       = "/usr/local/vesta"
	PathCWP         = "/usr/local/cwpsrv"
	PathInterWorx   = "/usr/local/interworx"
)

// panelChecks maps directory paths to panel types.
// Order matches the shell %post detection priority (directadmin first).
var panelChecks = []struct {
	dir   string
	panel PanelType
}{
	{PathDirectAdmin, PanelDirectAdmin},
	{PathCPanel, PanelCPanel},
	{PathPlesk, PanelPlesk},
	{PathCyberPanel, PanelCyberPanel},
	{PathHestia, PanelHestia},
	{PathVesta, PanelVesta},
	{PathCWP, PanelCWP},
	{PathInterWorx, PanelInterWorx},
}

// DetectPanel checks for installed control panels by directory existence.
// Returns PanelNone if no panel is detected.
func DetectPanel(exec executor.Executor, log *logging.Logger) PanelType {
	for _, check := range panelChecks {
		if exec.FileExists(check.dir) {
			log.Detect("panel", "type", string(check.panel))
			log.Detect("panel", "path", check.dir)
			// Check cPHulk (cPanel brute force) if cPanel detected
			if check.panel == PanelCPanel && exec.ServiceActive("cphulkd.service") {
				log.Detect("panel", "cphulk", "active")
			}
			return check.panel
		}
	}
	log.Detect("panel", "type", "none")
	return PanelNone
}

// HasPanel returns true if any panel was detected.
func HasPanel(panel PanelType) bool {
	return panel != PanelNone
}
