// meta:name="generate_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 2 tests: deterministic no-timestamp render (no-churn), 5-state classification, validation rejects bad policy, Generate writes then no-churn on rerun, Remove (rollback) durably deletes. Uses in-memory FS seams so no real systemd/disk is touched."
package healthresource

import (
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/safety"
)

// installMemFS swaps the package FS seams for an in-memory map; returns a restore.
func installMemFS(t *testing.T) map[string][]byte {
	t.Helper()
	fs := map[string][]byte{}
	owr, ord, omk, orm := writeDurable, readFile, mkdirAll, removeFile
	writeDurable = func(path string, data []byte, _ os.FileMode) error {
		cp := make([]byte, len(data))
		copy(cp, data)
		fs[path] = cp
		return nil
	}
	readFile = func(path string) ([]byte, error) {
		if b, ok := fs[path]; ok {
			return b, nil
		}
		return nil, os.ErrNotExist
	}
	mkdirAll = func(string, os.FileMode) error { return nil }
	removeFile = func(path string) error {
		if _, ok := fs[path]; !ok {
			return os.ErrNotExist
		}
		delete(fs, path)
		return nil
	}
	t.Cleanup(func() { writeDurable, readFile, mkdirAll, removeFile = owr, ord, omk, orm })
	return fs
}

func mediumProfile() safety.HealthResourceProfile {
	p := safety.ServerProfile{TotalRAM: 6 << 30, AvailRAM: 3 << 30, CPUCores: 4}
	return safety.HealthServiceMemoryLimitsFor(p, safety.ClassifyResourceTier(p))
}

func TestRenderDeterministicNoTimestamp(t *testing.T) {
	p := mediumProfile()
	a := Render(p, "1.222.1")
	b := Render(p, "1.222.1")
	if string(a) != string(b) {
		t.Fatalf("Render not deterministic:\n%s\n---\n%s", a, b)
	}
	// Must carry the effective values and provenance; must NOT carry a timestamp.
	s := string(a)
	for _, want := range []string{"[Service]", "MemoryHigh=", "MemoryMax=", "tier=medium", "authority=internal/safety"} {
		if !strings.Contains(s, want) {
			t.Errorf("render missing %q:\n%s", want, s)
		}
	}
}

func TestValidateRejectsBadPolicy(t *testing.T) {
	base := mediumProfile()
	bad := []safety.HealthResourceProfile{
		{Tier: base.Tier, MemoryHigh: 0, MemoryMax: base.MemoryMax, TotalRAM: base.TotalRAM},
		{Tier: base.Tier, MemoryHigh: base.MemoryMax, MemoryMax: base.MemoryMax, TotalRAM: base.TotalRAM}, // High==Max
		{Tier: base.Tier, MemoryHigh: 10 << 20, MemoryMax: 100 << 20, TotalRAM: base.TotalRAM},            // Max<128MiB
		{Tier: "bogus", MemoryHigh: base.MemoryHigh, MemoryMax: base.MemoryMax, TotalRAM: base.TotalRAM},
	}
	for i, p := range bad {
		if err := Validate(p); err == nil {
			t.Errorf("case %d: Validate accepted invalid policy %+v", i, p)
		}
	}
	if err := Validate(base); err != nil {
		t.Errorf("valid medium policy rejected: %v", err)
	}
}

func tierProfile(totalRAM int64) safety.HealthResourceProfile {
	p := safety.ServerProfile{TotalRAM: totalRAM, AvailRAM: totalRAM / 2, CPUCores: 4}
	return safety.HealthServiceMemoryLimitsFor(p, safety.ClassifyResourceTier(p))
}

