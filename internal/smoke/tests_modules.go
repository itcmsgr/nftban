// =============================================================================
// NFTBan - Smoke Framework: Module-Aware Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="smoke-tests-modules"
// meta:type="package"
// meta:version="1.95.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Module-gated smoke tests — SKIP when module disabled, not FAIL"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package smoke

import "time"

// ModuleTests returns the Phase 2 module-aware smoke test set.
// Each test is gated on module_enabled prerequisite — SKIP if disabled.
// These do NOT claim enforcement or protection — only that commands run
// and produce contract-safe output.
func ModuleTests() []SmokeTest {
	return []SmokeTest{
		// === DDoS ===
		{
			ID:       "MOD-DDOS-001",
			Name:     "ddos status",
			Category: "modules",
			Module:   "ddos",
			Command:  []string{"nftban", "ddos", "status"},
			AllowedExit: []int{0, 1, 2},
			Timeout:     10 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: PrereqBinary, Name: "nftban"},
				{Type: PrereqModuleEnabled, Name: "ddos"},
			},
			FatalPatterns: DefaultFatalPatterns,
			Assertions: []Assertion{
				AssertNoFatalPatterns(DefaultFatalPatterns),
			},
			Notes: "DDoS status must not crash when module is enabled",
		},

		// === Portscan ===
		{
			ID:       "MOD-PSCAN-001",
			Name:     "portscan status",
			Category: "modules",
			Module:   "portscan",
			Command:  []string{"nftban", "portscan", "status"},
			AllowedExit: []int{0, 1, 2},
			Timeout:     10 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: PrereqBinary, Name: "nftban"},
				{Type: PrereqModuleEnabled, Name: "portscan"},
			},
			FatalPatterns: DefaultFatalPatterns,
			Assertions: []Assertion{
				AssertNoFatalPatterns(DefaultFatalPatterns),
			},
			Notes: "Portscan status must not crash when module is enabled",
		},

		// === BotGuard ===
		{
			ID:       "MOD-BOTGUARD-001",
			Name:     "botguard status",
			Category: "modules",
			Module:   "botguard",
			Command:  []string{"nftban", "botguard", "status"},
			AllowedExit: []int{0, 1, 2},
			Timeout:     10 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: PrereqBinary, Name: "nftban"},
				{Type: PrereqModuleEnabled, Name: "botguard"},
			},
			FatalPatterns: DefaultFatalPatterns,
			Assertions: []Assertion{
				AssertNoFatalPatterns(DefaultFatalPatterns),
			},
			Notes: "BotGuard status must not crash when module is enabled",
		},

		// === LoginMon ===
		{
			ID:       "MOD-LOGIN-001",
			Name:     "login status",
			Category: "modules",
			Module:   "loginmon",
			Command:  []string{"nftban", "login", "status"},
			AllowedExit: []int{0, 1, 2},
			Timeout:     10 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: PrereqBinary, Name: "nftban"},
				{Type: PrereqModuleEnabled, Name: "login"},
				{Type: PrereqDaemonRunning, Name: "nftband.service"},
			},
			FatalPatterns: DefaultFatalPatterns,
			Assertions: []Assertion{
				AssertNoFatalPatterns(DefaultFatalPatterns),
			},
			Notes: "LoginMon status must not crash when module is enabled and daemon running",
		},
	}
}
