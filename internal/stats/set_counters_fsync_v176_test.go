// =============================================================================
// NFTBan v1.176 — FSYNC-RESIDUAL F-1 regression test (set_counts.json)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="set-counters-fsync-v176-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-12"
// meta:description="Locks v1.176 FSYNC-RESIDUAL F-1: WriteCacheFile persists set_counts.json via safety.SafeWriteFile (durable temp+fsync+atomic rename) — valid JSON round-trip, perms 0640, and NO leftover temp residue (no torn-write). The 'no raw os.WriteFile(tmp)+Rename' property is locked separately by fsync_residual_guard_v176_test.sh. Hermetic: t.TempDir, no root."
// meta:inventory.files="internal/stats/set_counters.go,internal/safety/file.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package stats

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestWriteCacheFile_DurableRoundTrip_F1(t *testing.T) {
	dir := t.TempDir()
	sc := NewSetCounters(dir)
	sc.Add("blacklist_ipv4", 7)
	sc.Add("blacklist_ipv6", 3)
	sc.cacheDirty.Store(true) // ensure the debounced writer runs

	if err := sc.WriteCacheFile(); err != nil {
		t.Fatalf("WriteCacheFile: %v", err)
	}

	cacheFile := filepath.Join(dir, "set_counts.json")
	data, err := os.ReadFile(cacheFile)
	if err != nil {
		t.Fatalf("read set_counts.json: %v", err)
	}
	var snap map[string]any
	if err := json.Unmarshal(data, &snap); err != nil {
		t.Fatalf("set_counts.json is not valid JSON (torn write?): %v", err)
	}

	// Perms preserved at 0640 (group-readable for the nftban shell consumers).
	fi, err := os.Stat(cacheFile)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0640 {
		t.Fatalf("set_counts.json perm = %o, want 0640", perm)
	}

	// No leftover temp residue from the atomic write (old .tmp or safe-write temp).
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	for _, e := range ents {
		n := e.Name()
		if n == "set_counts.json" {
			continue
		}
		if filepath.Ext(n) == ".tmp" || (len(n) > 0 && n[0] == '.') {
			t.Fatalf("unexpected temp residue after atomic write: %s", n)
		}
	}
}
