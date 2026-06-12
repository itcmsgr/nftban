// =============================================================================
// NFTBan v1.176 — FSYNC-RESIDUAL F-2 regression test (rebuild recovery marker)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rebuild-marker-fsync-v176-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-12"
// meta:description="Locks v1.176 FSYNC-RESIDUAL F-2: RecoveryMarker.WriteTo persists via safety.SafeWriteFile (durable temp+fsync+atomic rename) — valid JSON round-trip and NO leftover temp residue. Broader write/read/clear behavior is covered by TestMarkerWriteReadClear. Hermetic: t.TempDir, no root."
// meta:inventory.files="internal/rebuild/marker.go,internal/safety/file.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package rebuild

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestMarkerWriteTo_DurableNoResidue_F2(t *testing.T) {
	dir := t.TempDir()
	stateDir := filepath.Join(dir, "state")
	path := filepath.Join(stateDir, "rebuild_recovery.json")

	m := NewMarker(ClassModuleRestoreIncomplete, ResultFailedDegraded)
	m.LastHealthState = "degraded"
	if err := m.WriteTo(path); err != nil {
		t.Fatalf("WriteTo: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read marker: %v", err)
	}
	var rt map[string]any
	if err := json.Unmarshal(data, &rt); err != nil {
		t.Fatalf("recovery marker is not valid JSON (torn write?): %v", err)
	}

	// No temp residue (old .tmp or safety-helper temp) left in the state dir.
	ents, err := os.ReadDir(stateDir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	for _, e := range ents {
		n := e.Name()
		if n == "rebuild_recovery.json" {
			continue
		}
		if filepath.Ext(n) == ".tmp" || (len(n) > 0 && n[0] == '.') {
			t.Fatalf("unexpected temp residue after atomic write: %s", n)
		}
	}
}
