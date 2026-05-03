// =============================================================================
// NFTBan v1.102.0 - PR-P1: restore must NOT call ServiceResetFailed (#524)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-restore-engine-pr-p1-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-03"
// meta:description="Asserts no file in internal/installer/restore/ calls ServiceResetFailed. Restore re-arming watchdog state is out of scope per Amendment 1 §31; PR-P1 reset-failed is takeover-only."
// meta:inventory.files="internal/installer/restore/engine_pr_p1_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package restore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRestore_DoesNotCallServiceResetFailed locks in the PR-P1 invariant:
// the restore package must never invoke executor.ServiceResetFailed. The
// reset-failed call clears systemd's `failed (Result: signal)` cosmetic
// marker after takeover masks a service. Restore goes the OTHER way
// (unmask + re-enable + re-start) and is bound by Amendment 1 §31:
// re-arming the watchdog (lfd=OFF → lfd=ON) is NOT authorized in
// restore. By symmetry, restore must not clear-marker either, since
// that is the takeover-side hygiene of a unit takeover just tore down.
//
// This is a pure source-grep test: it walks every .go file under the
// restore/ package and fails if any non-test file references the
// ServiceResetFailed identifier. This is intentionally static and
// independent of mock execution paths so the invariant cannot be
// silently broken by adding a new restore code path that bypasses
// the mock.
func TestRestore_DoesNotCallServiceResetFailed(t *testing.T) {
	const forbidden = "ServiceResetFailed"

	pkgDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	// pkgDir is .../internal/installer/restore — walk it.

	var hits []string

	err = filepath.WalkDir(pkgDir, func(path string, d os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		// Only .go files, excluding test files (test files MAY mention
		// the identifier in this comment block / for the negative
		// assertion, and that is fine).
		name := d.Name()
		if !strings.HasSuffix(name, ".go") {
			return nil
		}
		if strings.HasSuffix(name, "_test.go") {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		if strings.Contains(string(data), forbidden) {
			rel, _ := filepath.Rel(pkgDir, path)
			hits = append(hits, rel)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}

	if len(hits) > 0 {
		t.Errorf("restore package must NOT reference %s — Amendment 1 §31 / PR-P1 invariant. Found in: %v",
			forbidden, hits)
	}
}
