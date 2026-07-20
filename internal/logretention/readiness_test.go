// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-readiness-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="DELTA-L1/L2/L3 readiness verdict matrix. L1: an install is COMMITTED only with a valid active policy (missing/empty/not-regular/wrong-mode/logrotate-invalid/unresolved-journal/hash-drift => NOT_READY). L2: READY_FALLBACK requires BYTE-IDENTITY to the approved shipped template AND boundedness — a valid-but-unrelated / unbounded / hand-edited policy is NOT_READY (FALLBACK_IDENTITY_MISMATCH). L3: READY_GENERATED covers the whole generated set — a missing/drifted/stale applicable suricata policy => NOT_READY."
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

// a bounded policy body (every stanza has `rotate`).
const boundedPolicy = "/var/log/nftban/bans.log {\n    daily\n    rotate 7\n    size 10M\n}\n"

// an UNBOUNDED policy body (no `rotate`).
const unboundedPolicy = "/var/log/nftban/bans.log {\n    daily\n    size 10M\n}\n"

func writeFileMode(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(path, mode)
}

func writePolicy(t *testing.T, path, content string) { writeFileMode(t, path, content, 0o644) }

// writeState writes a generated-state record with the given per-base hashes.
func writeState(t *testing.T, statePath string, hashes map[string]string) {
	t.Helper()
	gs := GeneratedState{ActivePolicyHashes: hashes}
	data, _ := json.MarshalIndent(gs, "", "  ")
	writeFileMode(t, statePath, string(data), 0o644)
}

func TestReadiness_GeneratedActive_NoSuricata(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	s := filepath.Join(d, "state.json")
	writePolicy(t, p, boundedPolicy)
	writeState(t, s, map[string]string{"nftban": sha256Hex([]byte(boundedPolicy))})
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: s, Validator: okV})
	if r.Verdict != ReadyGenerated || !r.MainHashMatch || r.SuricataApplicable {
		t.Fatalf("want READY_GENERATED (no suricata), got %+v", r)
	}
}

// ---- DELTA-L2: fallback identity ----

func TestReadiness_Fallback_ExactTemplate(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	tmpl := filepath.Join(d, "nftban.logrotate")
	writePolicy(t, tmpl, boundedPolicy)
	writePolicy(t, p, boundedPolicy) // verbatim copy of the template
	r := Readiness(ReadinessOptions{MainPath: p, TemplatePath: tmpl, StatePath: filepath.Join(d, "none"), Validator: okV})
	if r.Verdict != ReadyFallback || !r.FallbackIdentityMatch || !r.Ready() {
		t.Fatalf("want READY_FALLBACK on exact template, got %+v", r)
	}
}

