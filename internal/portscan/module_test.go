// =============================================================================
// NFTBan v1.0 - Port Scan Detection Module Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for portscan config parsing"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package portscan

import (
	"testing"
	"time"
)

// newTestModule creates a Module without calling nftbanconf.MustLoad() so
// tests can run without production configuration files.
func newTestModule() *Module {
	return &Module{
		config: portscanConfig{
			Enabled:      true,
			Mode:         "auto",
			BanThreshold: 3,
			BanDuration:  30 * time.Minute,
			TrackWindow:  5 * time.Minute,
		},
		mode:    "auto",
		enabled: true,
	}
}

// =============================================================================
// parseMainConfig Tests
// =============================================================================

func TestParseMainConfig_Enabled(t *testing.T) {
	m := newTestModule()

	m.parseMainConfig("PORTSCAN_ENABLED=true")
	if !m.config.Enabled {
		t.Error("expected Enabled=true")
	}

	m.parseMainConfig("PORTSCAN_ENABLED=false")
	if m.config.Enabled {
		t.Error("expected Enabled=false")
	}
}

func TestParseMainConfig_Mode(t *testing.T) {
	m := newTestModule()

	m.parseMainConfig("PORTSCAN_MODE=classic")
	if m.config.Mode != "classic" {
		t.Errorf("expected mode %q, got %q", "classic", m.config.Mode)
	}

	m.parseMainConfig("PORTSCAN_MODE=suricata")
	if m.config.Mode != "suricata" {
		t.Errorf("expected mode %q, got %q", "suricata", m.config.Mode)
	}

	m.parseMainConfig("PORTSCAN_MODE=hybrid")
	if m.config.Mode != "hybrid" {
		t.Errorf("expected mode %q, got %q", "hybrid", m.config.Mode)
	}
}

func TestParseMainConfig_MultipleSettings(t *testing.T) {
	m := newTestModule()

	content := `# Portscan module config
PORTSCAN_ENABLED=true
PORTSCAN_MODE=classic
`

	m.parseMainConfig(content)

	if !m.config.Enabled {
		t.Error("expected Enabled=true")
	}
	if m.config.Mode != "classic" {
		t.Errorf("expected mode %q, got %q", "classic", m.config.Mode)
	}
}

func TestParseMainConfig_SkipsComments(t *testing.T) {
	m := newTestModule()

	content := `# This is a comment
# PORTSCAN_ENABLED=false
PORTSCAN_ENABLED=true
`

	m.parseMainConfig(content)

	if !m.config.Enabled {
		t.Error("expected Enabled=true (comment should be skipped)")
	}
}

func TestParseMainConfig_SkipsEmptyLines(t *testing.T) {
	m := newTestModule()

	content := `

PORTSCAN_MODE=suricata

`

	m.parseMainConfig(content)

	if m.config.Mode != "suricata" {
		t.Errorf("expected mode %q, got %q", "suricata", m.config.Mode)
	}
}

func TestParseMainConfig_StripsQuotes(t *testing.T) {
	m := newTestModule()

	m.parseMainConfig(`PORTSCAN_MODE="classic"`)
	if m.config.Mode != "classic" {
		t.Errorf("expected mode %q (double-quoted), got %q", "classic", m.config.Mode)
	}

	m.parseMainConfig(`PORTSCAN_MODE='hybrid'`)
	if m.config.Mode != "hybrid" {
		t.Errorf("expected mode %q (single-quoted), got %q", "hybrid", m.config.Mode)
	}
}

func TestParseMainConfig_InvalidLine(t *testing.T) {
	m := newTestModule()
	original := m.config.Mode

	// Lines without = should be ignored
	m.parseMainConfig("PORTSCAN_MODE_NO_EQUALS")

	if m.config.Mode != original {
		t.Errorf("expected mode unchanged, got %q", m.config.Mode)
	}
}

// =============================================================================
// parseModeConfig Tests
// =============================================================================

func TestParseModeConfig_ClassicThresholds(t *testing.T) {
	m := newTestModule()

	content := `PORTSCAN_CLASSIC_MIN_PORTS=10
PORTSCAN_CLASSIC_TIME_WINDOW=300
PORTSCAN_CLASSIC_BAN_DEFAULT=3600
`

	m.parseModeConfig(content)

	if m.config.BanThreshold != 10 {
		t.Errorf("expected BanThreshold=10, got %d", m.config.BanThreshold)
	}
	if m.config.TrackWindow != 300*time.Second {
		t.Errorf("expected TrackWindow=300s, got %v", m.config.TrackWindow)
	}
	if m.config.BanDuration != 3600*time.Second {
		t.Errorf("expected BanDuration=3600s, got %v", m.config.BanDuration)
	}
}

func TestParseModeConfig_SuricataBanDuration(t *testing.T) {
	m := newTestModule()

	content := `PORTSCAN_SURICATA_BAN_DURATION_SHORT=600`

	m.parseModeConfig(content)

	if m.config.BanDuration != 600*time.Second {
		t.Errorf("expected BanDuration=600s, got %v", m.config.BanDuration)
	}
}

func TestParseModeConfig_InvalidValues(t *testing.T) {
	m := newTestModule()
	original := m.config.BanThreshold

	// Invalid integer should be ignored
	m.parseModeConfig("PORTSCAN_CLASSIC_MIN_PORTS=not_a_number")

	if m.config.BanThreshold != original {
		t.Errorf("expected BanThreshold unchanged at %d, got %d", original, m.config.BanThreshold)
	}
}

func TestParseModeConfig_SkipsComments(t *testing.T) {
	m := newTestModule()

	content := `# PORTSCAN_CLASSIC_MIN_PORTS=999
PORTSCAN_CLASSIC_MIN_PORTS=5
`

	m.parseModeConfig(content)

	if m.config.BanThreshold != 5 {
		t.Errorf("expected BanThreshold=5 (comment skipped), got %d", m.config.BanThreshold)
	}
}

// =============================================================================
// Module Constants Tests
// =============================================================================

func TestModuleConstants(t *testing.T) {
	if ModuleName != "portscan" {
		t.Errorf("ModuleName = %q, want %q", ModuleName, "portscan")
	}
	if ModuleVersion != "1.0.0" {
		t.Errorf("ModuleVersion = %q, want %q", ModuleVersion, "1.0.0")
	}
	if DefaultCheckInterval != 60*time.Second {
		t.Errorf("DefaultCheckInterval = %v, want 60s", DefaultCheckInterval)
	}
}

// =============================================================================
// Module.Name() Tests
// =============================================================================

func TestModule_Name(t *testing.T) {
	m := newTestModule()
	if m.Name() != "portscan" {
		t.Errorf("Name() = %q, want %q", m.Name(), "portscan")
	}
}
