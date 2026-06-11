// =============================================================================
// NFTBan v1.171 - State-write atomicity (§4.2/§4.3): SafeWriteFile guarantees
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="atomic_write_v171_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-10"
// meta:description="v1.171 §4.2/§4.3: proves the atomic-write mechanism that the suricata sid-stats snapshot (cache.go), the safety state files (limits.go SaveProtectionState/FilterState/PermanentBans) and panel_loader.go now route through. A concurrent reader during repeated writes must NEVER observe a torn/partial file (atomic temp+fsync+rename), and no stray temp file may remain on success. Pre-v1.171 those sites used a plain os.WriteFile/os.Create which can yield truncated reads on crash/concurrent read."
// meta:input="None"
// meta:output="t.Fatal on torn read / stray temp"
// meta:depends="testing,os,sync,bytes,path/filepath"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	"bytes"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// TestSafeWriteFile_AtomicConcurrentRead asserts a reader concurrent with many
// writers NEVER sees a torn file: each non-empty read must be a uniform block
// (all 'A' or all 'B', same length) — a mixed/partial read would prove a
// non-atomic write. With temp+rename the reader only ever observes the old or
// the new complete inode.
func TestSafeWriteFile_AtomicConcurrentRead(t *testing.T) {
	dir := t.TempDir() // 0700, not world-writable → passes ValidateDirectory
	target := filepath.Join(dir, "state.json")

	const sz = 64 * 1024
	payA := bytes.Repeat([]byte("A"), sz)
	payB := bytes.Repeat([]byte("B"), sz)

	// seed so the first reads have a complete file
	if err := SafeWriteFile(target, payA, 0o644); err != nil {
		t.Fatalf("seed SafeWriteFile: %v", err)
	}

	var wg sync.WaitGroup
	stop := make(chan struct{})

	// writer: alternate A/B blocks
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 400; i++ {
			p := payA
			if i%2 == 1 {
				p = payB
			}
			if err := SafeWriteFile(target, p, 0o644); err != nil {
				t.Errorf("SafeWriteFile iter %d: %v", i, err)
				return
			}
		}
		close(stop)
	}()

	// reader: every non-empty read must be a uniform full-size block
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			b, err := os.ReadFile(target)
			if err != nil {
				// transient ENOENT is impossible with rename (old inode stays),
				// but tolerate it rather than flake; never a torn-content pass.
				continue
			}
			if len(b) == 0 {
				continue
			}
			if len(b) != sz {
				t.Errorf("torn read: len=%d (want %d) — non-atomic write", len(b), sz)
				return
			}
			c := b[0]
			if c != 'A' && c != 'B' {
				t.Errorf("torn read: first byte %q", c)
				return
			}
			if !bytes.Equal(b, bytes.Repeat([]byte{c}, sz)) {
				t.Errorf("torn read: mixed content block — non-atomic write")
				return
			}
		}
	}()

	wg.Wait()
}

// TestSafeWriteFile_NoStrayTempOnSuccess asserts the temp file is renamed away
// (no `.nftban-safe-*` leftover) after a successful write — the dir holds only
// the target.
func TestSafeWriteFile_NoStrayTempOnSuccess(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "state.json")
	if err := SafeWriteFile(target, []byte(`{"ok":true}`), 0o644); err != nil {
		t.Fatalf("SafeWriteFile: %v", err)
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(ents) != 1 || ents[0].Name() != "state.json" {
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		t.Fatalf("stray entries after atomic write: %v (want only state.json)", names)
	}
}
