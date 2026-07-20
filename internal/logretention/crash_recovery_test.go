// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-crash-recovery-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Z1 crash-injection tests: simulate a process crash (no in-process rollback runs) at every rename boundary of the two-file activation by hand-constructing the exact on-disk state (durable journal present + partial renames + surviving candidates/backups), then assert Recover() drives the set to a UNIFORM all-new or all-old outcome, removes the journal, and cleans staging — proving there is no eventual-consistency-only window."
// meta:depends="crypto/sha256,encoding/json,os,path/filepath,testing"
// meta:inventory.files="internal/logretention/crash_recovery_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none (temp dir only)"
package logretention

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func hashOf(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func writeFileT(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// crashScene lays out a target dir + staging dir + journal representing a crash
// at a chosen boundary, and returns the main target path.
type crashScene struct {
	mainPath, suriPath string
	stagingDir         string
	oldMain, newMain   string
	oldSuri, newSuri   string
}

func newScene(t *testing.T) *crashScene {
	t.Helper()
	etc := filepath.Join(t.TempDir(), "etc", "logrotate.d")
	sc := &crashScene{
		mainPath: filepath.Join(etc, "nftban"),
		suriPath: filepath.Join(etc, "nftban-suricata"),
		oldMain:  "OLD-MAIN\n",
		newMain:  "NEW-MAIN\n",
		oldSuri:  "OLD-SURI\n",
		newSuri:  "NEW-SURI\n",
	}
	sc.stagingDir = stagingDirFor(sc.mainPath)
	if err := os.MkdirAll(sc.stagingDir, 0o700); err != nil {
		t.Fatal(err)
	}
	return sc
}

// journalEntries builds the two-entry journal for main+suri. prevMainExisted /
// prevSuriExisted control PrevHash ("" means the target did not exist before).
func (sc *crashScene) entries(prevMainExisted, prevSuriExisted bool) []journalEntry {
	pm, ps := "", ""
	if prevMainExisted {
		pm = hashOf(sc.oldMain)
	}
	if prevSuriExisted {
		ps = hashOf(sc.oldSuri)
	}
	return []journalEntry{
		{
			Target:        sc.mainPath,
			CandidatePath: filepath.Join(sc.stagingDir, "main.cand"),
			CandidateHash: hashOf(sc.newMain),
			BackupPath:    backupPathFor(sc.stagingDir, sc.mainPath),
			PrevHash:      pm,
		},
		{
			Target:        sc.suriPath,
			CandidatePath: filepath.Join(sc.stagingDir, "suri.cand"),
			CandidateHash: hashOf(sc.newSuri),
			BackupPath:    backupPathFor(sc.stagingDir, sc.suriPath),
			PrevHash:      ps,
		},
	}
}

func (sc *crashScene) writeJournal(t *testing.T, entries []journalEntry) {
	t.Helper()
	j := activationJournal{Version: activationJournalVersion, CreatedAt: "test", Entries: entries}
	data, err := json.MarshalIndent(j, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	writeFileT(t, journalPathIn(sc.stagingDir), string(data))
}

func fileContent(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return "\x00ABSENT"
	}
	return string(b)
}

func assertUniformNew(t *testing.T, sc *crashScene) {
	t.Helper()
	if got := fileContent(sc.mainPath); got != sc.newMain {
		t.Errorf("main not NEW after recovery: %q", got)
	}
	if got := fileContent(sc.suriPath); got != sc.newSuri {
		t.Errorf("suri not NEW after recovery: %q", got)
	}
}

func assertUniformOld(t *testing.T, sc *crashScene, mainExisted, suriExisted bool) {
	t.Helper()
	wantMain := "\x00ABSENT"
	if mainExisted {
		wantMain = sc.oldMain
	}
	wantSuri := "\x00ABSENT"
	if suriExisted {
		wantSuri = sc.oldSuri
	}
	if got := fileContent(sc.mainPath); got != wantMain {
		t.Errorf("main not OLD after rollback: %q want %q", got, wantMain)
	}
	if got := fileContent(sc.suriPath); got != wantSuri {
		t.Errorf("suri not OLD after rollback: %q want %q", got, wantSuri)
	}
}

func assertCleaned(t *testing.T, sc *crashScene) {
	t.Helper()
	if PendingActivation(sc.mainPath) {
		t.Error("journal still present after recovery")
	}
	entries, err := os.ReadDir(sc.stagingDir)
	if err == nil && len(entries) != 0 {
		t.Errorf("staging not cleaned: %d entries remain", len(entries))
	}
}

// B0: journal written, NO target renamed yet (both old, both candidates staged).
func TestRecover_B0_beforeAnyRename_rollsForward(t *testing.T) {
	sc := newScene(t)
	writeFileT(t, sc.mainPath, sc.oldMain)
	writeFileT(t, sc.suriPath, sc.oldSuri)
	writeFileT(t, filepath.Join(sc.stagingDir, "main.cand"), sc.newMain)
	writeFileT(t, filepath.Join(sc.stagingDir, "suri.cand"), sc.newSuri)
	sc.writeJournal(t, sc.entries(true, true))

	res, err := Recover(sc.mainPath)
	if err != nil {
		t.Fatal(err)
	}
	if res.Action != RecoverRolledFwd {
		t.Fatalf("action = %q, want %q", res.Action, RecoverRolledFwd)
	}
	assertUniformNew(t, sc)
	assertCleaned(t, sc)
}

// B1: crash AFTER main activated, BEFORE suricata — the classic split.
func TestRecover_B1_splitMidActivation_rollsForward(t *testing.T) {
	sc := newScene(t)
	writeFileT(t, sc.mainPath, sc.newMain)                               // main already swapped
	writeFileT(t, backupPathFor(sc.stagingDir, sc.mainPath), sc.oldMain) // main backup survives
	writeFileT(t, sc.suriPath, sc.oldSuri)                               // suri still old
	writeFileT(t, filepath.Join(sc.stagingDir, "suri.cand"), sc.newSuri) // suri candidate still staged
	sc.writeJournal(t, sc.entries(true, true))

	res, err := Recover(sc.mainPath)
	if err != nil {
		t.Fatal(err)
	}
	if res.FromState != "split" {
		t.Errorf("FromState = %q, want split", res.FromState)
	}
	if res.Action != RecoverRolledFwd {
		t.Fatalf("action = %q, want %q", res.Action, RecoverRolledFwd)
	}
	assertUniformNew(t, sc)
	assertCleaned(t, sc)
}

// B2: crash AFTER both activated, BEFORE journal removal — finalize only.
func TestRecover_B2_bothActivated_finalizes(t *testing.T) {
	sc := newScene(t)
	writeFileT(t, sc.mainPath, sc.newMain)
	writeFileT(t, sc.suriPath, sc.newSuri)
	writeFileT(t, backupPathFor(sc.stagingDir, sc.mainPath), sc.oldMain)
	writeFileT(t, backupPathFor(sc.stagingDir, sc.suriPath), sc.oldSuri)
	sc.writeJournal(t, sc.entries(true, true))

	res, err := Recover(sc.mainPath)
	if err != nil {
		t.Fatal(err)
	}
	if res.Action != RecoverAlreadyWhole {
		t.Fatalf("action = %q, want %q", res.Action, RecoverAlreadyWhole)
	}
	assertUniformNew(t, sc)
	assertCleaned(t, sc)
}

// Split where the pending target's candidate is LOST -> must roll BACK to old.
func TestRecover_split_candidateLost_rollsBack(t *testing.T) {
	sc := newScene(t)
	writeFileT(t, sc.mainPath, sc.newMain)                               // main new
	writeFileT(t, backupPathFor(sc.stagingDir, sc.mainPath), sc.oldMain) // main backup present
	writeFileT(t, sc.suriPath, sc.oldSuri)                               // suri old
	// suri.cand intentionally NOT written (lost)
	sc.writeJournal(t, sc.entries(true, true))

	res, err := Recover(sc.mainPath)
	if err != nil {
		t.Fatal(err)
	}
	if res.Action != RecoverRolledBack {
		t.Fatalf("action = %q, want %q", res.Action, RecoverRolledBack)
	}
	assertUniformOld(t, sc, true, true)
	assertCleaned(t, sc)
}

// Roll-back that must REMOVE a brand-new target (PrevHash == "" — did not exist).
func TestRecover_split_newTarget_rollsBackByRemoval(t *testing.T) {
	sc := newScene(t)
	writeFileT(t, sc.mainPath, sc.newMain) // main freshly created, no pre-image
	writeFileT(t, sc.suriPath, sc.oldSuri) // suri old
	// suri.cand lost -> can't roll forward
	sc.writeJournal(t, sc.entries(false, true)) // main PrevHash="" (did not exist)

	res, err := Recover(sc.mainPath)
	if err != nil {
		t.Fatal(err)
	}
	if res.Action != RecoverRolledBack {
		t.Fatalf("action = %q, want %q", res.Action, RecoverRolledBack)
	}
	assertUniformOld(t, sc, false, true) // main should be REMOVED
	assertCleaned(t, sc)
}

// Idempotence + no-journal: second Recover is a clean no-op.
func TestRecover_idempotentAndNoJournal(t *testing.T) {
	sc := newScene(t)
	writeFileT(t, sc.mainPath, sc.oldMain)
	writeFileT(t, sc.suriPath, sc.oldSuri)
	writeFileT(t, filepath.Join(sc.stagingDir, "main.cand"), sc.newMain)
	writeFileT(t, filepath.Join(sc.stagingDir, "suri.cand"), sc.newSuri)
	sc.writeJournal(t, sc.entries(true, true))

	if _, err := Recover(sc.mainPath); err != nil {
		t.Fatal(err)
	}
	res, err := Recover(sc.mainPath)
	if err != nil {
		t.Fatal(err)
	}
	if res.JournalFound || res.Action != RecoverNone {
		t.Fatalf("second Recover not a no-op: found=%v action=%q", res.JournalFound, res.Action)
	}
}
