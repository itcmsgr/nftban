// =============================================================================
// NFTBan v1.229.7 — Go mode-config-source authority (PR-4B)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="mode-config-source-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-24"
// meta:description="Proves the daemon selects its mode-specific config file from the published plan and never by re-resolving auto. The environment is rigged to disagree with the plan, so a loader that consults availability is caught; unknown must load NEITHER file rather than defaulting to classic."
// =============================================================================

package ddos

import (
	"os"
	"path/filepath"
	"testing"
)

// C1..C4 — THE DAEMON MUST NOT CHOOSE A MODE CONFIG FILE BY RE-RESOLVING AUTO.
//
// The motivating defect: loadConfig() ran from New() and read m.suricataAvail,
// which detectMode() does not assign until Init(). Its zero value made
// MODE=auto select classic.conf deterministically, and loadConfig() never
// re-ran. Because DDOS_CLASSIC_* and DDOS_SURICATA_* populate the SAME struct
// fields, an auto->suricata host ran on classic values.
func TestModeConfigSourceFollowsThePlan(t *testing.T) {
	for _, tc := range []struct {
		name, planEffective, wantFile string
		wantShort                     int // seconds; distinguishes which file was read
	}{
		{"C1 plan=classic  -> classic.conf", "classic", "classic.conf", 111},
		{"C2 plan=suricata -> suricata.conf", "suricata", "suricata.conf", 222},
		{"C3 plan=inactive -> neither", "inactive", "", 0},
		{"C4 no plan       -> neither (UNKNOWN must not guess classic)", "ABSENT", "", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfgDir, runDir := t.TempDir(), t.TempDir()
			modDir := filepath.Join(cfgDir, "conf.d", "ddos")
			if err := os.MkdirAll(modDir, 0o755); err != nil {
				t.Fatal(err)
			}
			write := func(p, s string) {
				if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			write(filepath.Join(modDir, "main.conf"), "DDOS_ENABLED=\"true\"\nDDOS_MODE=\"auto\"\n")
			// The two files carry DIFFERENT values for the SAME field, so which
			// one was read is observable rather than inferred.
			write(filepath.Join(modDir, "classic.conf"), "DDOS_CLASSIC_BAN_DURATION_SHORT=111\n")
			write(filepath.Join(modDir, "suricata.conf"), "DDOS_SURICATA_BAN_DURATION_SHORT=222\n")
			write(filepath.Join(runDir, "convergence-generation"), "4\n")
			if tc.planEffective != "ABSENT" {
				write(filepath.Join(runDir, "module-plan-ddos.env"),
					"NFTBAN_PLAN_MODULE=ddos\nNFTBAN_PLAN_CONFIGURED_MODE=auto\n"+
						"NFTBAN_PLAN_EFFECTIVE_MODE="+tc.planEffective+"\nNFTBAN_PLAN_BOUND_GENERATION=4\n")
			}

			m := New()
			// ⛔ Rig the environment to DISAGREE with the plan in every row. A
			// loader that consults availability instead of the plan is caught by
			// C1 (would pick suricata) and revealed by C3/C4 (would pick classic).
			m.suricataAvail = true
			m.config.Mode = "auto"
			m.config.BanDurationShort = 0

			m.loadModeConfig(cfgDir, runDir, modDir)

			if m.modeConfigSource != tc.wantFile {
				t.Fatalf("%s: loaded %q, want %q (basis=%s)", tc.name, m.modeConfigSource, tc.wantFile, m.modeConfigBasis)
			}
			got := int(m.config.BanDurationShort.Seconds())
			if got != tc.wantShort {
				t.Fatalf("%s: BanDurationShort=%ds, want %ds — the WRONG file's values were consumed",
					tc.name, got, tc.wantShort)
			}
		})
	}
}

// C5 — availability must not influence the choice at all. Same plan, opposite
// availability, identical outcome.
func TestModeConfigSourceIgnoresAvailability(t *testing.T) {
	run := func(avail bool) (string, int) {
		cfgDir, runDir := t.TempDir(), t.TempDir()
		modDir := filepath.Join(cfgDir, "conf.d", "ddos")
		_ = os.MkdirAll(modDir, 0o755)
		_ = os.WriteFile(filepath.Join(modDir, "main.conf"), []byte("DDOS_ENABLED=\"true\"\nDDOS_MODE=\"auto\"\n"), 0o644)
		_ = os.WriteFile(filepath.Join(modDir, "classic.conf"), []byte("DDOS_CLASSIC_BAN_DURATION_SHORT=111\n"), 0o644)
		_ = os.WriteFile(filepath.Join(modDir, "suricata.conf"), []byte("DDOS_SURICATA_BAN_DURATION_SHORT=222\n"), 0o644)
		_ = os.WriteFile(filepath.Join(runDir, "convergence-generation"), []byte("9\n"), 0o644)
		_ = os.WriteFile(filepath.Join(runDir, "module-plan-ddos.env"), []byte(
			"NFTBAN_PLAN_MODULE=ddos\nNFTBAN_PLAN_CONFIGURED_MODE=auto\n"+
				"NFTBAN_PLAN_EFFECTIVE_MODE=suricata\nNFTBAN_PLAN_BOUND_GENERATION=9\n"), 0o644)
		m := New()
		m.suricataAvail = avail
		m.config.Mode = "auto"
		m.config.BanDurationShort = 0
		m.loadModeConfig(cfgDir, runDir, modDir)
		return m.modeConfigSource, int(m.config.BanDurationShort.Seconds())
	}
	fT, vT := run(true)
	fF, vF := run(false)
	if fT != fF || vT != vF {
		t.Fatalf("C5 FAILED: availability changed the outcome (avail=true -> %s/%d, avail=false -> %s/%d) — the loader is still resolving",
			fT, vT, fF, vF)
	}
	if fT != "suricata.conf" {
		t.Fatalf("C5 FAILED: plan said suricata, loader chose %q", fT)
	}
}
