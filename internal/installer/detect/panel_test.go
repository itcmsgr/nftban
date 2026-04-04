// =============================================================================
// NFTBan v1.73 - Installer Panel Detection Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-panel-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for control panel detection"
// meta:inventory.files="internal/installer/detect/panel_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package detect

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func TestDetectPanel_CPanel(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Dirs["/usr/local/cpanel"] = true

	panel := DetectPanel(mock, newTestLogger())
	if panel != PanelCPanel {
		t.Errorf("panel = %s, want cpanel", panel)
	}
}

func TestDetectPanel_DirectAdminPriority(t *testing.T) {
	// DirectAdmin is checked before cPanel
	mock := executor.NewMockExecutor()
	mock.Dirs["/usr/local/directadmin"] = true
	mock.Dirs["/usr/local/cpanel"] = true

	panel := DetectPanel(mock, newTestLogger())
	if panel != PanelDirectAdmin {
		t.Errorf("panel = %s, want directadmin (checked first)", panel)
	}
}

func TestDetectPanel_Plesk(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Dirs["/usr/local/psa"] = true

	panel := DetectPanel(mock, newTestLogger())
	if panel != PanelPlesk {
		t.Errorf("panel = %s, want plesk", panel)
	}
}

func TestDetectPanel_None(t *testing.T) {
	mock := executor.NewMockExecutor()
	panel := DetectPanel(mock, newTestLogger())
	if panel != PanelNone {
		t.Errorf("panel = %s, want empty (none)", panel)
	}
}

func TestDetectPanel_AllPanels(t *testing.T) {
	tests := []struct {
		dir  string
		want PanelType
	}{
		{"/usr/local/directadmin", PanelDirectAdmin},
		{"/usr/local/cpanel", PanelCPanel},
		{"/usr/local/psa", PanelPlesk},
		{"/usr/local/CyberCP", PanelCyberPanel},
		{"/usr/local/hestia", PanelHestia},
		{"/usr/local/vesta", PanelVesta},
		{"/usr/local/cwpsrv", PanelCWP},
		{"/usr/local/interworx", PanelInterWorx},
	}
	for _, tt := range tests {
		mock := executor.NewMockExecutor()
		mock.Dirs[tt.dir] = true
		panel := DetectPanel(mock, newTestLogger())
		if panel != tt.want {
			t.Errorf("dir=%s: panel = %s, want %s", tt.dir, panel, tt.want)
		}
	}
}

func TestHasPanel(t *testing.T) {
	if HasPanel(PanelNone) {
		t.Error("HasPanel(PanelNone) = true, want false")
	}
	if !HasPanel(PanelCPanel) {
		t.Error("HasPanel(PanelCPanel) = false, want true")
	}
}
