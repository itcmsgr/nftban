// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package validator

// v1.238 D1/D2: health reads the DDoS / PortScan / BotGuard switches like every other reader —
// base < module .local < central nftban.conf.local, last definition, module truth table.

import "testing"

func TestReadModuleSwitchUnifiedRule(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/ddos/main.conf":       `DDOS_ENABLED="false"`,
		"conf.d/ddos/main.conf.local": "DDOS_ENABLED=\"no\"\nDDOS_ENABLED=\"yes\"",
	})
	defer cleanup()
	if got := readModuleSwitch("conf.d/ddos/main.conf", "DDOS_ENABLED"); got != ConfigEnabled {
		t.Fatalf("module .local last line yes -> want enabled, got %v", got)
	}
	cleanup2 := setupTestConfig(t, map[string]string{
		"conf.d/ddos/main.conf.local": `DDOS_ENABLED="yes"`,
		"nftban.conf.local":           `DDOS_ENABLED="false"`,
	})
	defer cleanup2()
	if got := readModuleSwitch("conf.d/ddos/main.conf", "DDOS_ENABLED"); got != ConfigDisabled {
		t.Fatalf("explicit central false must win, got %v", got)
	}
}
