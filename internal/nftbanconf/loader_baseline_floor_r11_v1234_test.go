// =============================================================================
// NFTBan - R-11 NFTBAN_BASELINE_TCP_IN loader presence semantics (v1.234)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftbanconf_loader_baseline_floor_r11_v1234_test"
// meta:type="package"
// meta:version="1.234.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-29"
// meta:description="R-11: the inbound-floor key must record PRESENCE, so an administrator's empty value (remove 80/443) is distinguishable from an absent key (package default), in both nftban.conf and the nftban.conf.local overlay."
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbanconf

import "testing"

func TestR11BaselineFloorKey_AbsentIsNotSet(t *testing.T) {
	cfg, err := loadFromFile(writeConf(t, "NFTBAN_LOG_LEVEL=info\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.BaselineTCPInSet {
		t.Fatal("absent key must not be reported as set")
	}
}

func TestR11BaselineFloorKey_EmptyIsSet(t *testing.T) {
	cfg, err := loadFromFile(writeConf(t, "NFTBAN_BASELINE_TCP_IN=\"\"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.BaselineTCPInSet || cfg.BaselineTCPIn != "" {
		t.Fatalf("empty value must be SET and empty (admin removal), got set=%v value=%q", cfg.BaselineTCPInSet, cfg.BaselineTCPIn)
	}
}

func TestR11BaselineFloorKey_LocalOverlayOverrides(t *testing.T) {
	cfg, err := loadFromFile(writeConf(t, "NFTBAN_LOG_LEVEL=info\n"))
	if err != nil {
		t.Fatal(err)
	}
	overlayFromFile(cfg, writeConf(t, "NFTBAN_BASELINE_TCP_IN=none\n"))
	if !cfg.BaselineTCPInSet || cfg.BaselineTCPIn != "none" {
		t.Fatalf("nftban.conf.local must carry the override, got set=%v value=%q", cfg.BaselineTCPInSet, cfg.BaselineTCPIn)
	}
}
