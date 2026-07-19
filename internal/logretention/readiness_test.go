// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-readiness-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="DELTA-L1 readiness verdict matrix: proves an install can be COMMITTED only when a VALID ACTIVE policy exists — generated (state hash matches => READY_GENERATED) or valid bounded fallback (valid file, no matching state => READY_FALLBACK) — and every no-valid-policy condition (missing/empty/not-regular/wrong-mode/logrotate-invalid/unresolved-journal/hash-drift) yields NOT_READY so the installer verdict becomes DEGRADED (INSTALL_COMMITTED_FALSE_CLEAN = IMPOSSIBLE)."
// meta:inventory.files="internal/logretention/readiness.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none (temp dir only)"
package logretention

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

var errFail = errors.New("invalid candidate")

func okV(_ []string) (string, error) { return "ok", nil }

func writePolicy(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeStateFor(t *testing.T, statePath, policyPath string) {
	t.Helper()
	gs := GeneratedState{ActivePolicyHashes: map[string]string{"nftban": hashFileOrEmpty(policyPath)}}
	data, _ := json.MarshalIndent(gs, "", "  ")
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestReadiness_GeneratedActive(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	s := filepath.Join(d, "state.json")
	writePolicy(t, p, "bans.log { daily }\n")
	writeStateFor(t, s, p)
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: s, Validator: okV})
	if r.Verdict != ReadyGenerated || r.PolicySource != "generated" || !r.Ready() {
		t.Fatalf("want READY_GENERATED, got %+v", r)
	}
}

func TestReadiness_FallbackActive_NoState(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	writePolicy(t, p, "bans.log { daily }\n")
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "absent.json"), Validator: okV})
	if r.Verdict != ReadyFallback || r.PolicySource != "fallback" || !r.SelfHealPending || !r.Ready() {
		t.Fatalf("want READY_FALLBACK, got %+v", r)
	}
}

func TestReadiness_FallbackActive_UnparseableState(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	s := filepath.Join(d, "state.json")
	writePolicy(t, p, "bans.log { daily }\n")
	_ = os.WriteFile(s, []byte("{not json"), 0o644)
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: s, Validator: okV})
	if r.Verdict != ReadyFallback || !r.Ready() {
		t.Fatalf("want READY_FALLBACK on unparseable state, got %+v", r)
	}
}

func TestReadiness_NotReady_Missing(t *testing.T) {
	d := t.TempDir()
	r := Readiness(ReadinessOptions{MainPath: filepath.Join(d, "nope"), StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("missing file must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_Empty(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	writePolicy(t, p, "")
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("empty file must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_NotRegular(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	if err := os.MkdirAll(p, 0o755); err != nil { // a directory, not a file
		t.Fatal(err)
	}
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("non-regular must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_WrongMode(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	writePolicy(t, p, "bans.log { daily }\n")
	if err := os.Chmod(p, 0o600); err != nil {
		t.Fatal(err)
	}
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("wrong mode must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_InvalidPolicy(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	writePolicy(t, p, "garbage { not valid\n")
	failV := func(_ []string) (string, error) { return "logrotate -d", errFail }
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: failV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("logrotate-invalid must be NOT_READY, got %+v", r)
	}
	if r.ValidationResult == "valid" {
		t.Error("validation result should carry the failure")
	}
}

func TestReadiness_NotReady_HashDrift(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	s := filepath.Join(d, "state.json")
	writePolicy(t, p, "bans.log { daily }\n")
	writeStateFor(t, s, p)
	// now hand-edit the active file so it no longer matches the recorded state
	writePolicy(t, p, "bans.log { weekly } # operator hand-edit\n")
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: s, Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("state-present hash-drift must be NOT_READY (not masquerade as ready), got %+v", r)
	}
}

func TestReadiness_NotReady_UnresolvedJournal(t *testing.T) {
	d := t.TempDir()
	etc := filepath.Join(d, "logrotate.d")
	p := filepath.Join(etc, "nftban")
	writePolicy(t, p, "bans.log { daily }\n")
	// plant an UNRECOVERABLE journal: a SPLIT where target p is already NEW but its
	// backup is gone (can't roll back), and a second target is OLD with its
	// candidate gone (can't roll forward). Recover() can do neither -> it errors,
	// the journal remains, PendingActivation stays true.
	staging := stagingDirFor(p)
	if err := os.MkdirAll(staging, 0o700); err != nil {
		t.Fatal(err)
	}
	q := filepath.Join(etc, "nftban-suricata")
	j := activationJournal{Version: activationJournalVersion, Entries: []journalEntry{
		{Target: p, CandidatePath: filepath.Join(staging, "gone-p.cand"), CandidateHash: hashFileOrEmpty(p),
			BackupPath: backupPathFor(staging, p), PrevHash: "backup-is-gone"}, // NEW, no backup -> can't roll back
		{Target: q, CandidatePath: filepath.Join(staging, "gone-q.cand"), CandidateHash: "neverlanded",
			BackupPath: backupPathFor(staging, q), PrevHash: ""}, // OLD, candidate gone -> can't roll forward
	}}
	data, _ := json.MarshalIndent(j, "", "  ")
	_ = os.WriteFile(journalPathIn(staging), data, 0o600)
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("unresolved journal must be NOT_READY, got %+v", r)
	}
}
