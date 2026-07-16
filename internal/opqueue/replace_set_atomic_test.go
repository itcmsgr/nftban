// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/replace_set_atomic_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Proves the opqueue replace_set and flush_source paths route through the atomic ReplaceSet primitive and NEVER call the separately-committing FlushSet()/AddElements(). A recording backend asserts: applyReplace → exactly one ReplaceSet, zero FlushSet/AddElements; flush_source → one ReplaceSet (explicit atomic flush); atomic failure preserves old state (Applied==0). Hermetic; no nft/netlink/root."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package opqueue

import (
	"errors"
	"testing"
)

// recordingBackend counts every backend call so we can prove the replace/flush
// paths use ReplaceSet exclusively (no standalone committed flush + later adds).
type recordingBackend struct {
	replaceCalls  int
	flushSetCalls int
	addCalls      int
	deleteCalls   int
	lastReplace   []SetElement
	replaceErr    error
}

func (b *recordingBackend) FlushSet(table, set string) error {
	b.flushSetCalls++
	return nil
}
func (b *recordingBackend) AddElements(table, set string, e []SetElement) (int, error) {
	b.addCalls++
	return len(e), nil
}
func (b *recordingBackend) DeleteElements(table, set string, e []SetElement) error {
	b.deleteCalls++
	return nil
}
func (b *recordingBackend) GetSetElements(table, set string) ([]string, error) { return nil, nil }
func (b *recordingBackend) ReplaceSet(table, set string, e []SetElement) error {
	b.replaceCalls++
	b.lastReplace = e
	return b.replaceErr
}

// NO_STANDALONE_FLUSHSET_IN_APPLY_REPLACE + applyReplace → ReplaceSet.
func TestApplyReplace_RoutesThroughReplaceSetOnly(t *testing.T) {
	b := &recordingBackend{}
	buf := newSetBuffer("geoban_ipv4")
	buf.replaceOp = &SetOp{Type: OpReplaceSet, Elements: []string{"192.0.2.1", "192.0.2.2"}}

	res := buf.flush(b, 100, nil)

	if b.replaceCalls != 1 {
		t.Fatalf("applyReplace must call ReplaceSet exactly once, got %d", b.replaceCalls)
	}
	if b.flushSetCalls != 0 {
		t.Fatalf("applyReplace must NOT call the standalone FlushSet(), got %d", b.flushSetCalls)
	}
	if b.addCalls != 0 {
		t.Fatalf("applyReplace must NOT call the standalone AddElements(), got %d", b.addCalls)
	}
	if !res.WasReplace || res.Applied != 2 || res.Intended != 2 {
		t.Fatalf("replace result wrong: WasReplace=%v Applied=%d Intended=%d", res.WasReplace, res.Applied, res.Intended)
	}
	if len(b.lastReplace) != 2 {
		t.Fatalf("ReplaceSet must receive the full element set, got %d", len(b.lastReplace))
	}
}

// FLUSH_SOURCE_ATOMIC — the flush path routes through ReplaceSet (explicit atomic
// flush), never a standalone committed FlushSet().
func TestFlushSource_RoutesThroughReplaceSet(t *testing.T) {
	b := &recordingBackend{}
	buf := newSetBuffer("geoban_ipv4")
	buf.enqueue(&SetOp{Type: OpFlushSet})

	res := buf.flush(b, 100, nil)

	if b.replaceCalls != 1 {
		t.Fatalf("flush_source must call ReplaceSet exactly once, got %d", b.replaceCalls)
	}
	if b.flushSetCalls != 0 {
		t.Fatalf("flush_source must NOT call the standalone FlushSet(), got %d", b.flushSetCalls)
	}
	if b.addCalls != 0 {
		t.Fatalf("flush_source must NOT call the standalone AddElements(), got %d", b.addCalls)
	}
	if !res.WasFlush {
		t.Fatalf("flush result must set WasFlush")
	}
	if len(b.lastReplace) != 0 {
		t.Fatalf("a pure flush_source must be an EMPTY atomic replacement, got %d elements", len(b.lastReplace))
	}
}

// Atomic failure preserves old state: Applied==0, error surfaced, WasReplace kept.
func TestApplyReplace_AtomicFailurePreservesOldState(t *testing.T) {
	b := &recordingBackend{replaceErr: errors.New("netlink commit boom")}
	buf := newSetBuffer("geoban_ipv4")
	buf.replaceOp = &SetOp{Type: OpReplaceSet, Elements: []string{"192.0.2.1", "192.0.2.2", "192.0.2.3"}}

	res := buf.flush(b, 100, nil)

	if res.Err == nil {
		t.Fatal("atomic replace failure must surface as result.Err")
	}
	if res.Applied != 0 {
		t.Fatalf("atomic replace is all-or-nothing: Applied must be 0 on failure, got %d", res.Applied)
	}
	if !res.WasReplace {
		t.Fatal("WasReplace must stay true on a failed replace")
	}
	if res.Intended != 3 {
		t.Fatalf("Intended must be preserved (3), got %d", res.Intended)
	}
}
