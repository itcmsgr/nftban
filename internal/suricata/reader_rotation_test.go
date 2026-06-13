// =============================================================================
// NFTBan v1.184.0 - Suricata EVE reader rotation tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="suricata_reader_rotation_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Tests for SURICATA-EVE-ROTATION-MISS: the EVE reader must re-sync after eve.json is rotated so alerts written post-rotate are not silently missed. Covers copytruncate (same inode truncated to 0 → offset past EOF → seek to start) and rename+create (path resolves to a new inode → reopen and read from start). Without reopenIfRotated the reader holds a stale offset/fd and sees 0 new alerts after logrotate."
//
// meta:inventory.files="reader_rotation_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package suricata

import (
	"os"
	"path/filepath"
	"testing"
)

const testAlertLine = `{"event_type":"alert","src_ip":"203.0.113.9","alert":{"signature_id":1}}` + "\n"

func newTestReader(t *testing.T, path string) *EveReader {
	t.Helper()
	r, err := NewEveReader(path, NewFilterMatcher(&Config{}))
	if err != nil {
		t.Fatalf("NewEveReader: %v", err)
	}
	return r
}

// TestEveReader_ReopenOnCopytruncate: logrotate copytruncate empties the same inode; the
// reader's offset is now past EOF. reopenIfRotated must seek to start so the new alert is read.
func TestEveReader_ReopenOnCopytruncate(t *testing.T) {
	p := filepath.Join(t.TempDir(), "eve.json")
	if err := os.WriteFile(p, []byte(`{"event_type":"stats"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := newTestReader(t, p) // seeks to end of the stats line
	defer r.Close()

	// logrotate copytruncate empties the inode...
	if err := os.Truncate(p, 0); err != nil {
		t.Fatal(err)
	}
	// ...a poll tick observes the shrink (size 0 < our offset) and seeks to start...
	r.reopenIfRotated()
	// ...then the app writes fresh events into the truncated file.
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(testAlertLine); err != nil {
		t.Fatal(err)
	}
	f.Close()

	r.reopenIfRotated() // file now grew past offset 0 → no-op
	ev, err := r.ReadEvent()
	if err != nil {
		t.Fatalf("ReadEvent: %v", err)
	}
	if ev == nil {
		t.Fatal("expected the post-copytruncate alert to be read; got nil (rotation missed)")
	}
	if ev.SrcIP != "203.0.113.9" {
		t.Errorf("SrcIP=%q want 203.0.113.9", ev.SrcIP)
	}
}

// TestEveReader_ReopenOnRename: logrotate rename+create swaps in a new inode at the same
// path. reopenIfRotated must reopen the path and read the fresh file from the start.
func TestEveReader_ReopenOnRename(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "eve.json")
	if err := os.WriteFile(p, []byte(`{"event_type":"stats"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := newTestReader(t, p)
	defer r.Close()

	if err := os.Rename(p, p+".1"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(testAlertLine), 0o644); err != nil {
		t.Fatal(err)
	}

	r.reopenIfRotated()
	ev, err := r.ReadEvent()
	if err != nil {
		t.Fatalf("ReadEvent: %v", err)
	}
	if ev == nil {
		t.Fatal("expected the post-rename alert to be read; got nil (rotation missed)")
	}
}

// TestEveReader_NoRotationNoReopen: without rotation, reopenIfRotated is a no-op and normal
// tailing still works (no spurious re-read of already-consumed lines).
func TestEveReader_NoRotationNoReopen(t *testing.T) {
	p := filepath.Join(t.TempDir(), "eve.json")
	if err := os.WriteFile(p, []byte(`{"event_type":"stats"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := newTestReader(t, p)
	defer r.Close()

	// Append a new alert (normal tailing — same inode, growing file).
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(testAlertLine); err != nil {
		t.Fatal(err)
	}
	f.Close()

	r.reopenIfRotated() // no rotation → must not reset offset
	ev, err := r.ReadEvent()
	if err != nil {
		t.Fatalf("ReadEvent: %v", err)
	}
	if ev == nil {
		t.Fatal("expected the appended alert to be read during normal tailing")
	}
}
