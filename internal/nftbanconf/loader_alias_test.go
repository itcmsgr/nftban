// =============================================================================
// NFTBan - Tests for v1.103 PR-C3-C canonical/alias DDoS+Portscan handling
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftbanconf_loader_alias_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-05"
// meta:description="PR-C3-C: aliasState + setBoolAlias coverage for DDoS + Portscan in loadFromFile and overlayFromFile"
// meta:input="None"
// meta:output="None"
// meta:depends="testing,bytes,log,os,path/filepath,strings"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbanconf

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// captureLog redirects the standard logger output for the duration of fn and
// returns the captured bytes. Used to assert warnAliasConflict() behavior.
func captureLog(t *testing.T, fn func()) string {
	t.Helper()
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)
	fn()
	return buf.String()
}

func writeConf(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "nftban.conf")
	if err := os.WriteFile(p, []byte(body), 0644); err != nil {
		t.Fatalf("write conf: %v", err)
	}
	return p
}

// -----------------------------------------------------------------------------
// loadFromFile — DDoS
// -----------------------------------------------------------------------------

func TestLoadFromFile_DDoSAlias_CanonicalOnly(t *testing.T) {
	p := writeConf(t, "DDOS_ENABLED=\"true\"\n")
	out := captureLog(t, func() {
		cfg, err := loadFromFile(p)
		if err != nil {
			t.Fatalf("loadFromFile: %v", err)
		}
		if !cfg.DDoSEnabled {
			t.Errorf("DDoSEnabled = false, want true (canonical only)")
		}
	})
	if strings.Contains(out, "WARN") || strings.Contains(out, "conflicting") {
		t.Errorf("unexpected warn captured: %q", out)
	}
}

func TestLoadFromFile_DDoSAlias_PrefixedOnly(t *testing.T) {
	p := writeConf(t, "NFTBAN_DDOS_ENABLED=\"true\"\n")
	out := captureLog(t, func() {
		cfg, err := loadFromFile(p)
		if err != nil {
			t.Fatalf("loadFromFile: %v", err)
		}
		if !cfg.DDoSEnabled {
			t.Errorf("DDoSEnabled = false, want true (alias only)")
		}
	})
	if strings.Contains(out, "conflicting") {
		t.Errorf("unexpected conflict warn: %q", out)
	}
}

func TestLoadFromFile_DDoSAlias_BothSame(t *testing.T) {
	p := writeConf(t, "NFTBAN_DDOS_ENABLED=\"true\"\nDDOS_ENABLED=\"true\"\n")
	out := captureLog(t, func() {
		cfg, err := loadFromFile(p)
		if err != nil {
			t.Fatalf("loadFromFile: %v", err)
		}
		if !cfg.DDoSEnabled {
			t.Errorf("DDoSEnabled = false, want true")
		}
	})
	if strings.Contains(out, "conflicting") {
		t.Errorf("unexpected conflict warn for matching values: %q", out)
	}
}

func TestLoadFromFile_DDoSAlias_BothConflict_AliasFirst_CanonicalWins(t *testing.T) {
	// Alias appears before canonical; canonical must win.
	p := writeConf(t, "NFTBAN_DDOS_ENABLED=\"false\"\nDDOS_ENABLED=\"true\"\n")
	out := captureLog(t, func() {
		cfg, err := loadFromFile(p)
		if err != nil {
			t.Fatalf("loadFromFile: %v", err)
		}
		if !cfg.DDoSEnabled {
			t.Errorf("DDoSEnabled = false, want true (canonical wins)")
		}
	})
	if !strings.Contains(out, "conflicting") {
		t.Errorf("expected conflict warn, got: %q", out)
	}
	if !strings.Contains(out, "DDOS_ENABLED") || !strings.Contains(out, "NFTBAN_DDOS_ENABLED") {
		t.Errorf("warn missing key names: %q", out)
	}
}

func TestLoadFromFile_DDoSAlias_BothConflict_CanonicalFirst_AliasIgnored(t *testing.T) {
	// Canonical appears before alias; alias must NOT overwrite, but conflict warn emitted.
	p := writeConf(t, "DDOS_ENABLED=\"true\"\nNFTBAN_DDOS_ENABLED=\"false\"\n")
	out := captureLog(t, func() {
		cfg, err := loadFromFile(p)
		if err != nil {
			t.Fatalf("loadFromFile: %v", err)
		}
		if !cfg.DDoSEnabled {
			t.Errorf("DDoSEnabled = false, want true (canonical wins; alias must not overwrite)")
		}
	})
	if !strings.Contains(out, "conflicting") {
		t.Errorf("expected conflict warn, got: %q", out)
	}
}

func TestLoadFromFile_DDoSAlias_Neither_DefaultsFalse(t *testing.T) {
	// Neither key present — DDoSEnabled stays at default (false).
	p := writeConf(t, "NFTBAN_VERSION=\"1.0.0\"\n")
	cfg, err := loadFromFile(p)
	if err != nil {
		t.Fatalf("loadFromFile: %v", err)
	}
	if cfg.DDoSEnabled {
		t.Errorf("DDoSEnabled = true, want false (neither key set)")
	}
}

// -----------------------------------------------------------------------------
// loadFromFile — Portscan
// -----------------------------------------------------------------------------

