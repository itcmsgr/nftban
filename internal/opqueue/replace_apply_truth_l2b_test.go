// =============================================================================
// NFTBan - L2b replace_set apply-truth (REPLACE-PARTIAL-SILENT + OPQUEUE_PER_ELEMENT_APPLY_RESULT)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/replace_apply_truth_l2b_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="L2b: proves the replace_set apply result is truth-bearing — reported_applied == actually_applied and partial_apply != success. Mocks NetlinkBackend to force a mid-replace shortfall and asserts FlushResult.Err is set, Applied is the true count, Intended is preserved, WasReplace stays true, the success onFlush callback does not fire, and QueueStats.ReplacePartialFailures increments. Hermetic; no real nft/netlink/root."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Invariant under test (the whole point of L2b):
//
//	reported_applied == actually_applied     // the count returned is the count really added
//	reported_success == (applied == intended) // success only when everything applied
//	partial_apply     != success              // a flushed-then-short replace is an ERROR, not success
//
// Before L2b, applyReplace/AddElements swallowed per-element/batch failures and returned a
// success-shaped partial count with a nil error, hiding a fail-open (blocklist short of intended).
// =============================================================================

package opqueue

import (
	"errors"
	"fmt"
	"testing"
)

// mockPartialBackend is a truth-bearing NetlinkBackend that accepts at most acceptLimit
// elements total (acceptLimit < 0 = accept all) and reports the REAL applied count + an
// error on any shortfall — exactly the contract the real wrapper now honors.
type mockPartialBackend struct {
	acceptLimit int // total elements it will accept across all AddElements calls; <0 = unlimited
	flushErr    error
	accepted    int      // elements actually accepted (ground truth)
	added       []string // values actually accepted
	flushed     bool
}

func (m *mockPartialBackend) FlushSet(table, set string) error {
	if m.flushErr != nil {
		return m.flushErr
	}
	m.flushed = true
	return nil
}

func (m *mockPartialBackend) AddElements(table, set string, els []SetElement) (int, error) {
	applied := 0
	var firstErr error
	for _, e := range els {
		if m.acceptLimit >= 0 && m.accepted >= m.acceptLimit {
			if firstErr == nil {
				firstErr = fmt.Errorf("simulated add failure for %s", e.Value)
			}
			continue
		}
		m.accepted++
		m.added = append(m.added, e.Value)
		applied++
	}
	if applied < len(els) {
		return applied, fmt.Errorf("mock applied %d of %d: %w", applied, len(els), firstErr)
	}
	return applied, nil
}

func (m *mockPartialBackend) DeleteElements(table, set string, els []SetElement) error { return nil }
func (m *mockPartialBackend) GetSetElements(table, set string) ([]string, error)        { return nil, nil }

// ReplaceSet models the ATOMIC contract: it applies either ALL elements or NONE.
// A configured flush failure, or an inability to accept every element (acceptLimit
// exceeded), records nothing and returns an error — never a partial state. This
// mirrors the single-transaction netlink primitive (flush+add+one commit).
func (m *mockPartialBackend) ReplaceSet(table, set string, els []SetElement) error {
	if m.flushErr != nil {
		return m.flushErr
	}
	if m.acceptLimit >= 0 && len(els) > m.acceptLimit {
		return fmt.Errorf("simulated atomic replace failure: cannot accept %d elements (limit %d)", len(els), m.acceptLimit)
	}
	m.flushed = true
	m.accepted = len(els)
	m.added = m.added[:0]
	for _, e := range els {
		m.added = append(m.added, e.Value)
	}
	return nil
}

func replaceElements(n int) []string {
	els := make([]string, n)
	for i := 0; i < n; i++ {
		// TEST-NET-3 (203.0.113.0/24) space, unique via a second octet.
		els[i] = fmt.Sprintf("203.0.113.%d/32", i%254+1)
	}
	return els
}

func flushReplace(backend NetlinkBackend, setName string, n, batchSize int) FlushResult {
	buf := newSetBuffer(setName)
	buf.replaceOp = &SetOp{Type: OpReplaceSet, Elements: replaceElements(n)}
	return buf.flush(backend, batchSize, nil)
}

// --- Invariant 1: reported_applied == actually_applied (atomic → 0 on failure) ---
// Under the atomic netlink primitive a replacement is all-or-nothing, so a backend
// that cannot accept every element applies NOTHING; reported still equals actual.
func TestReplaceApplyTruth_ReportedAppliedEqualsActuallyApplied(t *testing.T) {
	m := &mockPartialBackend{acceptLimit: 150} // < 250 → atomic replace applies none
	res := flushReplace(m, "blacklist_ipv4", 250, 100)

	if res.Applied != m.accepted {
		t.Fatalf("reported_applied(%d) != actually_applied(%d)", res.Applied, m.accepted)
	}
	if res.Applied != len(m.added) {
		t.Fatalf("reported_applied(%d) != len(added)(%d)", res.Applied, len(m.added))
	}
	if res.Applied != 0 {
		t.Fatalf("atomic replace on a rejecting backend must apply 0, got %d", res.Applied)
	}
	if res.Err == nil {
		t.Fatal("atomic replace that could not commit must report Err (no success-shaped result)")
	}
}

