// =============================================================================
// NFTBan v1.100 Amendment 2 — Test helper: read source files for invariants
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-restore-decide-evidence-test-helper"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Filesystem reader for source-scan invariants (§56.3 / §56.4)"
// meta:inventory.files="cmd/nftban-installer/restore_decide_evidence_test_helper.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import "os"

// readFileImpl reads a file path relative to the test working
// directory. Used by the Amendment 2 source-scan invariant tests.
func readFileImpl(path string) ([]byte, error) {
	return os.ReadFile(path)
}