// The core owner rule: effective (not file presence) decides protection, and the
// packaged fallback (192/256 MiB) is FALLBACK_MATCH for small but UNDERSIZED for
// medium/large.
func TestClassifyEffectiveFallbackSemantics(t *testing.T) {
	const MiB = int64(1) << 20
	fbHigh, fbMax := 192*MiB, 256*MiB // packaged fallback

	small := tierProfile(2 << 30)  // calc 192/256
	medium := tierProfile(6 << 30) // calc 256/384
	large := tierProfile(16 << 30) // calc 384/512

	// Small: fallback already meets calc → FALLBACK_MATCH (protected), even w/o drop-in.
	if s := ClassifyEffective(small, fbHigh, fbMax, false); s != StateFallbackMatch || !s.ProtectionActive() {
		t.Errorf("small fallback: got %s protected=%v want FALLBACK_MATCH/true", s, s.ProtectionActive())
	}
	// Small with the drop-in loaded at calc values → ACTIVE_MATCH.
	if s := ClassifyEffective(small, small.MemoryHigh, small.MemoryMax, true); s != StateActiveMatch {
		t.Errorf("small active: got %s want ACTIVE_MATCH", s)
	}
	// Medium under the packaged fallback → FALLBACK_UNDERSIZED (NOT protected).
	if s := ClassifyEffective(medium, fbHigh, fbMax, false); s != StateFallbackUnder || s.ProtectionActive() {
		t.Errorf("medium fallback: got %s protected=%v want FALLBACK_UNDERSIZED/false", s, s.ProtectionActive())
	}
	// Medium with the drop-in effective at calc values → ACTIVE_MATCH (protected).
	if s := ClassifyEffective(medium, medium.MemoryHigh, medium.MemoryMax, true); s != StateActiveMatch || !s.ProtectionActive() {
		t.Errorf("medium active: got %s want ACTIVE_MATCH/protected", s)
	}
	// Large under the packaged fallback → FALLBACK_UNDERSIZED.
	if s := ClassifyEffective(large, fbHigh, fbMax, false); s != StateFallbackUnder {
		t.Errorf("large fallback: got %s want FALLBACK_UNDERSIZED", s)
	}
	// A drop-in present but effective values stale/below calc (activation failed) → not ACTIVE_MATCH.
	if s := ClassifyEffective(large, fbHigh, fbMax, true); s.ProtectionActive() {
		t.Errorf("large drop-in-loaded-but-ineffective must NOT be protected, got %s", s)
	}
}

func TestClassifyStates(t *testing.T) {
	d := Render(mediumProfile(), "1.222.1")
	if Classify(nil, d) != StateAbsent {
		t.Error("nil existing must be ABSENT")
	}
	if Classify(d, d) != StateActiveMatch {
		t.Error("equal bytes must be ACTIVE_MATCH")
	}
	if Classify([]byte("different"), d) != StateStaleMismatch {
		t.Error("differing bytes must be STALE_MISMATCH")
	}
}

func TestGenerateNoChurn(t *testing.T) {
	fs := installMemFS(t)
	r1, err := Generate("1.222.1")
	if err != nil {
		t.Fatalf("first Generate: %v", err)
	}
	if r1.State != StateReadyGen || !r1.Changed {
		t.Fatalf("first Generate state=%s changed=%v want READY_GENERATED/true", r1.State, r1.Changed)
	}
	if _, ok := fs[DropinFile]; !ok {
		t.Fatal("drop-in not written")
	}
	r2, err := Generate("1.222.1")
	if err != nil {
		t.Fatalf("second Generate: %v", err)
	}
	if r2.State != StateActiveMatch || r2.Changed {
		t.Errorf("second Generate state=%s changed=%v want ACTIVE_MATCH/false (no-churn)", r2.State, r2.Changed)
	}
}

func TestRemoveRollback(t *testing.T) {
	fs := installMemFS(t)
	if _, err := Generate("1.222.1"); err != nil {
		t.Fatal(err)
	}
	changed, err := Remove()
	if err != nil || !changed {
		t.Fatalf("Remove got changed=%v err=%v want true/nil", changed, err)
	}
	if _, ok := fs[DropinFile]; ok {
		t.Error("drop-in not removed on rollback")
	}
	changed, err = Remove()
	if err != nil || changed {
		t.Errorf("second Remove got changed=%v err=%v want false/nil (idempotent)", changed, err)
	}
}