// --- Invariant 2: a failed replace is NOT success and leaves NO partial state ---
func TestReplaceApplyTruth_PartialApplyIsNotSuccess(t *testing.T) {
	m := &mockPartialBackend{acceptLimit: 150}
	res := flushReplace(m, "blacklist_ipv4", 250, 100)

	if res.Err == nil {
		t.Fatal("failed replace reported success (Err == nil) — this is the fail-open bug")
	}
	if res.Intended != 250 {
		t.Fatalf("Intended=%d, want 250", res.Intended)
	}
	if res.Applied != 0 {
		t.Fatalf("atomic replace is all-or-nothing: Applied(%d) must be 0 on failure", res.Applied)
	}
	if !res.WasReplace {
		t.Fatal("WasReplace must stay true even on a failed replace")
	}
}

// --- Invariant 3: full success is unchanged (Err nil, applied == intended) ---
func TestReplaceApplyTruth_FullSuccessUnchanged(t *testing.T) {
	m := &mockPartialBackend{acceptLimit: -1} // accept all
	res := flushReplace(m, "blacklist_ipv6", 250, 100)

	if res.Err != nil {
		t.Fatalf("full success must have nil Err, got %v", res.Err)
	}
	if res.Applied != 250 || res.Intended != 250 {
		t.Fatalf("full success: Applied=%d Intended=%d, want 250/250", res.Applied, res.Intended)
	}
	if !res.WasReplace {
		t.Fatal("WasReplace must be true")
	}
	if res.Applied != m.accepted {
		t.Fatalf("reported_applied(%d) != actually_applied(%d)", res.Applied, m.accepted)
	}
}

// --- Invariant 3b: zero-applied is degraded, not success-shaped ---
func TestReplaceApplyTruth_ZeroAppliedIsDegradedNotSuccess(t *testing.T) {
	m := &mockPartialBackend{acceptLimit: 0} // flush ok, every add fails
	res := flushReplace(m, "blacklist_ipv4", 100, 50)

	if res.Applied != 0 {
		t.Fatalf("Applied=%d, want 0", res.Applied)
	}
	if res.Err == nil {
		t.Fatal("zero-applied replace must be degraded (Err != nil), not success")
	}
	if res.Intended != 100 {
		t.Fatalf("Intended=%d, want 100", res.Intended)
	}
}

// --- Flush failure keeps failing (old -1 sentinel folded into an error) ---
func TestReplaceApplyTruth_FlushFailureSurfaced(t *testing.T) {
	m := &mockPartialBackend{flushErr: errors.New("flush boom")}
	res := flushReplace(m, "blacklist_ipv4", 100, 50)

	if res.Err == nil {
		t.Fatal("flush failure must surface as Err")
	}
	if res.Applied != 0 {
		t.Fatalf("Applied=%d, want 0 on flush failure", res.Applied)
	}
}

// --- AddElements contract: reports the real shortfall instead of nil success ---
func TestAddElementsContract_ReportsPerElementShortfall(t *testing.T) {
	m := &mockPartialBackend{acceptLimit: 2}
	applied, err := m.AddElements("nftban", "blacklist_ipv4", []SetElement{
		{Value: "203.0.113.1"}, {Value: "203.0.113.2"}, {Value: "203.0.113.3"},
	})
	if applied != 2 {
		t.Fatalf("applied=%d, want 2 (actually accepted)", applied)
	}
	if err == nil {
		t.Fatal("AddElements must return an error when applied < len(elements)")
	}
}

// --- Counter + no-success-callback: a partial replace increments ReplacePartialFailures
//     and does NOT fire the success onFlush callback with the wrong short count. ---
func TestReplaceApplyTruth_CounterIncrementsAndNoSuccessCallback(t *testing.T) {
	cfg := DefaultQueueConfig()
	cfg.MaxBatchSize = 100

	// Partial replace → counter increments, success callback must NOT fire.
	mPartial := &mockPartialBackend{acceptLimit: 150}
	qp := NewOpQueue(mPartial, cfg)
	var partialCallbackFired bool
	qp.SetOnFlush(func(setName string, applied int, opType string) { partialCallbackFired = true })
	bufP := qp.getOrCreateBuffer("blacklist_ipv4")
	bufP.replaceOp = &SetOp{Type: OpReplaceSet, Elements: replaceElements(250)}
	qp.flushSetWithReenqueue("blacklist_ipv4")

	if got := qp.Stats().ReplacePartialFailures; got != 1 {
		t.Fatalf("ReplacePartialFailures=%d, want 1 after a partial replace", got)
	}
	if partialCallbackFired {
		t.Fatal("success onFlush callback fired for a PARTIAL replace (would report the wrong short count)")
	}

	// Full success → counter stays 0, success callback fires.
	mFull := &mockPartialBackend{acceptLimit: -1}
	qf := NewOpQueue(mFull, cfg)
	var fullCallbackFired bool
	qf.SetOnFlush(func(setName string, applied int, opType string) { fullCallbackFired = true })
	bufF := qf.getOrCreateBuffer("blacklist_ipv4")
	bufF.replaceOp = &SetOp{Type: OpReplaceSet, Elements: replaceElements(250)}
	qf.flushSetWithReenqueue("blacklist_ipv4")

	if got := qf.Stats().ReplacePartialFailures; got != 0 {
		t.Fatalf("ReplacePartialFailures=%d, want 0 on full success", got)
	}
	if !fullCallbackFired {
		t.Fatal("success onFlush callback must fire on a full replace")
	}
}
