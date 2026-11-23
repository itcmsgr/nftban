// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package validator

// v1.238 VAL-GEOBAN-001 (BUG-VALIDATOR-GEOBAN-FINDING-NAMES-NONEXISTENT-SYNC): the GeoBan
// database finding must name a command that exists. `nftban geoban sync` is not a verb (it
// printed help, rc 1); the database is refreshed by `nftban geoip update`.

import (
	"strings"
	"testing"
)

func TestGeobanFindingRemediationNamesExistingCommand(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="true"`,
	})
	defer cleanup()
	restore := withDataDir(t, t.TempDir()) // DB missing -> finding
	defer restore()

	moduleFindings = nil
	_ = evaluateBlacklist(buildDoc(nil, nil))
	found := false
	for _, f := range moduleFindings {
		if f.Code != CodeGeobanDBMissing {
			continue
		}
		found = true
		if strings.Contains(f.Remediation, "geoban sync") {
			t.Errorf("remediation names the nonexistent command: %q", f.Remediation)
		}
		if f.Remediation != "Run: nftban geoip update" {
			t.Errorf("remediation = %q, want %q", f.Remediation, "Run: nftban geoip update")
		}
	}
	if !found {
		t.Fatal("expected the GeoBan database finding")
	}
}