func TestReadiness_NotReady_FallbackIdentityMismatch_Unrelated(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	tmpl := filepath.Join(d, "nftban.logrotate")
	writePolicy(t, tmpl, boundedPolicy)
	writePolicy(t, p, "/var/log/other.log {\n    weekly\n    rotate 4\n    size 5M\n}\n") // valid but NOT the template
	r := Readiness(ReadinessOptions{MainPath: p, TemplatePath: tmpl, StatePath: filepath.Join(d, "none"), Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("unrelated valid policy must be NOT_READY (identity mismatch), got %+v", r)
	}
}

func TestReadiness_NotReady_FallbackUnbounded(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	tmpl := filepath.Join(d, "nftban.logrotate")
	// template AND active are byte-identical but UNBOUNDED -> identity matches but
	// the boundedness guard fails.
	writePolicy(t, tmpl, unboundedPolicy)
	writePolicy(t, p, unboundedPolicy)
	r := Readiness(ReadinessOptions{MainPath: p, TemplatePath: tmpl, StatePath: filepath.Join(d, "none"), Validator: okV})
	if r.Verdict != NotReady || r.UnboundedStanzas == 0 {
		t.Fatalf("byte-identical-but-unbounded must be NOT_READY (unbounded=%d), got %+v", r.UnboundedStanzas, r)
	}
}

func TestReadiness_NotReady_HandEditedFallback(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	tmpl := filepath.Join(d, "nftban.logrotate")
	writePolicy(t, tmpl, boundedPolicy)
	writePolicy(t, p, boundedPolicy+"# operator hand-edit\n") // one byte off the template
	r := Readiness(ReadinessOptions{MainPath: p, TemplatePath: tmpl, StatePath: filepath.Join(d, "none"), Validator: okV})
	if r.Verdict != NotReady {
		t.Fatalf("hand-edited fallback must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_MissingTemplate(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	writePolicy(t, p, boundedPolicy)
	r := Readiness(ReadinessOptions{MainPath: p, TemplatePath: filepath.Join(d, "no-tmpl"), StatePath: filepath.Join(d, "none"), Validator: okV})
	if r.Verdict != NotReady {
		t.Fatalf("missing template must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_MalformedTemplate(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	tmpl := filepath.Join(d, "nftban.logrotate")
	writePolicy(t, p, boundedPolicy)
	writePolicy(t, tmpl, "") // empty template
	r := Readiness(ReadinessOptions{MainPath: p, TemplatePath: tmpl, StatePath: filepath.Join(d, "none"), Validator: okV})
	if r.Verdict != NotReady {
		t.Fatalf("empty/malformed template must be NOT_READY, got %+v", r)
	}
}

// ---- DELTA-L1 core NOT_READY cases ----

func TestReadiness_NotReady_Missing(t *testing.T) {
	d := t.TempDir()
	r := Readiness(ReadinessOptions{MainPath: filepath.Join(d, "nope"), StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady {
		t.Fatalf("missing file must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_Empty(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	writePolicy(t, p, "")
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady {
		t.Fatalf("empty file must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_WrongMode(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	writeFileMode(t, p, boundedPolicy, 0o600)
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady {
		t.Fatalf("wrong mode must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_InvalidPolicy(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	writePolicy(t, p, "garbage { not valid\n")
	failV := func(_ []string) (string, error) { return "logrotate -d", errFail }
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: failV})
	if r.Verdict != NotReady || r.ValidationResult == "valid" {
		t.Fatalf("logrotate-invalid must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_HashDrift(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "nftban")
	s := filepath.Join(d, "state.json")
	writePolicy(t, p, boundedPolicy)
	writeState(t, s, map[string]string{"nftban": sha256Hex([]byte(boundedPolicy))})
	writePolicy(t, p, boundedPolicy+"# drift\n") // no longer matches state
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: s, Validator: okV})
	if r.Verdict != NotReady {
		t.Fatalf("state-present hash-drift must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_UnresolvedJournal(t *testing.T) {
	d := t.TempDir()
	etc := filepath.Join(d, "logrotate.d")
	p := filepath.Join(etc, "nftban")
	writePolicy(t, p, boundedPolicy)
	staging := stagingDirFor(p)
	if err := os.MkdirAll(staging, 0o700); err != nil {
		t.Fatal(err)
	}
	q := filepath.Join(etc, "nftban-suricata")
	j := activationJournal{Version: activationJournalVersion, Entries: []journalEntry{
		{Target: p, CandidatePath: filepath.Join(staging, "gone-p.cand"), CandidateHash: hashFileOrEmpty(p),
			BackupPath: backupPathFor(staging, p), PrevHash: "backup-is-gone"},
		{Target: q, CandidatePath: filepath.Join(staging, "gone-q.cand"), CandidateHash: "neverlanded",
			BackupPath: backupPathFor(staging, q), PrevHash: ""},
	}}
	data, _ := json.MarshalIndent(j, "", "  ")
	_ = os.WriteFile(journalPathIn(staging), data, 0o600)
	r := Readiness(ReadinessOptions{MainPath: p, StatePath: filepath.Join(d, "s"), Validator: okV})
	if r.Verdict != NotReady {
		t.Fatalf("unresolved journal must be NOT_READY, got %+v", r)
	}
}

// ---- DELTA-L3: suricata generated-set coverage ----

const suriPolicy = "/var/log/nftban/suricata/eve-alerts.json {\n    daily\n    rotate 7\n    size 50M\n    copytruncate\n}\n"

func setupSuricataGenerated(t *testing.T) (main, suri, state string) {
	t.Helper()
	d := t.TempDir()
	main = filepath.Join(d, "nftban")
	suri = filepath.Join(d, "nftban-suricata")
	state = filepath.Join(d, "state.json")
	writePolicy(t, main, boundedPolicy)
	writePolicy(t, suri, suriPolicy)
	writeState(t, state, map[string]string{
		"nftban":          sha256Hex([]byte(boundedPolicy)),
		"nftban-suricata": sha256Hex([]byte(suriPolicy)),
	})
	return
}

func TestReadiness_Generated_SuricataMatch(t *testing.T) {
	main, suri, state := setupSuricataGenerated(t)
	r := Readiness(ReadinessOptions{MainPath: main, SuricataPath: suri, StatePath: state, Validator: okV})
	if r.Verdict != ReadyGenerated || !r.SuricataApplicable || !r.SuricataHashMatch {
		t.Fatalf("want READY_GENERATED with suricata match, got %+v", r)
	}
}

func TestReadiness_NotReady_SuricataDrift(t *testing.T) {
	main, suri, state := setupSuricataGenerated(t)
	writePolicy(t, suri, suriPolicy+"# drift\n") // suricata file no longer matches state
	r := Readiness(ReadinessOptions{MainPath: main, SuricataPath: suri, StatePath: state, Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("suricata drift must be NOT_READY (main matches), got %+v", r)
	}
}

func TestReadiness_NotReady_SuricataMissing(t *testing.T) {
	main, suri, state := setupSuricataGenerated(t)
	_ = os.Remove(suri) // state records suricata but the file is gone
	r := Readiness(ReadinessOptions{MainPath: main, SuricataPath: suri, StatePath: state, Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("applicable-but-missing suricata must be NOT_READY, got %+v", r)
	}
}

func TestReadiness_NotReady_StaleSuricata(t *testing.T) {
	d := t.TempDir()
	main := filepath.Join(d, "nftban")
	suri := filepath.Join(d, "nftban-suricata")
	state := filepath.Join(d, "state.json")
	writePolicy(t, main, boundedPolicy)
	writePolicy(t, suri, suriPolicy) // a live suricata policy exists
	// but the state records ONLY the main policy (suricata not part of generation)
	writeState(t, state, map[string]string{"nftban": sha256Hex([]byte(boundedPolicy))})
	r := Readiness(ReadinessOptions{MainPath: main, SuricataPath: suri, StatePath: state, Validator: okV})
	if r.Verdict != NotReady || r.Ready() {
		t.Fatalf("stale suricata policy must not be silently ignored (NOT_READY), got %+v", r)
	}
}