func TestLoadFromFile_PortscanAlias_CanonicalOnly(t *testing.T) {
	p := writeConf(t, "PORTSCAN_ENABLED=\"true\"\n")
	out := captureLog(t, func() {
		cfg, err := loadFromFile(p)
		if err != nil {
			t.Fatalf("loadFromFile: %v", err)
		}
		if !cfg.PortscanEnabled {
			t.Errorf("PortscanEnabled = false, want true (canonical only)")
		}
	})
	if strings.Contains(out, "conflicting") {
		t.Errorf("unexpected warn: %q", out)
	}
}

func TestLoadFromFile_PortscanAlias_PrefixedOnly(t *testing.T) {
	p := writeConf(t, "NFTBAN_PORTSCAN_ENABLED=\"true\"\n")
	cfg, err := loadFromFile(p)
	if err != nil {
		t.Fatalf("loadFromFile: %v", err)
	}
	if !cfg.PortscanEnabled {
		t.Errorf("PortscanEnabled = false, want true (alias only)")
	}
}

func TestLoadFromFile_PortscanAlias_BothConflict_CanonicalWins(t *testing.T) {
	p := writeConf(t, "PORTSCAN_ENABLED=\"false\"\nNFTBAN_PORTSCAN_ENABLED=\"true\"\n")
	out := captureLog(t, func() {
		cfg, err := loadFromFile(p)
		if err != nil {
			t.Fatalf("loadFromFile: %v", err)
		}
		if cfg.PortscanEnabled {
			t.Errorf("PortscanEnabled = true, want false (canonical wins)")
		}
	})
	if !strings.Contains(out, "conflicting") {
		t.Errorf("expected conflict warn, got: %q", out)
	}
}

// -----------------------------------------------------------------------------
// overlayFromFile — DDoS + Portscan
// -----------------------------------------------------------------------------

func TestOverlayFromFile_DDoSAlias_CanonicalWins(t *testing.T) {
	p := writeConf(t, "NFTBAN_DDOS_ENABLED=\"false\"\nDDOS_ENABLED=\"true\"\n")
	cfg := defaultConfig()
	cfg.DDoSEnabled = false
	out := captureLog(t, func() {
		overlayFromFile(cfg, p)
	})
	if !cfg.DDoSEnabled {
		t.Errorf("DDoSEnabled = false, want true (canonical wins on overlay)")
	}
	if !strings.Contains(out, "conflicting") {
		t.Errorf("expected conflict warn on overlay, got: %q", out)
	}
}

func TestOverlayFromFile_PortscanAlias_AliasOnly(t *testing.T) {
	p := writeConf(t, "NFTBAN_PORTSCAN_ENABLED=\"true\"\n")
	cfg := defaultConfig()
	cfg.PortscanEnabled = false
	overlayFromFile(cfg, p)
	if !cfg.PortscanEnabled {
		t.Errorf("PortscanEnabled = false, want true (alias-only overlay)")
	}
}

func TestOverlayFromFile_DDoSAlias_PreservesIndependentInvocationState(t *testing.T) {
	// Alias state must be per-invocation. A first overlay with a conflict must
	// not bleed into a second overlay against the same Config.
	cfg := defaultConfig()

	p1 := writeConf(t, "DDOS_ENABLED=\"true\"\nNFTBAN_DDOS_ENABLED=\"false\"\n")
	out1 := captureLog(t, func() { overlayFromFile(cfg, p1) })
	if !cfg.DDoSEnabled {
		t.Errorf("after overlay-1: DDoSEnabled = false, want true")
	}
	if !strings.Contains(out1, "conflicting") {
		t.Errorf("overlay-1: expected conflict warn, got: %q", out1)
	}

	// Second file: only canonical; should not emit conflict warn (state reset).
	p2 := writeConf(t, "DDOS_ENABLED=\"false\"\n")
	out2 := captureLog(t, func() { overlayFromFile(cfg, p2) })
	if cfg.DDoSEnabled {
		t.Errorf("after overlay-2: DDoSEnabled = true, want false")
	}
	if strings.Contains(out2, "conflicting") {
		t.Errorf("overlay-2: unexpected conflict warn (state should be per-invocation): %q", out2)
	}
}

// -----------------------------------------------------------------------------
// Login is intentionally NOT aliased here — DEFER to Lane M / v1.104.
// This negative assertion documents the intent.
// -----------------------------------------------------------------------------

func TestLoadFromFile_LoginNotAliasedInC3C(t *testing.T) {
	// Bare LOGIN_ENABLED is NOT recognized by the central nftbanconf loader
	// in v1.103 (Login is structurally deferred to Lane M / v1.104).
	// Only NFTBAN_LOGIN_MONITOR_ENABLED still drives cfg.LoginMonitorEnabled.
	p := writeConf(t, "LOGIN_ENABLED=\"true\"\n")
	cfg, err := loadFromFile(p)
	if err != nil {
		t.Fatalf("loadFromFile: %v", err)
	}
	if cfg.LoginMonitorEnabled {
		t.Errorf("LoginMonitorEnabled = true, want false (LOGIN_ENABLED must NOT alias to LoginMonitorEnabled in v1.103; deferred to Lane M)")
	}
}
