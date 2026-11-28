// =============================================================================
// NFTBan - v1.238.2: an unmet explicit PortScan suricata intent keeps classic (RC row 11)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="nftbanconf_modeplan_intent_unmet_v1238_2"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-11-28"
// meta:description="v1.238.2 RC row 11 (EL9 enforcing): the shell resolver kept classic for an explicit PortScan suricata switch whose target was not ready, but ReadEffectiveMode read effective classic vs configured suricata as plan_contradicts_explicit_intent, the daemon loaded no mode and no detector ran. The kept-classic outcome is now accepted ONLY for portscan + configured suricata + effective classic + the contract field NFTBAN_PLAN_INTENT_UNMET; every other mismatch (no field, DDoS, the other direction) stays a contradiction, and a normal suricata plan is unchanged."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_PLAN_TARGET_GENERATION"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbanconf

import (
	"os"
	"path/filepath"
	"testing"
)

func writePlanFixture(t *testing.T, module, configured, effective, unmet string) (string, string) {
	t.Helper()
	cfg := t.TempDir()
	run := t.TempDir()
	key := "PORTSCAN_MODE"
	if module == "ddos" {
		key = "DDOS_MODE"
	}
	if err := os.MkdirAll(filepath.Join(cfg, "conf.d", module), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg, "conf.d", module, "main.conf"), []byte(key+"=\""+configured+"\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(run, "convergence-generation"), []byte("7\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := "NFTBAN_PLAN_MODULE=" + module + "\nNFTBAN_PLAN_ENABLED=true\nNFTBAN_PLAN_CONFIGURED_MODE=" + configured +
		"\nNFTBAN_PLAN_EFFECTIVE_MODE=" + effective + "\nNFTBAN_PLAN_RESOLUTION_BASIS=x\nNFTBAN_PLAN_BOUND_GENERATION=7\n"
	if unmet != "" {
		rec += "NFTBAN_PLAN_INTENT_UNMET=" + unmet + "\n"
	}
	if err := os.WriteFile(filepath.Join(run, "module-plan-"+module+".env.7"), []byte(rec), 0o640); err != nil {
		t.Fatal(err)
	}
	return cfg, run
}

func TestModePlanIntentUnmetKeptClassic_v1238_2(t *testing.T) {
	t.Setenv("NFTBAN_PLAN_TARGET_GENERATION", "")
	cases := []struct {
		name, module, configured, effective, unmet string
		wantMode, wantBasis                        string
	}{
		{"portscan suricata not ready, classic kept + field", "portscan", "suricata", "classic", "suricata_not_ready", "classic", BasisIntentUnmetKeptClassic},
		{"portscan suricata, classic, NO field -> contradiction", "portscan", "suricata", "classic", "", ModeUnknown, BasisContradiction},
		{"ddos is not covered -> contradiction", "ddos", "suricata", "classic", "suricata_not_ready", ModeUnknown, BasisContradiction},
		{"other direction is not covered -> contradiction", "portscan", "classic", "suricata", "suricata_not_ready", ModeUnknown, BasisContradiction},
		{"normal suricata plan unchanged", "portscan", "suricata", "suricata", "", "suricata", BasisCurrentPlan},
		{"normal classic plan unchanged", "portscan", "classic", "classic", "", "classic", BasisCurrentPlan},
	}
	for _, c := range cases {
		cfg, run := writePlanFixture(t, c.module, c.configured, c.effective, c.unmet)
		mode, basis := ReadEffectiveMode(c.module, cfg, run)
		if mode != c.wantMode || basis != c.wantBasis {
			t.Errorf("%s: got (%s, %s), want (%s, %s)", c.name, mode, basis, c.wantMode, c.wantBasis)
		}
	}
}
